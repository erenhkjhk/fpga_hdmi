`timescale 1ns/1ps
`default_nettype none
// Fixed-throughput compositor. ROM address -> OUTREG output = two edges;
// RGB, glyph bit, alpha, AXIS user/last/valid have the identical pipeline.
module video_compositor #(parameter [3:0] TEXT_ALPHA=4'd15) (
 input wire clk,rst,frame_blank,
 input wire [23:0] in_rgb, input wire in_valid,in_user,in_last,
 input wire [65:0] status, input wire status_valid,
 input wire [255:0] heights, input wire heights_valid,
 output reg [23:0] out_rgb, output reg out_valid,out_user,out_last
);
 reg [65:0] latest_status,frame_status;
 reg [255:0] latest_heights;
 reg [7:0] bar [0:31];
 reg [7:0] peak [0:31];
 reg signed [10:0] scroll;
 reg scroll_phase;
 reg [9:0] next_x,next_y;
 wire [9:0] x=in_user ? 10'd0:next_x, y=in_user?10'd0:next_y;
 wire [23:0] time_bcd=frame_status[63:40];
 wire [15:0] picture=frame_status[39:24], count=frame_status[23:8];
 wire [1:0] brightness=frame_status[1:0],contrast=frame_status[3:2];
 wire wav_mode=frame_status[65],playing=frame_status[64];
 wire autoplay=frame_status[4],loading=frame_status[5],transition=frame_status[6],error=frame_status[7];
 integer i;
 function [7:0] adjust;
  input [7:0] value; input [1:0] bright,contr;
  reg signed [13:0] delta,scaled,result;
  begin
   delta=$signed({1'b0,value})-14'sd128;
   case(contr)
    1:scaled=(delta<<<2)+delta;
    2:scaled=(delta<<<2)-delta;
    3:scaled=(delta<<<2)+(delta<<<1);
    default:scaled=delta<<<2;
   endcase
   result=((scaled+14'sd2)>>>2)+14'sd128;
   case(bright) 1:result=result+32;2:result=result-32;3:result=result+64;default:begin end endcase
   adjust=result<0?8'd0:(result>255?8'd255:result[7:0]);
  end
 endfunction
 function [7:0] digit;
  input [15:0] number; input [2:0] place;
  begin
   case(place) 0:digit=48+(number/10000)%10;1:digit=48+(number/1000)%10;
    2:digit=48+(number/100)%10;3:digit=48+(number/10)%10;default:digit=48+number%10;endcase
  end
 endfunction
 reg [23:0] base_rgb;
 reg text_hit,logo_hit;
 reg [8:0] glyph;
 reg [6:0] glyph_cell;
 reg [3:0] row;
 reg [2:0] bit_index;
 reg half;
 reg [12:0] font_addr,logo_addr;
 reg [9:0] local_x;
 integer bar_index,bar_offset;
 // Chinese glyph = 128 + assets/osd glyph-map index. Each occupies two cells.
 always @* begin
  base_rgb={adjust(in_rgb[23:16],brightness,contrast),adjust(in_rgb[15:8],brightness,contrast),adjust(in_rgb[7:0],brightness,contrast)};
  text_hit=0;logo_hit=0;glyph=9'd32;glyph_cell=0;row=0;bit_index=0;half=0;local_x=0;
  font_addr=0;logo_addr=0;bar_index=0;bar_offset=0;
  if(x>=320 && x<632 && y>=320 && y<440) begin
   bar_index=((x-320)*32)/312;bar_offset=((x-320)*32)%312;
   if(bar_offset<240 && 440-y<=bar[bar_index]) begin
    if(y<360) base_rgb={(base_rgb[23:16]>>2)+8'd191,(base_rgb[15:8]>>2)+8'd96,(base_rgb[7:0]>>2)+8'd48};
    else base_rgb={(base_rgb[23:16]>>2)+8'd24,(base_rgb[15:8]>>2)+8'd156,(base_rgb[7:0]>>2)+8'd132};
   end
   if(peak[bar_index]!=0 && 440-y==peak[bar_index]) base_rgb=24'hFFF0A0;
  end
  if(x>=4 && x<296 && y>=364 && y<430) base_rgb={2'b00,base_rgb[23:18],2'b00,base_rgb[15:10],2'b00,base_rgb[7:2]};
  if(x>=272 && x<284 && y>=344 && y<356) begin
   if(autoplay ? (x-272 <= (y<350 ? y-344 : 355-y)) : (x<276 || x>=280)) base_rgb=24'h60F090;
  end
  if(x>=504 && x<632 && y>=8 && y<72) begin logo_hit=1;logo_addr=(y-8)*128+x-504;end
  if(x>=8 && x<104 && y>=8 && y<24) begin
   text_hit=1;local_x=x-8;glyph_cell=local_x[9:3];row=y-8;
   case(glyph_cell)
    0,1:glyph=135;2,3:glyph=136;
    4:glyph=48+time_bcd[23:20];5:glyph=48+time_bcd[19:16];6:glyph=58;
    7:glyph=48+time_bcd[15:12];8:glyph=48+time_bcd[11:8];9:glyph=58;
    10:glyph=48+time_bcd[7:4];11:glyph=48+time_bcd[3:0];default:glyph=32;
   endcase
  end else if(x>=8 && x<176 && y>=344 && y<360) begin
   text_hit=1;local_x=x-8;glyph_cell=local_x[9:3];row=y-344;
   case(glyph_cell)
    0:glyph=wav_mode?87:84;1:glyph=wav_mode?65:79;2:glyph=wav_mode?86:78;3:glyph=wav_mode?32:69;
    5:glyph=(wav_mode && !playing)?66:32;6:glyph=(wav_mode && !playing)?85:32;
    7:glyph=(wav_mode && !playing)?70:32;8:glyph=(wav_mode && !playing)?70:32;
    9:glyph=(wav_mode && !playing)?69:32;10:glyph=(wav_mode && !playing)?82:32;
    default:glyph=32;
   endcase
  end else if(x>=8 && x<288 && y>=368 && y<384) begin
   text_hit=1;local_x=x-8;glyph_cell=local_x[9:3];row=y-368;
   case(glyph_cell)
    0,1:glyph=137;2,3:glyph=138;4:glyph=58;
    5:glyph=brightness==2?45:43;
    6:glyph=brightness==0?48:(brightness==3?54:51);
    7:glyph=brightness==0?48:(brightness==3?52:50);
    10,11:glyph=139;12,13:glyph=140;14:glyph=58;
    15:glyph=contrast==2?48:49;16:glyph=46;
    17:glyph=contrast==1?50:(contrast==2?55:(contrast==3?53:48));
    18:glyph=(contrast==1 || contrast==2)?53:48;19:glyph=120;
    default:glyph=32;
   endcase
  end else if(x>=8 && x<288 && y>=388 && y<404) begin
   text_hit=1;local_x=x-8;glyph_cell=local_x[9:3];row=y-388;
   case(glyph_cell)
    0,1:glyph=141;2,3:glyph=142;4:glyph=58;
    6,7:glyph=autoplay?143:149;
    10,11:glyph=144;12,13:glyph=145;14:glyph=58;
    16,17:glyph=error?154:(transition?152:(loading?150:146));
    18,19:glyph=error?155:(transition?153:(loading?151:134));
    default:glyph=32;
   endcase
  end else if(x>=8 && x<176 && y>=408 && y<424) begin
   text_hit=1;local_x=x-8;glyph_cell=local_x[9:3];row=y-408;
   case(glyph_cell)
    0,1:glyph=147;2,3:glyph=148;4:glyph=58;
    5,6,7,8,9:glyph={1'b0,digit(picture,glyph_cell-5)};
    10:glyph=47;
    11,12,13,14,15:glyph={1'b0,digit(count,glyph_cell-11)};
    default:glyph=32;
   endcase
  end else if(y>=456 && y<472 && $signed({1'b0,x})>=scroll && $signed({1'b0,x})<scroll+11'sd160) begin
   text_hit=1;local_x=$signed({1'b0,x})-scroll;glyph_cell=local_x[9:3];row=y-456;
   case(glyph_cell)
    0,1:glyph=128;2,3:glyph=129;5:glyph=70;6:glyph=80;7:glyph=71;8:glyph=65;
    10,11:glyph=130;12,13:glyph=131;14,15:glyph=132;16,17:glyph=133;18,19:glyph=134;
    default:glyph=32;
   endcase
  end
  bit_index=3'd7-local_x[2:0];half=glyph_cell[0];
  font_addr=glyph[8:7]!=0 ? 13'd2048+(glyph-9'd128)*32+row*2+half : glyph*16+row;
 end
 wire [7:0] font_q; wire [15:0] logo_q;
 rom_osd_font u_font (.clka(clk),.rsta(rst),.addra(font_addr),.doa(font_q));
 rom_anlogic_logo u_logo (.clka(clk),.rsta(rst),.addra(logo_addr),.doa(logo_q));
 reg [23:0] rgb0,rgb1;
 reg [2:0] bit0,bit1;
 reg [1:0] text_pipe,logo_pipe,valid_pipe,user_pipe,last_pipe;
 function [7:0] alpha_channel;
  input [7:0] bg;input [3:0] fg,a;
  reg signed [8:0] difference;
  reg signed [13:0] product,mixed;
  begin
   difference=$signed({1'b0,fg,fg})-$signed({1'b0,bg});
   product=difference*$signed({1'b0,a});
   mixed=$signed({2'd0,bg,4'd0})-$signed({6'd0,bg})+product+14'sd7;
   alpha_channel=mixed/14'sd15;
  end
 endfunction
 wire [23:0] logo_composite=logo_pipe[1] ?
  {alpha_channel(rgb1[23:16],logo_q[11:8],logo_q[15:12]),
   alpha_channel(rgb1[15:8],logo_q[7:4],logo_q[15:12]),
   alpha_channel(rgb1[7:0],logo_q[3:0],logo_q[15:12])} : rgb1;
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   latest_status<=0;frame_status<=0;latest_heights<=0;next_x<=0;next_y<=0;
   scroll<=640;scroll_phase<=0;rgb0<=0;rgb1<=0;bit0<=0;bit1<=0;
   text_pipe<=0;logo_pipe<=0;valid_pipe<=0;user_pipe<=0;last_pipe<=0;
   out_rgb<=0;out_valid<=0;out_user<=0;out_last<=0;
   for(i=0;i<32;i=i+1) begin bar[i]<=0;peak[i]<=0;end
  end else begin
   if(status_valid) latest_status<=status;
   if(heights_valid) latest_heights<=heights;
   if(frame_blank) begin
    frame_status<=latest_status;scroll_phase<=!scroll_phase;
    if(scroll_phase) scroll<=(scroll<=-11'sd160)?11'sd640:scroll-11'sd1;
    for(i=0;i<32;i=i+1) begin
     if(latest_heights[i*8+:8]>=bar[i]) bar[i]<=latest_heights[i*8+:8];
     else bar[i]<=bar[i]>3?bar[i]-3:0;
     if(latest_heights[i*8+:8]>=peak[i]) peak[i]<=latest_heights[i*8+:8];
     else if(peak[i]!=0) peak[i]<=peak[i]-1'b1;
    end
   end
   if(in_valid) begin
    if(in_last) begin next_x<=0;next_y<=y+1'b1;end
    else begin next_x<=x+1'b1;next_y<=y;end
   end
   rgb0<=base_rgb;rgb1<=rgb0;bit0<=bit_index;bit1<=bit0;
   text_pipe<={text_pipe[0],text_hit};logo_pipe<={logo_pipe[0],logo_hit};
   valid_pipe<={valid_pipe[0],in_valid};user_pipe<={user_pipe[0],in_user};last_pipe<={last_pipe[0],in_last};
   out_valid<=valid_pipe[1];out_user<=user_pipe[1];out_last<=last_pipe[1];
   if(text_pipe[1] && font_q[bit1]) out_rgb<=
     {alpha_channel(logo_composite[23:16],4'hF,TEXT_ALPHA),
      alpha_channel(logo_composite[15:8],4'hF,TEXT_ALPHA),
      alpha_channel(logo_composite[7:0],4'hF,TEXT_ALPHA)};
   else out_rgb<=logo_composite;
  end
 end
endmodule
`default_nettype wire

