`timescale 1ns/1ps
`default_nettype none

// Load-time, align-corners bilinear scaling. Coordinates are exact rational
// accumulators: x*(width-1)/639, y*(height-1)/479; fractional weights are Q8.
// Two synchronous source-line RAMs retain adjacent rows. Input is stopped while
// they are in use; intervening downsampled rows can overwrite them safely.
// Output rows follow FILE order. The frame store alone reverses bottom-up BMPs.
module bilinear_scaler (
    input wire clk, rst, start, cancel,
    input wire [12:0] width, height,
    input wire [23:0] source_data,
    input wire source_valid,
    output wire source_ready,
    output reg [31:0] pixel_data,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg done
);
    localparam [3:0] IDLE=0, LOAD=1, ROW_CHECK=2, LEFT=3, RIGHT=4,
                     CAPTURE=5, H_TOP=6, H_BOTTOM=7, V_BLEND=8,
                     SEND=9, X_STEP=10, Y_STEP=11;
    reg [3:0] state;
    reg [12:0] w, h, input_x, input_y, loaded_rows, sx, sy;
    reg [12:0] x_rem, y_rem;
    reg [9:0] out_x;
    reg [8:0] out_y;
    reg [1:0] channel;
    reg [23:0] p00, p01, p10, p11;
    reg [15:0] h0, h1;
    wire [12:0] sx_next = (sx + 13'd1 < w) ? sx + 13'd1 : sx;
    wire [12:0] sy_next = (sy + 13'd1 < h) ? sy + 13'd1 : sy;
    wire [11:0] read_addr = (state == RIGHT) ? sx_next[11:0] : sx[11:0];
    wire [23:0] line0, line1;
    wire source_take = source_valid && source_ready;
    assign source_ready = !rst && !cancel && (state == LOAD);
    assign pixel_valid = !rst && !cancel && (state == SEND);
    ram_scale_line u_line0 (
        .dia(source_data), .addra(input_x[11:0]), .clka(clk),
        .wea(source_take && !input_y[0]), .addrb(read_addr), .clkb(clk), .dob(line0)
    );
    ram_scale_line u_line1 (
        .dia(source_data), .addra(input_x[11:0]), .clka(clk),
        .wea(source_take && input_y[0]), .addrb(read_addr), .clkb(clk), .dob(line1)
    );
    // Constant divisors, no divider IP. The remainders are normalized before use.
    wire [20:0] fx_full = {x_rem, 8'b0} / 21'd639;
    wire [20:0] fy_full = {y_rem, 8'b0} / 21'd479;
    function [7:0] component;
        input [23:0] rgb;
        input [1:0] c;
        begin
            case (c)
                0: component = rgb[7:0];
                1: component = rgb[15:8];
                default: component = rgb[23:16];
            endcase
        end
    endfunction
    // One signed multiplier is shared by both horizontal blends, the vertical
    // blend, and all three components. Horizontal values keep all Q8 bits.
    reg signed [17:0] mul_delta;
    reg signed [17:0] mul_weight;
    reg signed [26:0] blend_base;
    wire signed [35:0] product = mul_delta * mul_weight;
    wire signed [26:0] blend = blend_base + $signed(product[26:0]);
    always @* begin
        mul_delta = 0; mul_weight = $signed({10'b0, fx_full[7:0]});
        blend_base = 0;
        case (state)
            H_TOP: begin
                mul_delta = $signed({10'b0, component(p01, channel)})
                          - $signed({10'b0, component(p00, channel)});
                blend_base = $signed({11'b0, component(p00, channel), 8'b0});
            end
            H_BOTTOM: begin
                mul_delta = $signed({10'b0, component(p11, channel)})
                          - $signed({10'b0, component(p10, channel)});
                blend_base = $signed({11'b0, component(p10, channel), 8'b0});
            end
            V_BLEND: begin
                mul_delta = $signed({2'b0, h1}) - $signed({2'b0, h0});
                mul_weight = $signed({10'b0, fy_full[7:0]});
                blend_base = $signed({3'b0, h0, 8'b0}) + 27'sd32768;
            end
            default: begin end
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; w <= 0; h <= 0;
            input_x <= 0; input_y <= 0; loaded_rows <= 0;
            sx <= 0; sy <= 0; x_rem <= 0; y_rem <= 0;
            out_x <= 0; out_y <= 0; channel <= 0;
            p00 <= 0; p01 <= 0; p10 <= 0; p11 <= 0; h0 <= 0; h1 <= 0;
            pixel_data <= 0; done <= 0;
        end else if (cancel) begin
            state <= IDLE; done <= 0;
        end else if (start) begin
            w <= width; h <= height; state <= LOAD;
            input_x <= 0; input_y <= 0; loaded_rows <= 0;
            sx <= 0; sy <= 0; x_rem <= 0; y_rem <= 0;
            out_x <= 0; out_y <= 0; channel <= 0;
            pixel_data <= 0; done <= 0;
        end else case (state)
            LOAD: if (source_take) begin
                if (input_x == w - 1'b1) begin
                    input_x <= 0; input_y <= input_y + 1'b1;
                    loaded_rows <= loaded_rows + 1'b1; state <= ROW_CHECK;
                end else input_x <= input_x + 1'b1;
            end
            ROW_CHECK: begin
                if (loaded_rows > sy_next) state <= LEFT;
                else state <= LOAD;
            end
            LEFT: state <= RIGHT; // RAM samples x0 on this edge.
            RIGHT: begin          // Capture x0; RAM samples x1 on this edge.
                p00 <= sy[0] ? line1 : line0;
                p10 <= sy_next[0] ? line1 : line0;
                state <= CAPTURE;
            end
            CAPTURE: begin
                p01 <= sy[0] ? line1 : line0;
                p11 <= sy_next[0] ? line1 : line0;
                channel <= 0; state <= H_TOP;
            end
            H_TOP: begin h0 <= blend[15:0]; state <= H_BOTTOM; end
            H_BOTTOM: begin h1 <= blend[15:0]; state <= V_BLEND; end
            V_BLEND: begin
                case (channel)
                    0: pixel_data[7:0] <= blend[23:16];
                    1: pixel_data[15:8] <= blend[23:16];
                    default: pixel_data[23:16] <= blend[23:16];
                endcase
                if (channel == 2) state <= SEND;
                else begin channel <= channel + 1'b1; state <= H_TOP; end
            end
            SEND: if (pixel_ready) begin
                if (out_x == 639) begin
                    out_x <= 0; sx <= 0; x_rem <= 0;
                    if (out_y == 479) begin done <= 1; state <= IDLE; end
                    else begin
                        out_y <= out_y + 1'b1;
                        y_rem <= y_rem + h - 1'b1; state <= Y_STEP;
                    end
                end else begin
                    out_x <= out_x + 1'b1;
                    x_rem <= x_rem + w - 1'b1; state <= X_STEP;
                end
            end
            X_STEP: begin
                if (x_rem >= 639) begin x_rem <= x_rem - 13'd639; sx <= sx + 1'b1; end
                else state <= LEFT;
            end
            Y_STEP: begin
                if (y_rem >= 479) begin y_rem <= y_rem - 13'd479; sy <= sy + 1'b1; end
                else state <= ROW_CHECK;
            end
            default: begin end
        endcase
    end
endmodule
`default_nettype wire
