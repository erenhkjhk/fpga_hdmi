`timescale 1ns/1ps
`default_nettype none

module key_debounce #(parameter integer DEBOUNCE_MS = 20) (
    input wire clk,
    input wire rst,
    input wire tick_ms,
    input wire key_n,
    output reg press
);
    localparam [15:0] LAST_MS = (DEBOUNCE_MS > 0) ? DEBOUNCE_MS - 1 : 0;
    (* ASYNC_REG = "TRUE" *) reg key_meta, key_sync;
    reg stable_pressed;
    reg [15:0] count_ms;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
            stable_pressed <= 1'b0;
            count_ms <= 16'd0;
            press <= 1'b0;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;
            press <= 1'b0;
            if (tick_ms) begin
                if ((!key_sync) == stable_pressed) count_ms <= 16'd0;
                else if (count_ms == LAST_MS) begin
                    count_ms <= 16'd0;
                    stable_pressed <= !key_sync;
                    if (!key_sync) press <= 1'b1;
                end else count_ms <= count_ms + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
