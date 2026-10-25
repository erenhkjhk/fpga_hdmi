`timescale 1ns/1ps
`default_nettype none
module switch_filter #(parameter [3:0] ACTIVE_LOW=4'b0000) (
 input wire clk,rst,tick_ms,input wire [3:0] switches,output reg [3:0] stable
);
 wire [3:0] synchronized;
 reg [3:0] candidate;
 reg [4:0] age;
 cdc_level #(.WIDTH(4)) u_sync (.clk(clk),.rst(rst),.async_data(switches ^ ACTIVE_LOW),.sync_data(synchronized));
 always @(posedge clk or posedge rst) begin
  if(rst) begin stable<=0;candidate<=0;age<=0;end
  else if(tick_ms) begin
   if(synchronized!=candidate) begin candidate<=synchronized;age<=0;end
   else if(age<20) begin
    age<=age+1'b1;
    if(age==19) stable<=candidate;
   end
  end
 end
endmodule
`default_nettype wire
