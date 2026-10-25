`timescale 1ns/1ps
module tb_sdram_physical #(parameter USE_REAL_PLL=0);
 wire clk,shifted,clock_locked;
 reg rst=1;wire init,refresh,busy,valid;wire [31:0] data;
 generate if(USE_REAL_PLL) begin : real_clock
  reg refclk=0;always #10 refclk=~refclk;
  pll_sdram u_pll(.refclk(refclk),.reset(rst),.extlock(clock_locked),.clk0_out(clk),.clk1_out(shifted));
 end else begin : ideal_clock
  reg generated=0;always #3.333333 generated=~generated;
  assign clk=generated;assign shifted=~generated;assign clock_locked=1'b1;
 end endgenerate
 reg wr=0,rd=0,refreq=0;reg [20:0] wa=0,ra=0;reg [31:0] wd=0;reg [3:0] mask=0;
 sdram_ram_wrapper #(.SELF_REFRESH_OPEN(0)) dut(.Sdr_clk(clk),.Sdr_clk_sft(shifted),.Rst(rst || !clock_locked),
 .Sdr_init_done(init),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),.App_ref_req(refreq),
 .App_wr_en(wr),.App_wr_addr(wa),.App_wr_din(wd),.App_wr_dm(mask),.App_rd_en(rd),.App_rd_addr(ra),
 .Sdr_rd_en(valid),.Sdr_rd_dout(data));
 sdram_2mx32_model device(.clk(dut.sdram_clk),.ras_n(dut.sdr_ras),.cas_n(dut.sdr_cas),.we_n(dut.sdr_we),
 .ba(dut.sdr_ba),.addr(dut.sdr_addr),.dm(dut.sdr_dm),.dq(dut.sdr_dq));
 integer got=0,base=0,cycle=0,first_request=-1,first_response=-1,output_response=-1,checked=0;
 reg masked_test=0;reg [31:0] expected;
 function [31:0] pattern(input integer a);pattern=32'h9638fa01 ^ (a*32'h10207);endfunction
 always @(posedge clk) begin
  cycle++;
  if(rd && first_request<0) first_request=cycle;
  if(valid) begin
   if(first_response<0) first_response=cycle;
   expected=pattern(base+got);
   if(masked_test && got<4) expected=(expected&32'hff00ff00)|32'h00ff00ff;
   if(data!==expected) $fatal(1,"Physical SDRAM data index=%0d got=%h exp=%h request=%0d response=%0d",got,data,expected,first_request,first_response);
   got++;checked++;
  end
 end
 always @(posedge clk) begin
  #0.001;if(valid && output_response<0) output_response=cycle;
 end
 task block_test(input integer address);
  integer j;
  begin
   base=address;got=0;first_request=-1;first_response=-1;output_response=-1;
   for(j=0;j<64;j++) begin @(negedge clk);wr=1;wa=address+j;wd=pattern(address+j);end
   @(negedge clk);wr=0;repeat(40) @(negedge clk);
   for(j=0;j<64;j++) begin rd=1;ra=address+j;@(negedge clk);end
   rd=0;wait(got==64);repeat(40) @(negedge clk);
   if(output_response-first_request!=10 || first_response-first_request!=11) $fatal(1,"SDRAM read latency changed");
   $display("PHYSICAL_BLOCK base=%h words=%0d output_latency=%0d downstream_latency=%0d",address,got,output_response-first_request,first_response-first_request);
  end
 endtask
 initial begin
  #100;rst=0;wait(init);repeat(20) @(negedge clk);
  block_test(0);block_test(240);block_test(307200);block_test(1048576);block_test(2097088);
  @(negedge clk);refreq=1;@(negedge clk);refreq=0;wait(refresh);wait(!refresh);repeat(20) @(negedge clk);
  // Refresh must preserve data, including the highest bank/row.
  got=0;first_request=-1;first_response=-1;
  for(integer j=0;j<64;j++) begin rd=1;ra=base+j;@(negedge clk);end
  rd=0;wait(got==64);repeat(40) @(negedge clk);
  for(integer j=0;j<4;j++) begin wr=1;wa=j;wd=32'hffffffff;mask=4'b1010;@(negedge clk);end
  wr=0;repeat(40) @(negedge clk);
  masked_test=1;got=0;base=0;first_request=-1;first_response=-1;
  for(integer j=0;j<64;j++) begin rd=1;ra=j;@(negedge clk);end
  rd=0;wait(got==64);repeat(40) @(negedge clk);
  if(device.writes!=324 || device.reads!=448 || device.refreshes<1) $fatal(1,"Physical command totals writes=%0d reads=%0d refresh=%0d",device.writes,device.reads,device.refreshes);
  if(USE_REAL_PLL) $display("PASS: tb_sdram_physical_pll actual generated PLL 150MHz/180deg; words=%0d writes=%0d reads=%0d refreshes=%0d",checked,device.writes,device.reads,device.refreshes);
  else $display("PASS: tb_sdram_physical words=%0d writes=%0d reads=%0d refreshes=%0d",checked,device.writes,device.reads,device.refreshes);
  $finish;
 end
 initial begin #5000000;$fatal(1,"Physical SDRAM timeout init=%b got=%0d",init,got);end
endmodule
module tb_sdram_physical_pll;
 tb_sdram_physical #(.USE_REAL_PLL(1)) qualification();
endmodule
