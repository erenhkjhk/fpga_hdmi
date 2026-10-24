`timescale 1ns/1ps
module tb_display_control;
    reg clk=0,pixel_clk=0;always #10 clk=~clk;always #20 pixel_clk=~pixel_clk;
    reg rst=1,pixel_rst=1,tick_ms=0,frame_tick=0;
    reg [3:0] switch_async=5;
    reg [15:0] current_index=65534,image_count=65535;
    reg have_image=1,auto_enabled=1,busy=0,fading=0,error=0;
    wire [3:0] switch_frame,status_frame;
    wire [23:0] uptime_frame;
    wire [19:0] index_frame,count_frame;
    display_control dut(.*);
    task latch_frame;
        begin @(negedge pixel_clk);frame_tick=1;@(negedge pixel_clk);frame_tick=0;end
    endtask
    task ms(input integer n);
        begin repeat(n) begin @(negedge clk);tick_ms=1;@(negedge clk);tick_ms=0;end end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;pixel_rst=0;
        repeat(100) @(negedge clk);latch_frame();
        if(index_frame!==20'h65535 || count_frame!==20'h65535 || status_frame!==1 || switch_frame!==5)
            $fatal(1,"initial coherent BCD snapshot wrong: %h %h %h %h",index_frame,count_frame,status_frame,switch_frame);
        // Bounce is shorter than the required 20 stable millisecond samples.
        switch_async=15;ms(5);switch_async=0;ms(5);switch_async=10;
        ms(19);repeat(80) @(negedge clk);latch_frame();
        if(switch_frame!==5) $fatal(1,"switch debounce accepted a short interval");
        ms(2);repeat(100) @(negedge clk);
        if(switch_frame!==5) $fatal(1,"parameters changed outside a frame boundary");
        latch_frame();if(switch_frame!==10) $fatal(1,"stable switch not latched");
        // Advance exactly one simulated second (tick input is accelerated).
        ms(969);repeat(100) @(negedge clk);latch_frame();
        if(uptime_frame!==24'h000001) $fatal(1,"BCD second rollover wrong: %h",uptime_frame);
        current_index=9;image_count=12;busy=1;fading=1;error=1;auto_enabled=0;
        repeat(100) @(negedge clk);
        if(index_frame!==20'h65535 || status_frame!==1) $fatal(1,"UI changed mid-frame");
        latch_frame();
        if(index_frame!==20'h00010 || count_frame!==20'h00012 || status_frame!==4'b1110)
            $fatal(1,"updated snapshot fields torn");
        // Deposit a boundary value solely to avoid 100 simulated hours.
        @(negedge clk);dut.uptime=24'h995959;dut.second_ms=999;
        ms(1);repeat(100) @(negedge clk);latch_frame();
        if(uptime_frame!==0) $fatal(1,"99:59:59 rollover wrong: %h",uptime_frame);
        have_image=0;repeat(100) @(negedge clk);latch_frame();
        if(index_frame!==0) $fatal(1,"no-image index must be zero");
        $display("PASS tb_display_control: debounce, BCD 65535, atomic frame snapshots, uptime rollover");
        $finish;
    end
    initial begin #5000000;$fatal(1,"tb_display_control timeout");end
endmodule
