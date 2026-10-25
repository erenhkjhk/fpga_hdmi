`timescale 1ns/1ps
module tb_end_to_end;
 reg clk=0;always #10 clk=~clk;reg [3:0] keys=15;
 wire cs,sck,mosi,miso,ch0,ch1,ch2,tclk,scl;tri1 sda;wire [3:0] led;
 fpga_hdmi_top #(.AUTO_DEFAULT(0),.AUTO_INTERVAL_MS(200)) dut(.clk_50m(clk),.key_n(keys),.sw(4'd0),
 .sd_cs_n(cs),.sd_sck(sck),.sd_mosi(mosi),.sd_miso(miso),.tmds_ch0_p(ch0),.tmds_ch1_p(ch1),
 .tmds_ch2_p(ch2),.tmds_clk_p(tclk),.ddc_scl(scl),.ddc_sda(sda),.status_led(led));
 // Only delays/dwell are shortened. 640x480, all four real async FIFOs, seven
 // generated BRAM IPs, encrypted SDRAM/HDMI and physical serial PHY stay real.
 defparam dut.u_frame_store.TRANSITION_FRAMES=2;
 defparam dut.u_frame_store.AUDIO_LOW_WORDS=512;
 defparam dut.u_frame_store.AUDIO_HIGH_WORDS=1024;
 defparam dut.u_storage.POWER_WAIT_MS=1;
 defparam dut.u_key1.DEBOUNCE_MS=1,dut.u_key2.DEBOUNCE_MS=1,dut.u_key3.DEBOUNCE_MS=1;
 sdhc_spi_model card(.cs_n(cs),.sck(sck),.mosi(mosi),.miso(miso));
 sdram_2mx32_model memory(.clk(dut.u_sdram.sdram_clk),.ras_n(dut.u_sdram.sdr_ras),
 .cas_n(dut.u_sdram.sdr_cas),.we_n(dut.u_sdram.sdr_we),.ba(dut.u_sdram.sdr_ba),
 .addr(dut.u_sdram.sdr_addr),.dm(dut.u_sdram.sdr_dm),.dq(dut.u_sdram.sdr_dq));
 hdmi_serial_sink sink(.sample_clock(dut.clk_serial),.reset(dut.rst_pixel),.ch0(ch0),.ch1(ch1),.ch2(ch2),.clock_lane(tclk));
 integer samples=0,serial_samples=0,commits=0,picture_pixels=0,fade_pixels=0;
 integer frame=0,seen_a=0,seen_b=0,seen_half_ab=0,seen_half_ba=0;
 integer last_sample_cycle=0,pixel_cycle=0,serial_started=0,serial_index=0;
 integer scan_x=0,scan_y=0,expected_weight=0,from_picture=0,to_picture=0;
 reg audio_started=0;reg [23:0] expected_rgb;reg [2:0] weights_ab=0,weights_ba=0;
 reg [23:0] observed_frame[0:307199];reg [23:0] frame_center;
 integer frame_pixel_count=0,exported_a=0,exported_b=0,exported_half=0,export_file;
 integer wave_file,sequence_state=0,old_sequence=0;
 initial wave_file=$fopen("../sim/modelsim/results/e2e_hdmi_audio.hex","w");
 function [23:0] sample_value(input integer n,input integer right);
  integer value;
  begin value=(((n%2048)*7919+12345)&32'h3fffff)-32'h200000;if(right) value=-value;sample_value=value[23:0];end
 endfunction
 function [23:0] blended(input integer old_pic,new_pic,weight);
  integer a,b,c,v;reg [23:0] out;
  begin
   for(c=0;c<3;c++) begin
    a=old_pic?(128+32*c):(96-32*c);b=new_pic?(128+32*c):(96-32*c);
    v=(a*(256-weight)+b*weight+128)/256;out[c*8+:8]=v;
   end
   blended=out;
  end
 endfunction
 always @(posedge dut.clk_sdram) if(!dut.rst_mem) begin
  if(dut.result_mem && dut.result_ready_mem) begin
   if(dut.result_abort_mem) $fatal(1,"E2E image aborted");
   commits++;$display("E2E_COMMIT count=%0d t=%t",commits,$time);
  end
 end
 always @(posedge dut.clk_pixel) if(!dut.rst_pixel) begin
  pixel_cycle++;
  if(dut.audio_valid) begin
   if(audio_started || dut.audio_playing_pixel) begin
    if(dut.audio_left!==sample_value(samples,0) || dut.audio_right!==sample_value(samples,1))
     $fatal(1,"E2E PCM discontinuity pair=%0d left=%h right=%h expected=%h",samples,dut.audio_left,dut.audio_right,sample_value(samples,0));
    if(audio_started && pixel_cycle-last_sample_cycle!=520 && pixel_cycle-last_sample_cycle!=521)
     $fatal(1,"E2E PCM cadence=%0d",pixel_cycle-last_sample_cycle);
    audio_started=1;last_sample_cycle=pixel_cycle;samples++;
   end
  end
  if(dut.axis_valid) begin
   if(dut.axis_user) begin
    scan_x=0;scan_y=0;frame++;
    expected_weight=dut.u_frame_store.transitioning?dut.u_frame_store.alpha:256;
    // frame region1 contains first image, region0 contains second, then reused.
    from_picture=dut.u_frame_store.selected_region?0:1;
    to_picture=1-from_picture;
    if(!dut.u_frame_store.transitioning) to_picture=from_picture;
   end
   if(dut.displaying_image) begin
    expected_rgb=blended(from_picture,to_picture,expected_weight);
    if(dut.axis_data!==expected_rgb) $fatal(1,"E2E frame pixel frame=%0d x=%0d y=%0d actual=%h expected=%h alpha=%0d from=%0d",frame,scan_x,scan_y,dut.axis_data,expected_rgb,expected_weight,from_picture);
   end
   if(scan_x==639) begin scan_x=0;scan_y++;end else scan_x++;
  end
  if(dut.storage_error || dut.wav_fault_sys || dut.memory_fault_mem || dut.video_underflow || dut.audio_underflow_pixel || dut.audio_tag_error_pixel || dut.composed_protocol_error || dut.sample_cdc_overrun || dut.load_overflow || dut.audio_in_overflow || dut.audio_out_overflow)
   $fatal(1,"E2E fault storage=%b fat=%h sd=%h buffer=%h wav=%b memory=%b video=%b audio=%b tags=%b protocol=%b led=%h",dut.storage_error,dut.fat_error_code,dut.sd_error_code,dut.buffer_error_code,dut.wav_fault_sys,dut.memory_fault_mem,dut.video_underflow,dut.audio_underflow_pixel,dut.audio_tag_error_pixel,dut.composed_protocol_error,led);
 end
 always @(sink.audio_received) begin
  // Initial fallback tone is legal. Once first WAV pair arrives, every HDMI
  // packet must preserve all samples, including FAT loop and image switches.
  if(!serial_started && sink.audio_left===sample_value(0,0) && sink.audio_right===sample_value(0,1)) serial_started=1;
  if(serial_started) begin
   if(sink.audio_left!==sample_value(serial_index,0) || sink.audio_right!==sample_value(serial_index,1))
    $fatal(1,"HDMI serialized WAV discontinuity pair=%0d actual=%h/%h expected=%h",serial_index,sink.audio_left,sink.audio_right,sample_value(serial_index,0));
   serial_index++;serial_samples++;
   $fdisplay(wave_file,"%06h%06h",sink.audio_left,sink.audio_right);
  end
 end
 always @(sink.pixel_received) begin
  if(sink.video_x==0 && sink.video_y==0) frame_pixel_count=0;
  if(sink.video_x<640 && sink.video_y<480) begin
   observed_frame[sink.video_y*640+sink.video_x]=sink.rgb;frame_pixel_count++;
   if(sink.video_x==320 && sink.video_y==200) begin
    frame_center=sink.rgb;old_sequence=sequence_state;
    case(sequence_state)
     0:if(sink.rgb==24'h204060) sequence_state=1;else if(sink.rgb!=0) $fatal(1,"HDMI first image sequence");
     1:if(sink.rgb==24'h707070) sequence_state=2;else if(sink.rgb!=24'h204060) $fatal(1,"HDMI A->half sequence");
     2:if(sink.rgb==24'hc0a080) sequence_state=3;else if(sink.rgb!=24'h707070) $fatal(1,"HDMI half->B sequence");
     3:if(sink.rgb==24'h707070) sequence_state=4;else if(sink.rgb!=24'hc0a080) $fatal(1,"HDMI B->half sequence");
     4:if(sink.rgb==24'h204060) sequence_state=5;else if(sink.rgb!=24'h707070) $fatal(1,"HDMI half->A sequence");
     5:if(sink.rgb!=24'h204060) $fatal(1,"HDMI final A sequence");
    endcase
    if(old_sequence!=sequence_state) $display("HDMI_SEQUENCE phase=%0d center=%h t_ms=%0.3f",sequence_state,sink.rgb,$realtime/1000000.0);
   end
   if(sink.video_x==639 && sink.video_y==479 && frame_pixel_count==307200) begin
    export_file=0;
    case(frame_center)
     24'h204060:if(!exported_a) begin export_file=$fopen("../sim/modelsim/results/e2e_hdmi_a.hex","w");exported_a=1;end
     24'hc0a080:if(!exported_b) begin export_file=$fopen("../sim/modelsim/results/e2e_hdmi_b.hex","w");exported_b=1;end
     24'h707070:if(!exported_half) begin export_file=$fopen("../sim/modelsim/results/e2e_hdmi_half.hex","w");exported_half=1;end
    endcase
    if(export_file) begin
     for(integer p=0;p<307200;p++) $fdisplay(export_file,"%06h",observed_frame[p]);
     $fclose(export_file);$display("HDMI_FRAME_EXPORTED RGB=%h pixels=%0d",frame_center,frame_pixel_count);
    end
   end
  end
  // This area is clear of all OSD, logo and spectrum overlays.
  if(sink.video_x>=100 && sink.video_x<500 && sink.video_y>=100 && sink.video_y<300) begin
   case(sink.rgb)
    24'h204060:begin seen_a++;picture_pixels++;end
    24'hc0a080:begin seen_b++;picture_pixels++;end
    24'h707070:begin fade_pixels++;end
    24'h000000: ; // startup black
    default:$fatal(1,"HDMI physical RGB corruption x=%0d y=%0d rgb=%h",sink.video_x,sink.video_y,sink.rgb);
   endcase
  end
 end
 task press(input integer button);
  begin @(negedge clk);keys[button]=0;#3000000;@(negedge clk);keys[button]=1;#3000000;end
 endtask
 initial forever begin
  #5000000;
  $display("E2E_PROGRESS t=%t sd=%b mount=%b count=%0d state=%0d words=%0d image=%b frame=%0d commits=%0d pcm=%0d serial_pcm=%0d rgb=%0d fade=%0d sectors=%0d hdmi_frames=%0d packets=%0d acr=%0d",$time,dut.sd_init_done,dut.mount_done,dut.image_count,dut.u_frame_store.state,dut.u_frame_store.written_words,dut.displaying_image,frame,commits,samples,serial_samples,picture_pixels,fade_pixels,card.sectors,sink.video_frames,sink.audio_packets,sink.acr_packets);
 end
 initial begin
  wait(commits==1);wait(seen_a>=80000);
  $display("E2E_NEXT_KEY");press(1);
  wait(commits==2);wait(seen_b>=80000);
  $display("E2E_PREVIOUS_KEY");press(0);
  wait(commits==3);wait(seen_a>=160000);
  // Key3 is also exercised; the complete auto dwell state machine has its own
  // unit test, avoiding a redundant fourth full image load in this long test.
  $display("E2E_AUTO_KEY");press(2);if(!dut.auto_enabled) $fatal(1,"Auto enable key");
  press(2);if(dut.auto_enabled) $fatal(1,"Auto disable key");#100000;
  if(dut.image_count!=2 || samples<4096 || serial_samples<4096 || samples-serial_samples>16 || fade_pixels<160000 || memory.refreshes<100 || card.loops<3 || !exported_a || !exported_b || !exported_half || sequence_state!=5)
   $fatal(1,"E2E coverage incomplete samples=%0d serial=%0d fade=%0d refresh=%0d loops=%0d",samples,serial_samples,fade_pixels,memory.refreshes,card.loops);
  $fclose(wave_file);
  $display("PASS: tb_end_to_end TF SPI->FAT32->BMP/WAV->physical SDRAM->real HDMI serial; commits=%0d PCM=%0d HDMI_PCM=%0d image_pixels=%0d fade_pixels=%0d refreshes=%0d sectors=%0d WAV_loops=%0d",commits,samples,serial_samples,picture_pixels,fade_pixels,memory.refreshes,card.sectors,card.loops);$finish;
 end
 initial begin #600000000;$fatal(1,"E2E timeout commits=%0d samples=%0d serial=%0d",commits,samples,serial_samples);end
 initial if($test$plusargs("PROBE")) begin
  #10000000;
  $display("E2E_PROBE locked=%b symbols=%0d HDMI_pixels=%0d HDMI_frames=%0d audio_packets=%0d ACR_packets=%0d parallel=%h/%h/%h in_video=%b packet_index=%0d",dut.video_locked,sink.symbols,sink.video_pixels,sink.video_frames,sink.audio_packets,sink.acr_packets,dut.u_hdmi.S_ch0_tmds_data,dut.u_hdmi.S_ch1_tmds_data,dut.u_hdmi.S_ch2_tmds_data,sink.in_video,sink.packet_index);
  $display("PASS: tb_end_to_end PROBE diagnostic only");$finish;
 end
endmodule
