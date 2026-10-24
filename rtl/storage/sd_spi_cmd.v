// Project copy adapted from docs/reference_rtl/fat32/sd_spi_cmd.v
// Corrected the incomplete poll_count increment in the supplied reference.
`timescale 1ns/1ps
`default_nettype none
module sd_spi_cmd #(
    parameter integer R1_MAX_BYTES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [5:0]  cmd_index,
    input  wire [31:0] cmd_arg,
    input  wire [7:0]  cmd_crc,
    input  wire [2:0]  extra_len,
    output reg         done,
    output reg         timeout,
    output reg  [7:0]  r1,
    output reg  [31:0] extra,
    output reg         byte_start,
    output reg  [7:0]  byte_tx,
    input  wire [7:0]  byte_rx,
    input  wire        byte_busy,
    input  wire        byte_done
);
    localparam [31:0] R1_LAST = R1_MAX_BYTES - 1;
    localparam [2:0] IDLE=0, SEND=1, SEND_WAIT=2,
                     R1_SEND=3, R1_WAIT=4, EXTRA_SEND=5, EXTRA_WAIT=6;
    reg [2:0]  state;
    reg [47:0] packet;
    reg [2:0]  sent_count;
    reg [2:0]  extra_left;
    reg [31:0] poll_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            packet      <= 48'd0;
            sent_count  <= 3'd0;
            extra_left  <= 3'd0;
            poll_count  <= 32'd0;
            byte_start  <= 1'b0;
            byte_tx     <= 8'hFF;
            done        <= 1'b0;
            timeout     <= 1'b0;
            r1          <= 8'hFF;
            extra       <= 32'd0;
        end else begin
            byte_start <= 1'b0;
            done       <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    packet     <= {2'b01, cmd_index, cmd_arg, cmd_crc};
                    sent_count <= 3'd0;
                    extra_left <= extra_len;
                    poll_count <= 32'd0;
                    r1         <= 8'hFF;
                    extra      <= 32'd0;
                    timeout    <= 1'b0;
                    state      <= SEND;
                end
                SEND: if (!byte_busy) begin
                    byte_tx    <= packet[47:40];
                    byte_start <= 1'b1;
                    state      <= SEND_WAIT;
                end
                SEND_WAIT: if (byte_done) begin
                    packet <= {packet[39:0], 8'hFF};
                    if (sent_count == 3'd5)
                        state <= R1_SEND;
                    else begin
                        sent_count <= sent_count + 1'b1;
                        state <= SEND;
                    end
                end
                R1_SEND: if (!byte_busy) begin
                    byte_tx    <= 8'hFF;
                    byte_start <= 1'b1;
                    state      <= R1_WAIT;
                end
                R1_WAIT: if (byte_done) begin
                    if (!byte_rx[7]) begin
                        r1 <= byte_rx;
                        if ((extra_left == 0) || (byte_rx[6:1] != 0)) begin
                            done  <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= EXTRA_SEND;
                        end
                    end else if (poll_count == R1_LAST) begin
                        timeout <= 1'b1;
                        done    <= 1'b1;
                        state   <= IDLE;
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        state <= R1_SEND;
                    end
                end
                EXTRA_SEND: if (!byte_busy) begin
                    byte_tx    <= 8'hFF;
                    byte_start <= 1'b1;
                    state      <= EXTRA_WAIT;
                end
                EXTRA_WAIT: if (byte_done) begin
                    extra <= {extra[23:0], byte_rx};
                    if (extra_left == 1) begin
                        done  <= 1'b1;
                        state <= IDLE;
                    end else begin
                        extra_left <= extra_left - 1'b1;
                        state <= EXTRA_SEND;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
