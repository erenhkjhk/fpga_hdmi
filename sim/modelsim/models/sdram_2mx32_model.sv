`timescale 1ns/1ps
// Functional SDR SDRAM device, 4 banks x 2048 rows x 256 columns x 32 bits.
// Connected ONLY to the real controller's physical pins, never App_* signals.
// Checks bank state, burst ordering, DQ ownership and byte masks. Not a
// replacement for a device timing/SI signoff model (no analog timing checks).
module sdram_2mx32_model(
 input wire clk,ras_n,cas_n,we_n,input wire [1:0] ba,
 input wire [10:0] addr,input wire [3:0] dm,inout wire [31:0] dq
);
 reg [31:0] mem[0:2097151];
 reg [3:0] bank_open=0;
 integer row[0:3];
 integer burst_length=1,cas_latency=3,cycle=0;
 reg interleave=0,single_write=0;
 reg drive=0;reg [31:0] dout;
 assign dq=drive?dout:32'bz;
 integer due[0:63],location[0:63];reg close_after[0:63];integer queued_bank[0:63];
 integer wr_left=0,wr_bank,wr_row,wr_column,wr_beat;reg wr_ap;
 integer writes=0,reads=0,refreshes=0,activates=0,modes=0;
 integer i,j,slot,index,col;
 function integer column(input integer base,beat);
  if(interleave) column=(base & ~(burst_length-1)) | ((base ^ beat)&(burst_length-1));
  else column=(base & ~(burst_length-1)) | ((base+beat)&(burst_length-1));
 endfunction
 task store_word(input integer address);
  integer lane;
  begin
   if(drive) $fatal(1,"SDRAM DQ contention write while device drives");
   for(lane=0;lane<4;lane++) if(!dm[lane]) begin
    if($isunknown(dq[lane*8+:8])) $fatal(1,"SDRAM write unknown addr=%h dq=%h dm=%h",address,dq,dm);
    mem[address][lane*8+:8]=dq[lane*8+:8];
   end
   writes++;
  end
 endtask
 initial for(i=0;i<64;i++) due[i]=-1;
 always @(posedge clk) begin
  cycle=cycle+1;slot=cycle%64;
  // Change read data after clock-to-output delay, safely before the controller
  // samples on the opposite 180-degree clock phase.
  drive <= #1 0;
  if(due[slot]==cycle) begin
   dout <= #1 mem[location[slot]];drive <= #1 1;reads++;
   if(close_after[slot]) bank_open[queued_bank[slot]]=0;
   due[slot]=-1;
  end
  if(wr_left>0) begin
   store_word((wr_bank<<19)|(wr_row<<8)|column(wr_column,wr_beat));
   wr_beat++;wr_left--;
   if(wr_left==0 && wr_ap) bank_open[wr_bank]=0;
  end
  case({ras_n,cas_n,we_n})
   3'b011: begin
    if(bank_open[ba]) $fatal(1,"SDRAM ACTIVE on open bank=%0d row=%h",ba,addr);
    bank_open[ba]=1;row[ba]=addr;activates++;
   end
   3'b010: begin
    if(addr[10]) bank_open=0;else bank_open[ba]=0;
   end
   3'b000: begin
    if(bank_open!=0) $fatal(1,"SDRAM MRS with open banks");
    burst_length=1<<addr[2:0];cas_latency=addr[6:4];interleave=addr[3];single_write=addr[9];modes++;
    if(burst_length>8 || (cas_latency!=2 && cas_latency!=3)) $fatal(1,"Unsupported SDRAM MRS=%h",addr);
    $display("SDRAM_MODE BL=%0d CL=%0d sequential=%b write_single=%b",burst_length,cas_latency,!interleave,single_write);
   end
   3'b001: begin
    if(bank_open!=0 || wr_left>0 || drive) $fatal(1,"SDRAM refresh before precharge/drain banks=%b",bank_open);
    refreshes++;
   end
   3'b100: begin
    if(!bank_open[ba] || wr_left!=0) $fatal(1,"SDRAM WRITE bank/burst invalid bank=%0d",ba);
    wr_bank=ba;wr_row=row[ba];wr_column=addr[7:0];wr_beat=0;wr_ap=addr[10];
    store_word((wr_bank<<19)|(wr_row<<8)|wr_column);
    wr_beat=1;wr_left=single_write?0:burst_length-1;
    if(wr_left==0 && wr_ap) bank_open[ba]=0;
   end
   3'b101: begin
    if(!bank_open[ba] || wr_left>0) $fatal(1,"SDRAM READ bank/burst invalid bank=%0d",ba);
    for(j=0;j<burst_length;j++) begin
     index=(cycle+cas_latency+j)%64;
     if(due[index]!=-1) $fatal(1,"SDRAM read bursts overlap");
     due[index]=cycle+cas_latency+j;
     location[index]=(int'(ba)<<19)|(row[ba]<<8)|column(addr[7:0],j);
     close_after[index]=addr[10] && j==burst_length-1;queued_bank[index]=ba;
    end
   end
   3'b110: begin wr_left=0;for(j=0;j<64;j++) due[j]=-1;end
   default: ;
  endcase
 end
endmodule
