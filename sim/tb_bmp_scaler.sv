`timescale 1ns/1ps
module tb_bmp_scaler;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,start=0,cancel=0;
    reg [31:0] file_size=0;
    reg [7:0] file_data=0;
    reg file_valid=0,file_last=0,begin_ready=0,pixel_ready=0;
    wire file_ready,begin_valid,bottom_up,pixel_valid,done,image_complete,error;
    wire [7:0] error_code;
    wire [31:0] pixel_data;
    bmp24_decoder dut(.*);
    reg [7:0] bytes[0:1200000];
    reg [31:0] gold[0:307199];
    reg [31:0] rng=32'hc001beef;
    reg active=0,success_case=0,held=0;
    reg [31:0] held_data;
    integer ptr=0,byte_count=0,pixels=0,tests=0;
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        file_valid=active && ptr<byte_count && rng[1:0]!=0;
        if(ptr<byte_count) file_data=bytes[ptr];
        file_last=(ptr==byte_count-1);
        pixel_ready=(rng[5:3]!=0);
        begin_ready=(rng[8:6]!=0);
    end
    always @(posedge clk) if(!rst) begin
        if(file_valid && file_ready) ptr=ptr+1;
        if(held && !cancel && !error && (pixel_valid!==1'b1 || pixel_data!==held_data))
            $fatal(1,"output changed during pixel backpressure");
        held=pixel_valid && !pixel_ready;held_data=pixel_data;
        if(pixel_valid && pixel_ready) begin
            if(success_case && (pixels>=307200 || pixel_data!==gold[pixels]))
                $fatal(1,"pixel %0d got %h expected %h",pixels,pixel_data,gold[pixels]);
            pixels=pixels+1;
        end
        if(done && active && success_case && pixels!=307200)
            $fatal(1,"decoder completed early: %0d pixels",pixels);
    end
    task run_case(input string name,input integer declared_bytes,input integer code,input bit ok);
        integer fd;
        begin
            @(negedge clk);active=0;start=0;
            fd=$fopen({"../sim/out/vectors/",name,".bmp"},"rb");
            if(fd==0) $fatal(1,"cannot open fixture %s",name);
            byte_count=$fread(bytes,fd);$fclose(fd);
            if(ok) $readmemh({"../sim/out/vectors/",name,".hex"},gold);
            ptr=0;pixels=0;held=0;success_case=ok;file_size=declared_bytes;
            start=1;
            @(negedge clk);start=0;active=1;
            wait(done);@(negedge clk);
            if(error !== !ok || (ok && !image_complete) || (!ok && error_code!=code))
                $fatal(1,"%s result error=%b complete=%b code=%h expected code=%h",name,error,image_complete,error_code,code);
            if(ptr!=byte_count) $fatal(1,"%s left file bytes: %0d/%0d",name,ptr,byte_count);
            active=0;tests=tests+1;
            $display("case %s OK pixels=%0d code=%h",name,pixels,error_code);
        end
    endtask
    // Cancel/reset while the new registered arithmetic has work in flight.
    // Restart through the public file interface; no DUT state is forced.
    task interrupt_pipeline(input integer phase,input bit reset_job);
        integer fd;
        begin
            @(negedge clk);active=0;ptr=0;pixels=0;held=0;success_case=0;
            fd=$fopen("../sim/out/vectors/tiny.bmp","rb");
            if(fd==0) $fatal(1,"cannot open cancellation fixture");
            byte_count=$fread(bytes,fd);$fclose(fd);file_size=byte_count;
            start=1;@(negedge clk);start=0;active=1;
            wait(dut.u_scaler.state==phase);
            @(negedge clk);active=0;
            if(reset_job) rst=1;else cancel=1;
            @(negedge clk);rst=0;cancel=0;held=0;
            if(!reset_job && (!done || !error || error_code!=5))
                $fatal(1,"pipeline cancel phase %0d not acknowledged",phase);
            repeat(12) begin
                @(negedge clk);
                if(pixel_valid) $fatal(1,"stale pipeline output after interruption phase %0d",phase);
            end
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        interrupt_pipeline(dut.u_scaler.WEIGHT_STEP,0);
        interrupt_pipeline(dut.u_scaler.MULTIPLY,0);
        interrupt_pipeline(dut.u_scaler.ACCUMULATE,0);
        interrupt_pipeline(dut.u_scaler.MULTIPLY,1);
        `include "vectors/bmp_cases.vh"
        // Abort a valid long job, then reuse the same decoder without resetting it.
        @(negedge clk);file_size=66;byte_count=66;ptr=0;pixels=0;success_case=0;
        begin
            integer fd;
            fd=$fopen("../sim/out/vectors/tiny.bmp","rb");byte_count=$fread(bytes,fd);$fclose(fd);
            file_size=byte_count;
        end
        start=1;@(negedge clk);start=0;active=1;
        wait(pixels==10);@(negedge clk);cancel=1;
        @(negedge clk);cancel=0;active=0;
        if(!done || !error || error_code!=5 || pixel_valid) $fatal(1,"cancel did not stop job");
        run_case("one",58,0,1);
        $display("PASS tb_bmp_scaler: %0d BMP cases, all full-frame pixels, weight/multiply/accumulate cancellation and reset/restart",tests);
        $finish;
    end
    initial begin #(64'd6000000000); $fatal(1,"tb_bmp_scaler timeout"); end
endmodule
