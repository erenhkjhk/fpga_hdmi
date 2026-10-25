`timescale 1ns/1ps
module tb_dft;
 reg clk=0;always #10 clk=~clk;
 reg rst=1;reg [23:0] sample=0;reg valid=0;wire [255:0] heights;wire hv,overrun;
 reg hr=0;reg [23:0] samples[0:255];reg [7:0] reference_height[0:31];
 integer which,sent=0,received=0;reg [255:0] held;reg stalled=0;
 spectrum_dft dut(clk,rst,sample,valid,heights,hv,hr,overrun);
 initial begin wait(hv);repeat(20) @(negedge clk);hr=1;end
 always @(posedge clk) if(!rst) begin
  if(stalled && (!hv || heights!==held)) $fatal(1,"DFT publish changed under backpressure");
  stalled=hv && !hr;held=heights;
  if(hv && hr) begin
   for(integer b=0;b<32;b++) if(heights[b*8+:8]!==reference_height[b])
    $fatal(1,"DFT case=%0d frame=%0d bar=%0d got=%0d expected=%0d",which,received,b,heights[b*8+:8],reference_height[b]);
   received=received+1;
  end
 end
 initial begin
  string path;
  if(!$value$plusargs("CASE=%d",which)) which=2;
  path=$sformatf("../sim/modelsim/build/vectors/dft_samples_%0d.hex",which);$readmemh(path,samples);
  path=$sformatf("../sim/modelsim/build/vectors/dft_heights_%0d.hex",which);$readmemh(path,reference_height);
  #1000;@(negedge clk);rst=0;
  for(sent=0;sent<768;sent++) begin
   @(negedge clk);sample=samples[sent%256];valid=1;
   @(negedge clk);valid=0;repeat(1040+(sent%3==0)) @(negedge clk);
  end
  wait(received==3);@(negedge clk);
  if(overrun) $fatal(1,"DFT overrun at 48kHz cadence");
  $display("PASS: tb_dft CASE=%0d windows=%0d",which,received);$finish;
 end
 initial begin #30000000;$fatal(1,"DFT timeout sent=%0d received=%0d",sent,received);end
endmodule
