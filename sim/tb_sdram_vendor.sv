`timescale 1ns/1ps
module tb_sdram_vendor;
    reg Sdr_clk=0;always #3.333 Sdr_clk=~Sdr_clk;
    wire Sdr_clk_sft=~Sdr_clk;
    reg Rst=1,App_ref_req=0,App_wr_en=0,App_rd_en=0;
    reg [20:0] App_wr_addr=0,App_rd_addr=0;
    reg [31:0] App_wr_din=0;
    reg [3:0] App_wr_dm=0;
    wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,Sdr_rd_en;
    wire [31:0] Sdr_rd_dout;
    sdram_ram_wrapper #(.SELF_REFRESH_OPEN(0)) dut(.*);
    sdram_device memory(.clk(dut.sdram_clk),.ras_n(dut.sdr_ras),.cas_n(dut.sdr_cas),
        .we_n(dut.sdr_we),.addr(dut.sdr_addr),.ba(dut.sdr_ba),.dm(dut.sdr_dm),.dq(dut.sdr_dq));
    integer received=0,reads=0;
    reg checking=0;
    reg [31:0] pattern=0;
    always @(posedge Sdr_clk) if(!Rst && Sdr_rd_en) begin
        if(!checking || received>=64 || Sdr_rd_dout !== (pattern ^ received))
            $fatal(1,"real SDRAM returned %0d: %h expected %h",received,Sdr_rd_dout,pattern^received);
        received=received+1;
    end
    task write_block(input integer base,input reg [31:0] value);
        begin
            for(integer i=0;i<64;i=i+1) begin
                @(negedge Sdr_clk);App_wr_en=1;App_wr_addr=base+i;App_wr_din=value^i;
            end
            @(negedge Sdr_clk);App_wr_en=0;
            repeat(32) @(negedge Sdr_clk);
        end
    endtask
    task read_block(input integer base,input reg [31:0] value);
        begin
            checking=1;received=0;pattern=value;
            for(integer i=0;i<64;i=i+1) begin
                @(negedge Sdr_clk);App_rd_en=1;App_rd_addr=base+i;
            end
            @(negedge Sdr_clk);App_rd_en=0;
            wait(received==64);repeat(32) @(negedge Sdr_clk);
            checking=0;reads=reads+1;
        end
    endtask
    initial begin
        repeat(10) @(negedge Sdr_clk);Rst=0;
        wait(Sdr_init_done && !Sdr_init_ref_vld);repeat(32) @(negedge Sdr_clk);
        write_block(0,32'h10203040);write_block(307200,32'ha5b6c7d8);
        read_block(0,32'h10203040);read_block(307200,32'ha5b6c7d8);
        @(negedge Sdr_clk);App_ref_req=1;@(negedge Sdr_clk);App_ref_req=0;
        wait(Sdr_init_ref_vld);wait(!Sdr_init_ref_vld);repeat(32) @(negedge Sdr_clk);
        read_block(0,32'h10203040);read_block(307200,32'ha5b6c7d8);
        $display("PASS tb_sdram_vendor: real vendor controller + SDRAM device model, two 64-word regions, direction changes and manual refresh");
        $finish;
    end
    initial begin #10000000;$fatal(1,"tb_sdram_vendor timeout init=%b ref=%b got=%0d",Sdr_init_done,Sdr_init_ref_vld,received);end
endmodule
