`timescale 1ns/1ps
// Pin-only TMDS sink. Bit-clock is just the receiver sampling clock; symbol
// alignment comes from the transmitted clock lane and control symbols.
// Packet mapping independently checked against HDMI 1.4 packet_assembler,
// audio_sample_packet and tmds_channel in https://github.com/hdl-util/hdmi .
module hdmi_serial_sink(input wire sample_clock,reset,ch0,ch1,ch2,clock_lane);
 reg [9:0] s0=0,s1=0,s2=0,sc=0;reg aligned=0;
 integer countdown=0,guards=0,video_x=0,video_y=0,line_pixels=0;
 integer symbols=0,video_pixels=0,video_frames=0,audio_packets=0,audio_pairs=0,acr_packets=0;
 integer packet_index=-1,n0,n1,n2,k,j;
 reg in_video=0;reg [31:0] header=0;reg [63:0] subpacket[0:3];
 reg [23:0] rgb,audio_left,audio_right;reg [19:0] acr_n,acr_cts;
 event pixel_received,audio_received,frame_received;
 function integer control(input reg [9:0] s);
  case(s)
   10'b1101010100:control=0;10'b0010101011:control=1;
   10'b0101010100:control=2;10'b1010101011:control=3;
   default:control=-1;
  endcase
 endfunction
 function integer terc(input reg [9:0] s);
  case(s)
   10'b1010011100:terc=0;10'b1001100011:terc=1;10'b1011100100:terc=2;10'b1011100010:terc=3;
   10'b0101110001:terc=4;10'b0100011110:terc=5;10'b0110001110:terc=6;10'b0100111100:terc=7;
   10'b1011001100:terc=8;10'b0100111001:terc=9;10'b0110011100:terc=10;10'b1011000110:terc=11;
   10'b1010001110:terc=12;10'b1001110001:terc=13;10'b0101100011:terc=14;10'b1011000011:terc=15;
   default:terc=-1;
  endcase
 endfunction
 function [7:0] video_byte(input reg [9:0] s);
  reg [7:0] q,v;integer b;
  begin
   q=s[9]?~s[7:0]:s[7:0];v[0]=q[0];
   for(b=1;b<8;b++) v[b]=q[b]^q[b-1]^!s[8];
   video_byte=v;
  end
 endfunction
 function [7:0] ecc(input reg [63:0] data,input integer count);
  reg [7:0] value;integer b;
  begin value=0;for(b=0;b<count;b++) value=(value>>1)^((value[0]^data[b])?8'h83:0);ecc=value;end
 endfunction
 task packet_complete;
  integer a;
  begin
   if(header[31:24]!==ecc({32'd0,header},24)) $fatal(1,"HDMI header BCH %h",header);
   for(a=0;a<4;a++) if(subpacket[a][63:56]!==ecc(subpacket[a],56)) $fatal(1,"HDMI subpacket BCH index=%0d data=%h",a,subpacket[a]);
   if(header[7:0]==2) begin
    if(header[12]) $fatal(1,"Unexpected multichannel HDMI layout");
    audio_packets++;
    for(a=0;a<4;a++) if(header[8+a]) begin
     audio_left=subpacket[a][23:0];audio_right=subpacket[a][47:24];
     if((^{subpacket[a][51:48],audio_left})!==0 || (^{subpacket[a][55:52],audio_right})!==0)
      $fatal(1,"HDMI IEC60958 parity");
     audio_pairs++;->audio_received;#0;
    end
   end else if(header[7:0]==1) begin
    acr_packets++;acr_cts={subpacket[0][11:8],subpacket[0][23:16],subpacket[0][31:24]};
    acr_n={subpacket[0][35:32],subpacket[0][47:40],subpacket[0][55:48]};
    if(acr_n!==20'd6144 || acr_cts!==20'd25000) $fatal(1,"HDMI ACR N=%0d CTS=%0d",acr_n,acr_cts);
   end
  end
 endtask
 task symbol_received;
  begin
   symbols++;
   if(control(s0)>=0 && control(s1)>=0 && control(s2)>=0) begin
    if(in_video && line_pixels!=640) $fatal(1,"HDMI active width=%0d",line_pixels);
    in_video=0;guards=0;packet_index=-1;
    // VS active low. A full blank interval resets the active line count.
    if((control(s0)&2)==0) video_y=0;
   end else if(!in_video && s1==10'b0100110011 && s2==10'b1011001100 && s0==10'b1011001100) begin
    // RGB AB55AB can produce these same three words inside active video.
    // Only classify them as guards outside the active 640-pixel interval.
    // Two video guard symbols precede each active line.
    guards++;packet_index=-1;
    if(guards==2) begin
     video_x=0;line_pixels=0;in_video=1;
     if(video_y==0) begin video_frames++;->frame_received;end
    end
   end else if(in_video) begin
    rgb={video_byte(s2),video_byte(s1),video_byte(s0)};
    video_pixels++;line_pixels++;->pixel_received;#0;video_x++;
    if(video_x==640) begin in_video=0;video_y++;end
   end else if(s1==10'b0100110011 && s2==10'b0100110011 && terc(s0)>=12) begin
    guards++;if(guards==2) packet_index=0;
   end else if(packet_index>=0) begin
    n0=terc(s0);n1=terc(s1);n2=terc(s2);
    if(n0<0 || n1<0 || n2<0) $fatal(1,"HDMI invalid TERC4 %h %h %h index=%0d",s0,s1,s2,packet_index);
    header[packet_index]=(n0>>2)&1;
    for(k=0;k<4;k++) begin
     subpacket[k][2*packet_index]=(n1>>k)&1;
     subpacket[k][2*packet_index+1]=(n2>>k)&1;
    end
    if(packet_index==31) begin packet_complete();packet_index=0;end else packet_index++;
   end
  end
 endtask
 always @(posedge sample_clock or negedge sample_clock) begin
  #1;
  if(reset) begin aligned=0;countdown=0;end
  else begin
   s0={ch0,s0[9:1]};s1={ch1,s1[9:1]};s2={ch2,s2[9:1]};sc={clock_lane,sc[9:1]};
   if(!aligned) begin
    if((sc==10'b1111100000 || sc==10'b0000011111) && control(s0)>=0 && control(s1)>=0 && control(s2)>=0) begin
     aligned=1;countdown=10;$display("HDMI_SERIAL_ALIGNED clock=%b",sc);symbol_received();
    end
   end else begin
    countdown--;
    if(countdown==0) begin
     countdown=10;
     if(sc!=10'b1111100000 && sc!=10'b0000011111) $fatal(1,"HDMI clock lane lost alignment %b",sc);
     symbol_received();
    end
   end
  end
 end
endmodule
