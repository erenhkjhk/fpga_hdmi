`timescale 1ns/1ps
`default_nettype none

// BMP24 BI_RGB, dimensions 1..4096, signed height and four-byte row padding.
// The scaler emits 640x480 pixels in file row order. Completion requires BOTH
// the complete file and the last scaled output handshake; EOF alone is not done.
module bmp24_decoder (
    input wire clk,
    input wire rst,
    input wire start,
    input wire cancel,
    input wire [31:0] file_size,
    input wire [7:0] file_data,
    input wire file_valid,
    output wire file_ready,
    input wire file_last,
    output wire begin_valid,
    input wire begin_ready,
    output wire bottom_up,
    output wire [31:0] pixel_data,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg done,
    output reg image_complete,
    output reg error,
    output reg [7:0] error_code
);
    localparam [3:0] IDLE=0, HEADER=1, CHECK=2, BEGIN_IMAGE=3,
                     SKIP=4, PIXELS=5, TRAILER=6, DROP=7, FINISH=8, PAD=9;
    reg [3:0] state;
    reg [31:0] position;
    reg [15:0] signature, planes, bit_count;
    reg [31:0] declared_size, pixel_offset, dib_size, width, height;
    reg [31:0] compression, bitmap_size;
    reg [1:0] component;
    reg [7:0] blue, green;
    reg [12:0] source_x, source_y;
    reg [1:0] pad_left;
    reg [23:0] source_data;
    reg source_valid;
    wire source_ready, scale_done;
    wire [31:0] abs_height = height[31] ? (~height + 32'd1) : height;
    wire [13:0] row_stride = (({1'b0, width[12:0]} * 14'd3) + 14'd3) & ~14'd3;
    wire [26:0] pixel_bytes = row_stride * {1'b0,abs_height[12:0]};
    wire [32:0] required_size = {1'b0, pixel_offset} + {6'b0, pixel_bytes};
    wire [32:0] bitmap_end = {1'b0, pixel_offset} + {1'b0, bitmap_size};
    wire [1:0] padding = width[1:0]; // (-3*width) mod 4 == width mod 4
    bilinear_scaler u_scaler (
        .clk(clk), .rst(rst), .start(begin_valid && begin_ready),
        .cancel(cancel || start || error), .width(width[12:0]), .height(abs_height[12:0]),
        .source_data(source_data), .source_valid(source_valid), .source_ready(source_ready),
        .pixel_data(pixel_data), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .done(scale_done)
    );
    reg saw_last;
    wire accept_byte = file_valid && file_ready;
    wire geometry_ok = (dib_size >= 40) && (width >= 1) && (width <= 4096)
                       && (abs_height >= 1) && (abs_height <= 4096)
                       && (planes == 1) && (bit_count == 24) && (compression == 0)
                       && ((bitmap_size == 0) || (bitmap_size >= {5'b0, pixel_bytes}));
    wire size_ok = ({1'b0,pixel_offset} >= (33'd14 + {1'b0,dib_size}))
                   && (required_size <= {1'b0,file_size})
                   && (required_size <= {1'b0,declared_size})
                   && (declared_size <= file_size)
                   && ((bitmap_size == 0)
                       || ((bitmap_end <= {1'b0,declared_size})
                           && (bitmap_end <= {1'b0,file_size})));
    assign bottom_up = !height[31];
    assign begin_valid = (state == BEGIN_IMAGE) && !error;
    assign file_ready = !rst && !cancel && !saw_last
                       && ((state == HEADER) || (state == SKIP) || (state == PAD)
                           || (state == TRAILER) || (state == DROP)
                           || ((state == PIXELS) && !source_valid));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            position <= 0;
            signature <= 0; planes <= 0; bit_count <= 0;
            declared_size <= 0; pixel_offset <= 0; dib_size <= 0;
            width <= 0; height <= 0; compression <= 0; bitmap_size <= 0;
            component <= 0; blue <= 0; green <= 0;
            source_x <= 0; source_y <= 0; pad_left <= 0;
            source_data <= 0; source_valid <= 0;
            done <= 0; image_complete <= 0; error <= 0; error_code <= 0;
            saw_last <= 0;
        end else if (start) begin
            state <= HEADER;
            position <= 0;
            signature <= 0; planes <= 0; bit_count <= 0;
            declared_size <= 0; pixel_offset <= 0; dib_size <= 0;
            width <= 0; height <= 0; compression <= 0; bitmap_size <= 0;
            component <= 0;
            source_x <= 0; source_y <= 0; pad_left <= 0;
            source_valid <= 0; source_data <= 0;
            done <= 0; image_complete <= 0; error <= 0; error_code <= 0;
            saw_last <= 0;
        end else if (cancel) begin
            state <= IDLE;
            source_valid <= 0;
            image_complete <= 0;
            done <= 1;
            error <= 1;
            error_code <= 8'h05;
        end else begin
            if (source_valid && source_ready) source_valid <= 0;
            if (scale_done && !error) image_complete <= 1;
            if (accept_byte) begin
                position <= position + 1'b1;
                if (file_last) saw_last <= 1'b1;
            end
            case (state)
                HEADER: if (accept_byte) begin
                    case (position)
                        0: signature[7:0] <= file_data;
                        1: signature[15:8] <= file_data;
                        2: declared_size[7:0] <= file_data;
                        3: declared_size[15:8] <= file_data;
                        4: declared_size[23:16] <= file_data;
                        5: declared_size[31:24] <= file_data;
                        10: pixel_offset[7:0] <= file_data;
                        11: pixel_offset[15:8] <= file_data;
                        12: pixel_offset[23:16] <= file_data;
                        13: pixel_offset[31:24] <= file_data;
                        14: dib_size[7:0] <= file_data;
                        15: dib_size[15:8] <= file_data;
                        16: dib_size[23:16] <= file_data;
                        17: dib_size[31:24] <= file_data;
                        18: width[7:0] <= file_data;
                        19: width[15:8] <= file_data;
                        20: width[23:16] <= file_data;
                        21: width[31:24] <= file_data;
                        22: height[7:0] <= file_data;
                        23: height[15:8] <= file_data;
                        24: height[23:16] <= file_data;
                        25: height[31:24] <= file_data;
                        26: planes[7:0] <= file_data;
                        27: planes[15:8] <= file_data;
                        28: bit_count[7:0] <= file_data;
                        29: bit_count[15:8] <= file_data;
                        30: compression[7:0] <= file_data;
                        31: compression[15:8] <= file_data;
                        32: compression[23:16] <= file_data;
                        33: compression[31:24] <= file_data;
                        34: bitmap_size[7:0] <= file_data;
                        35: bitmap_size[15:8] <= file_data;
                        36: bitmap_size[23:16] <= file_data;
                        37: bitmap_size[31:24] <= file_data;
                        default: begin end
                    endcase
                    if (position == 53) state <= CHECK;
                    if (file_last && (position < 53)) begin
                        error <= 1;
                        error_code <= 8'h04;
                        state <= FINISH;
                    end
                end
                CHECK: begin
                    if (signature != 16'h4D42) begin
                        error <= 1; error_code <= 8'h01;
                        state <= saw_last ? FINISH : DROP;
                    end else if (!geometry_ok) begin
                        error <= 1; error_code <= 8'h02;
                        state <= saw_last ? FINISH : DROP;
                    end else if (!size_ok) begin
                        error <= 1; error_code <= 8'h03;
                        state <= saw_last ? FINISH : DROP;
                    end else if (saw_last) begin
                        error <= 1; error_code <= 8'h04; state <= FINISH;
                    end else state <= BEGIN_IMAGE;
                end
                BEGIN_IMAGE: if (begin_valid && begin_ready)
                    state <= (position == pixel_offset) ? PIXELS : SKIP;
                SKIP: if (accept_byte) begin
                    if (position == pixel_offset - 1'b1) state <= PIXELS;
                    if (file_last) begin
                        error <= 1; error_code <= 8'h04; state <= FINISH;
                    end
                end
                PIXELS: if (accept_byte) begin
                    if (component == 0) begin blue <= file_data; component <= 1; end
                    else if (component == 1) begin green <= file_data; component <= 2; end
                    else begin
                        source_data <= {file_data, green, blue}; source_valid <= 1;
                        component <= 0;
                        if (source_x == width[12:0] - 1'b1) begin
                            source_x <= 0; source_y <= source_y + 1'b1;
                            pad_left <= padding;
                            if (padding != 0) state <= PAD;
                            else if (source_y == abs_height[12:0] - 1'b1) state <= TRAILER;
                        end else source_x <= source_x + 1'b1;
                    end
                    if (file_last) begin
                        if (!((component == 2) && (source_x == width[12:0] - 1'b1)
                              && (source_y == abs_height[12:0] - 1'b1) && (padding == 0))) begin
                            error <= 1; error_code <= 8'h04; source_valid <= 0;
                        end
                        state <= FINISH;
                    end
                end
                PAD: if (accept_byte) begin
                    pad_left <= pad_left - 1'b1;
                    if (pad_left == 1)
                        state <= (source_y == abs_height[12:0]) ? TRAILER : PIXELS;
                    if (file_last) begin
                        if (!((pad_left == 1) && (source_y == abs_height[12:0]))) begin
                            error <= 1; error_code <= 8'h04; source_valid <= 0;
                        end
                        state <= FINISH;
                    end
                end
                TRAILER, DROP: if (accept_byte && file_last) state <= FINISH;
                FINISH: begin
                    if (error) begin source_valid <= 0; done <= 1; state <= IDLE; end
                    else if (scale_done && !source_valid) begin
                        image_complete <= 1; done <= 1; state <= IDLE;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule

`default_nettype wire
