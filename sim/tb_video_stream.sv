`timescale 1ns/1ps
module tb_video_stream;
    reg clk=0;always #20 clk=~clk;
    reg rst=1;
    wire frame_req_valid,frame_info_ready,fifo_re,frame_tick,axis_user,axis_valid,axis_last,axis_image,displaying_image,underflow;
    wire [9:0] axis_x;
    wire [8:0] axis_y;
    wire [23:0] axis_data;
    wire frame_req_ready=1,frame_has_image=1,fifo_ready=1;
    reg frame_info_valid=0,fifo_valid=0,fifo_empty=0;
    reg [31:0] fifo_data=0;
    wire [9:0] fifo_used=900;
    video_stream_640x480 dut(.*);
    // FIFO boundary stimulus: one-clock normal read response. The real FIFO
    // latency/order/reset are checked independently by tb_fifo_cdc.
    integer source_index=0,info_delay=0,requests=0;
    always @(posedge clk) begin
        if(rst) begin fifo_valid<=0;frame_info_valid<=0;source_index=0;info_delay=0;end
        else begin
            frame_info_valid<=0;fifo_valid<=fifo_re;
            if(frame_req_valid && frame_req_ready) begin source_index=0;info_delay=12;requests=requests+1;end
            if(info_delay>0) begin
                info_delay=info_delay-1;if(info_delay==0) frame_info_valid<=1;
            end
            if(fifo_re) begin fifo_data<=source_index;source_index=source_index+1;end
        end
    end
    integer cycles=0,frame=-1,pixels=0,total=0,last_start=0;
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;#1;
        if(axis_valid) begin
            if(axis_user) begin
                if(frame>=0 && (pixels!=307200 || cycles-last_start!=420000)) $fatal(1,"video frame shape/period");
                frame=frame+1;pixels=0;last_start=cycles;
            end
            if(axis_x!==pixels%640 || axis_y!==pixels/640 || axis_user!==(pixels==0) || axis_last!==(pixels%640==639))
                $fatal(1,"video RGB/coordinate/marker mismatch frame=%0d pixel=%0d x=%0d y=%0d",frame,pixels,axis_x,axis_y);
            if(axis_image) begin
                if(axis_data!==pixels) $fatal(1,"video FIFO/data latency %0d got %h",pixels,axis_data);
            end else if(axis_data!==0) $fatal(1,"video invalid image not black");
            if((frame==0 || frame==2) && !axis_image) $fatal(1,"unexpected blank image at frame %0d pixel %0d",frame,pixels);
            pixels=pixels+1;total=total+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(frame==1 && pixels==32050);@(negedge clk);fifo_empty=1;
        repeat(3) @(negedge clk);fifo_empty=0;
        wait(frame==2 && pixels==307200);@(negedge clk);
        if(!underflow || requests<3) $fatal(1,"video underflow/recovery coverage missing");
        $display("PASS tb_video_stream: %0d fixed-rate pixels, coordinates/markers, 800x525 period, underflow and next-frame recovery",total);
        $finish;
    end
    initial begin #60000000;$fatal(1,"tb_video_stream timeout");end
endmodule
