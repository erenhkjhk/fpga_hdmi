`timescale 1ns/1ps
`default_nettype none

// Assert asynchronously; release after four edges of the destination clock.
module reset_sync (
    input  wire clk,
    input  wire async_reset,
    output wire reset
);
    (* ASYNC_REG = "TRUE" *) reg [3:0] stages;
    always @(posedge clk or posedge async_reset) begin
        if (async_reset) stages <= 4'b1111;
        else stages <= {stages[2:0], 1'b0};
    end
    assign reset = stages[3];
endmodule

`default_nettype wire
