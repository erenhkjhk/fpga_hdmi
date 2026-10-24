`timescale 1ns/1ps
`default_nettype none

// Fs = F_TMDS * N / (128 * CTS).
// Actual 25 MHz pixel/TMDS clock, N=6144, CTS=25000 -> exactly 48000 Hz nominal.
// Send an ACR update every 48 stereo samples (approximately one millisecond).
module hdmi_acr_48k (
    input wire clk,
    input wire rst,
    input wire audio_valid,
    output reg acr_valid,
    output wire [19:0] acr_cts,
    output wire [19:0] acr_n
);
    reg [5:0] samples;
    assign acr_cts = 20'd25000;
    assign acr_n = 20'd6144;
    always @(posedge clk or posedge rst) begin
        if (rst) begin samples <= 0; acr_valid <= 0; end
        else begin
            acr_valid <= 0;
            if (audio_valid) begin
                if (samples == 47) begin samples <= 0; acr_valid <= 1; end
                else samples <= samples + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
