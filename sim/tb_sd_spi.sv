`timescale 1ns/1ps
module tb_sd_spi;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,req_valid=0,req_write=0,w_valid=0,r_ready=0,reject_read=0;
    reg [31:0] req_lba=32'h1234;
    reg [7:0] w_data=0;
    wire req_ready,w_ready,r_valid,r_last,init_done,busy,done,error,sd_cs_n,sd_sck,sd_mosi,sd_miso;
    wire [7:0] r_data,error_code;
    sd_spi_card #(.POWER_WAIT_MS(1)) dut(.*);
    sd_card_spi card(.cs_n(sd_cs_n),.sck(sd_sck),.mosi(sd_mosi),.miso(sd_miso),.*);
    integer received=0;
    reg [31:0] rng=32'h431b9f2d;
    bit held=0;
    reg [8:0] held_data;
    time last_sck=0,init_min=64'hffffffffffffffff,data_min=64'hffffffffffffffff;
    always @(posedge sd_sck) begin
        if(!sd_cs_n && last_sck!=0) begin
            if(init_done && $time-last_sck<200) $fatal(1,"SPI exceeds 5 MHz");
            if(!init_done && $time-last_sck<4000) $fatal(1,"SPI initialization exceeds 250 kHz");
            if(init_done && $time-last_sck<data_min) data_min=$time-last_sck;
            if(!init_done && $time-last_sck<init_min) init_min=$time-last_sck;
        end
        last_sck=$time;
    end
    always @(posedge sd_cs_n) last_sck=0;
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};r_ready=(rng[2:0]!=0);
    end
    always @(posedge clk) if(rst_n) begin
        if(held && (r_valid!==1 || {r_last,r_data}!==held_data)) $fatal(1,"SD data changed under backpressure");
        held=r_valid&&!r_ready;held_data={r_last,r_data};
        if(r_valid && r_ready) begin
            if(r_data!==8'((received*13+8'h34)&255) || r_last !== (received==511))
                $fatal(1,"SD read byte %0d got %h last=%b",received,r_data,r_last);
            received=received+1;
        end
    end
    task request_block;
        begin wait(req_ready);@(negedge clk);req_valid=1;@(negedge clk);req_valid=0;end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        wait(init_done || error);if(error) $fatal(1,"SD init error %h",error_code);
        request_block();wait(done || error);@(negedge clk);
        if(error || received!=512 || !sd_cs_n || card.acmd41_count!=2) $fatal(1,"SD init/read did not finish");
        if(init_min!=4000 || data_min!=200) $fatal(1,"SPI nominal periods init=%0t data=%0t",init_min,data_min);
        reject_read=1;request_block();wait(error);repeat(100) @(negedge clk);
        if(req_ready || !sd_cs_n || init_done) $fatal(1,"SD read error did not stop safely");
        $display("PASS tb_sd_spi: CMD0/8/55/41/58/59/17, 250 kHz/5 MHz, 512 bytes, backpressure, rejected-read fault");
        $finish;
    end
    initial begin #20000000;$fatal(1,"tb_sd_spi timeout state=%0d error=%h",dut.state,error_code);end
endmodule
