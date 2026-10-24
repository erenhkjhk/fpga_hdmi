`timescale 1ns/1ps
module tb_video_osd;
    reg clk=0;always #20 clk=~clk;
    reg rst=1,frame_tick=0;
    reg [3:0] switch_code=5,status=1;
    reg [23:0] uptime=0;
    reg [19:0] index_bcd=20'h00012,count_bcd=20'h00345;
    reg [23:0] in_data=0;
    reg [9:0] in_x=0;
    reg [8:0] in_y=0;
    reg in_valid=0,in_user=0,in_last=0,in_image=1;
    wire [23:0] color_data,out_data;
    wire [9:0] color_x,out_x;
    wire [8:0] color_y,out_y;
    wire color_valid,color_user,color_last,out_valid,out_user,out_last;
    video_color_adjust color(.out_data(color_data),.out_x(color_x),.out_y(color_y),
        .out_valid(color_valid),.out_user(color_user),.out_last(color_last),.*);
    video_osd osd(.in_data(color_data),.in_x(color_x),.in_y(color_y),
        .in_valid(color_valid),.in_user(color_user),.in_last(color_last),.*);
    defparam osd.u_font.inst.INIT_FILE="../assets/osd/td_init/osd_font_8x8192.mif.dath";
    defparam osd.u_logo.inst.INIT_FILE="../assets/osd/td_init/anlogic_logo_argb4444.mif.dath";
    reg [23:0] gold[0:307199],expected_rgb[0:3];
    reg [21:0] expected_meta[0:3];
    integer in_pixels=0,out_pixels=0,fd=0,frame=0;
    function automatic [23:0] background(input integer x,y);
        background={8'((x*43+y*17+11)&255),8'((x*7+y*67+23)&255),8'((x*59+y*3+191)&255)};
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            for(integer i=0;i<4;i=i+1) begin expected_rgb[i]=0;expected_meta[i]=0;end
        end else begin
            for(integer i=3;i>0;i=i-1) begin expected_rgb[i]=expected_rgb[i-1];expected_meta[i]=expected_meta[i-1];end
            expected_meta[0]={in_x,in_y,in_valid,in_user,in_last};
            expected_rgb[0]=in_valid ? gold[in_pixels] : 0;
            if(in_valid) in_pixels=in_pixels+1;
            #2;
            if({out_x,out_y,out_valid,out_user,out_last} !== expected_meta[3])
                $fatal(1,"video metadata latency mismatch at frame=%0d pixel=%0d",frame,out_pixels);
            if(out_valid) begin
                if(out_data!==expected_rgb[3])
                    $fatal(1,"OSD frame=%0d (%0d,%0d) got %h expected %h",frame,out_x,out_y,out_data,expected_rgb[3]);
                out_pixels=out_pixels+1;
                $fwrite(fd,"%c%c%c",out_data[23:16],out_data[15:8],out_data[7:0]);
            end
        end
    end
    task scroll_ticks(input integer n);
        begin repeat(n) begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;end end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(frame=0;frame<3;frame=frame+1) begin
            if(frame==1) begin scroll_ticks(799);switch_code=10;uptime=24'h123456;status=7;end
            if(frame==2) begin scroll_ticks(1);switch_code=15;uptime=24'h995959;status=8;in_image=0;end
            $readmemh($sformatf("../sim/out/vectors/osd_%0d.hex",frame),gold);
            fd=$fopen($sformatf("../sim/out/osd_actual_%0d.ppm",frame),"wb");
            $fwrite(fd,"P6\n640 480\n255\n");in_pixels=0;out_pixels=0;
            for(integer y=0;y<525;y=y+1) for(integer x=0;x<800;x=x+1) begin
                @(negedge clk);in_x=x;in_y=y;in_valid=(x<640 && y<480);
                in_user=(x==0 && y==0);in_last=(x==639 && y<480);
                in_data=background(x,y);
            end
            @(negedge clk);in_valid=0;in_user=0;in_last=0;
            repeat(8) @(negedge clk);
            if(out_pixels!=307200 || in_pixels!=307200) $fatal(1,"OSD frame pixel count");
            $fclose(fd);fd=0;
        end
        $display("PASS tb_video_osd: 921600 pixels, real font/logo ROMs, alpha, parameters, scrolling wrap and stream alignment");
        $finish;
    end
    initial begin #60000000;$fatal(1,"tb_video_osd timeout");end
endmodule
