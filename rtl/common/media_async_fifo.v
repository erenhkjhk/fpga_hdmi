`timescale 1ns/1ps
`default_nettype none
// Reuses the TD-generated 32x1024 asynchronous FIFO (1023 usable words).
module media_async_fifo (
 input wire wr_clk,wr_rst,rd_clk,rd_rst,
 input wire [31:0] in_data,input wire in_valid,output wire in_ready,
 output wire [31:0] out_data,output wire out_valid,input wire out_re,
 output wire out_empty,out_ready,output wire [9:0] wr_used,rd_used,
 output wire overflow,underflow
);
 wire wr_done,rd_done,rd_done_wr,wr_done_rd,full,afull;
 assign in_ready=wr_done && rd_done_wr && !full && !afull && !wr_rst;
 assign out_ready=rd_done && wr_done_rd && !rd_rst;
 cdc_level u_rd_done (.clk(wr_clk),.rst(wr_rst),.async_data(rd_done),.sync_data(rd_done_wr));
 cdc_level u_wr_done (.clk(rd_clk),.rst(rd_rst),.async_data(wr_done),.sync_data(wr_done_rd));
 fifo_pixel_async u_fifo (.di(in_data),.clkw(wr_clk),.wrst(wr_rst),.we(in_valid && in_ready),
  .clkr(rd_clk),.rrst(rd_rst),.re(out_re && out_ready && !out_empty),.dout(out_data),
  .empty_flag(out_empty),.aempty(),.full_flag(full),.afull(afull),.valid(out_valid),
  .overflow(overflow),.underflow(underflow),.wr_success(),.wrusedw(wr_used),.rdusedw(rd_used),
  .wr_rst_done(wr_done),.rd_rst_done(rd_done));
endmodule
`default_nettype wire
