`timescale 1ns/1ps
module tb_pcm;
 reg clk=0,sys=0;always #20 clk=~clk;always #10 sys=~sys;
 reg rst=1,wav=1,preroll=0;reg [31:0] din=0;reg iv=0;wire ir;
 wire [31:0] dout;wire valid,empty,ready,re,overflow,fifo_underflow;
 wire bclk,lrck,serial,tone_valid;wire [23:0] tl,tr;
 wire sample_valid,playing,underflow,tag_error;wire [23:0] left,right;
 wire acr_valid;wire [19:0] cts,n;
 reg sampled_wav=1;reg [23:0] sampled_tl,sampled_tr;
 integer samples=0,nonzero=0,cycles=0,last_cycle=0,acrs=0,phase=0;
 wire [23:0] crossed;wire cv,cr;reg [23:0] pending[0:255];integer pw=0,pr=0;
 media_async_fifo q(.wr_clk(sys),.wr_rst(rst),.rd_clk(clk),.rd_rst(rst),.in_data(din),.in_valid(iv),.in_ready(ir),
 .out_data(dout),.out_valid(valid),.out_re(re),.out_empty(empty),.out_ready(ready),.wr_used(),.rd_used(),.overflow(overflow),.underflow(fifo_underflow));
 i2s_test_tone tone(clk,rst,bclk,lrck,serial);
 i2s_stereo_receiver receiver(clk,rst,bclk,lrck,serial,tone_valid,tl,tr);
 pcm_player dut(clk,rst,tone_valid,1'b1,wav,preroll,tl,tr,dout,valid,empty,ready,re,sample_valid,left,right,underflow,tag_error,playing);
 hdmi_acr_48k acr(clk,rst,sample_valid,acr_valid,cts,n);
 cdc_mailbox #(.WIDTH(24)) mailbox(clk,rst,left,sample_valid,cr,,sys,rst,crossed,cv,1'b1);
 always @(posedge sys) if(!rst && cv) begin
  if(crossed!==pending[pr%256]) $fatal(1,"Played sample mailbox order");pr++;
 end
 always @(posedge clk) if(!rst) begin
  if(tone_valid) begin sampled_wav<=wav;sampled_tl<=tl;sampled_tr<=tr;end
  cycles++;
  if(sample_valid) begin
   if(last_cycle && cycles-last_cycle!=520 && cycles-last_cycle!=521) $fatal(1,"48kHz cadence %0d",cycles-last_cycle);
   last_cycle=cycles;samples++;
   if(!cr) $fatal(1,"Sample mailbox busy");pending[pw%256]=left;pw++;
   if(sampled_wav) begin
    if(left!=0 || right!=0) begin
     if(left!==24'(nonzero+1) || right!==24'(-(nonzero+1))) $fatal(1,"PCM pair order index=%0d L=%h R=%h",nonzero,left,right);
     nonzero++;
    end
   end else if(left!==sampled_tl || right!==sampled_tr) $fatal(1,"Fallback tone");
  end
  if(acr_valid) begin if(cts!=25000 || n!=6144) $fatal(1,"ACR values");acrs++;end
  if(overflow || fifo_underflow) $fatal(1,"Audio FIFO flags");
 end
 task send_word(input [31:0] value);
  @(negedge sys);iv=1;din=value;
  do @(posedge sys);while(!ir);
  @(negedge sys);iv=0;
 endtask
 task pairs(input integer first,last);
  for(integer j=first;j<=last;j++) begin send_word({8'd0,24'(j)});send_word({8'h80,24'(-j)});end
 endtask
 initial begin
  #1000;@(negedge sys);rst=0;
  pairs(1,4);wait(samples==3);if(nonzero!=0) $fatal(1,"Preroll gate");
  @(negedge clk);preroll=1;wait(nonzero==4);wait(underflow);@(negedge clk);preroll=0;
  // Deliberately inject a stray right tag, then verify resynchronization.
  send_word(32'h800000ff);pairs(5,7);wait(samples>=12);if(nonzero!=4) $fatal(1,"Rebuffer gate");
  @(negedge clk);preroll=1;wait(nonzero==7);wait(!playing);@(negedge clk);wav=0;
  wait(samples>=110);repeat(20) @(negedge clk);
  if(!tag_error || acrs<2 || pr!=pw) $fatal(1,"PCM finish tag=%b acr=%0d mailbox=%0d/%0d",tag_error,acrs,pr,pw);
  $display("PASS: tb_pcm 48kHz cadence, underrun/silence/rebuffer, tag recovery, fallback, ACR, played-sample CDC");$finish;
 end
 initial begin #5000000;$fatal(1,"PCM timeout samples=%0d nonzero=%0d",samples,nonzero);end
endmodule
