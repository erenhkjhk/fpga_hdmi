`timescale 1ns/1ps
`default_nettype none
// Two single-port source lines; OUTREG BRAM read takes two rising edges.
// File-order rows remain in file order. The frame writer handles bottom-up.
module bilinear_scaler (
 input wire clk, rst, start,
 input wire [11:0] width, height,
 input wire [23:0] in_data, input wire in_valid, output wire in_ready,
 output reg [23:0] out_data, output wire out_valid, input wire out_ready,
 output reg complete
);
 localparam FILL=0, LEFT=1, WAIT_L=2, CAP_L=3, WAIT_R=4, CAP_R=5,
            MIX=6, SEND=7, NEXT_ROW=8, IDLE=9, VERTICAL=10;
 reg [3:0] state;
 reg [11:0] source_row, source_x, loaded_row;
 reg [9:0] dx, dy;
 wire [35:0] sx_q = (({26'd0,dx} * (width-12'd1)) << 12) / 639;
 wire [31:0] sy_q = ((dy * (height-12'd1)) << 12) / 479;
 wire [10:0] x0=sx_q[22:12];
 wire [10:0] x1=(x0+12'd1 < width) ? x0+11'd1 : x0;
 wire [11:0] y0=sy_q[23:12];
 wire [11:0] y1=(y0+12'd1 < height) ? y0+12'd1 : y0;
 wire [12:0] wx={1'b0,sx_q[11:0]}, wy={1'b0,sy_q[11:0]};
 wire writing=(state==FILL) && in_valid && in_ready;
 wire [10:0] address=(state==FILL) ? source_x[10:0] :
                          ((state==LEFT || state==WAIT_L) ? x0 : x1);
 wire [23:0] q0,q1;
 ram_scale_line1 u_even (.clka(clk),.rsta(rst),.cea(1'b1),
   .wea(writing && !source_row[0]),.addra(address),.dia(in_data),.doa(q0));
 ram_scale_line1 u_odd (.clka(clk),.rsta(rst),.cea(1'b1),
   .wea(writing && source_row[0]),.addra(address),.dia(in_data),.doa(q1));
 reg [23:0] p00,p01,p10,p11;
 reg [19:0] top_r,top_g,top_b,bot_r,bot_g,bot_b;
 // a + (b-a)*w uses one multiplier per interpolation instead of two.
 // All differences are signed; the final weighted values remain nonnegative.
 function [19:0] horizontal;
  input [7:0] a,b; input [12:0] weight;
  reg signed [8:0] difference;
  reg signed [22:0] weighted,total;
  begin
   difference=$signed({1'b0,b})-$signed({1'b0,a});
   weighted=difference*$signed({1'b0,weight});
   total=$signed({3'd0,a,12'd0})+weighted;
   horizontal=total[19:0];
  end
 endfunction
 function [7:0] vertical;
  input [19:0] a,b; input [12:0] weight;
  reg signed [20:0] difference;
  reg signed [34:0] weighted,total;
  begin
   difference=$signed({1'b0,b})-$signed({1'b0,a});
   weighted=difference*$signed({1'b0,weight});
   total=$signed({3'd0,a,12'd0})+weighted+35'sd8388608;
   vertical=total[31:24];
  end
 endfunction
 assign in_ready=!rst && state==FILL;
 assign out_valid=!rst && state==SEND;
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=IDLE; source_row<=0; source_x<=0; loaded_row<=0; dx<=0; dy<=0;
   complete<=0; out_data<=0; p00<=0;p01<=0;p10<=0;p11<=0;
   top_r<=0;top_g<=0;top_b<=0;bot_r<=0;bot_g<=0;bot_b<=0;
  end else if(start) begin
   state<=FILL;source_row<=0;source_x<=0;loaded_row<=0;dx<=0;dy<=0;complete<=0;
  end else case(state)
   FILL: if(writing) begin
    if(source_x==width-1'b1) begin
     source_x<=0;loaded_row<=source_row;source_row<=source_row+1'b1;
     if(source_row==y1) state<=LEFT;
    end else source_x<=source_x+1'b1;
   end
   LEFT: state<=WAIT_L;
   WAIT_L: state<=CAP_L;
   CAP_L: begin p00<=y0[0]?q1:q0;p10<=y1[0]?q1:q0;state<=WAIT_R;end
   WAIT_R: state<=CAP_R;
   CAP_R: begin p01<=y0[0]?q1:q0;p11<=y1[0]?q1:q0;state<=MIX;end
   MIX: begin
    top_r<=horizontal(p00[23:16],p01[23:16],wx);
    top_g<=horizontal(p00[15:8],p01[15:8],wx);
    top_b<=horizontal(p00[7:0],p01[7:0],wx);
    bot_r<=horizontal(p10[23:16],p11[23:16],wx);
    bot_g<=horizontal(p10[15:8],p11[15:8],wx);
    bot_b<=horizontal(p10[7:0],p11[7:0],wx);
    state<=VERTICAL;
   end
   VERTICAL: begin
    out_data<={vertical(top_r,bot_r,wy),vertical(top_g,bot_g,wy),vertical(top_b,bot_b,wy)};
    state<=SEND;
   end
   SEND: if(out_ready) begin
    if(dx==639) begin
     dx<=0;
     if(dy==479) begin complete<=1;state<=IDLE;end
     else begin dy<=dy+1'b1;state<=NEXT_ROW;end
    end else begin dx<=dx+1'b1;state<=LEFT;end
   end
   NEXT_ROW: state<=(y1<=loaded_row) ? LEFT : FILL;
   default: state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
