`timescale 1ns/1ps
`default_nettype none

// 800x525 total, 640x480 active. Actual 25 MHz pixel clock gives 59.52381 Hz.
// Never stall an active line: the vendor HDMI core requires continuous data.
// The one-cycle normal FIFO response and its metadata are registered together.
module video_stream_640x480 (
    input wire clk,
    input wire rst,
    output reg frame_req_valid,
    input wire frame_req_ready,
    input wire frame_info_valid,
    output wire frame_info_ready,
    input wire frame_has_image,
    input wire [31:0] fifo_data,
    input wire fifo_valid,
    input wire fifo_empty,
    input wire [9:0] fifo_used,
    input wire fifo_ready,
    output wire fifo_re,
    input wire axis_ready,
    input wire video_locked,
    output reg axis_user,
    output reg axis_valid,
    output reg axis_last,
    output reg [23:0] axis_data,
    output reg displaying_image,
    output reg underflow,
    output reg protocol_error
);
    reg [9:0] x, y;
    reg next_has_image;
    reg active_d, first_d, last_d, image_d, requested_d;
    wire active = (x < 640) && (y < 480);
    assign fifo_re = !rst && active && displaying_image && fifo_ready && !fifo_empty;
    assign frame_info_ready = !rst;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 0; y <= 480; // Start with a complete vertical blank for prefetch.
            frame_req_valid <= 0; next_has_image <= 0;
            active_d <= 0; first_d <= 0; last_d <= 0;
            image_d <= 0; requested_d <= 0;
            axis_user <= 0; axis_valid <= 0; axis_last <= 0; axis_data <= 0;
            displaying_image <= 0; underflow <= 0; protocol_error <= 0;
        end else begin
            if (frame_req_valid && frame_req_ready) frame_req_valid <= 0;
            if ((x == 0) && (y == 480)) begin
                frame_req_valid <= 1;
                next_has_image <= 0;
            end
            if (frame_info_valid && frame_info_ready) next_has_image <= frame_has_image;
            if (x == 799) begin
                x <= 0;
                if (y == 524) begin
                    y <= 0;
                    displaying_image <= next_has_image && fifo_ready && (fifo_used >= 640);
                    if (next_has_image && (!fifo_ready || (fifo_used < 640))) underflow <= 1;
                end else y <= y + 1'b1;
            end else x <= x + 1'b1;

            active_d <= active;
            first_d <= active && (x == 0) && (y == 0);
            last_d <= active && (x == 639);
            image_d <= displaying_image;
            requested_d <= fifo_re;
            axis_valid <= active_d;
            axis_user <= first_d;
            axis_last <= last_d;
            if (active_d && image_d && requested_d && fifo_valid) axis_data <= fifo_data[23:0];
            else axis_data <= 24'h000000;

            if ((active && displaying_image && (!fifo_ready || fifo_empty))
                || (active_d && image_d && requested_d && !fifo_valid)) begin
                underflow <= 1;
                // Recover alignment through the coordinated FIFO flush next blank.
                displaying_image <= 0;
            end
            if (video_locked && axis_valid && !axis_last && !axis_ready) protocol_error <= 1;
        end
    end
endmodule

`default_nettype wire
