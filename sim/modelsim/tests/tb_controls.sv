`timescale 1ns/1ps
module tb_controls;
 reg clk=0;always #10 clk=~clk;
 reg rst=1,tick=0;reg [3:0] sw=0;wire [3:0] stable;wire [23:0] bcd;
 switch_filter filter(clk,rst,tick,sw,stable);
 uptime_counter timer(clk,rst,tick,bcd);
 task ms(input integer n);
  for(integer j=0;j<n;j++) begin @(negedge clk);tick=1;@(negedge clk);tick=0;end
 endtask
 initial begin
  #1000;@(negedge clk);rst=0;
  ms(999);if(bcd!=0) $fatal(1,"uptime early");ms(1);#1;if(bcd!=24'h000001) $fatal(1,"uptime second");
  @(negedge clk);timer.bcd=24'h995959;timer.ms=999;
  ms(1);#1;if(bcd!=0) $fatal(1,"99:59:59 rollover");
  sw=4'hf;repeat(4) @(negedge clk);ms(7);sw=0;repeat(4) @(negedge clk);ms(7);
  if(stable!=0) $fatal(1,"switch bounce passed");
  sw=4'ha;repeat(4) @(negedge clk);ms(20);#1;if(stable!=0) $fatal(1,"switch accepted early");
  ms(1);#1;if(stable!=4'ha) $fatal(1,"switch stable value");
  $display("PASS: tb_controls");$finish;
 end
endmodule
