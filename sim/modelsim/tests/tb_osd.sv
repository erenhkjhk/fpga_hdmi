`timescale 1ns/1ps
module tb_osd;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,blank=0,iv=0,iu=0,il=0,sv=0,hv=0;reg [23:0] rgb=0;
 reg [65:0] status=0;reg [255:0] heights=0;
 wire [23:0] oq;wire ov,ou,ol;
 reg [23:0] golden[0:307199],observed[0:307199];
 reg [23:0] queue_rgb[0:4095];reg queue_user[0:4095],queue_last[0:4095];
 integer wr=0,rd=0,expected_index=0,phase=0,b,k;reg checking=0;reg [2:0] valid_pipe=0;
 video_compositor dut(clk,rst,blank,rgb,iv,iu,il,status,sv,heights,hv,oq,ov,ou,ol);
 function [7:0] adjust(input integer value,brightness,contrast);
  integer result;
  begin
   result=((value-128)*(contrast==1?5:(contrast==2?3:(contrast==3?6:4)))+2)>>>2;
   result=result+128+(brightness==1?32:(brightness==2?-32:(brightness==3?64:0)));
   adjust=result<0?0:(result>255?255:result);
  end
 endfunction
 always @(posedge clk) if(!rst && checking) begin
  valid_pipe={valid_pipe[1:0],iv};
  if(iv) begin
   queue_rgb[wr%4096]=phase==0?golden[expected_index]:{3{adjust(rgb[7:0],b,k)}};
   queue_user[wr%4096]=iu;queue_last[wr%4096]=il;wr=wr+1;expected_index=expected_index+1;
  end
  #1;
  if(ov!==valid_pipe[2]) $fatal(1,"OSD valid latency");
  if(ov) begin
   if(oq!==queue_rgb[rd%4096] || ou!==queue_user[rd%4096] || ol!==queue_last[rd%4096])
    $fatal(1,"OSD phase=%0d pixel=%0d got=%h expected=%h user=%b/%b last=%b/%b",phase,rd,oq,queue_rgb[rd%4096],ou,queue_user[rd%4096],ol,queue_last[rd%4096]);
   if(phase==0) observed[rd]=oq;rd=rd+1;
  end
 end
 task latch_status;
  @(negedge clk);sv=1;hv=1;@(negedge clk);sv=0;hv=0;
  blank=1;@(negedge clk);blank=0;
 endtask
 initial begin
  $readmemh("../sim/modelsim/build/vectors/osd_frame.hex",golden);
  status={2'b11,24'h123456,16'd12,16'd34,4'b0001,4'b0110};
  for(integer j=0;j<32;j++) heights[j*8+:8]=j*4%121;
  #1000;@(negedge clk);rst=0;latch_status();
  // Accelerate the frame callback only: exactly 1280 blanks move scroll to 0.
  for(integer j=1;j<1280;j++) begin blank=1;@(negedge clk);blank=0;@(negedge clk);end
  if(dut.scroll!=0) $fatal(1,"scroll cadence got=%0d",dut.scroll);
  checking=1;
  for(integer y=0;y<480;y++) begin
   for(integer x=0;x<640;x++) begin
    iv=1;iu=(x==0 && y==0);il=(x==639);rgb={8'((3*x+y)%256),8'((x+5*y)%256),8'((x^y)&255)};
    @(negedge clk);
   end
   iv=0;iu=0;il=0;repeat(10) @(negedge clk);
   if(y==240) begin status[3:0]=15;sv=1;@(negedge clk);sv=0;end
  end
  repeat(5) @(negedge clk);if(rd!=307200) $fatal(1,"OSD frame length");
  $writememh("../sim/modelsim/results/osd_observed.hex",observed);
  checking=0;phase=1;
  for(k=0;k<4;k++) for(b=0;b<4;b++) begin
   status[3:0]={2'(k),2'(b)};latch_status();checking=1;
   for(integer c=0;c<256;c++) begin iv=1;iu=(c==0);il=(c==255);rgb={3{8'(c)}};@(negedge clk);end
   iv=0;iu=0;il=0;repeat(5) @(negedge clk);checking=0;
  end
  $display("PASS: tb_osd full frame + 16 adjustment combinations + frame-latched update");$finish;
 end
 initial begin #20000000;$fatal(1,"OSD timeout");end
endmodule
