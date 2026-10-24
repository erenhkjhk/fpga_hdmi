`timescale 1ns/1ps
`default_nettype none

// B=32*(brightness_code-1), C=(contrast_code+1)/2.
// Round halves away from zero, then saturate. One pixel per clock.
module video_color_adjust (
    input wire clk, rst,
    input wire [3:0] switch_code,
    input wire [23:0] in_data,
    input wire [9:0] in_x,
    input wire [8:0] in_y,
    input wire in_valid, in_user, in_last, in_image,
    output reg [23:0] out_data,
    output reg [9:0] out_x,
    output reg [8:0] out_y,
    output reg out_valid, out_user, out_last
);
    function [7:0] adjust;
        input [7:0] c;
        input [1:0] brightness, contrast;
        reg signed [11:0] centered, twice, rounded, offset, value;
        begin
            centered = $signed({4'b0,c}) - 12'sd128;
            case (contrast)
                0: twice = centered;
                1: twice = centered <<< 1;
                2: twice = (centered <<< 1) + centered;
                default: twice = centered <<< 2;
            endcase
            if (twice < 0) rounded = -(((-twice) + 12'sd1) >>> 1);
            else rounded = (twice + 12'sd1) >>> 1;
            offset = ($signed({10'b0,brightness}) - 12'sd1) <<< 5;
            value = rounded + 12'sd128 + offset;
            if (value < 0) adjust = 0;
            else if (value > 255) adjust = 255;
            else adjust = value[7:0];
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_data <= 0; out_x <= 0; out_y <= 0;
            out_valid <= 0; out_user <= 0; out_last <= 0;
        end else begin
            out_data <= in_image ? {adjust(in_data[23:16],switch_code[1:0],switch_code[3:2]),
                         adjust(in_data[15:8],switch_code[1:0],switch_code[3:2]),
                         adjust(in_data[7:0],switch_code[1:0],switch_code[3:2])} : 24'h000000;
            out_x <= in_x; out_y <= in_y;
            out_valid <= in_valid; out_user <= in_user; out_last <= in_last;
        end
    end
endmodule
`default_nettype wire
