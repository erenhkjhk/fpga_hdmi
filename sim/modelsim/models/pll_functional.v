`timescale 1ns/1fs
// Long E2E run only. Real generated PLLs are qualified by tb_pll/top_smoke.
// Avoid encrypted PLL VCO event overhead; retain exact output ratios and 180deg.
module pll_sdram(input refclk,reset,output reg extlock=0,output clk0_out,clk1_out);
 reg c=0;integer n=0;
 always #3.333333 c=~c;
 always @(posedge refclk or posedge reset)
  if(reset) begin n<=0;extlock<=0;end
  else if(n==7) extlock<=1;else n<=n+1;
 assign clk0_out=reset?1'b0:c;
 assign clk1_out=reset?1'b0:~c;
endmodule
module pll_hdmi(input refclk,reset,output reg extlock=0,output clk0_out,clk1_out);
 reg serial=0,pixel=0;integer n=0;
 always #4 serial=~serial;
 always #20 pixel=~pixel;
 always @(posedge refclk or posedge reset)
  if(reset) begin n<=0;extlock<=0;end
  else if(n==7) extlock<=1;else n<=n+1;
 assign clk0_out=reset?1'b0:serial;
 assign clk1_out=reset?1'b0:pixel;
endmodule
