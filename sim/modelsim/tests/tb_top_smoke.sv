`timescale 1ns/1ps
module tb_top_smoke;
 reg clk=0;always #10 clk=~clk;
 wire cs,sck,mosi,ch0,ch1,ch2,tclk,scl;tri1 sda;wire [3:0] led;
 fpga_hdmi_top dut(.clk_50m(clk),.key_n(4'b1111),.sw(4'd0),.sd_cs_n(cs),.sd_sck(sck),.sd_mosi(mosi),.sd_miso(1'b1),
 .tmds_ch0_p(ch0),.tmds_ch1_p(ch1),.tmds_ch2_p(ch2),.tmds_clk_p(tclk),.ddc_scl(scl),.ddc_sda(sda),.status_led(led));
 integer pixels=0,serial=0,memedges=0,audio=0;
 always @(posedge dut.clk_pixel) if(!dut.rst_pixel) pixels++;
 always @(posedge dut.clk_serial) if(!dut.rst_pixel) serial++;
 always @(posedge dut.clk_sdram) if(!dut.rst_mem) memedges++;
 always @(posedge dut.clk_pixel) if(dut.audio_valid) audio++;
 initial forever begin
  #1000000;
  $display("TOP_PROGRESS t=%t reset=%b lock=%b/%b sdram_init=%b video_lock=%b audio=%0d",$time,dut.reset_request,dut.locked_sdram,dut.locked_hdmi,dut.sdr_init_done,dut.video_locked,audio);
 end
 initial begin
  #3000000;
  if(dut.locked_hdmi!==1 || dut.locked_sdram!==1 || dut.sdr_init_done!==1) $fatal(1,"Top startup PLL=%b/%b SDRAM=%b",dut.locked_hdmi,dut.locked_sdram,dut.sdr_init_done);
  pixels=0;serial=0;memedges=0;#40000;
  if(pixels<999 || pixels>1001 || serial<4999 || serial>5001 || memedges<5999 || memedges>6001)
   $fatal(1,"Actual PLL clocks pixel=%0d serial=%0d mem=%0d",pixels,serial,memedges);
  @(posedge dut.clk_sdram);#0.001;if(dut.clk_sdram_180!==0) $fatal(1,"SDRAM PLL 180 degree phase");
  @(negedge dut.clk_sdram);#0.001;if(dut.clk_sdram_180!==1) $fatal(1,"SDRAM PLL inverted phase");
  wait(dut.video_locked===1 && audio>=100);@(negedge dut.clk_pixel);
  if(dut.video_locked!==1 || audio<100 || dut.memory_fault_mem || dut.video_underflow || dut.composed_protocol_error)
   $fatal(1,"Top video/audio startup locked=%b audio=%0d memfault=%b underflow=%b protocol=%b",dut.video_locked,audio,dut.memory_fault_mem,dut.video_underflow,dut.composed_protocol_error);
  $display("PASS: tb_top_smoke actual PLL + SDRAM + HDMI encrypted cores, OSD black background, fallback audio=%0d",audio);$finish;
 end
 initial begin #10000000;$fatal(1,"Top timeout");end
endmodule
