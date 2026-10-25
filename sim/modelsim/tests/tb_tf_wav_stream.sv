`timescale 1ns/1ps
// Real SPI/FAT/WAV bandwidth regression, isolated to reproduce starvation
// quickly before spending time on the full HDMI/memory simulation.
module tb_tf_wav_stream;
 reg clk=0;always #10 clk=~clk;reg rst=1;
 wire ao,aor,aod,cat,av,ar,al,done,err,mark,restart,pv,available,fault;
 wire [15:0] count;wire [31:0] size,looplen,pcm;wire [7:0] data;
 wire cs,sck,mosi,miso,storage_error;wire [7:0] ec,se,be;
 integer produced=0,consumed=0,queued=0,acc=0;reg started=0;
 integer cycle=0,first_cycle=0,checks=0;
 fat32_media_top #(.POWER_WAIT_MS(1)) dut(.clk(clk),.rst_n(!rst),.audio_priority(1'b1),
 .audio_bookmark(mark),.audio_restart(restart),.audio_loop_length(looplen),.audio_open(ao),
 .audio_open_ready(aor),.audio_open_done(aod),.audio_count(count),.audio_catalog(cat),
 .audio_size(size),.audio_data(data),.audio_valid(av),.audio_ready(ar),.audio_last(al),.audio_done(done),.audio_error(err),
 .open_valid(1'b0),.open_ready(),.open_index(16'd0),.image_count(),.catalog_ready(),.open_done(),.file_size(),
 .file_data(),.file_valid(),.file_ready(1'b1),.file_last(),.file_done(),.sd_init_done(),.mount_done(),.busy(),
 .error(storage_error),.error_code(ec),.sd_error_code(se),.buffer_error_code(be),
 .sd_cs_n(cs),.sd_sck(sck),.sd_mosi(mosi),.sd_miso(miso));
 wav_pcm_reader wav(.clk(clk),.rst(rst),.catalog_ready(cat),.file_count(count),.open_valid(ao),.open_ready(aor),.open_done(aod),
 .file_size(size),.file_data(data),.file_valid(av),.file_last(al),.file_done(done),.storage_error(err),.file_ready(ar),
 .pcm_data(pcm),.pcm_valid(pv),.pcm_ready(1'b1),.wav_available(available),.fault(fault),
 .bookmark_valid(mark),.loop_restart(restart),.loop_length(looplen));
 sdhc_spi_model card(.cs_n(cs),.sck(sck),.mosi(mosi),.miso(miso));
 function [31:0] word_value(input integer n);
  integer value;
  begin value=((((n/2)%2048)*7919+12345)&32'h3fffff)-32'h200000;if(n%2) value=-value;word_value={(n%2!=0),7'd0,value[23:0]};end
 endfunction
 always @(posedge clk) if(!rst) begin
  cycle++;
  if(pv) begin
   if(pcm!==word_value(produced)) $fatal(1,"SPI WAV sample=%0d value=%h expected=%h",produced,pcm,word_value(produced));
   produced++;queued++;
  end
  if(!started && queued>=2048) begin started=1;first_cycle=cycle;$display("SPI_WAV_START t_ms=%0.3f",$realtime/1000000.0);end
  if(started) begin
   acc+=48000;
   if(acc>=50000000) begin
    acc-=50000000;
    if(queued<2) $fatal(1,"SPI WAV bandwidth underrun t_ms=%0.3f produced=%0d consumed=%0d sectors=%0d",$realtime/1000000.0,produced,consumed,card.sectors);
    consumed+=2;queued-=2;
   end
  end
  if(storage_error || err || fault) $fatal(1,"SPI WAV error ec=%h se=%h be=%h",ec,se,be);
 end
 initial begin
  #1000;@(negedge clk);rst=0;
  #400000000;
  if(consumed<30000 || card.loops<5) $fatal(1,"SPI WAV coverage incomplete");
  $display("PASS: tb_tf_wav_stream physical SPI 5MHz; fragmented WAV; PCM words=%0d played=%0d loops=%0d sectors=%0d queued=%0d",produced,consumed,card.loops,card.sectors,queued);$finish;
 end
endmodule
