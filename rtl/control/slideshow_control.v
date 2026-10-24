`timescale 1ns/1ps
`default_nettype none

// Index order is the FAT root-directory order. One pending manual direction is
// retained while a file loads OR fades. Frame-store result means the complete
// transition has finished and the old region is reusable. Dwell starts then.
module slideshow_control #(
    parameter integer AUTO_INTERVAL_MS = 5000,
    parameter AUTO_DEFAULT = 1'b1
) (
    input wire clk,
    input wire rst,
    input wire tick_ms,
    input wire previous_press,
    input wire next_press,
    input wire auto_press,
    input wire memory_ready,
    input wire memory_fault,
    input wire mount_done,
    input wire catalog_ready,
    input wire [15:0] image_count,
    input wire storage_error,
    output wire open_valid,
    input wire open_ready,
    output wire [15:0] open_index,
    input wire file_done,
    output reg decoder_start,
    output reg decoder_cancel,
    input wire decoder_done,
    input wire decoder_complete,
    input wire decoder_error,
    input wire image_begin_valid,
    input wire image_begin_ready,
    output wire finish_valid,
    input wire finish_ready,
    output reg finish_abort,
    input wire result_valid,
    output wire result_ready,
    input wire result_abort,
    output reg auto_enabled,
    output wire busy,
    output reg error,
    output reg have_image,
    output reg [15:0] current_index
);
    localparam [3:0] WAIT_CATALOG=0, OPEN_FILE=1, READ_FILE=2,
                     SEND_FINISH=3, WAIT_RESULT=4, SHOW=5, RETRY=6, FAULT=7;
    localparam [31:0] LAST_AUTO_MS = (AUTO_INTERVAL_MS > 0) ? AUTO_INTERVAL_MS - 1 : 0;
    reg [3:0] state;
    reg [15:0] candidate_index, attempts;
    reg [1:0] pending_step;
    reg direction_previous, image_started, file_closed;
    reg fatal_after_result;
    reg [31:0] elapsed_ms;
    reg [15:0] retry_ms;
    wire [1:0] requested_step = previous_press ? 2'd2
                                 : next_press ? 2'd1 : pending_step;
    wire began = image_started || (image_begin_valid && image_begin_ready);
    assign open_valid = (state == OPEN_FILE) && memory_ready && !memory_fault;
    assign open_index = candidate_index;
    assign finish_valid = (state == SEND_FINISH);
    assign result_ready = (state == WAIT_RESULT);
    assign busy = (state != SHOW);

    function [15:0] adjacent;
        input [15:0] index;
        input backwards;
        begin
            if (backwards) adjacent = (index == 0) ? image_count - 1'b1 : index - 1'b1;
            else adjacent = (index >= image_count - 1'b1) ? 16'd0 : index + 1'b1;
        end
    endfunction
    task skip_failed_candidate;
        begin
            error <= 1;
            if (attempts >= image_count - 1'b1) begin
                if (have_image) state <= SHOW;
                else begin retry_ms <= 0; state <= RETRY; end
            end else begin
                attempts <= attempts + 1'b1;
                candidate_index <= adjacent(candidate_index, direction_previous);
                state <= OPEN_FILE;
            end
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_CATALOG;
            candidate_index <= 0; current_index <= 0; attempts <= 0;
            pending_step <= 0; direction_previous <= 0;
            have_image <= 0; image_started <= 0; file_closed <= 0;
            fatal_after_result <= 0;
            elapsed_ms <= 0; retry_ms <= 0;
            decoder_start <= 0; decoder_cancel <= 0;
            finish_abort <= 0; auto_enabled <= AUTO_DEFAULT; error <= 0;
        end else begin
            decoder_start <= 0;
            decoder_cancel <= 0;
            if (previous_press) pending_step <= 2;
            else if (next_press) pending_step <= 1;
            if (auto_press) auto_enabled <= !auto_enabled;
            if ((state != SHOW) || !auto_enabled || auto_press) elapsed_ms <= 0;
            if (image_begin_valid && image_begin_ready) image_started <= 1;

            if (memory_fault) begin
                error <= 1;
                decoder_cancel <= 1;
                state <= FAULT;
            end else case (state)
                WAIT_CATALOG: begin
                    if (catalog_ready && (image_count != 0) && memory_ready) begin
                        candidate_index <= 0; attempts <= 0; direction_previous <= 0;
                        state <= OPEN_FILE;
                    end else if (catalog_ready && (image_count == 0)) error <= 1;
                    else if (storage_error) begin error <= 1; state <= FAULT; end
                end
                OPEN_FILE: if (open_valid && open_ready) begin
                    decoder_start <= 1;
                    image_started <= 0;
                    file_closed <= 0;
                    fatal_after_result <= 0;
                    state <= READ_FILE;
                end
                READ_FILE: begin
                    if (file_done) file_closed <= 1;
                    if (storage_error) begin
                        decoder_cancel <= 1;
                        error <= 1;
                        finish_abort <= 1;
                        fatal_after_result <= !mount_done;
                        if (began) state <= SEND_FINISH;
                        else if (!mount_done) state <= FAULT;
                        else skip_failed_candidate;
                    end else if ((file_closed || file_done) && decoder_done) begin
                        finish_abort <= decoder_error || !decoder_complete;
                        if (began) state <= SEND_FINISH;
                        else skip_failed_candidate;
                    end
                end
                SEND_FINISH: if (finish_valid && finish_ready) state <= WAIT_RESULT;
                WAIT_RESULT: if (result_valid && result_ready) begin
                    if (fatal_after_result) begin error <= 1; state <= FAULT; end
                    else if (result_abort) skip_failed_candidate;
                    else begin
                        current_index <= candidate_index;
                        have_image <= 1;
                        error <= 0;
                        elapsed_ms <= 0;
                        state <= SHOW;
                    end
                end
                SHOW: begin
                    if (requested_step != 0) begin
                        candidate_index <= adjacent(current_index, requested_step == 2);
                        direction_previous <= (requested_step == 2);
                        pending_step <= 0;
                        attempts <= 0;
                        state <= OPEN_FILE;
                    end else if (auto_enabled && !auto_press && tick_ms) begin
                        if (elapsed_ms >= LAST_AUTO_MS) begin
                            elapsed_ms <= 0;
                            candidate_index <= adjacent(current_index, 1'b0);
                            direction_previous <= 0;
                            attempts <= 0;
                            state <= OPEN_FILE;
                        end else elapsed_ms <= elapsed_ms + 1'b1;
                    end
                end
                RETRY: if (tick_ms) begin
                    if (retry_ms == 999) begin
                        retry_ms <= 0;
                        candidate_index <= 0; attempts <= 0; direction_previous <= 0;
                        state <= OPEN_FILE;
                    end else retry_ms <= retry_ms + 1'b1;
                end
                FAULT: begin end // Storage/memory fatal errors require KEY4 reset.
                default: begin error <= 1; state <= FAULT; end
            endcase
        end
    end
endmodule

`default_nettype wire
