`timescale 1ns/1ps
`default_nettype none

// For the internal, same-clk I2S source above. LRCK changes one BCLK before MSB.
// External asynchronous I2S is outside this project's basic requirements.
module i2s_stereo_receiver (
    input wire clk,
    input wire rst,
    input wire bclk,
    input wire lrck,
    input wire serial_data,
    output reg audio_valid,
    output reg [23:0] audio_left,
    output reg [23:0] audio_right
);
    reg bclk_d, channel_d;
    reg [5:0] bit_count;
    reg [23:0] shift_word, left_word;
    reg have_left;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bclk_d <= 1; channel_d <= 1; bit_count <= 0;
            shift_word <= 0; left_word <= 0; have_left <= 0;
            audio_valid <= 0; audio_left <= 0; audio_right <= 0;
        end else begin
            bclk_d <= bclk;
            audio_valid <= 0;
            if (bclk && !bclk_d) begin
                channel_d <= lrck;
                if (lrck != channel_d) begin
                    bit_count <= 0;
                    shift_word <= 0;
                end else begin
                    if (bit_count < 24) begin
                        shift_word <= {shift_word[22:0], serial_data};
                        if (bit_count == 23) begin
                            if (!lrck) begin
                                left_word <= {shift_word[22:0], serial_data};
                                have_left <= 1;
                            end else if (have_left) begin
                                audio_left <= left_word;
                                audio_right <= {shift_word[22:0], serial_data};
                                audio_valid <= 1;
                                have_left <= 0;
                            end
                        end
                    end
                    if (bit_count != 63) bit_count <= bit_count + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
