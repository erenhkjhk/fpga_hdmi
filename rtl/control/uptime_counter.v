`timescale 1ns/1ps
`default_nettype none
module uptime_counter(input wire clk,rst,tick_ms,output reg [23:0] bcd);
 reg [9:0] ms;
 always @(posedge clk or posedge rst) begin
  if(rst) begin ms<=0;bcd<=0;end
  else if(tick_ms) begin
   if(ms==999) begin
    ms<=0;
    if(bcd[3:0]!=9) bcd[3:0]<=bcd[3:0]+1'b1;
    else begin bcd[3:0]<=0;
     if(bcd[7:4]!=5) bcd[7:4]<=bcd[7:4]+1'b1;
     else begin bcd[7:4]<=0;
      if(bcd[11:8]!=9) bcd[11:8]<=bcd[11:8]+1'b1;
      else begin bcd[11:8]<=0;
       if(bcd[15:12]!=5) bcd[15:12]<=bcd[15:12]+1'b1;
       else begin bcd[15:12]<=0;
        if(bcd[19:16]!=9) bcd[19:16]<=bcd[19:16]+1'b1;
        else begin bcd[19:16]<=0;bcd[23:20]<=bcd[23:20]==9?4'd0:bcd[23:20]+1'b1;end
       end
      end
     end
    end
   end else ms<=ms+1'b1;
  end
 end
endmodule
`default_nettype wire
