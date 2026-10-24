`timescale 1ns/1ps
`default_nettype none

// All ports here are in the 150 MHz domain. Commands cross through mailboxes.
// Each SDRAM word holds one RGB888 pixel. Banks below mean frame regions, not
// the SDRAM BA pins: region 0 = word 0, region 1 = word 307200.
// Vendor accesses are mutually exclusive, 64 words, four-word aligned. Each
// transaction drains before a direction change or an explicitly owned refresh.
module sdram_frame_store (
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
    output reg transition_active,
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
    localparam [3:0] IDLE=0, W_SEND=1, W_DRAIN=2, R_SEND=3, R_DRAIN=4,
                     REF_REQ=5, REF_HIGH=6, REF_LOW=7, V_FLUSH=8, V_READY=9;
    localparam [18:0] FRAME_WORDS = 19'd307200;
    localparam [20:0] FRAME_STRIDE = 21'd307200;
    localparam [20:0] LAST_ROW = 21'd306560;
    // 4000 + the longest bounded transaction remains below 4687 cycles/row.
    localparam [12:0] REFRESH_INTERVAL = 13'd4000;
    reg [3:0] state;
    reg [12:0] refresh_timer;
    reg [7:0] wait_count, quiet_count;
    reg [6:0] issued, transferred, pop_remaining, flush_count;
    reg front_valid, front_region, pending_front, pending_region;
    reg load_active, load_region, load_bottom_up, finish_seen, abort_requested;
    reg [18:0] written_words;
    reg [20:0] write_address, row_base;
    reg [9:0] write_x;
    reg [3:0] abort_empty_count;
    reg read_active, selected_valid, selected_region;
    reg [18:0] read_remaining;
    reg [20:0] read_address;
    reg [8:0] fade_alpha, selected_alpha;
    reg selected_fade, selected_new_region, read_new, pair_pending, block_half;
    wire [31:0] old_pixel;
    reg [31:0] new_pixel_d, mixed_pixel;
    reg return_valid_d, mixed_valid;
    wire reading = (state == R_SEND) || (state == R_DRAIN);
    wire old_pass = selected_fade && !read_new;
    wire read_return = reading && sdr_rd_valid && (transferred < 64);
    ram_fade_block u_old_block (
        .dia(sdr_rd_data), .addra({block_half, transferred[5:0]}), .clka(clk),
        .wea(!rst && !fault && read_return && old_pass),
        .addrb({block_half, transferred[5:0]}), .clkb(clk), .dob(old_pixel)
    );
    function [7:0] fade_channel;
        input [7:0] old_c, new_c;
        input [8:0] alpha;
        reg signed [9:0] delta;
        reg signed [19:0] scaled, product;
        begin
            delta = $signed({2'b0,new_c}) - $signed({2'b0,old_c});
            product = delta * $signed({1'b0,alpha});
            scaled = product + $signed({4'b0,old_c,8'b0}) + 20'sd128;
            fade_channel = scaled[15:8];
        end
    endfunction
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
                       && !pending_front && !transition_active && !result_valid && load_fifo_ready;
    assign finish_ready = !rst && load_active && !finish_seen;
    assign load_fifo_re = !rst && !fault && load_fifo_ready && !load_fifo_empty
                         && (write_pop || abort_draining);
    assign app_refresh_req = !rst && !fault && (state == REF_REQ);
    assign app_wr_en = !rst && !fault && (state == W_SEND)
                       && load_fifo_valid && (transferred < 7'd64);
    assign app_wr_addr = write_address;
    assign app_wr_data = load_fifo_data;
    assign app_wr_mask = 4'b0000;
    assign app_rd_en = !rst && !fault && (state == R_SEND);
    // read_address is an offset shared by the two corresponding frame regions.
    assign app_rd_addr = read_address + {14'd0, issued}
                        + ((read_new ? selected_new_region : selected_region) ? FRAME_STRIDE : 21'd0);
    assign video_fifo_data = mixed_pixel;
    assign video_fifo_we = !rst && !fault && mixed_valid && video_fifo_wr_ready
                         && !video_fifo_reset && !video_fifo_full;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
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
            fault <= 0; transition_active <= 0; fade_alpha <= 0;
            selected_fade <= 0; selected_alpha <= 0; selected_new_region <= 0;
            read_new <= 0; pair_pending <= 0; block_half <= 0;
            new_pixel_d <= 0; mixed_pixel <= 0; return_valid_d <= 0; mixed_valid <= 0;
        end else begin
            // One clock for synchronous block RAM, then one registered RGB blend.
            // R_DRAIN's quiet interval includes both stages and the FIFO write.
            return_valid_d <= !fault && read_return && !old_pass;
            new_pixel_d <= sdr_rd_data;
            mixed_valid <= return_valid_d && !fault;
            if (selected_fade) mixed_pixel <= {8'b0,
                fade_channel(old_pixel[23:16], new_pixel_d[23:16], selected_alpha),
                fade_channel(old_pixel[15:8], new_pixel_d[15:8], selected_alpha),
                fade_channel(old_pixel[7:0], new_pixel_d[7:0], selected_alpha)};
            else mixed_pixel <= new_pixel_d;
            if (mixed_valid && (!video_fifo_wr_ready || video_fifo_full || video_fifo_reset)) fault <= 1;
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
            if (app_wr_en) begin
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
                if (transferred >= 64) fault <= 1;
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
                            selected_new_region <= pending_region;
                            selected_fade <= transition_active;
                            selected_alpha <= fade_alpha;
                            read_new <= 0; pair_pending <= 0; block_half <= 0;
                            if (pending_front && !front_valid) begin
                                // First image has no predecessor to blend with.
                                selected_region <= pending_region;
                                front_region <= pending_region; front_valid <= 1;
                                pending_front <= 0; selected_fade <= 0;
                                result_abort <= 0; result_valid <= 1;
                            end else if (pending_front && !transition_active) begin
                                transition_active <= 1; fade_alpha <= 0;
                                selected_fade <= 1; selected_alpha <= 0;
                            end else if (transition_active) begin
                                if (fade_alpha == 256) begin
                                    // Alpha=256 has occupied a complete display frame.
                                    // Release the OLD region only now, after all reads drain.
                                    transition_active <= 0; selected_fade <= 0;
                                    selected_region <= pending_region;
                                    front_region <= pending_region; pending_front <= 0;
                                    result_abort <= 0; result_valid <= 1;
                                end else begin
                                    fade_alpha <= fade_alpha + 9'd4;
                                    selected_alpha <= fade_alpha + 9'd4;
                                end
                            end
                            state <= V_FLUSH;
                        end else if (read_active && (read_remaining >= 64)
                                     && video_fifo_wr_ready && (video_fifo_used <= 10'd896)) begin
                            issued <= 0; transferred <= 0;
                            read_new <= pair_pending;
                            state <= R_SEND;
                        end else if (load_active && !abort_requested
                                     && (written_words < FRAME_WORDS)
                                     && load_fifo_ready && (load_fifo_used >= 10'd64)) begin
                            pop_remaining <= 7'd64;
                            transferred <= 0;
                            state <= W_SEND;
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
                        if (old_pass) begin
                            pair_pending <= 1; // Preserve old block across refresh/idle.
                        end else begin
                            pair_pending <= 0; read_new <= 0; block_half <= !block_half;
                            read_address <= read_address + 21'd64;
                            read_remaining <= read_remaining - 19'd64;
                            if (read_remaining == 64) read_active <= 0;
                        end
                        state <= IDLE;
                    end else if (wait_count == 255) begin
                        fault <= 1; read_active <= 0; state <= IDLE;
                    end
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
                        read_address <= 0;
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
