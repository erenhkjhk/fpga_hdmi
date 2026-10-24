`timescale 1ns/1ps
`default_nettype none

// Internal I2S source: stereo, 24 significant bits in each 32-bit slot, 64fs.
// All state uses clk; BCLK is a data signal, never an internal register clock.
// Rational edge accumulator preserves average 48 kHz with the actual 25 MHz
// clock: edges occur every 4/5 cycles, samples every 520/521 cycles.
module i2s_test_tone #(
    parameter integer CLK_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter [31:0] TONE_PHASE_INC = 32'd89478485, // 1 kHz at 48 kHz
    parameter signed [23:0] AMPLITUDE = 24'sd1048576
) (
    input wire clk,
    input wire rst,
    output reg bclk,
    output reg lrck,
    output reg serial_data
);
    localparam [32:0] EDGE_HZ = SAMPLE_HZ * 128;
    localparam [32:0] CLOCK_RATE = CLK_HZ;
    reg [31:0] edge_phase, tone_phase;
    reg [5:0] slot_bit;
    reg signed [23:0] sample_word;
    wire [32:0] phase_sum = {1'b0, edge_phase} + EDGE_HZ;
    wire [32:0] phase_remainder = phase_sum - CLOCK_RATE;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            edge_phase <= 0; tone_phase <= 0; slot_bit <= 0;
            sample_word <= AMPLITUDE;
            bclk <= 1; lrck <= 1; serial_data <= 0;
        end else begin
            if (phase_sum >= CLOCK_RATE) begin
                edge_phase <= phase_remainder[31:0];
                bclk <= ~bclk;
                if (bclk) begin // Falling BCLK: change LRCK/data before sampling edge.
                    if (slot_bit == 0) begin
                        lrck <= 0;
                        serial_data <= 0; // I2S one-bit delay before left MSB.
                        tone_phase <= tone_phase + TONE_PHASE_INC;
                        sample_word <= tone_phase[31] ? -AMPLITUDE : AMPLITUDE;
                    end else if (slot_bit == 32) begin
                        lrck <= 1;
                        serial_data <= 0; // I2S one-bit delay before right MSB.
                    end else if ((slot_bit >= 1) && (slot_bit <= 24))
                        serial_data <= sample_word[24 - slot_bit];
                    else if ((slot_bit >= 33) && (slot_bit <= 56))
                        serial_data <= sample_word[56 - slot_bit];
                    else serial_data <= 0;
                    slot_bit <= slot_bit + 1'b1;
                end
            end else edge_phase <= phase_sum[31:0];
        end
    end
endmodule

`default_nettype wire
