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
                     SEND=9, X_STEP=10, Y_STEP=11, WEIGHT_INIT=12,
                     WEIGHT_STEP=13, MULTIPLY=14, ACCUMULATE=15;
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
    // Eight registered binary-fraction steps compute floor(rem*256/divisor).
    // X_STEP/Y_STEP normalize the remainders first, so each step needs only
    // one 11-bit compare/subtract. No combinational divider or new IP.
    reg [9:0] fx_rem, fy_rem;
    reg [7:0] fx, fy;
    reg [2:0] weight_bit;
    wire [10:0] fx_double = {fx_rem, 1'b0};
    wire [10:0] fy_double = {fy_rem, 1'b0};
    wire [10:0] fx_sub = fx_double - 11'd639;
    wire [10:0] fy_sub = fy_double - 11'd479;
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
    reg signed [17:0] mul_delta, mul_weight;
    reg signed [26:0] blend_base;
    reg signed [17:0] delta_next, weight_next;
    reg signed [26:0] base_next;
    reg signed [35:0] product;
    reg [1:0] blend_kind; // 0: top, 1: bottom, 2: vertical
    wire signed [26:0] blend = blend_base + $signed(product[26:0]);
    always @* begin
        delta_next = 0; weight_next = $signed({10'b0, fx});
        base_next = 0;
        case (state)
            H_TOP: begin
                delta_next = $signed({10'b0, component(p01, channel)})
                          - $signed({10'b0, component(p00, channel)});
                base_next = $signed({11'b0, component(p00, channel), 8'b0});
            end
            H_BOTTOM: begin
                delta_next = $signed({10'b0, component(p11, channel)})
                          - $signed({10'b0, component(p10, channel)});
                base_next = $signed({11'b0, component(p10, channel), 8'b0});
            end
            V_BLEND: begin
                delta_next = $signed({2'b0, h1}) - $signed({2'b0, h0});
                weight_next = $signed({10'b0, fy});
                base_next = $signed({3'b0, h0, 8'b0}) + 27'sd32768;
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
            fx_rem <= 0; fy_rem <= 0; fx <= 0; fy <= 0; weight_bit <= 0;
            mul_delta <= 0; mul_weight <= 0; blend_base <= 0;
            product <= 0; blend_kind <= 0;
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
                if (loaded_rows > sy_next) state <= WEIGHT_INIT;
                else state <= LOAD;
            end
            WEIGHT_INIT: begin
                fx_rem <= x_rem[9:0]; fy_rem <= y_rem[9:0];
                fx <= 0; fy <= 0; weight_bit <= 0;
                state <= WEIGHT_STEP;
            end
            WEIGHT_STEP: begin
                fx_rem <= (fx_double >= 11'd639) ? fx_sub[9:0] : fx_double[9:0];
                fy_rem <= (fy_double >= 11'd479) ? fy_sub[9:0] : fy_double[9:0];
                fx <= {fx[6:0], (fx_double >= 11'd639)};
                fy <= {fy[6:0], (fy_double >= 11'd479)};
                if (weight_bit == 7) state <= LEFT;
                else weight_bit <= weight_bit + 1'b1;
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
            H_TOP, H_BOTTOM, V_BLEND: begin
                mul_delta <= delta_next; mul_weight <= weight_next;
                blend_base <= base_next;
                blend_kind <= (state == H_TOP) ? 2'd0
                            : (state == H_BOTTOM) ? 2'd1 : 2'd2;
                state <= MULTIPLY;
            end
            MULTIPLY: begin
                product <= mul_delta * mul_weight;
                state <= ACCUMULATE;
            end
            ACCUMULATE: begin
                case (blend_kind)
                    0: begin h0 <= blend[15:0]; state <= H_BOTTOM; end
                    1: begin h1 <= blend[15:0]; state <= V_BLEND; end
                    default: begin
                        case (channel)
                            0: pixel_data[7:0] <= blend[23:16];
                            1: pixel_data[15:8] <= blend[23:16];
                            default: pixel_data[23:16] <= blend[23:16];
                        endcase
                        if (channel == 2) state <= SEND;
                        else begin channel <= channel + 1'b1; state <= H_TOP; end
                    end
                endcase
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
                else state <= WEIGHT_INIT;
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
