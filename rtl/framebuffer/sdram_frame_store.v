`timescale 1ns/1ps
`default_nettype none

// All ports here are in the 150 MHz domain. Commands cross through mailboxes.
// Each SDRAM word holds one RGB888 pixel. Banks below mean frame regions, not
// the SDRAM BA pins: region 0 = word 0, region 1 = word 307200.
// Vendor accesses are mutually exclusive, 64 words, four-word aligned. Each
// transaction drains before a direction change or an explicitly owned refresh.
module sdram_frame_store #(
    parameter integer TRANSITION_FRAMES = 60,
    parameter integer AUDIO_LOW_WORDS = 96000,
    parameter integer AUDIO_HIGH_WORDS = 192000
) (
    input wire [31:0] audio_in_data,
    input wire audio_in_valid,audio_in_empty,audio_in_ready,
    input wire [9:0] audio_in_used, output wire audio_in_re,
    output wire [31:0] audio_out_data, output wire audio_out_we,
    input wire audio_out_ready,audio_out_full, input wire [9:0] audio_out_used,
    output wire audio_low,audio_high, output wire audio_prerolled,
    output reg transitioning,
    input wire clk,
    input wire rst,
    input wire begin_valid,
    output wire begin_ready,
    input wire begin_bottom_up,
    input wire finish_valid,
    output wire finish_ready,
    input wire finish_abort,
    output reg result_valid,
    input wire result_ready,
    output reg result_abort,
    input wire frame_req_valid,
    output wire frame_req_ready,
    output reg frame_info_valid,
    input wire frame_info_ready,
    output reg frame_has_image,
    input wire [31:0] load_fifo_data,
    input wire load_fifo_valid,
    input wire load_fifo_empty,
    input wire [9:0] load_fifo_used,
    input wire load_fifo_ready,
    output wire load_fifo_re,
    output wire [31:0] video_fifo_data,
    output wire video_fifo_we,
    input wire video_fifo_full,
    input wire [9:0] video_fifo_used,
    input wire video_fifo_wr_ready,
    input wire video_fifo_rd_ready,
    output reg video_fifo_reset,
    output reg fault,
    input wire sdr_init_done,
    input wire sdr_refresh,
    output wire app_refresh_req,
    output wire app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_data,
    output wire [3:0] app_wr_mask,
    output wire app_rd_en,
    output wire [20:0] app_rd_addr,
    input wire sdr_rd_valid,
    input wire [31:0] sdr_rd_data
);
    localparam [4:0] IDLE=0, W_SEND=1, W_DRAIN=2, R_SEND=3, R_DRAIN=4,
                     REF_REQ=5, REF_HIGH=6, REF_LOW=7, V_FLUSH=8, V_READY=9, A_W_SEND=10,A_W_DRAIN=11,A_R_SEND=12,A_R_DRAIN=13,BLEND=14;
    localparam [18:0] FRAME_WORDS = 19'd307200;
    localparam [20:0] FRAME_STRIDE = 21'd307200;
    localparam [20:0] LAST_ROW = 21'd306560;
    // 4000 + the longest bounded transaction remains below 4687 cycles/row.
    localparam [12:0] REFRESH_INTERVAL = 13'd4000;
    reg [4:0] state;
    reg [6:0] issued, transferred, pop_remaining, flush_count;
    wire reading = (state == R_SEND) || (state == R_DRAIN);
    reg [17:0] audio_write_ptr,audio_read_ptr;
    reg [18:0] audio_words;
    reg [5:0] transition_frame;
    reg [8:0] alpha;
    reg blend_second;
    reg [6:0] blend_index;
    reg [1:0] blend_valid;
    wire blend_old_we=reading && sdr_rd_valid && transitioning && !blend_second && transferred<64;
    wire blend_new_we=reading && sdr_rd_valid && transitioning && blend_second && transferred<64;
    wire [5:0] blend_addr=(state==BLEND)?blend_index[5:0]:transferred[5:0];
    wire [23:0] old_rgb,new_rgb;
    ram_blend_block u_old (.clka(clk),.rsta(rst),.cea(1'b1),.wea(blend_old_we),
      .addra(blend_addr),.dia(sdr_rd_data[23:0]),.doa(old_rgb));
    ram_blend_block u_new (.clka(clk),.rsta(rst),.cea(1'b1),.wea(blend_new_we),
      .addra(blend_addr),.dia(sdr_rd_data[23:0]),.doa(new_rgb));
    function [7:0] blend_channel;
      input [7:0] a,b; input [8:0] weight;
      reg signed [8:0] difference;
      reg signed [18:0] product,value;
      begin
          difference=$signed({1'b0,b})-$signed({1'b0,a});
          product=difference*$signed({1'b0,weight});
          value=$signed({3'd0,a,8'd0})+product+19'sd128;
          blend_channel=value[15:8];
      end
    endfunction
    wire [23:0] blend_rgb={blend_channel(old_rgb[23:16],new_rgb[23:16],alpha),
      blend_channel(old_rgb[15:8],new_rgb[15:8],alpha),blend_channel(old_rgb[7:0],new_rgb[7:0],alpha)};
    wire audio_reading=state==A_R_SEND || state==A_R_DRAIN;
    assign audio_low=audio_words<AUDIO_LOW_WORDS;
    assign audio_high=audio_words>=AUDIO_HIGH_WORDS;
    assign audio_prerolled=audio_words>=AUDIO_HIGH_WORDS;
    assign audio_in_re=!rst && !fault && state==A_W_SEND && pop_remaining!=0
                       && audio_in_ready && !audio_in_empty;
    assign audio_out_data=sdr_rd_data;
    assign audio_out_we=!rst && !fault && audio_reading && sdr_rd_valid
                       && transferred<64 && audio_out_ready && !audio_out_full;
    reg [12:0] refresh_timer;
    reg [7:0] wait_count, quiet_count;
    reg front_valid, front_region, pending_front, pending_region;
    reg load_active, load_region, load_bottom_up, finish_seen, abort_requested;
    reg [18:0] written_words;
    reg [20:0] write_address, row_base;
    reg [9:0] write_x;
    reg [3:0] abort_empty_count;
    reg read_active, selected_valid, selected_region;
    reg [18:0] read_remaining;
    reg [20:0] read_address;
    wire refresh_due = (refresh_timer >= REFRESH_INTERVAL);
    // APUG011 lists Sdr_busy as reserved. Own transaction/drain states enforce
    // exclusion; Sdr_init_ref_vld is the documented refresh exclusion signal.
    wire controller_idle = sdr_init_done && !sdr_refresh;
    wire writing = (state == W_SEND) || (state == W_DRAIN);
    wire abort_draining = load_active && abort_requested && !writing;
    wire write_pop = (state == W_SEND) && (pop_remaining != 0);

    assign frame_req_ready = !rst && !fault && (state == IDLE)
                           && controller_idle && !refresh_due && !frame_info_valid;
    assign begin_ready = !rst && !fault && (state == IDLE) && controller_idle
                       && !refresh_due && !frame_req_valid && !load_active
                       && !pending_front && !transitioning && !result_valid && load_fifo_ready;
    assign finish_ready = !rst && load_active && !finish_seen;
    assign load_fifo_re = !rst && !fault && load_fifo_ready && !load_fifo_empty
                         && (write_pop || abort_draining);
    assign app_refresh_req = !rst && !fault && (state == REF_REQ);
    assign app_wr_en = !rst && !fault && transferred<64 &&
         ((state==W_SEND && load_fifo_valid) || (state==A_W_SEND && audio_in_valid));
    assign app_wr_addr = state==A_W_SEND ? 21'h100000+{3'd0,audio_write_ptr}+transferred : write_address;
    assign app_wr_data = state==A_W_SEND ? audio_in_data : load_fifo_data;
    assign app_wr_mask = 4'b0000;
    assign app_rd_en = !rst && !fault && (state==R_SEND || state==A_R_SEND);
    assign app_rd_addr = state==A_R_SEND ? 21'h100000+{3'd0,audio_read_ptr}+issued :
       (read_address + {14'd0,issued} + ((transitioning && blend_second) ?
         (selected_region ? -FRAME_STRIDE : FRAME_STRIDE) : 21'd0));
    assign video_fifo_data = transitioning ? {8'd0,blend_rgb} : sdr_rd_data;
    assign video_fifo_we = !rst && !fault && video_fifo_wr_ready && !video_fifo_full &&
       (transitioning ? (state==BLEND && blend_valid[1]) : (reading && sdr_rd_valid && transferred<64));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            audio_write_ptr<=0;audio_read_ptr<=0;audio_words<=0;
            transitioning<=0;transition_frame<=0;alpha<=0;blend_second<=0;blend_index<=0;blend_valid<=0;
            refresh_timer <= 0; wait_count <= 0; quiet_count <= 0;
            issued <= 0; transferred <= 0; pop_remaining <= 0; flush_count <= 0;
            front_valid <= 0; front_region <= 0;
            pending_front <= 0; pending_region <= 0;
            load_active <= 0; load_region <= 1; load_bottom_up <= 0;
            finish_seen <= 0; abort_requested <= 0;
            written_words <= 0; write_address <= 0; row_base <= 0; write_x <= 0;
            abort_empty_count <= 0;
            read_active <= 0; selected_valid <= 0; selected_region <= 0;
            read_remaining <= 0; read_address <= 0;
            result_valid <= 0; result_abort <= 0;
            frame_info_valid <= 0; frame_has_image <= 0;
            video_fifo_reset <= 1;
            fault <= 0;
        end else begin
            if (!sdr_init_done) refresh_timer <= 0;
            else if (refresh_timer != 13'h1FFF) refresh_timer <= refresh_timer + 1'b1;
            if (result_valid && result_ready) result_valid <= 0;
            if (frame_info_valid && frame_info_ready) frame_info_valid <= 0;

            if (begin_valid && begin_ready) begin
                load_active <= 1;
                load_region <= !front_region;
                load_bottom_up <= begin_bottom_up;
                finish_seen <= 0; abort_requested <= 0; written_words <= 0;
                write_x <= 0;
                row_base <= (front_region ? 21'd0 : FRAME_STRIDE)
                            + (begin_bottom_up ? LAST_ROW : 21'd0);
                write_address <= (front_region ? 21'd0 : FRAME_STRIDE)
                                 + (begin_bottom_up ? LAST_ROW : 21'd0);
            end
            if (finish_valid && finish_ready) begin
                finish_seen <= 1;
                abort_requested <= finish_abort;
            end

            // Aborted jobs discard their entire FIFO tail before acknowledging.
            if (abort_draining && load_fifo_empty && !load_fifo_valid
                && (load_fifo_used == 0)) begin
                if (abort_empty_count == 8) begin
                    load_active <= 0; finish_seen <= 0; abort_requested <= 0;
                    result_abort <= 1; result_valid <= 1;
                    abort_empty_count <= 0;
                end else abort_empty_count <= abort_empty_count + 1'b1;
            end else abort_empty_count <= 0;

            if (load_active && finish_seen && !abort_requested && !writing
                && (written_words == FRAME_WORDS) && load_fifo_empty
                && !load_fifo_valid && !fault) begin
                pending_front <= 1;
                pending_region <= load_region;
                load_active <= 0;
                finish_seen <= 0;
            end
            if (app_wr_en && state==W_SEND) begin
                written_words <= written_words + 1'b1;
                if (write_x == 10'd639) begin
                    write_x <= 0;
                    if (written_words != FRAME_WORDS - 1'b1) begin
                        if (load_bottom_up) begin
                            row_base <= row_base - 21'd640;
                            write_address <= row_base - 21'd640;
                        end else begin
                            row_base <= row_base + 21'd640;
                            write_address <= row_base + 21'd640;
                        end
                    end
                end else begin
                    write_x <= write_x + 1'b1;
                    write_address <= write_address + 1'b1;
                end
            end
            if (reading && sdr_rd_valid) begin
                transferred <= transferred + 1'b1;
                if ((!transitioning && (video_fifo_full || !video_fifo_wr_ready)) || transferred>=64) fault<=1;
            end

            if(audio_reading && sdr_rd_valid) begin
                transferred<=transferred+1'b1;
                if(audio_out_full || !audio_out_ready || transferred>=64) fault<=1;
            end
            case (state)
                IDLE: begin
                    wait_count <= 0; quiet_count <= 0;
                    if (!fault && controller_idle) begin
                        if (refresh_due) state <= REF_REQ;
                        else if (frame_req_valid && frame_req_ready) begin
                            // All old read responses have drained before this reset.
                            read_active <= 0;
                            video_fifo_reset <= 1;
                            flush_count <= 0;
                            selected_valid <= front_valid || pending_front;
                            selected_region <= front_region;
                            blend_second<=0;
                            if(transitioning) begin
                                if(transition_frame==TRANSITION_FRAMES-1) begin
                                    transitioning<=0;front_region<=!front_region;
                                    selected_region<=!front_region;alpha<=256;
                                    result_abort<=0;result_valid<=1;
                                end else begin
                                    transition_frame<=transition_frame+1'b1;
                                    alpha<=((transition_frame+9'd1)*9'd256)/TRANSITION_FRAMES;
                                end
                            end else if(pending_front) begin
                                pending_front<=0;front_valid<=1;
                                if(front_valid) begin transitioning<=1;transition_frame<=0;alpha<=0;end
                                else begin
                                    front_region<=pending_region;selected_region<=pending_region;
                                    result_abort<=0;result_valid<=1;
                                end
                            end
                            state <= V_FLUSH;
                        end else if(read_active && read_remaining>=64 && video_fifo_wr_ready && video_fifo_used<256) begin
                            issued<=0;transferred<=0;blend_second<=0;state<=R_SEND;
                        end else if(audio_words>=64 && audio_out_ready && audio_out_used<=768) begin
                            issued<=0;transferred<=0;state<=A_R_SEND;
                        end else if(audio_in_ready && audio_in_used>=64 && audio_words<=19'd262080) begin
                            pop_remaining<=64;transferred<=0;state<=A_W_SEND;
                        end else if(read_active && read_remaining>=64 && video_fifo_wr_ready && video_fifo_used<=896) begin
                            issued<=0;transferred<=0;blend_second<=0;state<=R_SEND;
                        end else if(load_active && !abort_requested && written_words<FRAME_WORDS
                                    && load_fifo_ready && load_fifo_used>=64) begin
                            pop_remaining<=64;transferred<=0;state<=W_SEND;
                        end
                    end
                end
                W_SEND: begin
                    wait_count <= wait_count + 1'b1;
                    if (load_fifo_re) pop_remaining <= pop_remaining - 1'b1;
                    if (app_wr_en) begin
                        transferred <= transferred + 1'b1;
                        if (transferred == 63) begin
                            wait_count <= 0;
                            state <= W_DRAIN;
                        end
                    end
                    if (wait_count == 255) begin fault <= 1; state <= IDLE; end
                end
                W_DRAIN: begin
                    if (wait_count == 20) begin wait_count <= 0; state <= IDLE; end
                    else wait_count <= wait_count + 1'b1;
                end
                R_SEND: begin
                    issued <= issued + 1'b1;
                    if (issued == 63) begin
                        wait_count <= 0; quiet_count <= 0; state <= R_DRAIN;
                    end
                end
                R_DRAIN: begin
                    wait_count <= wait_count + 1'b1;
                    if (sdr_rd_valid) quiet_count <= 0;
                    else if (quiet_count != 255) quiet_count <= quiet_count + 1'b1;
                    if ((transferred == 64) && (quiet_count >= 20)) begin
                        if(transitioning && !blend_second) begin
                            blend_second<=1;issued<=0;transferred<=0;state<=R_SEND;
                        end else if(transitioning) begin
                            blend_index<=0;blend_valid<=0;state<=BLEND;
                        end else begin
                            read_address<=read_address+64;read_remaining<=read_remaining-64;
                            if(read_remaining==64) read_active<=0;
                            state<=IDLE;
                        end
                    end else if (wait_count == 255) begin
                        fault <= 1; read_active <= 0; state <= IDLE;
                    end
                end
                BLEND: begin
                    blend_valid<={blend_valid[0],blend_index<64};
                    if(blend_index<66) blend_index<=blend_index+1'b1;
                    if(blend_valid[1] && (video_fifo_full || !video_fifo_wr_ready)) fault<=1;
                    if(blend_index==65) begin
                        read_address<=read_address+64;read_remaining<=read_remaining-64;
                        if(read_remaining==64) read_active<=0;
                        blend_second<=0;state<=IDLE;
                    end
                end
                A_W_SEND: begin
                    wait_count<=wait_count+1'b1;
                    if(audio_in_re) pop_remaining<=pop_remaining-1'b1;
                    if(app_wr_en) begin
                        transferred<=transferred+1'b1;
                        if(transferred==63) begin state<=A_W_DRAIN;wait_count<=0;end
                    end
                    if(wait_count==255) begin fault<=1;state<=IDLE;end
                end
                A_W_DRAIN: begin
                    if(wait_count==20) begin
                        audio_write_ptr<=audio_write_ptr+18'd64;
                        audio_words<=audio_words+19'd64;
                        state<=IDLE;wait_count<=0;
                    end else wait_count<=wait_count+1'b1;
                end
                A_R_SEND: begin
                    issued<=issued+1'b1;
                    if(issued==63) begin state<=A_R_DRAIN;wait_count<=0;quiet_count<=0;end
                end
                A_R_DRAIN: begin
                    wait_count<=wait_count+1'b1;
                    if(sdr_rd_valid) quiet_count<=0;
                    else if(quiet_count!=255) quiet_count<=quiet_count+1'b1;
                    if(transferred==64 && quiet_count>=20) begin
                        audio_read_ptr<=audio_read_ptr+18'd64;audio_words<=audio_words-19'd64;
                        state<=IDLE;
                    end else if(wait_count==255) begin fault<=1;state<=IDLE;end
                end
                REF_REQ: begin
                    refresh_timer <= 0;
                    wait_count <= 0;
                    state <= REF_HIGH;
                end
                REF_HIGH: begin
                    wait_count <= wait_count + 1'b1;
                    if (sdr_refresh) begin wait_count <= 0; state <= REF_LOW; end
                    else if (wait_count == 255) begin fault <= 1; state <= IDLE; end
                end
                REF_LOW: begin
                    wait_count <= wait_count + 1'b1;
                    if (!sdr_refresh) state <= IDLE;
                    else if (wait_count == 255) begin fault <= 1; state <= IDLE; end
                end
                V_FLUSH: begin
                    // 96 SDRAM clocks = 16 pixel clocks at the actual 150/25 ratio.
                    if (flush_count == 95) begin
                        video_fifo_reset <= 0;
                        wait_count <= 0;
                        state <= V_READY;
                    end else flush_count <= flush_count + 1'b1;
                end
                V_READY: begin
                    wait_count <= wait_count + 1'b1;
                    if (video_fifo_wr_ready && video_fifo_rd_ready) begin
                        read_active <= selected_valid;
                        read_address <= selected_region ? FRAME_STRIDE : 21'd0;
                        read_remaining <= selected_valid ? FRAME_WORDS : 19'd0;
                        frame_has_image <= selected_valid;
                        frame_info_valid <= 1;
                        state <= IDLE;
                    end else if (wait_count == 255) begin fault <= 1; state <= IDLE; end
                end
                default: begin fault <= 1; state <= IDLE; end
            endcase
        end
    end
endmodule

`default_nettype wire
