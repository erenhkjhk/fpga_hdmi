`timescale 1ns/1ps
`default_nettype none

// Synchronize/debounce the entire switch vector, count reset-relative uptime,
// and send coherent UI snapshots. Decimal conversion is serial double-dabble,
// not a bank of dividers in the pixel path. Active values change only in blank.
module display_control (
    input wire clk, rst, tick_ms,
    input wire [3:0] switch_async,
    input wire [15:0] current_index, image_count,
    input wire have_image, auto_enabled, busy, fading, error,
    input wire pixel_clk, pixel_rst, frame_tick,
    output wire [3:0] switch_frame,
    output wire [23:0] uptime_frame,
    output wire [19:0] index_frame, count_frame,
    output wire [3:0] status_frame
);
    (* ASYNC_REG = "TRUE" *) reg [3:0] sw_meta, sw_sync;
    reg [3:0] sw_candidate, sw_stable;
    reg [4:0] sw_ms;
    reg [9:0] second_ms;
    reg [23:0] uptime;
    reg [1:0] state;
    reg [4:0] bit_count;
    reg [15:0] index_shift, count_shift;
    reg [19:0] index_bcd, count_bcd;
    reg [31:0] held_info;
    reg [19:0] index_adjust, count_adjust;
    integer digit;
    wire snapshot_ready;
    wire [71:0] incoming;
    wire incoming_valid;
    reg [71:0] latest, active;
    assign {switch_frame, uptime_frame, status_frame, index_frame, count_frame} = active;
    cdc_mailbox #(.WIDTH(72)) u_snapshot (
        .src_clk(clk), .src_rst(rst), .src_data({held_info,index_bcd,count_bcd}),
        .src_valid(state == 2), .src_ready(snapshot_ready), .src_done(),
        .dst_clk(pixel_clk), .dst_rst(pixel_rst), .dst_data(incoming),
        .dst_valid(incoming_valid), .dst_ready(1'b1)
    );
    always @* begin
        index_adjust = index_bcd; count_adjust = count_bcd;
        for (digit=0; digit<5; digit=digit+1) begin
            if (index_bcd[digit*4 +: 4] >= 5)
                index_adjust[digit*4 +: 4] = index_bcd[digit*4 +: 4] + 4'd3;
            if (count_bcd[digit*4 +: 4] >= 5)
                count_adjust[digit*4 +: 4] = count_bcd[digit*4 +: 4] + 4'd3;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_meta <= 4'b0101; sw_sync <= 4'b0101;
            sw_candidate <= 4'b0101; sw_stable <= 4'b0101; sw_ms <= 0;
            second_ms <= 0; uptime <= 0; state <= 0; bit_count <= 0;
            index_shift <= 0; count_shift <= 0; index_bcd <= 0; count_bcd <= 0;
            held_info <= 0;
        end else begin
            sw_meta <= switch_async; sw_sync <= sw_meta;
            if (sw_sync != sw_candidate) begin sw_candidate <= sw_sync; sw_ms <= 0; end
            else if (tick_ms && (sw_ms < 20)) begin
                sw_ms <= sw_ms + 1'b1;
                if (sw_ms == 19) sw_stable <= sw_candidate;
            end
            if (tick_ms) begin
                if (second_ms == 999) begin
                    second_ms <= 0;
                    if (uptime[3:0] != 9) uptime[3:0] <= uptime[3:0] + 1'b1;
                    else begin
                        uptime[3:0] <= 0;
                        if (uptime[7:4] != 5) uptime[7:4] <= uptime[7:4] + 1'b1;
                        else begin
                            uptime[7:4] <= 0;
                            if (uptime[11:8] != 9) uptime[11:8] <= uptime[11:8] + 1'b1;
                            else begin
                                uptime[11:8] <= 0;
                                if (uptime[15:12] != 5) uptime[15:12] <= uptime[15:12] + 1'b1;
                                else begin
                                    uptime[15:12] <= 0;
                                    if (uptime[19:16] != 9) uptime[19:16] <= uptime[19:16] + 1'b1;
                                    else begin
                                        uptime[19:16] <= 0;
                                        uptime[23:20] <= (uptime[23:20] == 9) ? 4'd0 : uptime[23:20] + 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end else second_ms <= second_ms + 1'b1;
            end
            case (state)
                0: begin
                    held_info <= {sw_stable,uptime,error,fading,busy,auto_enabled};
                    index_shift <= have_image ? current_index + 16'd1 : 16'd0;
                    count_shift <= image_count;
                    index_bcd <= 0; count_bcd <= 0; bit_count <= 0; state <= 1;
                end
                1: begin
                    index_bcd <= {index_adjust[18:0],index_shift[15]};
                    count_bcd <= {count_adjust[18:0],count_shift[15]};
                    index_shift <= {index_shift[14:0],1'b0};
                    count_shift <= {count_shift[14:0],1'b0};
                    if (bit_count == 15) state <= 2;
                    else bit_count <= bit_count + 1'b1;
                end
                2: if (snapshot_ready) state <= 0;
                default: state <= 0;
            endcase
        end
    end
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin latest <= {4'b0101,68'b0}; active <= {4'b0101,68'b0}; end
        else begin
            if (incoming_valid) latest <= incoming;
            if (frame_tick) active <= incoming_valid ? incoming : latest;
        end
    end
endmodule
`default_nettype wire
