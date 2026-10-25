`timescale 1ns/1ps
module tb_pll;
 reg refclk=0;always #10 refclk=~refclk;reg rst=1;
 wire m,m180,serial,pixel,ml,hl;
 pll_sdram mempll(refclk,rst,ml,m,m180);
 pll_hdmi hdpll(refclk,rst,hl,serial,pixel);
 integer mc=0,pc=0,sc=0;reg count_en=0;
 always @(posedge m) if(count_en) mc++;
 always @(posedge pixel) if(count_en) pc++;
 always @(posedge serial) if(count_en) sc++;
 initial begin
  #1000;@(negedge refclk);rst=0;wait(ml && hl);#1000;
  @(negedge refclk);count_en=1;#40000;count_en=0;
  if(mc<5999 || mc>6001 || sc<4999 || sc>5001 || pc<999 || pc>1001) $fatal(1,"PLL frequencies m=%0d serial=%0d pixel=%0d",mc,sc,pc);
  @(posedge m);#0.001;if(m180!==0) $fatal(1,"SDRAM 180 degree positive edge");
  @(negedge m);#0.001;if(m180!==1) $fatal(1,"SDRAM 180 degree negative edge");
  @(negedge refclk);rst=1;repeat(4) @(negedge refclk);
  if(ml!==0 || hl!==0) $fatal(1,"PLL lock did not clear on reset");
  rst=0;wait(ml && hl);
  $display("PASS: tb_pll actual 150/125/25MHz, SDRAM180degree, reset and relock");$finish;
 end
 initial begin #1000000;$fatal(1,"PLL timeout");end
endmodule
