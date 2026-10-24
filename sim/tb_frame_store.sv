`timescale 1ns/1ps
module tb_frame_store;
    reg clk=0,load_clk=0,pixel_clk=0;
    always #3.333 clk=~clk;always #10 load_clk=~load_clk;always #20 pixel_clk=~pixel_clk;
    reg rst=1;
    reg begin_valid=0,begin_bottom_up=0,finish_valid=0,finish_abort=0,frame_req_valid=0;
    wire begin_ready,finish_ready,result_valid,result_abort,frame_req_ready,frame_info_valid,frame_has_image;
    wire result_ready=1,frame_info_ready=1;
    wire [31:0] load_fifo_data,video_fifo_data;
    wire load_fifo_valid,load_fifo_empty,load_fifo_re;
    wire [9:0] load_fifo_used,video_fifo_used;
    wire load_fifo_ready,video_fifo_we,video_fifo_full,video_fifo_wr_ready,video_fifo_rd_ready,video_fifo_reset;
    wire fault,transition_active,sdr_init_done,sdr_refresh;
    wire app_refresh_req,app_wr_en,app_rd_en,sdr_rd_valid;
    wire [20:0] app_wr_addr,app_rd_addr;
    wire [31:0] app_wr_data,sdr_rd_data;
    wire [3:0] app_wr_mask;
    sdram_frame_store dut(.*);
    sdram_ram_wrapper #(.SELF_REFRESH_OPEN(0)) controller(
        .Sdr_clk(clk),.Sdr_clk_sft(~clk),.Rst(rst),.Sdr_init_done(sdr_init_done),
        .Sdr_init_ref_vld(sdr_refresh),.Sdr_busy(),.App_ref_req(app_refresh_req),
        .App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),.App_wr_din(app_wr_data),.App_wr_dm(app_wr_mask),
        .App_rd_en(app_rd_en),.App_rd_addr(app_rd_addr),.Sdr_rd_en(sdr_rd_valid),.Sdr_rd_dout(sdr_rd_data));
    sdram_device memory(.clk(controller.sdram_clk),.ras_n(controller.sdr_ras),.cas_n(controller.sdr_cas),
        .we_n(controller.sdr_we),.addr(controller.sdr_addr),.ba(controller.sdr_ba),
        .dm(controller.sdr_dm),.dq(controller.sdr_dq));

    reg produce=0,load_we=0;
    reg [31:0] load_di=0;
    integer produced=0,load_target=0,load_id=0;
    bit load_bottom=0;
    wire load_afull,load_full,load_wr_done,load_rd_done;
    assign load_fifo_ready=load_wr_done && load_rd_done;
    fifo_pixel_async load_fifo(.clkw(load_clk),.clkr(clk),.wrst(rst),.rrst(rst),.we(load_we),.di(load_di),
        .re(load_fifo_re),.dout(load_fifo_data),.valid(load_fifo_valid),.empty_flag(load_fifo_empty),
        .rdusedw(load_fifo_used),.afull(load_afull),.full_flag(load_full),
        .wr_rst_done(load_wr_done),.rd_rst_done(load_rd_done),.aempty(),.wrusedw(),.overflow(),.underflow(),.wr_success());
    reg consume=0;
    integer checked_pixels=0,check_length=0,check_alpha=0,total_checked=0;
    wire [31:0] video_q;
    wire video_valid,video_empty;
    wire [9:0] video_used_pixel;
    wire video_re=consume && video_fifo_rd_ready && !video_empty && checked_pixels<check_length;
    fifo_pixel_async video_fifo(.clkw(clk),.clkr(pixel_clk),.wrst(rst || video_fifo_reset),.rrst(rst || video_fifo_reset),
        .we(video_fifo_we),.di(video_fifo_data),.re(video_re),.dout(video_q),.valid(video_valid),
        .empty_flag(video_empty),.full_flag(video_fifo_full),.wrusedw(video_fifo_used),.rdusedw(video_used_pixel),
        .wr_rst_done(video_fifo_wr_ready),.rd_rst_done(video_fifo_rd_ready),.afull(),.aempty(),
        .overflow(),.underflow(),.wr_success());
    function automatic [31:0] pattern(input integer id,index);
        integer x,y;
        begin
            x=index%640;y=index/640;
            pattern={8'b0,8'((x*3+y*5+id*47)&255),8'((x^y^(id*19))&255),8'((x*7+y*11+id*71)&255)};
        end
    endfunction
    function automatic [31:0] expected_pixel(input integer alpha,index);
        reg [31:0] old_c,new_c;
        begin
            old_c=pattern(0,index);new_c=pattern(1,index);expected_pixel=0;
            for(integer b=0;b<3;b=b+1)
                expected_pixel[b*8+:8]=((256-alpha)*old_c[b*8+:8]+alpha*new_c[b*8+:8]+128)/256;
        end
    endfunction
    always @(negedge load_clk) begin
        load_we=produce && produced<load_target && load_wr_done && !load_afull;
        load_di=pattern(load_id,load_bottom ? (479-produced/640)*640+produced%640 : produced);
    end
    always @(posedge load_clk) if(!rst && load_we && !load_full) produced=produced+1;

    integer success_count=0,abort_count=0,refresh_gap=0,max_refresh_gap=0;
    bit expect_fault=0;
    always @(posedge clk) if(!rst) begin
        if(result_valid && result_ready) begin
            if(result_abort) abort_count=abort_count+1;else success_count=success_count+1;
        end
        if(fault && !expect_fault) $fatal(1,"frame store fault state=%0d",dut.state);
        if(transition_active && begin_ready) $fatal(1,"old region released during fade");
        if(app_wr_en && app_rd_en) $fatal(1,"SDRAM read/write overlap");
        if(video_fifo_reset && video_fifo_we) $fatal(1,"mixed data leaked into FIFO reset");
        if(sdr_init_done && !fault) begin
            refresh_gap=refresh_gap+1;
            if(app_refresh_req) begin
                if(refresh_gap>max_refresh_gap) max_refresh_gap=refresh_gap;
                refresh_gap=0;
            end
            if(refresh_gap>4687) $fatal(1,"refresh starvation: %0d clocks",refresh_gap);
        end
    end
    always @(posedge pixel_clk) if(!rst && consume) begin
        if(checked_pixels<check_length && video_empty) $fatal(1,"25 MHz active-pixel underflow at %0d",checked_pixels);
        #1;
        if(video_valid) begin
            if(video_q!==expected_pixel(check_alpha,checked_pixels))
                $fatal(1,"fade alpha=%0d pixel=%0d got %h expected %h",check_alpha,checked_pixels,video_q,expected_pixel(check_alpha,checked_pixels));
            checked_pixels=checked_pixels+1;total_checked=total_checked+1;
        end
    end
    task load_image(input integer id,input bit bottom,input integer words,input bit abort_job);
        begin
            wait(sdr_init_done && load_fifo_ready);
            @(negedge clk);begin_bottom_up=bottom;begin_valid=1;
            do @(posedge clk);while(!begin_ready);
            @(negedge clk);begin_valid=0;
            @(negedge load_clk);load_id=id;load_bottom=bottom;produced=0;load_target=words;produce=1;
            wait(produced==words);@(negedge load_clk);produce=0;
            @(negedge clk);finish_abort=abort_job;finish_valid=1;
            do @(posedge clk);while(!finish_ready);
            @(negedge clk);finish_valid=0;
            if(abort_job) wait(abort_count==1);else wait(dut.pending_front);
        end
    endtask
    task display_frame(input integer alpha,length);
        begin
            consume=0;
            @(negedge clk);frame_req_valid=1;
            do @(posedge clk);while(!frame_req_ready);
            @(negedge clk);frame_req_valid=0;
            wait(frame_info_valid);
            if(!frame_has_image) $fatal(1,"frame missing valid image");
            wait(video_fifo_rd_ready && video_used_pixel>=640);
            @(negedge pixel_clk);check_alpha=alpha;check_length=length;checked_pixels=0;consume=1;
            wait(checked_pixels==length);@(negedge pixel_clk);consume=0;
        end
    endtask
    initial begin
        repeat(8) @(negedge load_clk);rst=0;
        load_image(0,1,307200,0);display_frame(0,307200);
        if(success_count!=1 || transition_active) $fatal(1,"first image commit");
        load_image(1,0,307200,0);
        for(integer alpha=0;alpha<=256;alpha=alpha+4) begin
            display_frame(alpha,(alpha==128 || alpha==256) ? 307200 : 1024);
            if(success_count!=1 || !transition_active) $fatal(1,"fade committed prematurely at %0d",alpha);
        end
        display_frame(256,2048);
        if(success_count!=2 || transition_active) $fatal(1,"final frame did not release old region");
        load_image(0,0,37,1);display_frame(256,2048);
        if(abort_count!=1 || success_count!=2) $fatal(1,"partial load committed");
        expect_fault=1;
        @(negedge clk);frame_req_valid=1;
        do @(posedge clk);while(!frame_req_ready);
        @(negedge clk);frame_req_valid=0;
        wait(dut.state==3);force sdr_rd_valid=0;
        wait(fault);release sdr_rd_valid;
        $display("PASS tb_frame_store: %0d pixels, 65 alpha levels, two full loads, bottom-up, abort, 25 MHz sink, max refresh gap %0d, timeout detection",total_checked,max_refresh_gap);
        $finish;
    end
    initial begin #400000000;$fatal(1,"tb_frame_store timeout state=%0d pixels=%0d",dut.state,checked_pixels);end
endmodule
