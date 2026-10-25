// Project copy adapted from docs/reference_rtl/fat32/fat32_read_top.v
`timescale 1ns/1ps
`default_nettype none
module fat32_media_top #(
    parameter integer CLK_HZ          = 50000000,
    parameter integer INIT_SPI_HZ     = 250000,
    parameter integer DATA_SPI_HZ     = 5000000,
    parameter integer POWER_WAIT_MS   = 20,
    parameter integer INIT_MAX_TRIES  = 4096,
    parameter integer READY_MAX_BYTES = 32768,
    parameter integer TOKEN_MAX_BYTES = 262144,
    parameter integer BUSY_MAX_BYTES  = 1048576
) (
    input wire audio_priority,audio_bookmark,audio_restart,
    input wire [31:0] audio_loop_length,
    input wire audio_open, output wire audio_open_ready, audio_open_done,
    output wire [15:0] audio_count, output wire audio_catalog,
    output wire [31:0] audio_size, output wire [7:0] audio_data,
    output wire audio_valid, input wire audio_ready, output wire audio_last, audio_done,
    output wire audio_error,
    input  wire        clk,
    input  wire        rst_n,
    input  wire        open_valid,
    output wire        open_ready,
    input  wire [15:0] open_index,
    output wire [15:0] image_count,
    output wire        catalog_ready,
    output wire        open_done,
    output wire [31:0] file_size,
    output wire [7:0]  file_data,
    output wire        file_valid,
    input  wire        file_ready,
    output wire        file_last,
    output wire        file_done,
    output wire        sd_init_done,
    output wire        mount_done,
    output wire        busy,
    output wire        error,
    output wire [7:0]  error_code,
    output wire [7:0]  sd_error_code,
    output wire [7:0]  buffer_error_code,
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso
);
    wire        load_valid, load_ready, load_done, buffer_error;
    wire [31:0] load_lba;
    wire        buf_rd_en, buf_rd_valid;
    wire [8:0]  buf_rd_addr;
    wire [7:0]  buf_rd_data;
    wire        sd_req_valid, sd_req_ready;
    wire [31:0] sd_req_lba;
    wire [7:0]  sd_r_data;
    wire        sd_r_valid, sd_r_ready, sd_r_last;
    wire        sd_done, sd_error;
    fat32_reader u_fat32_reader (
        .bookmark_valid(1'b0),.loop_restart(1'b0),.loop_length(32'd0),
        .clk(clk), .rst_n(rst_n), .card_ready(sd_init_done),
        .open_valid(open_valid), .open_ready(open_ready), .open_index(open_index), .image_count(image_count), .catalog_ready(catalog_ready),
        .open_done(open_done), .file_size(file_size),
        .file_data(file_data), .file_valid(file_valid), .file_ready(file_ready),
        .file_last(file_last), .file_done(file_done),
        .mount_done(mount_done), .busy(busy),
        .error(error), .error_code(error_code),
        .load_valid(load_valid), .load_ready(load_ready), .load_lba(load_lba),
        .load_done(load_done), .buffer_error(buffer_error),
        .buf_rd_en(buf_rd_en), .buf_rd_addr(buf_rd_addr),
        .buf_rd_data(buf_rd_data), .buf_rd_valid(buf_rd_valid)
    );
    sd_sector_buffer u_sector_buffer (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready), .load_lba(load_lba),
        .load_done(load_done), .error(buffer_error),
        .error_code(buffer_error_code),
        .buf_valid(),
        .rd_en(buf_rd_en), .rd_addr(buf_rd_addr),
        .rd_data(buf_rd_data), .rd_valid(buf_rd_valid),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_lba(sd_req_lba),
        .sd_r_data(sd_r_data), .sd_r_valid(sd_r_valid), .sd_r_ready(sd_r_ready),
        .sd_r_last(sd_r_last), .sd_done(sd_done), .sd_error(sd_error)
    );
    wire        a_load_valid, a_load_ready, a_load_done, a_buffer_error;
    wire [31:0] a_load_lba;
    wire        a_buf_rd_en, a_buf_rd_valid;
    wire [8:0]  a_buf_rd_addr;
    wire [7:0]  a_buf_rd_data;
    wire        a_sd_req_valid, a_sd_req_ready;
    wire [31:0] a_sd_req_lba;
    wire [7:0]  a_sd_r_data;
    wire        a_sd_r_valid, a_sd_r_ready, a_sd_r_last;
    wire        a_sd_done, a_sd_error;
    fat32_reader #(.NAMED_FILE(1)) u_audio_reader (
        .bookmark_valid(audio_bookmark),.loop_restart(audio_restart),.loop_length(audio_loop_length),
        .clk(clk), .rst_n(rst_n), .card_ready(sd_init_done),
        .open_valid(audio_open), .open_ready(audio_open_ready), .open_index(16'd0), .image_count(audio_count), .catalog_ready(audio_catalog),
        .open_done(audio_open_done), .file_size(audio_size),
        .file_data(audio_data), .file_valid(audio_valid), .file_ready(audio_ready),
        .file_last(audio_last), .file_done(audio_done),
        .mount_done(), .busy(),
        .error(audio_error), .error_code(),
        .load_valid(a_load_valid), .load_ready(a_load_ready), .load_lba(a_load_lba),
        .load_done(a_load_done), .buffer_error(a_buffer_error),
        .buf_rd_en(a_buf_rd_en), .buf_rd_addr(a_buf_rd_addr),
        .buf_rd_data(a_buf_rd_data), .buf_rd_valid(a_buf_rd_valid)
    );
    sd_sector_buffer u_audio_sector_buffer (
        .clk(clk), .rst_n(rst_n),
        .load_valid(a_load_valid), .load_ready(a_load_ready), .load_lba(a_load_lba),
        .load_done(a_load_done), .error(a_buffer_error),
        .error_code(),
        .buf_valid(),
        .rd_en(a_buf_rd_en), .rd_addr(a_buf_rd_addr),
        .rd_data(a_buf_rd_data), .rd_valid(a_buf_rd_valid),
        .sd_req_valid(a_sd_req_valid), .sd_req_ready(a_sd_req_ready), .sd_req_lba(a_sd_req_lba),
        .sd_r_data(a_sd_r_data), .sd_r_valid(a_sd_r_valid), .sd_r_ready(a_sd_r_ready),
        .sd_r_last(a_sd_r_last), .sd_done(a_sd_done), .sd_error(a_sd_error)
    );

    wire c_sd_req_valid,c_sd_req_ready,c_sd_r_valid,c_sd_r_ready,c_sd_r_last,c_sd_done,c_sd_error;
    wire [31:0] c_sd_req_lba;
    wire [7:0] c_sd_r_data;
    reg owned, owner, last_owner;
    wire choose_audio=a_sd_req_valid && (!sd_req_valid || audio_priority || !last_owner);
    assign c_sd_req_valid=!owned && (sd_req_valid || a_sd_req_valid);
    assign c_sd_req_lba=choose_audio ? a_sd_req_lba : sd_req_lba;
    assign sd_req_ready=!owned && !choose_audio && c_sd_req_ready;
    assign a_sd_req_ready=!owned && choose_audio && c_sd_req_ready;
    assign sd_r_data=c_sd_r_data;
    assign a_sd_r_data=c_sd_r_data;
    assign sd_r_valid=owned && !owner && c_sd_r_valid;
    assign a_sd_r_valid=owned && owner && c_sd_r_valid;
    assign sd_r_last=c_sd_r_last;
    assign a_sd_r_last=c_sd_r_last;
    assign c_sd_r_ready=owned && (owner ? a_sd_r_ready : sd_r_ready);
    assign sd_done=owned && !owner && c_sd_done;
    assign a_sd_done=owned && owner && c_sd_done;
    assign sd_error=c_sd_error;
    assign a_sd_error=c_sd_error;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin owned<=0;owner<=0;last_owner<=0;end
      else if(!owned && c_sd_req_valid && c_sd_req_ready) begin
        owned<=1;owner<=choose_audio;last_owner<=choose_audio;
      end else if(owned && (c_sd_done || c_sd_error)) owned<=0;
    end
    sd_spi_card #(
        .CLK_HZ(CLK_HZ), .INIT_SPI_HZ(INIT_SPI_HZ), .DATA_SPI_HZ(DATA_SPI_HZ),
        .POWER_WAIT_MS(POWER_WAIT_MS), .INIT_MAX_TRIES(INIT_MAX_TRIES),
        .READY_MAX_BYTES(READY_MAX_BYTES), .TOKEN_MAX_BYTES(TOKEN_MAX_BYTES),
        .BUSY_MAX_BYTES(BUSY_MAX_BYTES)
    ) u_sd_card (
        .clk(clk), .rst_n(rst_n),
        .req_valid(c_sd_req_valid), .req_ready(c_sd_req_ready),
        .req_write(1'b0),
        .req_lba(c_sd_req_lba),
        .w_data(8'h00), .w_valid(1'b0), .w_ready(),
        .r_data(c_sd_r_data), .r_valid(c_sd_r_valid), .r_ready(c_sd_r_ready), .r_last(c_sd_r_last),
        .init_done(sd_init_done), .busy(), .done(c_sd_done),
        .error(c_sd_error), .error_code(sd_error_code),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );
endmodule

`default_nettype wire
