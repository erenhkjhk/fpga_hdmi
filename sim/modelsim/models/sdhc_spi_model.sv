`timescale 1ns/1ps
// Read-only SDHC card in SPI mode 0. Host sees only CS/SCK/MOSI/MISO.
// Sparse FAT32 sectors from generate_e2e_media.py, including fragmented WAV.
module sdhc_spi_model(input wire cs_n,sck,mosi,output wire miso);
 reg [7:0] image[0:65535];reg [31:0] lbas[0:127];
 reg [7:0] reply[0:1023];reg [7:0] command[0:5];
 reg [7:0] receive=0,transmit=8'hff;reg miso_bit=1;
 integer bits=0,command_bytes=0,head=0,tail=0;
 integer commands=0,sectors=0,power_clocks=0,loops=0;
 integer cmd,arg,i,hit,reads_picture0=0,reads_picture1=0,reads_music=0;
 reg idle=1,app=0,initialized=0;
 assign miso=cs_n?1'b1:miso_bit;
 initial begin
  $readmemh("../sim/modelsim/build/e2e_card.mem",image);
  $readmemh("../sim/modelsim/build/e2e_card.lba",lbas);
 end
 task enqueue(input reg [7:0] value);
  begin if(tail>=1024) $fatal(1,"SD reply overflow");reply[tail]=value;tail++;end
 endtask
 task execute_command;
  integer k,n;
  begin
   cmd=command[0]&63;arg={command[1],command[2],command[3],command[4]};commands++;
   if(tail!=head) $fatal(1,"SD command before previous response drained");
   head=0;tail=0;enqueue(8'hff);
   case(cmd)
    0: begin
     if(power_clocks<74 || arg!=0 || command[5]!=8'h95) $fatal(1,"SD CMD0 power/CRC");
     idle=1;initialized=0;enqueue(1);
    end
    8: begin
     if(arg!=32'h1aa || command[5]!=8'h87) $fatal(1,"SD CMD8 argument/CRC");
     enqueue(1);enqueue(0);enqueue(0);enqueue(1);enqueue(8'haa);
    end
    55: begin app=1;enqueue(idle?1:0);end
    41: begin
     if(!app || !arg[30]) $fatal(1,"SD ACMD41 missing CMD55/HCS");
     idle=0;initialized=1;app=0;enqueue(0);
    end
    58: begin enqueue(idle?1:0);enqueue(8'hc0);enqueue(0);enqueue(0);enqueue(0);end
    59: enqueue(idle?1:0);
    17: begin
     if(!initialized) $fatal(1,"SD read before initialization");
     hit=-1;for(k=0;k<128;k++) if(lbas[k]==arg) hit=k;
     if(hit<0) $fatal(1,"SD read unpopulated LBA=%0d",arg);
     enqueue(0);enqueue(8'hff);enqueue(8'hff);enqueue(8'hfe);
     for(n=0;n<512;n++) enqueue(image[hit*512+n]);
     enqueue(8'hff);enqueue(8'hff);sectors++;
     if(arg==546) reads_picture0++;
     else if(arg==547) reads_picture1++;
     else if(arg>=550 && arg<620) begin reads_music++;if(arg==550) loops++;end
    end
    default: $fatal(1,"Unexpected SD command CMD%0d",cmd);
   endcase
  end
 endtask
 always @(posedge sck or posedge cs_n) begin
  if(cs_n) begin bits=0;receive=0;command_bytes=0;tail=0;if(sck) power_clocks++;end
  else begin
   receive={receive[6:0],mosi};bits=(bits+1)%8;
   if(bits==0) begin
    if(command_bytes==0) begin
     if(receive[7:6]==2'b01) begin command[0]=receive;command_bytes=1;end
    end else begin
     command[command_bytes]=receive;command_bytes++;
     if(command_bytes==6) begin execute_command();command_bytes=0;end
    end
   end
  end
 end
 always @(negedge sck or posedge cs_n) begin
  if(cs_n) begin head=0;transmit=8'hff;miso_bit=1;end
  else begin
   if(bits==0) begin
    if(head<tail) begin transmit=reply[head];head++;end else transmit=8'hff;
   end
   miso_bit=transmit[7-bits];
  end
 end
endmodule
