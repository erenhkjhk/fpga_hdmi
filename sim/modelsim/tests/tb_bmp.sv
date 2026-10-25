`timescale 1ns/1ps
module tb_bmp;
 reg clk=0;always #10 clk=~clk;
 reg rst=1,start=0,cancel=0;reg [31:0] size;
 reg [7:0] data;reg valid=0;wire ready;reg last=0;
 wire begin_valid,bottom_up,pixel_valid,done,complete,error;wire [7:0] code;
 wire [31:0] pixel;reg pixel_ready=0;
 byte unsigned bytes[];
 integer which,w,h,stride,total,index=0,got=0,cycle=0;reg bottom;
 reg stalled=0;reg [31:0] held;
 bmp24_decoder dut(.clk(clk),.rst(rst),.start(start),.cancel(cancel),.file_size(size),
 .file_data(data),.file_valid(valid),.file_ready(ready),.file_last(last),
 .begin_valid(begin_valid),.begin_ready(1'b1),.bottom_up(bottom_up),.pixel_data(pixel),
 .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.done(done),.image_complete(complete),.error(error),.error_code(code));
 function [23:0] source_rgb(input integer x,y);
  integer r,g,b;
  begin r=(17*x+29*y+37)%256;g=(3*x+41*y+91)%256;b=(53*x+7*y+13)%256;source_rgb={r[7:0],g[7:0],b[7:0]};end
 endfunction
 function [23:0] expected(input integer n);
  longint unsigned sx,sy,t,u,v;integer x0,x1,y0,y1,fx,fy,c;
  reg [23:0] a,b,d,e,result;
  begin
   sx=n%640;sx=((sx*(w-1))<<12)/639;
   sy=n/640;sy=((sy*(h-1))<<12)/479;
   x0=sx>>12;x1=x0+1<w?x0+1:x0;fx=sx%4096;
   y0=sy>>12;y1=y0+1<h?y0+1:y0;fy=sy%4096;
   a=source_rgb(x0,bottom?h-1-y0:y0);b=source_rgb(x1,bottom?h-1-y0:y0);
   d=source_rgb(x0,bottom?h-1-y1:y1);e=source_rgb(x1,bottom?h-1-y1:y1);
   for(c=0;c<3;c=c+1) begin
    t=a[c*8+:8]*(4096-fx)+b[c*8+:8]*fx;
    u=d[c*8+:8]*(4096-fx)+e[c*8+:8]*fx;
    v=(t*(4096-fy)+u*fy+8388608)>>24;result[c*8+:8]=v;
   end
   expected=result;
  end
 endfunction
 task put32(input integer offset,value);
  for(integer j=0;j<4;j++) bytes[offset+j]=(value>>(j*8))&255;
 endtask
 always @(negedge clk) begin
  if(!rst && !start) begin
   pixel_ready=(cycle%17!=0 && cycle%17!=1);
   valid=(index<total && cycle%7!=0);data=index<total?bytes[index]:0;last=(index==total-1);
  end
 end
 always @(posedge clk) if(!rst) begin
  cycle=cycle+1;
  if(valid && ready) index=index+1;
  if(stalled && (pixel_valid!==1 || pixel!==held)) $fatal(1,"output changed during backpressure");
  stalled=pixel_valid && !pixel_ready;held=pixel;
  if(pixel_valid && pixel_ready) begin
   if(which<5 && pixel!=={8'd0,expected(got)}) $fatal(1,"BMP case=%0d pixel=%0d xy=%0d,%0d got=%h expected=%h",which,got,got%640,got/640,pixel,expected(got));
   got=got+1;
  end
 end
 initial begin : run_case
  integer x,y;reg [23:0] rgb;
  if(!$value$plusargs("CASE=%d",which)) which=0;
  case(which)
   0:begin w=1;h=1;bottom=0;end
   1:begin w=3;h=2;bottom=1;end
   2:begin w=641;h=481;bottom=0;end
   3:begin w=1920;h=1080;bottom=1;end
   4:begin w=2048;h=1;bottom=0;end
   default:begin w=3;h=2;bottom=0;end
  endcase
  stride=(w*3+3)&~3;total=54+stride*h;bytes=new[total];size=total;
  bytes[0]="B";bytes[1]="M";put32(2,total);put32(10,54);put32(14,40);
  put32(18,w);put32(22,bottom?h:-h);bytes[26]=1;bytes[28]=24;put32(34,stride*h);
  for(y=0;y<h;y++) for(x=0;x<w;x++) begin
   rgb=source_rgb(x,bottom?h-1-y:y);bytes[54+y*stride+x*3]=rgb[7:0];
   bytes[55+y*stride+x*3]=rgb[15:8];bytes[56+y*stride+x*3]=rgb[23:16];
  end
  if(which==5) put32(18,2049);
  if(which==6) begin total=55;size=total;put32(2,total);end
  #1000;@(negedge clk);rst=0;start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(which<5) begin
   if(error || !complete || got!=307200 || bottom_up!==bottom || index!=total)
    $fatal(1,"BMP completion case=%0d error=%b code=%h complete=%b count=%0d input=%0d/%0d",which,error,code,complete,got,index,total);
  end else if(!error || got!=0) $fatal(1,"Invalid BMP not rejected");
  $display("PASS: tb_bmp CASE=%0d W=%0d H=%0d pixels=%0d cycles=%0d",which,w,h,got,cycle);$finish;
 end
 initial begin #500000000;$fatal(1,"BMP timeout index=%0d got=%0d state=%0d",index,got,dut.state);end
endmodule
