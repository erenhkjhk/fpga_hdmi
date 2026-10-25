`timescale 1ns/1ps
module tb_wav;
 reg clk=0;always #10 clk=~clk;
 reg rst=1,catalog=0;wire ov;reg ory=1,od=0;
 reg [31:0] size;wire [7:0] data;wire fv,fl,fr,done,mark,restart,available,fault,pv;
 wire [31:0] pd,looplen;reg pr=0;reg io_error=0;
 byte unsigned bytes[0:2047];integer which,total,index=0,cycle=0,words=0,loops=0,book=-1;
 reg opened=0;integer firstdata;reg [31:0] held;reg stalled=0;
 wav_pcm_reader dut(.clk(clk),.rst(rst),.catalog_ready(catalog),.file_count(16'd1),.open_valid(ov),
 .open_ready(ory),.open_done(od),.file_size(size),.file_data(data),.file_valid(fv),.file_last(fl),
 .file_done(done),.storage_error(io_error),.file_ready(fr),.pcm_data(pd),.pcm_valid(pv),.pcm_ready(pr),
 .wav_available(available),.fault(fault),.bookmark_valid(mark),.loop_restart(restart),.loop_length(looplen));
 assign fv=opened && index<total && cycle%5!=0;
 assign data=bytes[index];assign fl=(index==total-1);assign done=0;
 function [31:0] sample_word(input integer n);
  integer v;
  begin v=(n/2)*12345+17;if(n%2) v=-v;sample_word={(n%2!=0),7'd0,v[23:0]};end
 endfunction
 task put(input integer offset,value,count);
  for(integer j=0;j<count;j++) bytes[offset+j]=(value>>(8*j))&255;
 endtask
 always @(negedge clk) if(!rst) pr=cycle%13!=0 && cycle%13!=1 && cycle%13!=2;
 always @(posedge clk) if(!rst) begin
  cycle=cycle+1;
  if(ov && ory) begin opened<=1;index<=0;end
  else if(restart) begin
   if(book!=firstdata || looplen!=198) $fatal(1,"bookmark mismatch offset=%0d/%0d len=%0d",book,firstdata,looplen);
   index<=book;loops=loops+1;
  end else if(fv && fr) begin if(mark) book=index;index<=index+1;end
  if(stalled && (!pv || pd!==held)) $fatal(1,"WAV output changed during stall");
  stalled=pv && !pr;held=pd;
  if(pv && pr) begin
   if(pd!==sample_word(words%66)) $fatal(1,"WAV word %0d got=%h want=%h",words,pd,sample_word(words%66));
   words=words+1;
  end
 end
 initial begin : run_case
  integer j,offset;reg [31:0] word;
  if(!$value$plusargs("CASE=%d",which)) which=0;
  foreach(bytes[j]) bytes[j]=0;
  put(0,32'h46464952,4);put(8,32'h45564157,4);
  // Unknown odd chunk precedes an extended odd fmt block.
  put(12,32'h4b4e554a,4);put(16,3,4);bytes[20]=1;bytes[21]=2;bytes[22]=3;
  put(24,32'h20746d66,4);put(28,19,4);put(32,1,2);put(34,2,2);
  put(36,48000,4);put(40,288000,4);put(44,6,2);put(46,24,2);
  put(52,32'h61746164,4);put(56,198,4);firstdata=60;
  for(j=0;j<66;j++) begin word=sample_word(j);put(firstdata+j*3,word[23:0],3);end
  total=firstdata+198;put(4,total-8,4);size=total;
  if(which==1) put(36,44100,4);
  if(which==2) put(56,197,4);
  if(which==3) put(28,4096,4);
  if(which==4) put(32,3,2);
  #1000;@(negedge clk);rst=0;catalog=1;
  if(which==0) begin wait(loops==3);if(fault || !available || words!=198) $fatal(1,"WAV loop finish");end
  else begin wait(fault);if(words!=0 || available) $fatal(1,"bad WAV emitted data");end
  $display("PASS: tb_wav CASE=%0d words=%0d loops=%0d",which,words,loops);$finish;
 end
 initial begin #1000000;$fatal(1,"WAV timeout state=%0d index=%0d",dut.state,index);end
endmodule
