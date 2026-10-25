`timescale 1ns/1ps
`default_nettype none

// BI_RGB BGR24, 1..2048 in each dimension, padded rows, either orientation.
// Endpoint-aligned bilinear resampling produces exactly 640x480 pixels.
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
                     SKIP=4, PIXELS=5, TRAILER=6, DROP=7, FINISH=8;
    localparam [18:0] PIXEL_COUNT = 19'd307200;
    reg [3:0] state;
    reg [31:0] position;
    reg [15:0] signature, planes, bit_count;
    reg [31:0] declared_size, pixel_offset, dib_size, width, height;
    reg [31:0] compression, bitmap_size;
    reg [1:0] component;
    reg [7:0] blue, green;
    reg [22:0] assembled_pixels;
    reg [18:0] sent_pixels;
    reg [12:0] row_byte;
    reg [23:0] raw_data;
    reg raw_valid;
    wire raw_ready, scale_complete;
    wire [23:0] scaled_data;
    wire [31:0] abs_height = height[31] ? (~height+32'd1) : height;
    wire [31:0] source_pixels=width*abs_height;
    wire [31:0] row_stride=(width*32'd3+32'd3)&32'hFFFFFFFC;
    wire [63:0] source_bytes={32'd0,row_stride}*abs_height;
    bilinear_scaler u_scale (.clk(clk),.rst(rst || cancel || start || error),
      .start(begin_valid && begin_ready),.width(width[11:0]),.height(abs_height[11:0]),
      .in_data(raw_data),.in_valid(raw_valid),.in_ready(raw_ready),
      .out_data(scaled_data),.out_valid(pixel_valid),.out_ready(pixel_ready),.complete(scale_complete));
    assign pixel_data={8'd0,scaled_data};
    reg saw_last;
    wire accept_byte = file_valid && file_ready;
    wire [63:0] required_size = {32'd0,pixel_offset}+source_bytes;
    wire geometry_ok = dib_size>=40 && width>=1 && width<=2048
        && abs_height>=1 && abs_height<=2048 && planes==1 && bit_count==24
        && compression==0 && (bitmap_size==0 || bitmap_size>=source_bytes);
    wire size_ok = {32'd0,pixel_offset} >= 64'd14+dib_size
        && required_size<=file_size && required_size<=declared_size && declared_size<=file_size;
    assign bottom_up = !height[31];
    assign begin_valid = (state == BEGIN_IMAGE) && !error;
    assign file_ready = !rst && ((state == HEADER) || (state == SKIP)
                         || (state == TRAILER) || (state == DROP)
                         || ((state == PIXELS) && !raw_valid));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            position <= 0;
            signature <= 0; planes <= 0; bit_count <= 0;
            declared_size <= 0; pixel_offset <= 0; dib_size <= 0;
            width <= 0; height <= 0; compression <= 0; bitmap_size <= 0;
            component <= 0; blue <= 0; green <= 0;
            assembled_pixels <= 0; sent_pixels <= 0;
            raw_data <= 0; raw_valid <= 0; row_byte<=0;
            done <= 0; image_complete <= 0; error <= 0; error_code <= 0;
            saw_last <= 0;
        end else if (start) begin
            state <= HEADER;
            position <= 0;
            signature <= 0; planes <= 0; bit_count <= 0;
            declared_size <= 0; pixel_offset <= 0; dib_size <= 0;
            width <= 0; height <= 0; compression <= 0; bitmap_size <= 0;
            component <= 0;
            assembled_pixels <= 0; sent_pixels <= 0;
            raw_valid <= 0; raw_data <= 0; row_byte<=0;
            done <= 0; image_complete <= 0; error <= 0; error_code <= 0;
            saw_last <= 0;
        end else if (cancel) begin
            state <= IDLE;
            raw_valid <= 0;
            done <= 1;
            error <= 1;
            error_code <= 8'h05;
        end else begin
            if (pixel_valid && pixel_ready) begin
                sent_pixels <= sent_pixels + 1'b1;
                if (sent_pixels == PIXEL_COUNT - 1'b1) image_complete <= 1'b1;
            end
            if(raw_valid && raw_ready) raw_valid<=0;
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
                    if(row_byte < width*3) begin
                        if(component==0) begin blue<=file_data;component<=1;end
                        else if(component==1) begin green<=file_data;component<=2;end
                        else begin
                            raw_data<={file_data,green,blue};raw_valid<=1;component<=0;
                            assembled_pixels<=assembled_pixels+1'b1;
                        end
                    end
                    if(row_byte==row_stride-1'b1) begin
                        row_byte<=0;
                        if(position+1'b1==required_size) state<=TRAILER;
                    end else row_byte<=row_byte+1'b1;
                    if(file_last) begin
                        if(position+1'b1!=required_size) begin error<=1;error_code<=8'h04;end
                        state<=FINISH;
                    end
                end
                TRAILER, DROP: if (accept_byte && file_last) state <= FINISH;
                FINISH: if (error || scale_complete) begin
                    done <= 1;
                    if (!image_complete && !error) begin error <= 1; error_code <= 8'h04; end
                    state <= IDLE;
                end
                default: begin end
            endcase
        end
    end
endmodule

`default_nettype wire
