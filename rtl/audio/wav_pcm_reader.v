`timescale 1ns/1ps
`default_nettype none
// RIFF/WAVE PCM, stereo signed 24-bit little endian at 48 kHz.
// Chunk lengths (including odd-byte padding) are checked before consuming them.
module wav_pcm_reader (
 output wire bookmark_valid,loop_restart, output wire [31:0] loop_length,
 input wire clk,rst, catalog_ready, input wire [15:0] file_count,
 output wire open_valid, input wire open_ready,open_done,
 input wire [31:0] file_size, input wire [7:0] file_data,
 input wire file_valid,file_last,file_done,storage_error,
 output wire file_ready, output wire [31:0] pcm_data,
 output wire pcm_valid, input wire pcm_ready,
 output reg wav_available, output reg fault
);
 localparam IDLE=0,OPEN=1,HEAD=2,CHUNK=3,CHECK=4,FMT=5,SKIP=6,
            DATA=7,LEFT=8,RIGHT=9,FAILED=12,CHECK_HEAD=13,CHECK_FMT=14;
 reg [3:0] state;
 reg [31:0] position,riff_end,chunk_id,chunk_size,remaining;
 reg [31:0] riff_tag,wave_tag,riff_size,sample_rate,byte_rate;
 reg [15:0] format_tag,channels,align_bytes,bits;
 reg [5:0] index;
 reg fmt_ok,chunk_pad,bookmark_sent;
 reg [31:0] data_length;
 assign bookmark_valid=state==DATA && !bookmark_sent;
 assign loop_restart=state==RIGHT && pcm_ready && remaining==0;
 assign loop_length=data_length;
 reg [47:0] pair;
 wire take=file_valid && file_ready;
 wire [32:0] chunk_end={1'b0,position}+{1'b0,chunk_size}+chunk_size[0];
 wire format_ok=format_tag==1 && channels==2 && sample_rate==48000
               && byte_rate==288000 && align_bytes==6 && bits==24;
 assign open_valid=state==OPEN;
 assign file_ready=!rst && (state==HEAD || state==CHUNK || state==FMT
                   || state==SKIP || state==DATA);
 assign pcm_valid=!rst && (state==LEFT || state==RIGHT);
 assign pcm_data=(state==RIGHT) ? {1'b1,7'd0,pair[47:24]} : {8'd0,pair[23:0]};
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=IDLE;position<=0;riff_end<=0;chunk_id<=0;chunk_size<=0;remaining<=0;
   riff_tag<=0;wave_tag<=0;riff_size<=0;sample_rate<=0;byte_rate<=0;
   format_tag<=0;channels<=0;align_bytes<=0;bits<=0;index<=0;
   bookmark_sent<=0;data_length<=0;fmt_ok<=0;chunk_pad<=0;pair<=0;wav_available<=0;fault<=0;
  end else if(storage_error) begin state<=FAILED;fault<=1;wav_available<=0;end
  else begin
   if(take && state!=DATA) position<=position+1'b1;
   case(state)
    IDLE: if(catalog_ready) begin
     if(file_count!=0) state<=OPEN; else state<=FAILED;
    end
    OPEN: if(open_valid && open_ready) begin
     state<=HEAD;index<=0;position<=0;fmt_ok<=0;
    end
    HEAD: if(take) begin
     if(index<4) riff_tag[index*8+:8]<=file_data;
     else if(index<8) riff_size[(index-4)*8+:8]<=file_data;
     else wave_tag[(index-8)*8+:8]<=file_data;
     index<=index+1'b1;
     if(index==11) begin state<=CHECK_HEAD; index<=0;end
     if(file_last) begin fault<=1;state<=FAILED;wav_available<=0;end
    end
    CHECK_HEAD: begin
     if(riff_tag!=32'h46464952 || wave_tag!=32'h45564157 || riff_size<4
        || {1'b0,riff_size}+33'd8>file_size) begin fault<=1;state<=FAILED;wav_available<=0;end
     else begin riff_end<=riff_size+8;state<=CHUNK;end
    end
    CHUNK: if(take) begin
     if(index<4) chunk_id[index*8+:8]<=file_data;
     else chunk_size[(index-4)*8+:8]<=file_data;
     if(index==7) begin index<=0;state<=CHECK;end else index<=index+1'b1;
     if(file_last) begin fault<=1;state<=FAILED;wav_available<=0;end
    end
    CHECK: begin
     remaining<=chunk_size;chunk_pad<=chunk_size[0];index<=0;
     if(chunk_end>riff_end || chunk_end>file_size) begin fault<=1;state<=FAILED;wav_available<=0;end
     else if(chunk_id==32'h20746D66) begin
      if(chunk_size<16 || fmt_ok) begin fault<=1;state<=FAILED;wav_available<=0;end
      else state<=FMT;
     end else if(chunk_id==32'h61746164) begin
      if(!fmt_ok || chunk_size==0 || chunk_size%6!=0) begin fault<=1;state<=FAILED;wav_available<=0;end
      else begin state<=DATA;wav_available<=1;data_length<=chunk_size;bookmark_sent<=0;end
     end else if(chunk_size==0) state<=CHUNK;
     else state<=SKIP;
    end
    FMT: if(take) begin
     case(index)
      0:format_tag[7:0]<=file_data;1:format_tag[15:8]<=file_data;
      2:channels[7:0]<=file_data;3:channels[15:8]<=file_data;
      4,5,6,7:sample_rate[(index-4)*8+:8]<=file_data;
      8,9,10,11:byte_rate[(index-8)*8+:8]<=file_data;
      12:align_bytes[7:0]<=file_data;13:align_bytes[15:8]<=file_data;
      14:bits[7:0]<=file_data;15:bits[15:8]<=file_data;
      default: begin end
     endcase
     remaining<=remaining-1'b1;index<=index+1'b1;
     if(index==15) state<=CHECK_FMT;
     if(file_last) begin fault<=1;state<=FAILED;wav_available<=0;end
    end
    CHECK_FMT: begin
     if(!format_ok) begin fault<=1;state<=FAILED;wav_available<=0;end
     else begin fmt_ok<=1;index<=0;
      if(remaining!=0) state<=SKIP;
      else if(chunk_pad) begin remaining<=1;chunk_pad<=0;state<=SKIP;end
      else state<=CHUNK;
     end
    end
    SKIP: if(take) begin
     remaining<=remaining-1'b1;
     if(remaining==1) begin
      if(chunk_pad) begin remaining<=1;chunk_pad<=0;end
      else begin index<=0;state<=CHUNK;end
     end
     if(file_last || position+1>=riff_end) begin fault<=1;state<=FAILED;wav_available<=0;end
    end
    DATA: if(take) begin
     bookmark_sent<=1;
     pair[index*8+:8]<=file_data;remaining<=remaining-1'b1;
     if(index==5) begin index<=0;state<=LEFT;end else index<=index+1'b1;
     if(file_last && remaining!=1) begin fault<=1;state<=FAILED;wav_available<=0;end
    end
    LEFT: if(pcm_ready) state<=RIGHT;
    RIGHT: if(pcm_ready) begin
     if(remaining!=0) state<=DATA;
     else begin state<=DATA;remaining<=data_length;index<=0;end
    end
    default: begin end
   endcase
  end
 end
endmodule
`default_nettype wire
