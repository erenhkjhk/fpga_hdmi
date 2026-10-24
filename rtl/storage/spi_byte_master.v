// Project copy adapted from docs/reference_rtl/fat32/spi_byte_master.v
`timescale 1ns/1ps
`default_nettype none
module spi_byte_master (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] half_div,
    input  wire        start,
    input  wire [7:0]  tx_data,
    output reg  [7:0]  rx_data,
    output reg         busy,
    output reg         done,
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso
);
    reg [15:0] div_latched;
    reg [15:0] div_count;
    reg [2:0]  bit_index;
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_latched <= 16'd1;
            div_count   <= 16'd0;
            bit_index   <= 3'd7;
            tx_shift    <= 8'hFF;
            rx_shift    <= 8'h00;
            rx_data     <= 8'h00;
            busy        <= 1'b0;
            done        <= 1'b0;
            spi_sck     <= 1'b0;
            spi_mosi    <= 1'b1;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                spi_sck  <= 1'b0;
                spi_mosi <= 1'b1;
                if (start) begin
                    div_latched <= (half_div == 0) ? 16'd1 : half_div;
                    div_count   <= 16'd0;
                    bit_index   <= 3'd7;
                    tx_shift    <= tx_data;
                    rx_shift    <= 8'h00;
                    spi_mosi    <= tx_data[7];
                    busy        <= 1'b1;
                end
            end else if (div_count == div_latched - 1'b1) begin
                div_count <= 16'd0;
                if (!spi_sck) begin
                    spi_sck <= 1'b1;
                    rx_shift <= {rx_shift[6:0], spi_miso};
                end else begin
                    spi_sck <= 1'b0;
                    if (bit_index == 0) begin
                        rx_data  <= rx_shift;
                        spi_mosi <= 1'b1;
                        busy     <= 1'b0;
                        done     <= 1'b1;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        tx_shift  <= {tx_shift[6:0], 1'b1};
                        spi_mosi  <= tx_shift[6];
                    end
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
