`timescale 1ns/1ps
module tb_vendor_ip;
 reg fifo_done=0;integer received=0;
 reg clk=0; always #10 clk=~clk;
 reg rst=1,ce=1,we=0;
 reg [10:0] addr=0; reg [23:0] data=0;
 wire [23:0] q,qa,qb;
 wire [7:0] font; wire [15:0] logo,window_q; wire [31:0] twiddle;
 reg [12:0] rom_addr=0;
 reg [7:0] font_ref[0:8191];reg [15:0] logo_ref[0:8191],window_ref[0:255];
 reg [31:0] twiddle_ref[0:255];
 ram_scale_line1 line_ram(q,data,addr,ce,clk,we,rst);
 ram_blend_block blend_ram(qa,data,addr[5:0],ce,clk,we,rst);
 ram_audio_window audio_ram(qb,data,addr[7:0],ce,clk,we,rst);
 rom_osd_font font_rom(font,rom_addr,clk,rst);
 rom_anlogic_logo logo_rom(logo,rom_addr,clk,rst);
 rom_dft_window window_rom(window_q,rom_addr[7:0],clk,rst);
 rom_dft_twiddle twiddle_rom(twiddle,rom_addr[7:0],clk,rst);
 task ram_equal(input [23:0] expected);
  if(q!==expected || qa!==expected || qb!==expected) $fatal(1,"RAM q=%h,%h,%h expected=%h",q,qa,qb,expected);
 endtask
 initial begin : memory_checks
  integer i;
  $readmemh("../assets/osd/osd_font_8x8192.hex",font_ref);
  $readmemh("../assets/osd/anlogic_logo_argb4444.hex",logo_ref);
  $readmemh("../assets/spectrum/hann_q15_16x256.hex",window_ref);
  $readmemh("../assets/spectrum/dft_twiddle_q15_32x256.hex",twiddle_ref);
  #1000; @(negedge clk);rst=0;
  we=1;addr=0;data=24'h123456; @(negedge clk);addr=1;data=24'habcdef;
  @(negedge clk);we=0;addr=0;
  repeat(2) @(posedge clk);#1;ram_equal(24'h123456);
  @(negedge clk);addr=1;
  @(posedge clk);#1;ram_equal(24'h123456);
  @(posedge clk);#1;ram_equal(24'habcdef);
  @(negedge clk);rst=1;#1;ram_equal(24'habcdef);
  @(posedge clk);#1;ram_equal(0);
  @(negedge clk);rst=0;addr=0;
  repeat(2) @(posedge clk);#1;ram_equal(24'h123456);
  @(negedge clk);ce=0;addr=1;
  repeat(3) @(posedge clk);#1;ram_equal(24'h123456);
  @(negedge clk);rst=1;
  @(posedge clk);#1;$display("OBSERVE RAM reset cea=0 q=%h/%h/%h",q,qa,qb);
  @(negedge clk);ce=1;rst=0;
  for(i=0;i<8192;i=i+1) begin
   @(negedge clk);rom_addr=i;
   @(posedge clk);#1;
   if(i>0 && (font!==font_ref[i-1] || logo!==logo_ref[i-1] || window_q!==window_ref[(i-1)%256] || twiddle!==twiddle_ref[(i-1)%256]))
    $fatal(1,"ROM did not retain previous address on first read edge addr=%0d",i);
   @(posedge clk);#1;
   if(font!==font_ref[i] || logo!==logo_ref[i] || window_q!==window_ref[i%256] || twiddle!==twiddle_ref[i%256])
    $fatal(1,"ROM addr=%0d font=%h/%h logo=%h/%h win=%h/%h tw=%h/%h",i,font,font_ref[i],logo,logo_ref[i],window_q,window_ref[i%256],twiddle,twiddle_ref[i%256]);
  end
  @(negedge clk);rst=1;
  #1;if(twiddle!==twiddle_ref[255]) $fatal(1,"ROM reset asserted asynchronously");
  @(posedge clk);#1;if(font!==0 || logo!==0 || window_q!==0 || twiddle!==0) $fatal(1,"ROM synchronous reset output");
  @(negedge clk);rst=0;rom_addr=0;repeat(2) @(posedge clk);#1;
  if(twiddle!==twiddle_ref[0]) $fatal(1,"ROM initialization lost after reset");
  $display("CONFIRMED RAM/ROM: two-edge OUTREG; synchronous reset; contents retained; all ROM words match.");
  wait(fifo_done);$display("PASS: tb_vendor_ip");$finish;
 end
 reg rclk=0;always #17 rclk=~rclk;
 reg frst=1,fwe=0,fre=0;reg [31:0] fdi=0;
 wire [31:0] fdo;wire fe,ff,faf,fae,fvalid,fov,funder,fws,wrd,rdd;wire [9:0] wu,ru;
 fifo_pixel_async fifo(fdi,rclk,frst,fre,clk,frst,fwe,fdo,fe,fae,ff,faf,fvalid,fov,funder,fws,ru,wu,wrd,rdd);
 always @(posedge rclk) begin
  #1;
  if(!frst && fvalid) begin
   if(fdo!==32'hcafe0000+received) $fatal(1,"FIFO order n=%0d q=%h",received,fdo);
   received=received+1;
  end
 end
 initial begin : fifo_checks
  integer i;
  #1100;@(negedge clk);frst=0;
  wait(wrd && rdd);
  if(!fe || wu!=0) $fatal(1,"FIFO reset state");
  for(i=0;i<1023;i=i+1) begin @(negedge clk);fwe=1;fdi=32'hcafe0000+i;end
  @(negedge clk);fwe=0;
  repeat(6) @(posedge clk);#1;
  if(!ff || !faf || wu!=1023) $fatal(1,"FIFO capacity full=%b used=%0d",ff,wu);
  @(negedge rclk);fre=1;
  @(posedge rclk);#1;if(!fvalid || fdo!==32'hcafe0000) $fatal(1,"Normal FIFO read latency");
  wait(received==1023);@(negedge rclk);fre=0;
  repeat(5) @(posedge rclk);#1;
  if(!fe || ru!=0) $fatal(1,"FIFO drain state");
  @(negedge clk);frst=1;
  repeat(5) @(posedge clk);@(negedge clk);frst=0;
  wait(wrd && rdd);repeat(4) @(posedge rclk);#1;
  if(!fe || wu!=0 || ru!=0) $fatal(1,"FIFO second reset");
  $display("CONFIRMED FIFO: 1023 words; normal valid/data ordered; both reset-done handshakes.");fifo_done=1;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
