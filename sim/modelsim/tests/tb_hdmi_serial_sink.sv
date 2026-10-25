`timescale 1ns/1ps
// Guard-band words are also legal video encodings of RGB AB55AB. Once the
// active interval starts they must be decoded as pixels, not as new guards.
module tb_hdmi_serial_sink;
 reg clk=0;always #4 clk=~clk;reg reset=1,b=0,g=0,r=0,c=0;
 integer received=0;
 hdmi_serial_sink sink(.sample_clock(clk),.reset(reset),.ch0(b),.ch1(g),.ch2(r),.clock_lane(c));
 task symbol(input reg [9:0] blue,green,red);
  integer bitn;
  begin
   for(bitn=0;bitn<10;bitn++) begin
    @(posedge clk or negedge clk);b=blue[bitn];g=green[bitn];r=red[bitn];c=(bitn<5);
   end
   #2;
  end
 endtask
 always @(sink.pixel_received) begin
  if(sink.rgb !== (received<10?24'hab55ab:24'h000000)) $fatal(1,"Sink RGB index=%0d rgb=%h",received,sink.rgb);
  received++;
 end
 initial begin
  #100;reset=0;
  repeat(12) symbol(10'b1101010100,10'b1101010100,10'b1101010100);
  repeat(2) symbol(10'b1011001100,10'b0100110011,10'b1011001100);
  repeat(10) symbol(10'b1011001100,10'b0100110011,10'b1011001100);
  for(integer i=0;i<630;i++) symbol(i%2?10'h3ff:10'h100,i%2?10'h3ff:10'h100,i%2?10'h3ff:10'h100);
  repeat(4) symbol(10'b1101010100,10'b1101010100,10'b1101010100);
  if(received!=640) $fatal(1,"Sink lost pixels count=%0d",received);
  $display("PASS: tb_hdmi_serial_sink 640 physical pixels; active RGB AB55AB shares guard words; LSB-first alignment");$finish;
 end
 initial begin #100000;$fatal(1,"HDMI sink timeout");end
endmodule
