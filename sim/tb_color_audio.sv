`timescale 1ns/1ps
module tb_color_audio;
    reg clk=0;always #20 clk=~clk;
    reg rst=1;
    reg [3:0] switch_code=5;
    reg [23:0] in_data=0;
    reg [9:0] in_x=0;
    reg [8:0] in_y=0;
    reg in_valid=0,in_user=0,in_last=0,in_image=1;
    wire [23:0] out_data;
    wire [9:0] out_x;
    wire [8:0] out_y;
    wire out_valid,out_user,out_last;
    video_color_adjust color(.*);
    wire bclk,lrck,serial_data,audio_valid,acr_valid;
    wire [23:0] audio_left,audio_right;
    wire [19:0] acr_cts,acr_n;
    i2s_test_tone tone(.*);
    i2s_stereo_receiver rx(.*);
    hdmi_acr_48k acr(.*);
    integer c,s,n=0,last_sample=0,samples=0,acr_count=0,positive=0,negative=0;
    integer first_sample=0,cycles=0;
    bit expect_acr=0;
    function automatic [7:0] reference_channel(input integer v,input integer code);
        integer num,rounded,result;
        begin
            num=(v-128)*((code>>2)+1);
            rounded=(num<0) ? -((-num+1)/2) : (num+1)/2;
            result=rounded+128+32*((code&3)-1);
            reference_channel=(result<0) ? 0 : (result>255) ? 255 : result;
        end
    endfunction
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;
        #1;
        if(audio_valid) begin
            if(samples>0 && (cycles-last_sample<520 || cycles-last_sample>521))
                $fatal(1,"48 kHz interval %0d",cycles-last_sample);
            if(audio_left!==audio_right || (audio_left!==24'h100000 && audio_left!==24'hf00000))
                $fatal(1,"I2S stereo/sample mismatch L=%h R=%h",audio_left,audio_right);
            if(audio_left==24'h100000) positive=positive+1;else negative=negative+1;
            if(samples==0) first_sample=cycles;
            last_sample=cycles;samples=samples+1;
        end
        if(acr_valid) begin
            if(acr_cts!=25000 || acr_n!=6144) $fatal(1,"ACR wrong clock parameters");
            acr_count=acr_count+1;
            if(samples!=48*acr_count) $fatal(1,"ACR cadence samples=%0d updates=%0d",samples,acr_count);
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(s=0;s<16;s=s+1) for(c=0;c<256;c=c+1) begin
            @(negedge clk);
            switch_code=s;in_data={8'(c),8'(255-c),8'((c*37)&255)};
            in_x=n%640;in_y=n/640;in_valid=1;in_user=(n==0);in_last=(n%640==639);n=n+1;
            @(posedge clk);#2;
            if(out_data !== {reference_channel(c,s),reference_channel(255-c,s),reference_channel((c*37)&255,s)})
                $fatal(1,"color code=%0d c=%0d RGB=%h",s,c,out_data);
            if({out_x,out_y,out_valid,out_user,out_last} !== {in_x,in_y,in_valid,in_user,in_last})
                $fatal(1,"color metadata misaligned");
        end
        @(negedge clk);in_image=0;switch_code=15;
        @(posedge clk);#2;if(out_data!==0) $fatal(1,"invalid image must remain black");
        wait(acr_count>=10);@(negedge clk);
        if(acr_count!=10 || positive<200 || negative<200) $fatal(1,"audio polarity/ACR coverage");
        if(last_sample-first_sample<249478 || last_sample-first_sample>249480)
            $fatal(1,"mean sample rate does not match 25 MHz / 48 kHz");
        $display("PASS tb_color_audio: 4096 RGB settings, metadata, 480 stereo samples, 10 ACR updates");
        $finish;
    end
    initial begin #20000000;$fatal(1,"tb_color_audio timeout");end
endmodule
