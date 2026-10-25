`timescale 1ns/1ps
// Application-interface SDRAM memory/refresh responder; all four FIFOs and
// blend RAMs use the real TD models. This is not a physical SDRAM timing model.
module tb_memory_integration;
 reg sys=0,mem=0,pix=0;always #10 sys=~sys;always #3.333 mem=~mem;always #20 pix=~pix;
 reg rst=1,bv=0,up=0,fv=0,abort_job=0,req=0;
 wire br,fr,rv,ra,rr,info,has,reset_video,fault;
 reg [31:0] memory[0:2097151];
 wire we,re,refresh_req,read_valid;wire [20:0] wa,raddr;wire [31:0] wd,read_data;wire [3:0] mask;
 reg refresh=0;integer refresh_count=0,refresh_age=0,refreshes=0;
 reg [5:0] read_pipe=0;reg [20:0] read_addr_pipe[0:5];
 reg job=0;integer source_count=0,image_id=1;reg source_bottom=0;
 wire [31:0] load_in,load_data;wire load_ival,load_iready,load_valid,load_empty,load_ready,load_re;
 wire [9:0] load_used;
 wire [31:0] vi,vo;wire vw,vr,vvalid,vempty,vfull,vwr_done,vrd_done,vrd_mem,vwr_pix;
 wire [9:0] vu_mem,vu_pix;wire vwr_rst,vrd_rst;
 wire [31:0] ai,ad,ao,ap;wire ai_ready,av,ae,ar,are,aw,ao_ready,apv,ape,apr,apre;
 wire [9:0] au,ou;integer audio_sent=0,played=0;
 wire low,high,prerolled,trans;
 wire audio_valid;wire [23:0] left,right;wire playing,underflow,tag_error;
 reg tick=0;integer tick_count=0;
 integer target=0,requested=0,returned=0,frame_number=0,weight=0;
 reg stream_mode=0;
 reg [23:0] expected_old,expected_new;
 function [23:0] photo(input integer id,n);
  integer r,g,b;
  begin r=(n%640+id*31)%256;g=(n/640+id*47)%256;b=(n%640+n/640+id*71)%256;photo={r[7:0],g[7:0],b[7:0]};end
 endfunction
 function [31:0] audio_word(input integer n);
  integer v;
  begin v=n/2+1;if(n%2) v=-v;audio_word={(n%2!=0),7'd0,v[23:0]};end
 endfunction
 function [23:0] mix(input [23:0] a,b,input integer alpha);
  integer c,v;reg [23:0] result;
  begin for(c=0;c<3;c++) begin v=((256-alpha)*a[c*8+:8]+alpha*b[c*8+:8]+128)/256;result[c*8+:8]=v;end mix=result;end
 endfunction
 assign load_in={8'd0,photo(image_id,source_bottom?((479-source_count/640)*640+source_count%640):source_count)};
 assign load_ival=job && source_count<307200;
 media_async_fifo loadq(.wr_clk(sys),.wr_rst(rst),.rd_clk(mem),.rd_rst(rst),.in_data(load_in),.in_valid(load_ival),
 .in_ready(load_iready),.out_data(load_data),.out_valid(load_valid),.out_re(load_re),.out_empty(load_empty),.out_ready(load_ready),.wr_used(),.rd_used(load_used),.overflow(),.underflow());
 always @(posedge sys) begin
  if(rst) begin source_count<=0;audio_sent<=0;end
  else begin
   if(load_ival && load_iready) source_count<=source_count+1;
   if(job && !dut.load_active) $fatal(1,"Test producer started before accepted begin handshake");
   if(audio_sent<220000 && ai_ready) audio_sent<=audio_sent+1;
  end
 end
 assign ai=audio_word(audio_sent);
 media_async_fifo audio_load(.wr_clk(sys),.wr_rst(rst),.rd_clk(mem),.rd_rst(rst),.in_data(ai),.in_valid(audio_sent<220000 && !rst),
 .in_ready(ai_ready),.out_data(ad),.out_valid(av),.out_re(are),.out_empty(ae),.out_ready(ar),.wr_used(),.rd_used(au),.overflow(),.underflow());
 media_async_fifo audio_play(.wr_clk(mem),.wr_rst(rst),.rd_clk(pix),.rd_rst(rst),.in_data(ao),.in_valid(aw),
 .in_ready(ao_ready),.out_data(ap),.out_valid(apv),.out_re(apre),.out_empty(ape),.out_ready(apr),.wr_used(ou),.rd_used(),.overflow(),.underflow());
 pcm_player player(.clk(pix),.rst(rst),.tick(tick),.enable(1'b1),.wav_mode(1'b1),.prerolled(prerolled),
 .tone_left(24'd0),.tone_right(24'd0),.fifo_data(ap),.fifo_valid(apv),.fifo_empty(ape),.fifo_ready(apr),.fifo_re(apre),
 .sample_valid(audio_valid),.sample_left(left),.sample_right(right),.underflow(underflow),.tag_error(tag_error),.playing(playing));
 always @(posedge pix) begin
  if(stream_mode && target!=0 && requested>0 && requested<target && vempty)
   $fatal(1,"Video FIFO starved during continuous 25Mpixel/s blend at pixel=%0d",requested);
  tick<=0;if(!rst) begin if(tick_count==520) begin tick<=1;tick_count<=0;end else tick_count<=tick_count+1;end
  if(!rst && audio_valid && (left!=0 || right!=0)) begin
   if(left!==24'(played+1) || right!==24'(-(played+1))) $fatal(1,"Audio order played=%0d L=%h R=%h",played,left,right);
   played=played+1;
  end
 end
 reset_sync wr_reset(mem,rst || reset_video,vwr_rst);
 reset_sync rd_reset(pix,rst || reset_video,vrd_rst);
 fifo_pixel_async videoq(.di(vi),.clkw(mem),.wrst(vwr_rst),.we(vw),.clkr(pix),.rrst(vrd_rst),.re(vr),.dout(vo),
 .empty_flag(vempty),.aempty(),.full_flag(vfull),.afull(),.valid(vvalid),.overflow(),.underflow(),.wr_success(),
 .rdusedw(vu_pix),.wrusedw(vu_mem),.wr_rst_done(vwr_done),.rd_rst_done(vrd_done));
 cdc_level sync_rd(mem,rst,vrd_done,vrd_mem);cdc_level sync_wr(pix,rst,vwr_done,vwr_pix);
 assign vr=!vrd_rst && vrd_done && vwr_pix && !vempty && requested<target;
 always @(posedge pix) begin
  if(vr) requested<=requested+1;
  #1;
  if(vvalid && !vrd_rst) begin
   expected_old=photo(frame_number==0?1:1,returned);expected_new=photo(2,returned);
   if(vo!=={8'd0,mix(expected_old,expected_new,weight)})
    $fatal(1,"Video frame=%0d pixel=%0d alpha=%0d got=%h expected=%h",frame_number,returned,weight,vo,mix(expected_old,expected_new,weight));
   returned=returned+1;
  end
 end
 sdram_frame_store dut(.clk(mem),.rst(rst),.begin_valid(bv),.begin_ready(br),.begin_bottom_up(up),
 .finish_valid(fv),.finish_ready(fr),.finish_abort(abort_job),.result_valid(rv),.result_ready(1'b1),.result_abort(ra),
 .frame_req_valid(req),.frame_req_ready(rr),.frame_info_valid(info),.frame_info_ready(1'b1),.frame_has_image(has),
 .load_fifo_data(load_data),.load_fifo_valid(load_valid),.load_fifo_empty(load_empty),.load_fifo_used(load_used),.load_fifo_ready(load_ready),.load_fifo_re(load_re),
 .video_fifo_data(vi),.video_fifo_we(vw),.video_fifo_full(vfull),.video_fifo_used(vu_mem),.video_fifo_wr_ready(vwr_done),.video_fifo_rd_ready(vrd_mem),.video_fifo_reset(reset_video),.fault(fault),
 .audio_in_data(ad),.audio_in_valid(av),.audio_in_empty(ae),.audio_in_ready(ar),.audio_in_used(au),.audio_in_re(are),
 .audio_out_data(ao),.audio_out_we(aw),.audio_out_ready(ao_ready),.audio_out_full(!ao_ready),.audio_out_used(ou),
 .audio_low(low),.audio_high(high),.audio_prerolled(prerolled),.transitioning(trans),
 .sdr_init_done(!rst),.sdr_refresh(refresh),.app_refresh_req(refresh_req),.app_wr_en(we),.app_wr_addr(wa),.app_wr_data(wd),.app_wr_mask(mask),
 .app_rd_en(re),.app_rd_addr(raddr),.sdr_rd_valid(read_valid),.sdr_rd_data(read_data));
 assign read_valid=read_pipe[5];assign read_data=memory[read_addr_pipe[5]];
 always @(posedge mem) begin
  if(rst) begin read_pipe<=0;refresh<=0;refresh_count<=0;refresh_age<=0;end
  else begin
   if(we && re || (refresh && (we || re))) $fatal(1,"SDRAM ownership violation");
   if(we) begin
    if(mask!=0 || wa>=21'h140000 || (wa>=614400 && wa<21'h100000)) $fatal(1,"SDRAM invalid write address %h",wa);
    memory[wa]<=wd;
   end
   read_pipe<={read_pipe[4:0],re};read_addr_pipe[0]<=raddr;
   for(integer j=1;j<6;j++) read_addr_pipe[j]<=read_addr_pipe[j-1];
   refresh_age<=refresh_age+1;
   if(refresh_req) begin refresh_count<=15;refreshes<=refreshes+1;refresh_age<=0;end
   else if(refresh_count!=0) refresh_count<=refresh_count-1;
   refresh<=refresh_count!=0;
   if(refresh_age>4687) $fatal(1,"Refresh exceeded row budget age=%0d",refresh_age);
   if(fault || underflow || tag_error) $fatal(1,"Integration flags fault=%b underflow=%b tag=%b",fault,underflow,tag_error);
  end
 end
 task load_photo(input integer id,input bit bottom);
  @(negedge mem);bv=1;up=bottom;do @(posedge mem);while(!br);@(negedge mem);bv=0;
  @(negedge sys);source_count=0;image_id=id;source_bottom=bottom;job=1;
  wait(source_count==307200);@(negedge sys);job=0;
  @(negedge mem);fv=1;do @(posedge mem);while(!fr);@(negedge mem);fv=0;
  wait(dut.pending_front);@(negedge mem);
  for(integer n=0;n<307200;n++) if(memory[(id==1?307200:0)+n]!=={8'd0,photo(id,n)}) $fatal(1,"Frame write id=%0d pixel=%0d",id,n);
  $display("CHECK full frame write id=%0d at %t; audio played=%0d",id,$time,played);
 endtask
 task read_frame_prefix(input integer alpha);
  target=0;requested=0;returned=0;weight=alpha;
  @(negedge mem);req=1;do @(posedge mem);while(!rr);@(negedge mem);req=0;
  wait(info);wait(!reset_video);repeat(10) @(negedge pix);
  if(!has) $fatal(1,"Missing frame metadata");
  if(stream_mode) wait(vu_pix>=640);
  target=stream_mode?307200:128;
  wait(returned==target);repeat(4) @(negedge pix);
 endtask
 initial begin
  stream_mode=$test$plusargs("STREAM");
  #1500;@(negedge mem);rst=0;
  // Seed empty ring at its final aligned block to test wrap without 262144 filler words.
  dut.audio_write_ptr=18'h3ffc0;dut.audio_read_ptr=18'h3ffc0;
  if(stream_mode) begin
   for(integer p=0;p<307200;p++) begin memory[p]={8'd0,photo(2,p)};memory[p+307200]={8'd0,photo(1,p)};end
   dut.front_valid=1;dut.front_region=1;dut.transitioning=1;dut.transition_frame=29;
   frame_number=1;read_frame_prefix(128);
   if(played<100) $fatal(1,"Audio not exercised during video stream");
   $display("PASS: tb_memory_integration STREAM full307200 pixels at continuous25Mpixel/s with audio + refresh, samples=%0d",played);$finish;
  end
  load_photo(1,0);read_frame_prefix(0);
  frame_number=1;load_photo(2,1);
  for(integer f=0;f<=60;f++) begin
   read_frame_prefix(f==60?256:(f*256/60));
   if(f<60 && br) $fatal(1,"Old frame released during transition");
  end
  if(trans || dut.front_region!=0 || dut.alpha!=256 || played<100 || refreshes==0) $fatal(1,"Integration completion played=%0d refreshes=%0d",played,refreshes);
  $display("PASS: tb_memory_integration two full image writes; 61 transition endpoints; audio ring wrap; samples=%0d refreshes=%0d",played,refreshes);$finish;
 end
 initial begin #20000000;$fatal(1,"Memory integration timeout state=%0d words=%0d source=%0d",dut.state,dut.written_words,source_count);end
endmodule
