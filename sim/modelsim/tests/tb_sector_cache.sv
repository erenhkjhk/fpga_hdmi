`timescale 1ns/1ps
module tb_sector_cache;
 reg clk=0;always #10 clk=~clk;reg rst=1,load=0,rd=0;
 reg [31:0] lba;reg [8:0] address;wire ready,done,error,valid,rv,req,reqready,rready;
 wire [7:0] data,ec;wire [31:0] requested;
 reg active=0,sd_done=0,pending_done=0;integer offset=0,transactions=0;reg [31:0] sector;
 wire [7:0] incoming=sector_byte(sector,offset);
 assign reqready=!active && !pending_done && !sd_done;
 sd_sector_buffer dut(.clk(clk),.rst_n(!rst),.load_valid(load),.load_ready(ready),.load_lba(lba),.load_done(done),
 .error(error),.error_code(ec),.buf_valid(valid),.rd_en(rd),.rd_addr(address),.rd_data(data),.rd_valid(rv),
 .sd_req_valid(req),.sd_req_ready(reqready),.sd_req_lba(requested),.sd_r_data(incoming),.sd_r_valid(active),
 .sd_r_ready(rready),.sd_r_last(offset==511),.sd_done(sd_done),.sd_error(1'b0));
 function [7:0] sector_byte(input integer s,n);sector_byte=(s*37+n*13)&255;endfunction
 always @(posedge clk) begin
  if(rst) begin active<=0;pending_done<=0;sd_done<=0;offset<=0;end
  else begin
   sd_done<=0;
   if(req && reqready) begin active<=1;offset<=0;sector<=requested;transactions++;end
   if(active && rready) begin
    if(offset==511) begin active<=0;pending_done<=1;end else offset<=offset+1;
   end
   if(pending_done) begin pending_done<=0;sd_done<=1;end
   if(error) $fatal(1,"Sector cache transport error=%h",ec);
  end
 end
 task check_sector(input integer s,expected_transactions);
  integer n;
  begin
   @(negedge clk);load=1;lba=s;
   do @(posedge clk);while(!ready);
   @(negedge clk);load=0;
   wait(done);@(negedge clk);
   if(!valid || transactions!=expected_transactions) $fatal(1,"Cache LBA=%h transactions=%0d expected=%0d valid=%b",s,transactions,expected_transactions,valid);
   for(n=0;n<512;n++) begin
    rd=1;address=n;@(negedge clk);rd=0;wait(rv);#1;
    if(data!==sector_byte(s,n)) $fatal(1,"Cache data lba=%h offset=%0d value=%h",s,n,data);
    @(negedge clk);
   end
  end
 endtask
 initial begin
  #100;@(negedge clk);rst=0;
  check_sector('h11,1);check_sector('h22,2);check_sector('h11,2);
  check_sector('h33,3);check_sector('h11,3);check_sector('h22,4);check_sector('h11,4);
  @(negedge clk);rst=1;repeat(4) @(negedge clk);rst=0;
  check_sector('h11,5);
  $display("PASS: tb_sector_cache 8 full sector comparisons, LRU hits/misses, reset invalidation, requests=%0d",transactions);$finish;
 end
 initial begin #1000000;$fatal(1,"Sector cache timeout");end
endmodule
