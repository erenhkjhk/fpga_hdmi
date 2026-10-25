`timescale 1ns/1ps
// Sector-transport boundary: real FAT32, arbitration, two sector buffers, WAV.
// SPI/card initialization itself is exercised separately by the top smoke test.
module tb_fat_media;
 reg clk=0;always #10 clk=~clk;reg rst=1;
 wire open_ready,open_done,cat,file_valid,file_ready,file_last,file_done,init,mount,busy,err;
 reg open_valid=0;wire [15:0] count;wire [31:0] size;wire [7:0] data,ec,se,be;
 wire aopen,aory,aod,acat,av,ardy,al,adone,aerr;wire [15:0] acount;wire [31:0] asize;wire [7:0] adata;
 wire mark,restart,pv,available,wfault;wire [31:0] looplen,pcm;
 reg pcm_ready=0;integer cycle=0,got=0,image_bytes=0,loops=0,transactions=0;
 reg transport_busy=0;integer offset=-1,lba=-1;reg transport_done=0,pending_done=0;
 wire transport_valid=transport_busy && cycle%3!=0;
 byte unsigned boot[0:511],directory[0:511],fat[0:511],picture[0:77],music[0:707];
 wire [7:0] transport_data=sector_byte(lba,offset);
 wire [31:0] expected_pcm=sample_word(got%66);
 function [31:0] sample_word(input integer n);
  integer value;
  begin value=n/2*357+19;if(n%2) value=-value;sample_word={(n%2!=0),7'd0,value[23:0]};end
 endfunction
 function [7:0] sector_byte(input integer sector,byte_index);
  if(sector==0) sector_byte=boot[byte_index];
  else if(sector==32) sector_byte=fat[byte_index];
  else if(sector==545) sector_byte=directory[byte_index];
  else if(sector==546) sector_byte=byte_index<78?picture[byte_index]:0;
  else if(sector==548) sector_byte=music[byte_index];
  else if(sector==552) sector_byte=byte_index<196?music[512+byte_index]:0;
  else sector_byte=0;
 endfunction
 fat32_media_top dut(.clk(clk),.rst_n(!rst),.audio_priority(cycle%1000<500),
 .audio_bookmark(mark),.audio_restart(restart),.audio_loop_length(looplen),
 .audio_open(aopen),.audio_open_ready(aory),.audio_open_done(aod),.audio_count(acount),.audio_catalog(acat),
 .audio_size(asize),.audio_data(adata),.audio_valid(av),.audio_ready(ardy),.audio_last(al),.audio_done(adone),.audio_error(aerr),
 .open_valid(open_valid),.open_ready(open_ready),.open_index(16'd0),.image_count(count),.catalog_ready(cat),.open_done(open_done),
 .file_size(size),.file_data(data),.file_valid(file_valid),.file_ready(file_ready),.file_last(file_last),.file_done(file_done),
 .sd_init_done(init),.mount_done(mount),.busy(busy),.error(err),.error_code(ec),.sd_error_code(se),.buffer_error_code(be),
 .sd_cs_n(),.sd_sck(),.sd_mosi(),.sd_miso(1'b1));
 wav_pcm_reader wav(.clk(clk),.rst(rst),.catalog_ready(acat),.file_count(acount),.open_valid(aopen),.open_ready(aory),.open_done(aod),
 .file_size(asize),.file_data(adata),.file_valid(av),.file_last(al),.file_done(adone),.storage_error(aerr),.file_ready(ardy),
 .pcm_data(pcm),.pcm_valid(pv),.pcm_ready(pcm_ready),.wav_available(available),.fault(wfault),
 .bookmark_valid(mark),.loop_restart(restart),.loop_length(looplen));
 assign file_ready=cycle%11<6;
 always @(negedge clk) if(!rst) pcm_ready=cycle%17<12;
 always @(posedge clk) begin
  if(rst) begin cycle<=0;transport_busy<=0;transport_done<=0;pending_done<=0;end
  else begin
   cycle<=cycle+1;transport_done<=0;
   if(dut.u_audio_reader.state==4) $display("BOOT audio signature=%h%h jump=%h/%h BPBbytes=%0d root=%0d total=%0d fat=%0d",dut.u_audio_reader.signature_high,dut.u_audio_reader.signature_low,dut.u_audio_reader.jump_first,dut.u_audio_reader.jump_third,dut.u_audio_reader.bpb_bytes_per_sector,dut.u_audio_reader.bpb_root_cluster,dut.u_audio_reader.bpb_total32,dut.u_audio_reader.bpb_fat32);
   if(dut.c_sd_req_valid && dut.c_sd_req_ready) begin
    if(transport_busy) $fatal(1,"Overlapping sector requests");
    transport_busy<=1;lba<=dut.c_sd_req_lba;offset<=0;transactions++;
   end
   if(transport_valid && dut.c_sd_r_ready) begin
    if(offset==511) begin transport_busy<=0;pending_done<=1;end else offset<=offset+1;
   end
   if(pending_done) begin transport_done<=1;pending_done<=0;end
   if(file_valid && file_ready) begin
    if(data!==picture[image_bytes] || file_last!==(image_bytes==77)) $fatal(1,"BMP stream byte=%0d data=%h",image_bytes,data);
    image_bytes++;
   end
   if(pv && pcm_ready) begin
    if(pcm!==expected_pcm) $fatal(1,"Fragmented WAV word=%0d actual=%h expected=%h",got,pcm,expected_pcm);
    got++;
   end
   if(restart) loops++;
   if(err || aerr || wfault) $fatal(1,"Storage flags image=%b audio=%b wav=%b code=%h audio_code=%h buffer=%h byte=%0d lba=%0d",err,aerr,wfault,ec,dut.u_audio_reader.error_code,dut.u_audio_sector_buffer.error_code,dut.u_audio_sector_buffer.receive_count,lba);
  end
 end
 initial begin : stimulus
  integer i,j,value;reg [87:0] name;
  foreach(boot[i]) begin boot[i]=0;directory[i]=0;fat[i]=0;end
  foreach(picture[i]) picture[i]=(i*13+3)%256;
  foreach(music[i]) music[i]=0;
  boot[0]=8'heb;boot[2]=8'h90;boot[12]=2;boot[13]=1;boot[14]=32;boot[16]=1;
  value=66070;for(i=0;i<4;i++) boot[32+i]=(value>>(8*i))&255;
  value=513;for(i=0;i<4;i++) boot[36+i]=(value>>(8*i))&255;
  boot[44]=2;boot[510]=8'h55;boot[511]=8'haa;
  for(i=0;i<4;i++) begin fat[8+i]=8'hff;fat[12+i]=8'hff;fat[36+i]=8'hff;end
  fat[20]=9;
  name="PIC     BMP";for(i=0;i<11;i++) directory[i]=name[(10-i)*8+:8];directory[11]=32;directory[26]=3;directory[28]=78;
  name="BGM     WAV";for(i=0;i<11;i++) directory[32+i]=name[(10-i)*8+:8];directory[43]=32;directory[58]=5;directory[60]=8'hc4;directory[61]=2;
  value=32'h46464952;for(j=0;j<4;j++) music[j]=(value>>(8*j))&255;
  value=700;for(j=0;j<4;j++) music[4+j]=(value>>(8*j))&255;
  value=32'h45564157;for(j=0;j<4;j++) music[8+j]=(value>>(8*j))&255;
  value=32'h4b4e554a;for(j=0;j<4;j++) music[12+j]=(value>>(8*j))&255;
  value=458;for(j=0;j<4;j++) music[16+j]=(value>>(8*j))&255;
  value=32'h20746d66;for(j=0;j<4;j++) music[478+j]=(value>>(8*j))&255;
  music[482]=16;music[486]=1;music[488]=2;
  value=48000;for(j=0;j<4;j++) music[490+j]=(value>>(8*j))&255;
  value=288000;for(j=0;j<4;j++) music[494+j]=(value>>(8*j))&255;
  music[498]=6;music[500]=24;
  value=32'h61746164;for(j=0;j<4;j++) music[502+j]=(value>>(8*j))&255;
  music[506]=198;
  for(i=0;i<66;i++) begin value=sample_word(i);for(j=0;j<3;j++) music[510+i*3+j]=(value>>(8*j))&255;end
  force dut.sd_init_done=1'b1;
  force dut.c_sd_req_ready=!transport_busy && !pending_done && !transport_done;
  force dut.c_sd_r_data=transport_data;force dut.c_sd_r_valid=transport_valid;
  force dut.c_sd_r_last=(offset==511);force dut.c_sd_done=transport_done;force dut.c_sd_error=1'b0;
  #1000;@(negedge clk);rst=0;
  wait(cat);if(count!=1) $fatal(1,"Image catalog count");
  @(negedge clk);open_valid=1;wait(open_ready);@(negedge clk);open_valid=0;
  wait(loops==4 && image_bytes==78);@(negedge clk);
  if(got!=264 || wav.bookmark_sent!==1 || dut.u_audio_reader.bookmark_offset!=510 || transactions<15)
   $fatal(1,"FAT completion samples=%0d bookmark=%0d transactions=%0d",got,dut.u_audio_reader.bookmark_offset,transactions);
  $display("PASS: tb_fat_media two independent file contexts; data offset510; fragmented 5->9; 4 loops; PCM words=%0d transactions=%0d",got,transactions);$finish;
 end
 initial begin #10000000;$fatal(1,"FAT timeout image=%0d audio=%0d",image_bytes,got);end
endmodule
