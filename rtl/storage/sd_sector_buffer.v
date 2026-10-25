// Project copy adapted from docs/reference_rtl/fat32/sd_sector_buffer.v
`timescale 1ns/1ps
`default_nettype none
module sd_sector_buffer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_valid,
    output wire        load_ready,
    input  wire [31:0] load_lba,
    output reg         load_done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         buf_valid,
    input  wire        rd_en,
    input  wire [8:0]  rd_addr,
    output reg  [7:0]  rd_data,
    output reg         rd_valid,
    output wire        sd_req_valid,
    input  wire        sd_req_ready,
    output reg  [31:0] sd_req_lba,
    input  wire [7:0]  sd_r_data,
    input  wire        sd_r_valid,
    output wire        sd_r_ready,
    input  wire        sd_r_last,
    input  wire        sd_done,
    input  wire        sd_error
);
    localparam [1:0] S_IDLE=0, S_REQUEST=1, S_RECEIVE=2, S_ERROR=3;
    reg [1:0] state;
    reg [9:0] receive_count;
    // Two read-only sector cache ways. Retain a frequently reused FAT sector
    // while streaming data sectors; rereading FAT for every one-sector cluster
    // otherwise consumes almost half of the 5 MHz SPI bandwidth.
    // This extends the existing inferred sector RAM by 512 bytes per context.
    reg [7:0] memory [0:1023];
    reg [31:0] tag [0:1];
    reg [1:0] cache_valid;
    reg active_way,fill_way;
    wire hit0=cache_valid[0] && tag[0]==load_lba;
    wire hit1=cache_valid[1] && tag[1]==load_lba;
    wire replacement_way=!cache_valid[0] ? 1'b0 :
                         (!cache_valid[1] ? 1'b1 : !active_way);
    wire receive_byte = sd_r_valid && sd_r_ready;
    wire read_enable = rd_en && buf_valid && (state == S_IDLE)
                       && !load_valid && !sd_error && !error;
    assign load_ready   = (state == S_IDLE) && !error && !sd_error;
    assign sd_req_valid = (state == S_REQUEST) && !sd_error;
    assign sd_r_ready   = (state == S_RECEIVE) && (receive_count < 10'd512)
                          && !sd_error;
    always @(posedge clk) begin
        if (receive_byte)
            memory[{fill_way,receive_count[8:0]}] <= sd_r_data;
        if (read_enable)
            rd_data <= memory[{active_way,rd_addr}];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            receive_count <= 10'd0;
            sd_req_lba    <= 32'd0;
            load_done     <= 1'b0;
            error         <= 1'b0;
            error_code    <= 8'h00;
            buf_valid     <= 1'b0;
            rd_valid      <= 1'b0;
            cache_valid   <= 0;
            active_way    <= 0;
            fill_way      <= 0;
            tag[0]        <= 0;
            tag[1]        <= 0;
        end else begin
            load_done <= 1'b0;
            rd_valid  <= read_enable;
            if (sd_error) begin
                error      <= 1'b1;
                error_code <= 8'h01;
                buf_valid  <= 1'b0;
                rd_valid   <= 1'b0;
                cache_valid <= 0;
                state      <= S_ERROR;
            end else begin
                case (state)
                    S_IDLE: if (load_valid && load_ready) begin
                        if(hit0 || hit1) begin
                            active_way <= hit1;
                            buf_valid <= 1'b1;
                            load_done <= 1'b1;
                        end else begin
                            sd_req_lba    <= load_lba;
                            receive_count <= 10'd0;
                            buf_valid     <= 1'b0;
                            fill_way <= replacement_way;
                            cache_valid[replacement_way] <= 1'b0;
                            state         <= S_REQUEST;
                        end
                    end
                    S_REQUEST: if (sd_req_ready) state <= S_RECEIVE;
                    S_RECEIVE: begin
                        if (receive_byte) begin
                            receive_count <= receive_count + 1'b1;
                            if (sd_r_last != (receive_count == 10'd511)) begin
                                error      <= 1'b1;
                                error_code <= 8'h02;
                                state      <= S_ERROR;
                            end
                        end
                        if (sd_done) begin
                            if (receive_count == 10'd512) begin
                                buf_valid <= 1'b1;
                                load_done <= 1'b1;
                                active_way <= fill_way;
                                tag[fill_way] <= sd_req_lba;
                                cache_valid[fill_way] <= 1'b1;
                                state     <= S_IDLE;
                            end else begin
                                error      <= 1'b1;
                                error_code <= 8'h02;
                                state      <= S_ERROR;
                            end
                        end
                    end
                    S_ERROR: state <= S_ERROR;
                    default: begin
                        error      <= 1'b1;
                        error_code <= 8'h02;
                        buf_valid  <= 1'b0;
                        state      <= S_ERROR;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
