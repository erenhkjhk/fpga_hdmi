`timescale 1ns/1ps
`default_nettype none
// Continuous cadence is supplied by the existing 48-kHz tone receiver.
// A stereo pair is committed atomically; a bad channel tag never shifts L/R.
module pcm_player (
 input wire clk,rst,tick,enable,wav_mode,prerolled,
 input wire [23:0] tone_left,tone_right,
 input wire [31:0] fifo_data, input wire fifo_valid,fifo_empty,fifo_ready,
 output wire fifo_re, output reg sample_valid,
 output reg [23:0] sample_left,sample_right,
 output reg underflow,tag_error, output reg playing
);
 reg [1:0] state;
 reg outstanding,pair_ready;
 reg [23:0] left_hold,right_hold;
 assign fifo_re=!rst && fifo_ready && !fifo_empty && !outstanding && !pair_ready;
 always @(posedge clk or posedge rst) begin
  if(rst) begin state<=0;outstanding<=0;pair_ready<=0;left_hold<=0;right_hold<=0;
   sample_valid<=0;sample_left<=0;sample_right<=0;underflow<=0;tag_error<=0;playing<=0;
  end else begin
   sample_valid<=0;
   if(fifo_re) outstanding<=1;
   if(fifo_valid && outstanding) begin
    outstanding<=0;
    if(state==0) begin
     if(!fifo_data[31]) begin left_hold<=fifo_data[23:0];state<=1;end
     else tag_error<=1;
    end else if(fifo_data[31]) begin right_hold<=fifo_data[23:0];state<=0;pair_ready<=1;end
    else begin left_hold<=fifo_data[23:0];tag_error<=1;end
   end
   if(!wav_mode) playing<=0;
   else if(!playing && prerolled && pair_ready && enable) playing<=1;
   if(tick && enable) begin
    sample_valid<=1;
    if(!wav_mode) begin sample_left<=tone_left;sample_right<=tone_right;end
    else if(playing && pair_ready) begin
     sample_left<=left_hold;sample_right<=right_hold;pair_ready<=0;
    end else begin
     sample_left<=0;sample_right<=0;
     if(playing) begin underflow<=1;playing<=0;end
    end
   end
  end
 end
endmodule
`default_nettype wire
