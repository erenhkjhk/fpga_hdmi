// SPI Mode 0：SCK 空闲为低，上升沿采样，下降沿更新 MOSI，MSB 先行。
// 所有寄存器都由 clk 驱动；spi_sck 只是输出信号，不作为内部时钟。
module spi_byte_master (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] half_div, // 每半个 SCK 周期包含的 clk 周期数，至少为 1
    input  wire        start,    // busy=0 时给一个 clk 周期脉冲
    input  wire [7:0]  tx_data,
    output reg  [7:0]  rx_data,  //在某次发送done的同一个周期，就会对rx_data进行赋值，直到下一次done才会更新rx_data
    output reg         busy,
    output reg         done,     // 完成一个字节后，脉冲一个 clk 周期
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
                    spi_mosi    <= tx_data[7]; // 第一位在第一个上升沿前建立
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
                        // 最后一位已在上一个上升沿进入 rx_shift。
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
