`timescale 1ns/1ps
`default_nettype none

// Shared synchronous font ROM (8x16 ASCII / 16x16 Chinese), independent ARGB4444
// logo ROM. Pipeline: ROM + half-alpha panel -> logo alpha -> text alpha.
// Every stage carries RGB, coordinates and user/valid/last at one pixel/clock.
module video_osd (
    input wire clk, rst, frame_tick,
    input wire [3:0] switch_code, status,
    input wire [23:0] uptime,
    input wire [19:0] index_bcd, count_bcd,
    input wire [23:0] in_data,
    input wire [9:0] in_x,
    input wire [8:0] in_y,
    input wire in_valid, in_user, in_last,
    output reg [23:0] out_data,
    output reg [9:0] out_x,
    output reg [8:0] out_y,
    output reg out_valid, out_user, out_last
);
    reg [9:0] scroll;
    wire [10:0] scroll_sum = {1'b0,in_x} + {1'b0,scroll};
    wire [10:0] scroll_pos = (scroll_sum >= 800) ? scroll_sum - 11'd800 : scroll_sum;
    reg [3:0] brightness_tens, brightness_ones, contrast_integer, contrast_fraction;
    wire [6:0] state_char0 = status[3] ? 7'd26 : status[2] ? 7'd24 : status[1] ? 7'd22 : 7'd18;
    wire [6:0] state_char1 = status[3] ? 7'd27 : status[2] ? 7'd25 : status[1] ? 7'd23 : 7'd6;
    always @* begin
        case (switch_code[1:0])
            0,2: begin brightness_tens=3; brightness_ones=2; end
            1: begin brightness_tens=0; brightness_ones=0; end
            default: begin brightness_tens=6; brightness_ones=4; end
        endcase
        case (switch_code[3:2])
            0: begin contrast_integer=0; contrast_fraction=5; end
            1: begin contrast_integer=1; contrast_fraction=0; end
            2: begin contrast_integer=1; contrast_fraction=5; end
            default: begin contrast_integer=2; contrast_fraction=0; end
        endcase
    end
    function [8:0] cn;
        input [6:0] slot;
        input half;
        begin cn = {1'b1,slot,half}; end
    endfunction
    function [8:0] asc;
        input [6:0] code;
        begin asc = {1'b0,code,1'b0}; end
    endfunction
    function [8:0] dec_digit;
        input [3:0] digit;
        begin dec_digit = asc(7'd48 + {3'b0,digit}); end
    endfunction
    function [8:0] cell_glyph;
        input [2:0] line_id;
        input [6:0] cell_id;
        begin
            cell_glyph = asc(7'd32);
            case (line_id)
                3'd0: case (cell_id)
                    7'd0: cell_glyph = cn(7'd7,1'b0);
                    7'd1: cell_glyph = cn(7'd7,1'b1);
                    7'd2: cell_glyph = cn(7'd8,1'b0);
                    7'd3: cell_glyph = cn(7'd8,1'b1);
                    7'd4: cell_glyph = asc(7'd32);
                    7'd5: cell_glyph = dec_digit(uptime[23:20]);
                    7'd6: cell_glyph = dec_digit(uptime[19:16]);
                    7'd7: cell_glyph = asc(7'd58);
                    7'd8: cell_glyph = dec_digit(uptime[15:12]);
                    7'd9: cell_glyph = dec_digit(uptime[11:8]);
                    7'd10: cell_glyph = asc(7'd58);
                    7'd11: cell_glyph = dec_digit(uptime[7:4]);
                    7'd12: cell_glyph = dec_digit(uptime[3:0]);
                    default: cell_glyph = asc(7'd32);
                endcase
                3'd1: case (cell_id)
                    7'd0: cell_glyph = cn(7'd9,1'b0);
                    7'd1: cell_glyph = cn(7'd9,1'b1);
                    7'd2: cell_glyph = cn(7'd10,1'b0);
                    7'd3: cell_glyph = cn(7'd10,1'b1);
                    7'd4: cell_glyph = asc(7'd58);
                    7'd5: cell_glyph = asc((switch_code[1:0] == 0) ? 7'd45 : 7'd43);
                    7'd6: cell_glyph = dec_digit(brightness_tens);
                    7'd7: cell_glyph = dec_digit(brightness_ones);
                    7'd8: cell_glyph = asc(7'd32);
                    7'd9: cell_glyph = cn(7'd11,1'b0);
                    7'd10: cell_glyph = cn(7'd11,1'b1);
                    7'd11: cell_glyph = cn(7'd12,1'b0);
                    7'd12: cell_glyph = cn(7'd12,1'b1);
                    7'd13: cell_glyph = asc(7'd58);
                    7'd14: cell_glyph = dec_digit(contrast_integer);
                    7'd15: cell_glyph = asc(7'd46);
                    7'd16: cell_glyph = dec_digit(contrast_fraction);
                    7'd17: cell_glyph = asc(7'd120);
                    default: cell_glyph = asc(7'd32);
                endcase
                3'd2: case (cell_id)
                    7'd0: cell_glyph = cn(7'd13,1'b0);
                    7'd1: cell_glyph = cn(7'd13,1'b1);
                    7'd2: cell_glyph = cn(7'd14,1'b0);
                    7'd3: cell_glyph = cn(7'd14,1'b1);
                    7'd4: cell_glyph = asc(7'd58);
                    7'd5: cell_glyph = cn(status[0] ? 7'd15 : 7'd21,1'b0);
                    7'd6: cell_glyph = cn(status[0] ? 7'd15 : 7'd21,1'b1);
                    7'd7: cell_glyph = asc(7'd32);
                    7'd8: cell_glyph = cn(7'd16,1'b0);
                    7'd9: cell_glyph = cn(7'd16,1'b1);
                    7'd10: cell_glyph = cn(7'd17,1'b0);
                    7'd11: cell_glyph = cn(7'd17,1'b1);
                    7'd12: cell_glyph = asc(7'd58);
                    7'd13: cell_glyph = cn(state_char0,1'b0);
                    7'd14: cell_glyph = cn(state_char0,1'b1);
                    7'd15: cell_glyph = cn(state_char1,1'b0);
                    7'd16: cell_glyph = cn(state_char1,1'b1);
                    default: cell_glyph = asc(7'd32);
                endcase
                3'd3: case (cell_id)
                    7'd0: cell_glyph = cn(7'd19,1'b0);
                    7'd1: cell_glyph = cn(7'd19,1'b1);
                    7'd2: cell_glyph = cn(7'd20,1'b0);
                    7'd3: cell_glyph = cn(7'd20,1'b1);
                    7'd4: cell_glyph = asc(7'd58);
                    7'd5: cell_glyph = dec_digit(index_bcd[19:16]);
                    7'd6: cell_glyph = dec_digit(index_bcd[15:12]);
                    7'd7: cell_glyph = dec_digit(index_bcd[11:8]);
                    7'd8: cell_glyph = dec_digit(index_bcd[7:4]);
                    7'd9: cell_glyph = dec_digit(index_bcd[3:0]);
                    7'd10: cell_glyph = asc(7'd47);
                    7'd11: cell_glyph = dec_digit(count_bcd[19:16]);
                    7'd12: cell_glyph = dec_digit(count_bcd[15:12]);
                    7'd13: cell_glyph = dec_digit(count_bcd[11:8]);
                    7'd14: cell_glyph = dec_digit(count_bcd[7:4]);
                    7'd15: cell_glyph = dec_digit(count_bcd[3:0]);
                    default: cell_glyph = asc(7'd32);
                endcase
                3'd4: case (cell_id)
                    7'd0: cell_glyph = cn(7'd0,1'b0);
                    7'd1: cell_glyph = cn(7'd0,1'b1);
                    7'd2: cell_glyph = cn(7'd1,1'b0);
                    7'd3: cell_glyph = cn(7'd1,1'b1);
                    7'd4: cell_glyph = asc(7'd32);
                    7'd5: cell_glyph = asc(7'd70);
                    7'd6: cell_glyph = asc(7'd80);
                    7'd7: cell_glyph = asc(7'd71);
                    7'd8: cell_glyph = asc(7'd65);
                    7'd9: cell_glyph = asc(7'd32);
                    7'd10: cell_glyph = cn(7'd2,1'b0);
                    7'd11: cell_glyph = cn(7'd2,1'b1);
                    7'd12: cell_glyph = cn(7'd3,1'b0);
                    7'd13: cell_glyph = cn(7'd3,1'b1);
                    7'd14: cell_glyph = cn(7'd4,1'b0);
                    7'd15: cell_glyph = cn(7'd4,1'b1);
                    7'd16: cell_glyph = cn(7'd5,1'b0);
                    7'd17: cell_glyph = cn(7'd5,1'b1);
                    7'd18: cell_glyph = cn(7'd6,1'b0);
                    7'd19: cell_glyph = cn(7'd6,1'b1);
                    default: cell_glyph = asc(7'd32);
                endcase
                default: cell_glyph = asc(7'd32);
            endcase
        end
    endfunction
    reg text_req, panel_req;
    reg [8:0] glyph;
    reg [3:0] font_row;
    reg [23:0] text_color;
    wire [9:0] text_x = in_x - 10'd16;
    wire [8:0] slogan_y = in_y - 9'd460;
    wire [12:0] font_addr = glyph[8]
                           ? 13'h0800 + {1'b0,glyph[7:1],font_row,glyph[0]}
                           : {2'b0,glyph[7:1],font_row};
    wire [9:0] logo_x = in_x - 10'd496;
    wire [8:0] logo_y = in_y - 9'd8;
    wire logo_req = (in_x >= 496) && (in_x < 624) && (in_y >= 8) && (in_y < 72);
    wire [12:0] logo_addr = {logo_y[5:0],logo_x[6:0]};
    wire [7:0] font_bits;
    wire [15:0] logo_word;
    rom_osd_font u_font (.addra(font_addr), .clka(clk), .doa(font_bits));
    rom_anlogic_logo u_logo (.addra(logo_addr), .clka(clk), .doa(logo_word));
    always @* begin
        text_req=0; glyph=asc(7'd32); font_row=in_y[3:0]; text_color=24'hF0F5FF;
        panel_req = ((in_x >= 8) && (in_x < 168) && (in_y >= 8) && (in_y < 40))
                  || ((in_x >= 8) && (in_x < 320) && (in_y >= 376) && (in_y < 448))
                  || (in_y >= 456);
        if ((in_x >= 16) && (in_x < 160) && (in_y >= 16) && (in_y < 32)) begin
            text_req=1; glyph=cell_glyph(3'd0,text_x[9:3]);
        end else if ((in_x >= 16) && (in_x < 304) && (in_y >= 384) && (in_y < 400)) begin
            text_req=1; glyph=cell_glyph(3'd1,text_x[9:3]);
        end else if ((in_x >= 16) && (in_x < 304) && (in_y >= 404) && (in_y < 420)) begin
            text_req=1; glyph=cell_glyph(3'd2,text_x[9:3]); font_row=in_y[3:0]-4'd4;
        end else if ((in_x >= 16) && (in_x < 304) && (in_y >= 424) && (in_y < 440)) begin
            text_req=1; glyph=cell_glyph(3'd3,text_x[9:3]); font_row=in_y[3:0]-4'd8;
        end else if ((in_y >= 460) && (in_y < 476) && (scroll_pos < 160)) begin
            text_req=1; glyph=cell_glyph(3'd4,scroll_pos[9:3]);
            font_row=slogan_y[3:0]; text_color=24'h6EE7FF;
        end
    end
    function [7:0] alpha_channel;
        input [7:0] background, foreground;
        input [8:0] alpha;
        reg signed [9:0] delta;
        reg signed [19:0] sum, product;
        begin
            delta = $signed({2'b0,foreground}) - $signed({2'b0,background});
            product = delta * $signed({1'b0,alpha});
            sum = product + $signed({4'b0,background,8'b0}) + 20'sd128;
            alpha_channel = sum[15:8];
        end
    endfunction
    function [23:0] alpha_rgb;
        input [23:0] background, foreground;
        input [8:0] alpha;
        begin
            alpha_rgb = {alpha_channel(background[23:16],foreground[23:16],alpha),
                         alpha_channel(background[15:8],foreground[15:8],alpha),
                         alpha_channel(background[7:0],foreground[7:0],alpha)};
        end
    endfunction
    reg [23:0] panel_s1, logo_s2, color_s1, color_s2;
    reg text_s1, text_s2, logo_s1;
    reg [2:0] bit_s1;
    reg [9:0] x_s1, x_s2;
    reg [8:0] y_s1, y_s2;
    reg valid_s1, valid_s2, user_s1, user_s2, last_s1, last_s2;
    wire [8:0] logo_alpha = (logo_word[15:12] == 15) ? 9'd256
                           : {1'b0,logo_word[15:12],logo_word[15:12]};
    wire [23:0] logo_rgb = {logo_word[11:8],logo_word[11:8],
                           logo_word[7:4],logo_word[7:4],logo_word[3:0],logo_word[3:0]};
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            scroll <= 0; panel_s1 <= 0; logo_s2 <= 0; color_s1 <= 0; color_s2 <= 0;
            text_s1 <= 0; text_s2 <= 0; logo_s1 <= 0; bit_s1 <= 0;
            x_s1 <= 0; x_s2 <= 0; y_s1 <= 0; y_s2 <= 0;
            valid_s1 <= 0; valid_s2 <= 0; user_s1 <= 0; user_s2 <= 0; last_s1 <= 0; last_s2 <= 0;
            out_x <= 0; out_y <= 0; out_data <= 0; out_valid <= 0; out_user <= 0; out_last <= 0;
        end else begin
            if (frame_tick) scroll <= (scroll == 799) ? 10'd0 : scroll + 1'b1;
            panel_s1 <= panel_req ? alpha_rgb(in_data,24'h102030,9'd128) : in_data;
            text_s1 <= text_req && in_valid; logo_s1 <= logo_req && in_valid;
            bit_s1 <= ((in_y >= 460) && (in_y < 476)) ? 3'd7-scroll_pos[2:0] : 3'd7-in_x[2:0];
            color_s1 <= text_color;
            x_s1 <= in_x; y_s1 <= in_y; valid_s1 <= in_valid; user_s1 <= in_user; last_s1 <= in_last;
            // ROM outputs now correspond to all stage-one metadata.
            logo_s2 <= logo_s1 ? alpha_rgb(panel_s1,logo_rgb,logo_alpha) : panel_s1;
            text_s2 <= text_s1 && font_bits[bit_s1]; color_s2 <= color_s1;
            x_s2 <= x_s1; y_s2 <= y_s1; valid_s2 <= valid_s1; user_s2 <= user_s1; last_s2 <= last_s1;
            out_data <= text_s2 ? alpha_rgb(logo_s2,color_s2,9'd240) : logo_s2;
            out_x <= x_s2; out_y <= y_s2; out_valid <= valid_s2; out_user <= user_s2; out_last <= last_s2;
        end
    end
endmodule
`default_nettype wire
