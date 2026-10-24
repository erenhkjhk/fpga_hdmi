`timescale 1ns/1ps
`default_nettype none

// For independent status bits only. Multi-bit commands use cdc_mailbox.
module cdc_level #(parameter integer WIDTH = 1) (
    input  wire clk,
    input  wire rst,
    input  wire [WIDTH-1:0] async_data,
    output wire [WIDTH-1:0] sync_data
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] meta, synced;
    always @(posedge clk or posedge rst) begin
        if (rst) begin meta <= {WIDTH{1'b0}}; synced <= {WIDTH{1'b0}}; end
        else begin meta <= async_data; synced <= meta; end
    end
    assign sync_data = synced;
endmodule

`default_nettype wire
