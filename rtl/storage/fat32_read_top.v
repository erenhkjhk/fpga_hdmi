// Project copy adapted from docs/reference_rtl/fat32/fat32_read_top.v
`timescale 1ns/1ps
`default_nettype none
module fat32_read_top #(
    parameter integer CLK_HZ          = 50000000,
    parameter integer INIT_SPI_HZ     = 250000,
    parameter integer DATA_SPI_HZ     = 5000000,
    parameter integer POWER_WAIT_MS   = 20,
    parameter integer INIT_MAX_TRIES  = 4096,
    parameter integer READY_MAX_BYTES = 32768,
    parameter integer TOKEN_MAX_BYTES = 262144,
    parameter integer BUSY_MAX_BYTES  = 1048576
) (
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
    sd_spi_card #(
        .CLK_HZ(CLK_HZ), .INIT_SPI_HZ(INIT_SPI_HZ), .DATA_SPI_HZ(DATA_SPI_HZ),
        .POWER_WAIT_MS(POWER_WAIT_MS), .INIT_MAX_TRIES(INIT_MAX_TRIES),
        .READY_MAX_BYTES(READY_MAX_BYTES), .TOKEN_MAX_BYTES(TOKEN_MAX_BYTES),
        .BUSY_MAX_BYTES(BUSY_MAX_BYTES)
    ) u_sd_card (
        .clk(clk), .rst_n(rst_n),
        .req_valid(sd_req_valid), .req_ready(sd_req_ready),
        .req_write(1'b0),
        .req_lba(sd_req_lba),
        .w_data(8'h00), .w_valid(1'b0), .w_ready(),
        .r_data(sd_r_data), .r_valid(sd_r_valid), .r_ready(sd_r_ready), .r_last(sd_r_last),
        .init_done(sd_init_done), .busy(), .done(sd_done),
        .error(sd_error), .error_code(sd_error_code),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );
endmodule

`default_nettype wire
