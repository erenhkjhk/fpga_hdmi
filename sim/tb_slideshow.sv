`timescale 1ns/1ps
module tb_slideshow;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,tick_ms=0,previous_press=0,next_press=0,auto_press=0;
    reg memory_ready=1,memory_fault=0,mount_done=1,catalog_ready=1,storage_error=0;
    reg [15:0] image_count=3;
    wire open_valid;reg open_ready=0;
    wire [15:0] open_index;
    reg file_done=0,decoder_done=0,decoder_complete=0,decoder_error=0;
    wire decoder_start,decoder_cancel;
    reg image_begin_valid=0,image_begin_ready=1;
    wire finish_valid,finish_abort;reg finish_ready=0;
    reg result_valid=0,result_abort=0;wire result_ready;
    wire auto_enabled,busy,error,have_image;
    wire [15:0] current_index;
    slideshow_control #(.AUTO_INTERVAL_MS(20),.AUTO_DEFAULT(0)) dut(.*);
    task key(input integer k);
        begin
            @(negedge clk);previous_press=(k==1);next_press=(k==2);auto_press=(k==3);
            @(negedge clk);previous_press=0;next_press=0;auto_press=0;
        end
    endtask
    task tick(input integer n);
        begin repeat(n) begin @(negedge clk);tick_ms=1;@(negedge clk);tick_ms=0;end end
    endtask
    task load_job(input integer index,input bit bad);
        begin
            wait(open_valid);@(negedge clk);
            if(open_index!==index) $fatal(1,"expected open %0d got %0d",index,open_index);
            open_ready=1;@(negedge clk);open_ready=0;
            if(!decoder_start) $fatal(1,"decoder start pulse missing");
            decoder_done=0;decoder_complete=0;decoder_error=0;
            image_begin_valid=1;@(negedge clk);image_begin_valid=0;
            repeat(4) @(negedge clk);
            file_done=1;decoder_done=1;decoder_complete=!bad;decoder_error=bad;
            @(negedge clk);file_done=0;
            wait(finish_valid);@(negedge clk);
            if(finish_abort!==bad) $fatal(1,"bad finish abort flag");
            finish_ready=1;@(negedge clk);finish_ready=0;
            if(!result_ready) $fatal(1,"missing wait-for-transition state");
        end
    endtask
    task acknowledge(input bit abort_job);
        begin
            @(negedge clk);result_abort=abort_job;result_valid=1;
            @(negedge clk);result_valid=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        load_job(0,0);
        tick(50);
        if(open_valid || have_image || current_index!=0) $fatal(1,"premature image/region release");
        key(2);key(1); // Latest direction wins while waiting for a fade.
        acknowledge(0);
        if(!have_image || current_index!=0) $fatal(1,"first commit failed");
        load_job(2,0);acknowledge(0);
        if(current_index!=2) $fatal(1,"previous wrap or queued direction failed");
        key(2);load_job(0,1);acknowledge(1);
        if(current_index!=2) $fatal(1,"failed frame replaced current image");
        load_job(1,0);acknowledge(0);
        if(current_index!=1 || error) $fatal(1,"failed-candidate skip recovery");
        key(3);if(!auto_enabled) $fatal(1,"KEY3 did not enable auto");
        tick(19);if(open_valid) $fatal(1,"auto dwell too short");
        tick(1);load_job(2,0);
        tick(100);if(open_valid || current_index!=1) $fatal(1,"auto ran during fade");
        acknowledge(0);
        tick(19);if(open_valid) $fatal(1,"dwell must start after transition result");
        key(3);tick(50);if(auto_enabled || open_valid) $fatal(1,"KEY3 disable failed");
        memory_fault=1;@(negedge clk);
        if(!decoder_cancel || !error || open_valid) $fatal(1,"fatal memory stop failed");
        $display("PASS tb_slideshow: keys, wrap, queued direction, failed candidate, dwell after fade, auto toggle, fault");
        $finish;
    end
    initial begin #1000000;$fatal(1,"tb_slideshow timeout");end
endmodule
