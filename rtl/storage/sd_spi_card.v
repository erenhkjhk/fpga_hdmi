// Project copy adapted from docs/reference_rtl/fat32/sd_spi_card.v
// Corrected the missing CMD58 condition closing parenthesis in the reference.
`timescale 1ns/1ps
`default_nettype none
module sd_spi_card #(
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
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_lba,
    input  wire [7:0]  w_data,
    input  wire        w_valid,
    output wire        w_ready,
    output reg  [7:0]  r_data,
    output wire        r_valid,
    input  wire        r_ready,
    output wire        r_last,
    output reg         init_done,
    output wire        busy,
    output reg         done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso
);
    localparam integer INIT_DIV = (CLK_HZ + 2*INIT_SPI_HZ - 1)
                                  / (2*INIT_SPI_HZ);
    localparam integer DATA_DIV = (CLK_HZ + 2*DATA_SPI_HZ - 1)
                                  / (2*DATA_SPI_HZ);
    localparam integer POWER_CYCLES = (CLK_HZ / 1000) * POWER_WAIT_MS;
    wire [15:0] half_div = init_done ? DATA_DIV[15:0] : INIT_DIV[15:0];
    localparam [31:0] POWER_LAST = POWER_CYCLES - 1;
    localparam [31:0] INIT_LAST = INIT_MAX_TRIES - 1;
    localparam [31:0] READY_LAST = READY_MAX_BYTES - 1;
    localparam [31:0] TOKEN_LAST = TOKEN_MAX_BYTES - 1;
    localparam [31:0] BUSY_LAST = BUSY_MAX_BYTES - 1;
    localparam [7:0]
        S_POWER=0, S_CLOCKS=1, S_CLOCKS_CHECK=2,
        S_CMD0=3, S_CMD0_REPLY=4, S_CMD8=5, S_CMD8_REPLY=6,
        S_CMD55=7, S_CMD55_REPLY=8, S_ACMD41=9, S_ACMD41_REPLY=10,
        S_CMD58=11, S_CMD58_REPLY=12, S_CMD59=13, S_CMD59_REPLY=14,
        S_INIT_FINISH=15,
        S_IDLE=16, S_OP_REPLY=17,
        S_READ_TOKEN=18, S_READ_TOKEN_CHECK=19,
        S_READ_DATA=20, S_READ_HAVE=21, S_READ_DELIVER=22,
        S_READ_CRC1=23, S_READ_CRC2=24, S_READ_FINISH=25,
        S_WRITE_TOKEN=26, S_WRITE_FETCH=27, S_WRITE_SENT=28,
        S_WRITE_CRC1=29, S_WRITE_CRC2=30,
        S_WRITE_RESP=31, S_WRITE_RESP_CHECK=32,
        S_WRITE_BUSY=33, S_WRITE_BUSY_CHECK=34,
        S_WRITE_STATUS=35, S_WRITE_STATUS_REPLY=36,
        S_OP_DONE=37, S_ERROR=38,
        S_BYTE_START=40, S_BYTE_WAIT=41,
        S_CMD_SELECT=42, S_CMD_READY=43, S_CMD_WAIT=44;
    reg [7:0]  state;
    reg [7:0]  after_byte;
    reg [7:0]  after_cmd;
    reg [31:0] power_count;
    reg [3:0]  clock_bytes;
    reg [31:0] init_tries;
    reg [31:0] poll_count;
    reg [8:0]  byte_index;
    reg        op_write;
    reg        main_start;
    reg [7:0]  main_tx;
    wire       cmd_byte_start;
    wire [7:0] cmd_byte_tx;
    wire [7:0] byte_rx;
    wire       byte_busy;
    wire       byte_done;
    wire       cmd_owns_bus = (state == S_CMD_WAIT);
    reg        cmd_start;
    reg [5:0]  cmd_index;
    reg [31:0] cmd_arg;
    reg [7:0]  cmd_crc;
    reg [2:0]  cmd_extra_len;
    wire       cmd_done;
    wire       cmd_timeout;
    wire [7:0] cmd_r1;
    wire [31:0] cmd_extra;
    assign req_ready = (state == S_IDLE) && init_done && !error;
    assign busy      = !req_ready;
    assign w_ready   = (state == S_WRITE_FETCH);
    assign r_valid   = (state == S_READ_DELIVER);
    assign r_last    = r_valid && (byte_index == 9'd511);
    spi_byte_master u_spi_byte (
        .clk(clk), .rst_n(rst_n), .half_div(half_div),
        .start(cmd_owns_bus ? cmd_byte_start : main_start),
        .tx_data(cmd_owns_bus ? cmd_byte_tx : main_tx),
        .rx_data(byte_rx), .busy(byte_busy), .done(byte_done),
        .spi_sck(sd_sck), .spi_mosi(sd_mosi), .spi_miso(sd_miso)
    );
    sd_spi_cmd u_sd_cmd (
        .clk(clk), .rst_n(rst_n), .start(cmd_start),
        .cmd_index(cmd_index), .cmd_arg(cmd_arg), .cmd_crc(cmd_crc),
        .extra_len(cmd_extra_len), .done(cmd_done), .timeout(cmd_timeout),
        .r1(cmd_r1), .extra(cmd_extra),
        .byte_start(cmd_byte_start), .byte_tx(cmd_byte_tx),
        .byte_rx(byte_rx), .byte_busy(byte_busy), .byte_done(byte_done)
    );
    task exchange_byte;
        input [7:0] value;
        input [7:0] next_state;
        begin
            main_tx    <= value;
            after_byte <= next_state;
            state      <= S_BYTE_START;
        end
    endtask
    task issue_command;
        input [5:0] index;
        input [31:0] argument;
        input [7:0] crc_byte;
        input [2:0] response_bytes;
        input [7:0] next_state;
        begin
            cmd_index     <= index;
            cmd_arg       <= argument;
            cmd_crc       <= crc_byte;
            cmd_extra_len <= response_bytes;
            after_cmd     <= next_state;
            poll_count    <= 32'd0;
            state         <= S_CMD_SELECT;
        end
    endtask
    task release_card;
        input [7:0] next_state;
        begin
            sd_cs_n <= 1'b1;
            exchange_byte(8'hFF, next_state);
        end
    endtask
    task fail;
        input [7:0] code;
        begin
            error      <= 1'b1;
            error_code <= code;
            init_done  <= 1'b0;
            release_card(S_ERROR);
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_POWER;
            after_byte    <= S_POWER;
            after_cmd     <= S_POWER;
            power_count   <= 32'd0;
            clock_bytes   <= 4'd0;
            init_tries    <= 32'd0;
            poll_count    <= 32'd0;
            byte_index    <= 9'd0;
            op_write      <= 1'b0;
            main_start    <= 1'b0;
            main_tx       <= 8'hFF;
            cmd_start     <= 1'b0;
            cmd_index     <= 6'd0;
            cmd_arg       <= 32'd0;
            cmd_crc       <= 8'h01;
            cmd_extra_len <= 3'd0;
            r_data        <= 8'd0;
            sd_cs_n       <= 1'b1;
            init_done     <= 1'b0;
            done          <= 1'b0;
            error         <= 1'b0;
            error_code    <= 8'h00;
        end else begin
            main_start <= 1'b0;
            cmd_start  <= 1'b0;
            done       <= 1'b0;
            case (state)
                S_POWER: begin
                    if (power_count == POWER_LAST)
                        state <= S_CLOCKS;
                    else
                        power_count <= power_count + 1'b1;
                end
                S_CLOCKS: exchange_byte(8'hFF, S_CLOCKS_CHECK);
                S_CLOCKS_CHECK: begin
                    if (clock_bytes == 4'd9)
                        state <= S_CMD0;
                    else begin
                        clock_bytes <= clock_bytes + 1'b1;
                        state <= S_CLOCKS;
                    end
                end
                S_CMD0: issue_command(6'd0, 32'd0, 8'h95, 3'd0, S_CMD0_REPLY);
                S_CMD0_REPLY: begin
                    if (cmd_r1 == 8'h01) release_card(S_CMD8);
                    else fail(8'h02);
                end
                S_CMD8: issue_command(6'd8, 32'h000001AA, 8'h87, 3'd4, S_CMD8_REPLY);
                S_CMD8_REPLY: begin
                    if ((cmd_r1 == 8'h01) && (cmd_extra[11:0] == 12'h1AA))
                        release_card(S_CMD55);
                    else fail(8'h03);
                end
                S_CMD55: issue_command(6'd55, 32'd0, 8'h01, 3'd0, S_CMD55_REPLY);
                S_CMD55_REPLY: begin
                    if ((cmd_r1 == 8'h01) || (cmd_r1 == 8'h00))
                        release_card(S_ACMD41);
                    else fail(8'h04);
                end
                S_ACMD41: issue_command(6'd41, 32'h40000000, 8'h01, 3'd0, S_ACMD41_REPLY);
                S_ACMD41_REPLY: begin
                    if (cmd_r1 == 8'h00) begin
                        release_card(S_CMD58);
                    end else if ((cmd_r1 == 8'h01) && (init_tries < INIT_LAST)) begin
                        init_tries <= init_tries + 1'b1;
                        release_card(S_CMD55);
                    end else fail(8'h05);
                end
                S_CMD58: issue_command(6'd58, 32'd0, 8'h01, 3'd4, S_CMD58_REPLY);
                S_CMD58_REPLY: begin
                    if ((cmd_r1 != 8'h00) || !cmd_extra[31])
                        fail(8'h06);
                    else if (!cmd_extra[30])
                        fail(8'h07);
                    else release_card(S_CMD59);
                end
                S_CMD59: issue_command(6'd59, 32'd0, 8'h01, 3'd0, S_CMD59_REPLY);
                S_CMD59_REPLY: begin
                    if (cmd_r1 == 8'h00) release_card(S_INIT_FINISH);
                    else fail(8'h08);
                end
                S_INIT_FINISH: begin
                    init_done <= 1'b1;
                    state <= S_IDLE;
                end
                S_IDLE: if (req_valid && req_ready) begin
                    op_write   <= req_write;
                    byte_index <= 9'd0;
                    issue_command(req_write ? 6'd24 : 6'd17,
                                  req_lba, 8'h01, 3'd0, S_OP_REPLY);
                end
                S_OP_REPLY: begin
                    poll_count <= 32'd0;
                    if (cmd_r1 != 8'h00) fail(8'h10);
                    else if (op_write)
                        exchange_byte(8'hFF, S_WRITE_TOKEN);
                    else state <= S_READ_TOKEN;
                end
                S_READ_TOKEN: exchange_byte(8'hFF, S_READ_TOKEN_CHECK);
                S_READ_TOKEN_CHECK: begin
                    if (byte_rx == 8'hFE) begin
                        state <= S_READ_DATA;
                    end else if (byte_rx != 8'hFF) begin
                        fail(8'h12);
                    end else if (poll_count == TOKEN_LAST) begin
                        fail(8'h11);
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        state <= S_READ_TOKEN;
                    end
                end
                S_READ_DATA: exchange_byte(8'hFF, S_READ_HAVE);
                S_READ_HAVE: begin
                    r_data <= byte_rx;
                    state <= S_READ_DELIVER;
                end
                S_READ_DELIVER: if (r_ready) begin
                    if (byte_index == 9'd511)
                        state <= S_READ_CRC1;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= S_READ_DATA;
                    end
                end
                S_READ_CRC1: exchange_byte(8'hFF, S_READ_CRC2);
                S_READ_CRC2: exchange_byte(8'hFF, S_READ_FINISH);
                S_READ_FINISH: release_card(S_OP_DONE);
                S_WRITE_TOKEN: exchange_byte(8'hFE, S_WRITE_FETCH);
                S_WRITE_FETCH: if (w_valid) begin
                    exchange_byte(w_data, S_WRITE_SENT);
                end
                S_WRITE_SENT: begin
                    if (byte_index == 9'd511)
                        state <= S_WRITE_CRC1;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= S_WRITE_FETCH;
                    end
                end
                S_WRITE_CRC1: exchange_byte(8'hFF, S_WRITE_CRC2);
                S_WRITE_CRC2: begin
                    poll_count <= 32'd0;
                    exchange_byte(8'hFF, S_WRITE_RESP);
                end
                S_WRITE_RESP: exchange_byte(8'hFF, S_WRITE_RESP_CHECK);
                S_WRITE_RESP_CHECK: begin
                    if (byte_rx == 8'hFF) begin
                        if (poll_count == TOKEN_LAST)
                            fail(8'h13);
                        else begin
                            poll_count <= poll_count + 1'b1;
                            state <= S_WRITE_RESP;
                        end
                    end else if (byte_rx[4:0] == 5'b00101) begin
                        poll_count <= 32'd0;
                        state <= S_WRITE_BUSY;
                    end else fail(8'h14);
                end
                S_WRITE_BUSY: exchange_byte(8'hFF, S_WRITE_BUSY_CHECK);
                S_WRITE_BUSY_CHECK: begin
                    if (byte_rx == 8'hFF) begin
                        release_card(S_WRITE_STATUS);
                    end else if (poll_count == BUSY_LAST) begin
                        fail(8'h15);
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        state <= S_WRITE_BUSY;
                    end
                end
                S_WRITE_STATUS: issue_command(6'd13, 32'd0, 8'h01, 3'd1, S_WRITE_STATUS_REPLY);
                S_WRITE_STATUS_REPLY: begin
                    if ((cmd_r1 == 8'h00) && (cmd_extra[7:0] == 8'h00))
                        release_card(S_OP_DONE);
                    else fail(8'h16);
                end
                S_OP_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                S_ERROR: state <= S_ERROR;
                S_BYTE_START: if (!byte_busy) begin
                    main_start <= 1'b1;
                    state <= S_BYTE_WAIT;
                end
                S_BYTE_WAIT: if (byte_done) state <= after_byte;
                S_CMD_SELECT: begin
                    sd_cs_n <= 1'b0;
                    exchange_byte(8'hFF, S_CMD_READY);
                end
                S_CMD_READY: begin
                    if (byte_rx == 8'hFF) begin
                        cmd_start <= 1'b1;
                        state <= S_CMD_WAIT;
                    end else if (poll_count == READY_LAST) begin
                        fail(8'h17);
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        exchange_byte(8'hFF, S_CMD_READY);
                    end
                end
                S_CMD_WAIT: if (cmd_done) begin
                    if (cmd_timeout) fail(8'h01);
                    else state <= after_cmd;
                end
                default: fail(8'hFF);
            endcase
        end
    end
endmodule

`default_nettype wire
