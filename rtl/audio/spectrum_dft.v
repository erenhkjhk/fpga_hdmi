`timescale 1ns/1ps
`default_nettype none
// 256-point Hann-windowed DFT, bins 0..127, four bins per display bar.
// One signed 24x16 multiplier is time shared by real/imaginary products.
// The capture-side window multiplier runs once per actual played sample.
module spectrum_dft (
 input wire clk,rst, input wire [23:0] sample, input wire sample_valid,
 output reg [255:0] heights, output reg heights_valid, input wire heights_ready,
 output reg overrun
);
 reg capture_bank,compute_bank;
 reg [7:0] capture_index,n;
 reg [6:0] k;
 reg [2:0] capture_state;
 reg [3:0] state;
 reg signed [23:0] captured_sample;
 reg signed [39:0] window_product,product;
 reg signed [47:0] acc_r,acc_i;
 reg signed [17:0] norm_r,norm_i;
 reg [36:0] power;
 reg [38:0] group_power;
 reg [255:0] work_heights;
 wire [15:0] window_q;
 wire [31:0] twiddle_q;
 wire [7:0] phase=n*k;
 rom_dft_window u_window (.clka(clk),.rsta(rst),.addra(capture_index),.doa(window_q));
 rom_dft_twiddle u_twiddle (.clka(clk),.rsta(rst),.addra(phase),.doa(twiddle_q));
 wire capture_write=capture_state==4;
 wire [23:0] windowed=window_product>>>15;
 wire [23:0] q0,q1;
 ram_audio_window u_a (.clka(clk),.rsta(rst),.cea(1'b1),
  .wea(capture_write && !capture_bank),.addra(capture_bank ? n : capture_index),.dia(windowed),.doa(q0));
 ram_audio_window u_b (.clka(clk),.rsta(rst),.cea(1'b1),
  .wea(capture_write && capture_bank),.addra(capture_bank ? capture_index : n),.dia(windowed),.doa(q1));
 wire signed [23:0] x=compute_bank ? q1 : q0;
 wire signed [15:0] coefficient=(state==4) ? $signed(twiddle_q[15:0]) : $signed(twiddle_q[31:16]);
 wire signed [39:0] multiply=x*coefficient;
 wire [35:0] square_r=norm_r*norm_r, square_i=norm_i*norm_i;
 wire [38:0] next_group=group_power+{2'd0,power};
 function [7:0] log_height;
  input [38:0] energy;
  integer i,level;
  begin
   level=0;
   for(i=0;i<39;i=i+1) if(energy[i]) level=i;
   level=level*5-50;
   log_height=(level<0)?8'd0:((level>120)?8'd120:level[7:0]);
  end
 endfunction
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   capture_bank<=0;compute_bank<=1;capture_index<=0;n<=0;k<=0;capture_state<=0;state<=0;
   captured_sample<=0;window_product<=0;product<=0;acc_r<=0;acc_i<=0;
   norm_r<=0;norm_i<=0;power<=0;group_power<=0;work_heights<=0;
   heights<=0;heights_valid<=0;overrun<=0;
  end else begin
   if(heights_valid && heights_ready) heights_valid<=0;
   if(sample_valid && capture_state!=0) overrun<=1;
   case(capture_state)
    0: if(sample_valid) begin captured_sample<=$signed(sample);capture_state<=1;end
    1: capture_state<=2;
    2: begin window_product<=captured_sample*$signed(window_q);capture_state<=3;end
    3: capture_state<=4;
    4: begin
     capture_state<=0;capture_index<=capture_index+1'b1;
     if(capture_index==255) begin
      if(state==0) begin
       compute_bank<=capture_bank;capture_bank<=!capture_bank;
       n<=0;k<=0;acc_r<=0;acc_i<=0;group_power<=0;state<=1;
      end else overrun<=1; // Keep capture bank; never overwrite a bank being read.
     end
    end
    default:capture_state<=0;
   endcase
   case(state)
    0: begin end
    1:state<=2;
    2:state<=3;
    3:begin product<=multiply;state<=4;end
    4:begin acc_r<=acc_r+{{8{product[39]}},product};product<=multiply;state<=5;end
    5:begin
     acc_i<=acc_i+{{8{product[39]}},product};
     if(n==255) state<=6;else begin n<=n+1'b1;state<=1;end
    end
    6:begin norm_r<=acc_r>>>29;norm_i<=acc_i>>>29;state<=7;end
    7:begin power<=(k==0)?37'd0:({1'b0,square_r}+{1'b0,square_i});state<=8;end
    8:begin
     if(k[1:0]==3) begin
      work_heights[k[6:2]*8+:8]<=log_height(next_group);group_power<=0;
     end else group_power<=next_group;
     if(k==127) begin
      if(!heights_valid || heights_ready) begin
       heights<={log_height(next_group),work_heights[247:0]};heights_valid<=1;
      end else overrun<=1;
      state<=0;
     end else begin k<=k+1'b1;n<=0;acc_r<=0;acc_i<=0;state<=1;end
    end
    default:state<=0;
   endcase
  end
 end
endmodule
`default_nettype wire
