`timescale 1ns/1ps
`default_nettype none

// One outstanding message. Payload is held from request until acknowledgement.
// Both ends must share the same reset event, with local synchronous release.
module cdc_mailbox #(parameter integer WIDTH = 1) (
    input  wire src_clk,
    input  wire src_rst,
    input  wire [WIDTH-1:0] src_data,
    input  wire src_valid,
    output wire src_ready,
    output reg  src_done,
    input  wire dst_clk,
    input  wire dst_rst,
    output reg  [WIDTH-1:0] dst_data,
    output reg  dst_valid,
    input  wire dst_ready
);
    reg [WIDTH-1:0] held_data;
    reg request_toggle, acknowledge_toggle, occupied;
    (* ASYNC_REG = "TRUE" *) reg ack_meta, ack_sync;
    (* ASYNC_REG = "TRUE" *) reg req_meta, req_sync;
    assign src_ready = !src_rst && !occupied;
    always @(posedge src_clk or posedge src_rst) begin
        if (src_rst) begin
            held_data <= {WIDTH{1'b0}};
            request_toggle <= 1'b0;
            occupied <= 1'b0;
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
            src_done <= 1'b0;
        end else begin
            ack_meta <= acknowledge_toggle;
            ack_sync <= ack_meta;
            src_done <= 1'b0;
            if (src_valid && src_ready) begin
                held_data <= src_data;
                request_toggle <= ~request_toggle;
                occupied <= 1'b1;
            end else if (occupied && (ack_sync == request_toggle)) begin
                occupied <= 1'b0;
                src_done <= 1'b1;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            acknowledge_toggle <= 1'b0;
            dst_data <= {WIDTH{1'b0}};
            dst_valid <= 1'b0;
        end else begin
            req_meta <= request_toggle;
            req_sync <= req_meta;
            if (!dst_valid && (req_sync != acknowledge_toggle)) begin
                dst_data <= held_data;
                dst_valid <= 1'b1;
            end else if (dst_valid && dst_ready) begin
                acknowledge_toggle <= req_sync;
                dst_valid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
