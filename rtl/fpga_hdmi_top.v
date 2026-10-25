`timescale 1ns/1ps
`default_nettype none

// HX4S20C / EG4S20BG256. Actual generated clocks: SDRAM 150 MHz/180 deg,
// HDMI 25 MHz pixels and 125 MHz serialization. KEY1 previous, KEY2 next,
// KEY3 auto-play toggle, KEY4 asynchronous system reset. Keys are active low.
module fpga_hdmi_top #(
    parameter integer AUTO_INTERVAL_MS = 5000,
    parameter AUTO_DEFAULT = 1'b1,
    parameter STATUS_LED_ACTIVE_LOW = 1'b0,
    parameter [3:0] SWITCH_ACTIVE_LOW = 4'b0000
) (
    input wire clk_50m,
    input wire [3:0] key_n,
    input wire [3:0] sw, // SW1/2 brightness, SW3/4 contrast, active high
    output wire sd_cs_n,
    output wire sd_sck,
    output wire sd_mosi,
    input wire sd_miso,
    output wire tmds_ch0_p,
    output wire tmds_ch1_p,
    output wire tmds_ch2_p,
    output wire tmds_clk_p,
    output wire ddc_scl,
    inout wire ddc_sda,
    output wire [3:0] status_led
);
    // Configuration-time register initialization supplies power-on reset even
    // when KEY4 is not held. Reset remains asserted for 65535 input clocks.
    reg [15:0] power_count = 16'd0;
    always @(posedge clk_50m)
        if (!(&power_count)) power_count <= power_count + 1'b1;
    wire raw_reset = !(&power_count) || !key_n[3];
    wire clk_sdram, clk_sdram_180, clk_pixel, clk_serial;
    wire locked_sdram, locked_hdmi;
    wire reset_request = raw_reset || !locked_sdram || !locked_hdmi;
    wire rst_sys, rst_mem, rst_pixel;
    pll_sdram u_pll_sdram (
        .refclk(clk_50m), .reset(raw_reset), .extlock(locked_sdram),
        .clk0_out(clk_sdram), .clk1_out(clk_sdram_180)
    );
    pll_hdmi u_pll_hdmi (
        .refclk(clk_50m), .reset(raw_reset), .extlock(locked_hdmi),
        .clk0_out(clk_serial), .clk1_out(clk_pixel)
    );
    reset_sync u_reset_sys (.clk(clk_50m), .async_reset(reset_request), .reset(rst_sys));
    reset_sync u_reset_mem (.clk(clk_sdram), .async_reset(reset_request), .reset(rst_mem));
    reset_sync u_reset_pixel (.clk(clk_pixel), .async_reset(reset_request), .reset(rst_pixel));

    reg [15:0] ms_divider;
    reg tick_ms;
    always @(posedge clk_50m or posedge rst_sys) begin
        if (rst_sys) begin ms_divider <= 0; tick_ms <= 0; end
        else begin
            tick_ms <= 0;
            if (ms_divider == 49999) begin ms_divider <= 0; tick_ms <= 1; end
            else ms_divider <= ms_divider + 1'b1;
        end
    end
    wire previous_press, next_press, auto_press;
    key_debounce u_key1 (.clk(clk_50m), .rst(rst_sys), .tick_ms(tick_ms),
                         .key_n(key_n[0]), .press(previous_press));
    key_debounce u_key2 (.clk(clk_50m), .rst(rst_sys), .tick_ms(tick_ms),
                         .key_n(key_n[1]), .press(next_press));
    key_debounce u_key3 (.clk(clk_50m), .rst(rst_sys), .tick_ms(tick_ms),
                         .key_n(key_n[2]), .press(auto_press));

    wire open_valid, open_ready, open_done, file_done;
    wire [15:0] open_index, image_count;
    wire [31:0] file_size;
    wire [7:0] file_data;
    wire file_valid, file_ready, file_last;
    wire sd_init_done, mount_done, catalog_ready, storage_busy, storage_error;
    wire [7:0] fat_error_code, sd_error_code, buffer_error_code;
    wire wav_open,wav_open_ready,wav_open_done,wav_catalog,wav_valid,wav_ready,wav_last,wav_done,wav_storage_error;
    wire [15:0] wav_count;
    wire [31:0] wav_size;
    wire [7:0] wav_byte;
    wire audio_low_mem,audio_low_sys,audio_high_mem,audio_high_sys,wav_bookmark,wav_restart;
    wire audio_playing_sys,wav_available_sys;
    reg audio_fill;
    always @(posedge clk_50m or posedge rst_sys)
      if(rst_sys) audio_fill<=1;
      else if(audio_high_sys) audio_fill<=0;
      else if(audio_low_sys || (wav_available_sys && !audio_playing_sys)) audio_fill<=1;
    cdc_level u_audio_high (.clk(clk_50m),.rst(rst_sys),.async_data(audio_high_mem),.sync_data(audio_high_sys));
    wire [31:0] wav_loop_length;
    cdc_level u_audio_priority (.clk(clk_50m),.rst(rst_sys),.async_data(audio_low_mem),.sync_data(audio_low_sys));
    fat32_media_top #(.CLK_HZ(50000000), .INIT_SPI_HZ(250000), .DATA_SPI_HZ(5000000)) u_storage (
        .audio_bookmark(wav_bookmark),.audio_restart(wav_restart),.audio_loop_length(wav_loop_length),
        .audio_priority(audio_low_sys),.audio_open(wav_open),.audio_open_ready(wav_open_ready),
        .audio_open_done(wav_open_done),.audio_count(wav_count),.audio_catalog(wav_catalog),
        .audio_size(wav_size),.audio_data(wav_byte),.audio_valid(wav_valid),.audio_ready(wav_ready),
        .audio_last(wav_last),.audio_done(wav_done),.audio_error(wav_storage_error),
        .clk(clk_50m), .rst_n(!rst_sys),
        .open_valid(open_valid), .open_ready(open_ready), .open_index(open_index),
        .image_count(image_count), .catalog_ready(catalog_ready),
        .open_done(open_done), .file_size(file_size),
        .file_data(file_data), .file_valid(file_valid), .file_ready(file_ready),
        .file_last(file_last), .file_done(file_done),
        .sd_init_done(sd_init_done), .mount_done(mount_done), .busy(storage_busy),
        .error(storage_error), .error_code(fat_error_code),
        .sd_error_code(sd_error_code), .buffer_error_code(buffer_error_code),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );
    wire decoder_start, decoder_cancel, decoder_done, decoder_complete, decoder_error;
    wire [7:0] decoder_error_code;
    wire image_begin_sys, image_begin_ready_sys, image_bottom_up;
    wire [31:0] decoded_pixel;
    wire decoded_valid, decoded_ready;
    bmp24_decoder u_bmp (
        .clk(clk_50m), .rst(rst_sys), .start(decoder_start), .cancel(decoder_cancel),
        .file_size(file_size), .file_data(file_data), .file_valid(file_valid),
        .file_ready(file_ready), .file_last(file_last),
        .begin_valid(image_begin_sys), .begin_ready(image_begin_ready_sys),
        .bottom_up(image_bottom_up), .pixel_data(decoded_pixel),
        .pixel_valid(decoded_valid), .pixel_ready(decoded_ready),
        .done(decoder_done), .image_complete(decoder_complete),
        .error(decoder_error), .error_code(decoder_error_code)
    );

    wire [31:0] load_data;
    wire load_empty, load_full, load_afull, load_aempty, load_valid, load_re;
    wire [9:0] load_used_mem, load_used_sys;
    wire load_wr_done, load_rd_done, load_rd_done_sys, load_wr_done_mem;
    wire load_overflow, load_underflow, load_wr_success;
    assign decoded_ready = load_wr_done && load_rd_done_sys && !load_full && !load_afull;
    fifo_pixel_async u_load_fifo (
        .di(decoded_pixel), .clkw(clk_50m), .wrst(rst_sys),
        .we(decoded_valid && decoded_ready),
        .clkr(clk_sdram), .rrst(rst_mem), .re(load_re), .dout(load_data),
        .empty_flag(load_empty), .aempty(load_aempty), .full_flag(load_full),
        .afull(load_afull), .valid(load_valid), .overflow(load_overflow),
        .underflow(load_underflow), .wr_success(load_wr_success),
        .rdusedw(load_used_mem), .wrusedw(load_used_sys),
        .wr_rst_done(load_wr_done), .rd_rst_done(load_rd_done)
    );
    cdc_level u_load_rd_done_sys (.clk(clk_50m), .rst(rst_sys),
                                  .async_data(load_rd_done), .sync_data(load_rd_done_sys));
    cdc_level u_load_wr_done_mem (.clk(clk_sdram), .rst(rst_mem),
                                  .async_data(load_wr_done), .sync_data(load_wr_done_mem));

    wire image_begin_mem, image_begin_ready_mem, bottom_up_mem;
    wire finish_sys, finish_ready_sys, finish_abort_sys;
    wire finish_mem, finish_ready_mem, finish_abort_mem;
    wire result_mem, result_ready_mem, result_abort_mem;
    wire result_sys, result_ready_sys, result_abort_sys;
    cdc_mailbox u_image_begin (
        .src_clk(clk_50m), .src_rst(rst_sys), .src_data(image_bottom_up),
        .src_valid(image_begin_sys), .src_ready(image_begin_ready_sys), .src_done(),
        .dst_clk(clk_sdram), .dst_rst(rst_mem), .dst_data(bottom_up_mem),
        .dst_valid(image_begin_mem), .dst_ready(image_begin_ready_mem)
    );
    cdc_mailbox u_image_finish (
        .src_clk(clk_50m), .src_rst(rst_sys), .src_data(finish_abort_sys),
        .src_valid(finish_sys), .src_ready(finish_ready_sys), .src_done(),
        .dst_clk(clk_sdram), .dst_rst(rst_mem), .dst_data(finish_abort_mem),
        .dst_valid(finish_mem), .dst_ready(finish_ready_mem)
    );
    cdc_mailbox u_image_result (
        .src_clk(clk_sdram), .src_rst(rst_mem), .src_data(result_abort_mem),
        .src_valid(result_mem), .src_ready(result_ready_mem), .src_done(),
        .dst_clk(clk_50m), .dst_rst(rst_sys), .dst_data(result_abort_sys),
        .dst_valid(result_sys), .dst_ready(result_ready_sys)
    );

    wire frame_req_pixel, frame_req_ready_pixel, frame_req_mem, frame_req_ready_mem;
    wire unused_frame_token;
    wire frame_info_mem, frame_info_ready_mem, frame_has_image_mem;
    wire frame_info_pixel, frame_info_ready_pixel, frame_has_image_pixel;
    cdc_mailbox u_frame_request (
        .src_clk(clk_pixel), .src_rst(rst_pixel), .src_data(1'b1),
        .src_valid(frame_req_pixel), .src_ready(frame_req_ready_pixel), .src_done(),
        .dst_clk(clk_sdram), .dst_rst(rst_mem), .dst_data(unused_frame_token),
        .dst_valid(frame_req_mem), .dst_ready(frame_req_ready_mem)
    );
    cdc_mailbox u_frame_info (
        .src_clk(clk_sdram), .src_rst(rst_mem), .src_data(frame_has_image_mem),
        .src_valid(frame_info_mem), .src_ready(frame_info_ready_mem), .src_done(),
        .dst_clk(clk_pixel), .dst_rst(rst_pixel), .dst_data(frame_has_image_pixel),
        .dst_valid(frame_info_pixel), .dst_ready(frame_info_ready_pixel)
    );

    wire [31:0] video_fifo_in, video_fifo_out;
    wire video_fifo_we, video_fifo_re, video_fifo_valid, video_fifo_empty;
    wire video_fifo_full, video_fifo_afull, video_fifo_aempty;
    wire video_fifo_overflow, video_fifo_underflow, video_fifo_wr_success;
    wire [9:0] video_used_mem, video_used_pixel;
    wire video_fifo_reset, video_wr_reset, video_rd_reset;
    wire video_wr_done, video_rd_done, video_rd_done_mem, video_wr_done_pixel;
    reset_sync u_video_wr_reset (.clk(clk_sdram),
        .async_reset(rst_mem || video_fifo_reset), .reset(video_wr_reset));
    reset_sync u_video_rd_reset (.clk(clk_pixel),
        .async_reset(rst_pixel || video_fifo_reset), .reset(video_rd_reset));
    fifo_pixel_async u_video_fifo (
        .di(video_fifo_in), .clkw(clk_sdram), .wrst(video_wr_reset), .we(video_fifo_we),
        .clkr(clk_pixel), .rrst(video_rd_reset), .re(video_fifo_re), .dout(video_fifo_out),
        .empty_flag(video_fifo_empty), .aempty(video_fifo_aempty),
        .full_flag(video_fifo_full), .afull(video_fifo_afull), .valid(video_fifo_valid),
        .overflow(video_fifo_overflow), .underflow(video_fifo_underflow),
        .wr_success(video_fifo_wr_success), .rdusedw(video_used_pixel), .wrusedw(video_used_mem),
        .wr_rst_done(video_wr_done), .rd_rst_done(video_rd_done)
    );
    cdc_level u_video_rd_done_mem (.clk(clk_sdram), .rst(rst_mem),
        .async_data(video_rd_done), .sync_data(video_rd_done_mem));
    cdc_level u_video_wr_done_pixel (.clk(clk_pixel), .rst(rst_pixel),
        .async_data(video_wr_done), .sync_data(video_wr_done_pixel));

    wire sdr_init_done, sdr_refresh, sdr_busy;
    wire app_refresh_req, app_wr_en, app_rd_en, sdr_rd_valid;
    wire [20:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_data, sdr_rd_data;
    wire [3:0] app_wr_mask;
    wire memory_fault_mem, memory_fault_sys, memory_ready_sys;
    sdram_ram_wrapper #(.SELF_REFRESH_OPEN(1'b0)) u_sdram (
        .Sdr_clk(clk_sdram), .Sdr_clk_sft(clk_sdram_180), .Rst(rst_mem),
        .Sdr_init_done(sdr_init_done), .Sdr_init_ref_vld(sdr_refresh), .Sdr_busy(sdr_busy),
        .App_ref_req(app_refresh_req), .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .App_wr_din(app_wr_data), .App_wr_dm(app_wr_mask),
        .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
        .Sdr_rd_en(sdr_rd_valid), .Sdr_rd_dout(sdr_rd_data)
    );
    wire [31:0] pcm_sys,pcm_mem,audio_mem,audio_pixel;
    wire pcm_valid_sys,pcm_ready_sys,pcm_valid_mem,pcm_empty_mem,pcm_ready_mem,pcm_re_mem;
    wire audio_we_mem,audio_ready_mem,audio_valid_pixel,audio_empty_pixel,audio_ready_pixel,audio_re_pixel;
    wire [9:0] pcm_used_mem,audio_used_mem;
    wire wav_fault_sys,prerolled_mem,prerolled_pixel,wav_available_pixel;
    wire transitioning_mem,transitioning_sys;
    wire audio_in_overflow,audio_in_underflow,audio_out_overflow,audio_out_underflow;
    wav_pcm_reader u_wav (.bookmark_valid(wav_bookmark),.loop_restart(wav_restart),.loop_length(wav_loop_length),.clk(clk_50m),.rst(rst_sys),.catalog_ready(wav_catalog),.file_count(wav_count),
      .open_valid(wav_open),.open_ready(wav_open_ready),.open_done(wav_open_done),.file_size(wav_size),
      .file_data(wav_byte),.file_valid(wav_valid),.file_ready(wav_ready),.file_last(wav_last),
      .file_done(wav_done),.storage_error(wav_storage_error),.pcm_data(pcm_sys),.pcm_valid(pcm_valid_sys),
      .pcm_ready(pcm_ready_sys && (audio_fill || pcm_sys[31])),.wav_available(wav_available_sys),.fault(wav_fault_sys));
    media_async_fifo u_audio_load (.wr_clk(clk_50m),.wr_rst(rst_sys),.rd_clk(clk_sdram),.rd_rst(rst_mem),
      .in_data(pcm_sys),.in_valid(pcm_valid_sys && (audio_fill || pcm_sys[31])),.in_ready(pcm_ready_sys),.out_data(pcm_mem),
      .out_valid(pcm_valid_mem),.out_re(pcm_re_mem),.out_empty(pcm_empty_mem),.out_ready(pcm_ready_mem),
      .wr_used(),.rd_used(pcm_used_mem),.overflow(audio_in_overflow),.underflow(audio_in_underflow));
    media_async_fifo u_audio_playback (.wr_clk(clk_sdram),.wr_rst(rst_mem),.rd_clk(clk_pixel),.rd_rst(rst_pixel),
      .in_data(audio_mem),.in_valid(audio_we_mem),.in_ready(audio_ready_mem),.out_data(audio_pixel),
      .out_valid(audio_valid_pixel),.out_re(audio_re_pixel),.out_empty(audio_empty_pixel),.out_ready(audio_ready_pixel),
      .wr_used(audio_used_mem),.rd_used(),.overflow(audio_out_overflow),.underflow(audio_out_underflow));
    cdc_level u_preroll (.clk(clk_pixel),.rst(rst_pixel),.async_data(prerolled_mem),.sync_data(prerolled_pixel));
    cdc_level u_wav_mode (.clk(clk_pixel),.rst(rst_pixel),.async_data(wav_available_sys),.sync_data(wav_available_pixel));
    cdc_level u_transition (.clk(clk_50m),.rst(rst_sys),.async_data(transitioning_mem),.sync_data(transitioning_sys));
    sdram_frame_store u_frame_store (
        .audio_in_data(pcm_mem),.audio_in_valid(pcm_valid_mem),.audio_in_empty(pcm_empty_mem),
        .audio_in_ready(pcm_ready_mem),.audio_in_used(pcm_used_mem),.audio_in_re(pcm_re_mem),
        .audio_out_data(audio_mem),.audio_out_we(audio_we_mem),.audio_out_ready(audio_ready_mem),
        .audio_out_full(!audio_ready_mem),.audio_out_used(audio_used_mem),.audio_low(audio_low_mem),
        .audio_high(audio_high_mem),.audio_prerolled(prerolled_mem),.transitioning(transitioning_mem),
        .clk(clk_sdram), .rst(rst_mem),
        .begin_valid(image_begin_mem), .begin_ready(image_begin_ready_mem),
        .begin_bottom_up(bottom_up_mem), .finish_valid(finish_mem),
        .finish_ready(finish_ready_mem), .finish_abort(finish_abort_mem),
        .result_valid(result_mem), .result_ready(result_ready_mem), .result_abort(result_abort_mem),
        .frame_req_valid(frame_req_mem), .frame_req_ready(frame_req_ready_mem),
        .frame_info_valid(frame_info_mem), .frame_info_ready(frame_info_ready_mem),
        .frame_has_image(frame_has_image_mem),
        .load_fifo_data(load_data), .load_fifo_valid(load_valid), .load_fifo_empty(load_empty),
        .load_fifo_used(load_used_mem), .load_fifo_ready(load_rd_done && load_wr_done_mem),
        .load_fifo_re(load_re), .video_fifo_data(video_fifo_in), .video_fifo_we(video_fifo_we),
        .video_fifo_full(video_fifo_full), .video_fifo_used(video_used_mem),
        .video_fifo_wr_ready(video_wr_done), .video_fifo_rd_ready(video_rd_done_mem),
        .video_fifo_reset(video_fifo_reset), .fault(memory_fault_mem),
        .sdr_init_done(sdr_init_done), .sdr_refresh(sdr_refresh),
        .app_refresh_req(app_refresh_req), .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_data(app_wr_data), .app_wr_mask(app_wr_mask),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdr_rd_valid(sdr_rd_valid), .sdr_rd_data(sdr_rd_data)
    );
    cdc_level u_memory_ready_sys (.clk(clk_50m), .rst(rst_sys),
        .async_data(sdr_init_done), .sync_data(memory_ready_sys));
    cdc_level u_memory_fault_sys (.clk(clk_50m), .rst(rst_sys),
        .async_data(memory_fault_mem || video_fifo_overflow || load_underflow),
        .sync_data(memory_fault_sys));

    wire auto_enabled, slideshow_busy, slideshow_error;
    wire [15:0] current_index;
    slideshow_control #(.AUTO_INTERVAL_MS(AUTO_INTERVAL_MS), .AUTO_DEFAULT(AUTO_DEFAULT)) u_slideshow (
        .clk(clk_50m), .rst(rst_sys), .tick_ms(tick_ms),
        .previous_press(previous_press), .next_press(next_press), .auto_press(auto_press),
        .memory_ready(memory_ready_sys), .memory_fault(memory_fault_sys),
        .mount_done(mount_done), .catalog_ready(catalog_ready), .image_count(image_count),
        .storage_error(storage_error), .open_valid(open_valid), .open_ready(open_ready),
        .open_index(open_index), .file_done(file_done),
        .decoder_start(decoder_start), .decoder_cancel(decoder_cancel),
        .decoder_done(decoder_done), .decoder_complete(decoder_complete), .decoder_error(decoder_error),
        .image_begin_valid(image_begin_sys), .image_begin_ready(image_begin_ready_sys),
        .finish_valid(finish_sys), .finish_ready(finish_ready_sys), .finish_abort(finish_abort_sys),
        .result_valid(result_sys), .result_ready(result_ready_sys), .result_abort(result_abort_sys),
        .auto_enabled(auto_enabled), .busy(slideshow_busy), .error(slideshow_error),
        .current_index(current_index)
    );

    wire axis_user, axis_valid, axis_last, axis_ready, video_locked;
    wire [23:0] axis_data;
    wire displaying_image, video_underflow, video_protocol_error;
    video_stream_640x480 u_video_stream (
        .clk(clk_pixel), .rst(rst_pixel),
        .frame_req_valid(frame_req_pixel), .frame_req_ready(frame_req_ready_pixel),
        .frame_info_valid(frame_info_pixel), .frame_info_ready(frame_info_ready_pixel),
        .frame_has_image(frame_has_image_pixel),
        .fifo_data(video_fifo_out), .fifo_valid(video_fifo_valid), .fifo_empty(video_fifo_empty),
        .fifo_used(video_used_pixel),
        .fifo_ready(video_rd_done && video_wr_done_pixel && !video_rd_reset),
        .fifo_re(video_fifo_re), .axis_ready(1'b1), .video_locked(video_locked),
        .axis_user(axis_user), .axis_valid(axis_valid), .axis_last(axis_last), .axis_data(axis_data),
        .displaying_image(displaying_image), .underflow(video_underflow), .protocol_error(video_protocol_error)
    );
    wire i2s_bclk, i2s_lrck, i2s_data, audio_valid, acr_valid;
    wire [23:0] audio_left, audio_right;
    wire [19:0] acr_cts, acr_n;
    wire audio_enable = video_locked;
    wire tone_valid;
    wire [23:0] tone_left,tone_right;
    wire audio_underflow_pixel,audio_tag_error_pixel,audio_playing_pixel;
    pcm_player u_player (.clk(clk_pixel),.rst(rst_pixel),.tick(tone_valid),.enable(audio_enable),
      .wav_mode(wav_available_pixel),.prerolled(prerolled_pixel),.tone_left(tone_left),.tone_right(tone_right),
      .fifo_data(audio_pixel),.fifo_valid(audio_valid_pixel),.fifo_empty(audio_empty_pixel),
      .fifo_ready(audio_ready_pixel),.fifo_re(audio_re_pixel),.sample_valid(audio_valid),
      .sample_left(audio_left),.sample_right(audio_right),.underflow(audio_underflow_pixel),
      .tag_error(audio_tag_error_pixel),.playing(audio_playing_pixel));
    i2s_test_tone u_tone (.clk(clk_pixel), .rst(rst_pixel),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .serial_data(i2s_data));
    i2s_stereo_receiver u_audio_receiver (.clk(clk_pixel), .rst(rst_pixel),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .serial_data(i2s_data),
        .audio_valid(tone_valid), .audio_left(tone_left), .audio_right(tone_right));
    hdmi_acr_48k u_acr (.clk(clk_pixel), .rst(rst_pixel),
        .audio_valid(audio_valid && audio_enable), .acr_valid(acr_valid),
        .acr_cts(acr_cts), .acr_n(acr_n));
    wire [23:0] played_sample_sys;
    wire played_sample_valid_sys,played_sample_ready_pixel;
    reg sample_cdc_overrun;
    always @(posedge clk_pixel or posedge rst_pixel)
      if(rst_pixel) sample_cdc_overrun<=0;
      else if(audio_valid && !played_sample_ready_pixel) sample_cdc_overrun<=1;
    cdc_mailbox #(.WIDTH(24)) u_played_sample (
      .src_clk(clk_pixel),.src_rst(rst_pixel),.src_data(audio_left),.src_valid(audio_valid),
      .src_ready(played_sample_ready_pixel),.src_done(),.dst_clk(clk_50m),.dst_rst(rst_sys),
      .dst_data(played_sample_sys),.dst_valid(played_sample_valid_sys),.dst_ready(1'b1));
    wire [255:0] heights_sys,heights_pixel;
    wire heights_valid_sys,heights_ready_sys,heights_valid_pixel,spectrum_overrun;
    spectrum_dft u_spectrum (.clk(clk_50m),.rst(rst_sys),.sample(played_sample_sys),
      .sample_valid(played_sample_valid_sys),.heights(heights_sys),.heights_valid(heights_valid_sys),
      .heights_ready(heights_ready_sys),.overrun(spectrum_overrun));
    cdc_mailbox #(.WIDTH(256)) u_spectrum_cdc (
      .src_clk(clk_50m),.src_rst(rst_sys),.src_data(heights_sys),.src_valid(heights_valid_sys),
      .src_ready(heights_ready_sys),.src_done(),.dst_clk(clk_pixel),.dst_rst(rst_pixel),
      .dst_data(heights_pixel),.dst_valid(heights_valid_pixel),.dst_ready(1'b1));
    wire [23:0] uptime_bcd;
    uptime_counter u_uptime (.clk(clk_50m),.rst(rst_sys),.tick_ms(tick_ms),.bcd(uptime_bcd));
    wire [3:0] switches_sys;
    switch_filter #(.ACTIVE_LOW(SWITCH_ACTIVE_LOW)) u_switches (.clk(clk_50m),.rst(rst_sys),
      .tick_ms(tick_ms),.switches(sw),.stable(switches_sys));
    wire [15:0] display_index=(image_count==0)?16'd0:current_index+16'd1;
    cdc_level u_playing (.clk(clk_50m),.rst(rst_sys),.async_data(audio_playing_pixel),.sync_data(audio_playing_sys));
    wire [65:0] osd_status_sys={wav_available_sys,audio_playing_sys,uptime_bcd,display_index,image_count,
      slideshow_error || storage_error,transitioning_sys,slideshow_busy,auto_enabled,switches_sys};
    wire [65:0] osd_status_pixel;
    wire osd_status_valid;
    cdc_mailbox #(.WIDTH(66)) u_osd_status (
      .src_clk(clk_50m),.src_rst(rst_sys),.src_data(osd_status_sys),.src_valid(1'b1),.src_ready(),.src_done(),
      .dst_clk(clk_pixel),.dst_rst(rst_pixel),.dst_data(osd_status_pixel),.dst_valid(osd_status_valid),.dst_ready(1'b1));
    wire [23:0] composed_rgb;
    wire composed_valid,composed_user,composed_last;
    video_compositor u_compositor (.clk(clk_pixel),.rst(rst_pixel),
      .frame_blank(frame_req_pixel && frame_req_ready_pixel),.in_rgb(axis_data),.in_valid(axis_valid),
      .in_user(axis_user),.in_last(axis_last),.status(osd_status_pixel),.status_valid(osd_status_valid),
      .heights(heights_pixel),.heights_valid(heights_valid_pixel),.out_rgb(composed_rgb),
      .out_valid(composed_valid),.out_user(composed_user),.out_last(composed_last));
    reg composed_protocol_error;
    always @(posedge clk_pixel or posedge rst_pixel)
      if(rst_pixel) composed_protocol_error<=0;
      else if(video_locked && composed_valid && !composed_last && !axis_ready) composed_protocol_error<=1;
    hdmi_tx_640x480 u_hdmi (
        .I_pixel_clk(clk_pixel), .I_serial_clk(clk_serial), .I_rst(rst_pixel),
        .I_axis_s_user(composed_user), .I_axis_s_valid(composed_valid), .I_axis_s_last(composed_last),
        .I_axis_s_data(composed_rgb), .O_axis_s_ready(axis_ready), .O_video_locked(video_locked),
        .I_audio_valid(audio_valid && audio_enable), .I_audio_left_data(audio_left),
        .I_audio_right_data(audio_right), .I_acr_valid(acr_valid && audio_enable),
        .I_acr_cts(acr_cts), .I_acr_n(acr_n), .I_edid_read_trig(1'b0),
        .O_edid_read_valid(), .O_edid_read_data(), .O_ddc_scl(ddc_scl), .IO_ddc_sda(ddc_sda),
        .O_tmds_ch0_p(tmds_ch0_p), .O_tmds_ch1_p(tmds_ch1_p),
        .O_tmds_ch2_p(tmds_ch2_p), .O_tmds_clk_p(tmds_clk_p)
    );
    wire [2:0] video_status_sys;
    cdc_level #(.WIDTH(3)) u_video_status_sys (.clk(clk_50m), .rst(rst_sys),
        .async_data({composed_protocol_error || video_protocol_error, video_underflow || video_fifo_underflow, video_locked}),
        .sync_data(video_status_sys));
    wire audio_fault_sys;
    cdc_level u_audio_fault (.clk(clk_50m),.rst(rst_sys),
      .async_data(audio_underflow_pixel || audio_tag_error_pixel || sample_cdc_overrun
                  || audio_out_overflow || audio_out_underflow || audio_in_underflow),.sync_data(audio_fault_sys));
    wire [3:0] led_on = {slideshow_error || storage_error || memory_fault_sys
                        || load_overflow || wav_fault_sys || spectrum_overrun || audio_fault_sys || audio_in_overflow || video_status_sys[2] || video_status_sys[1],
                        auto_enabled, slideshow_busy, sd_init_done && memory_ready_sys && video_status_sys[0]};
    assign status_led = STATUS_LED_ACTIVE_LOW ? ~led_on : led_on;
endmodule

`default_nettype wire
