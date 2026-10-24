`timescale 1ns/1ps
module tb_fifo_cdc;
    reg clkw=0,clkr=0;
    always #10 clkw=~clkw;
    always #3.333 clkr=~clkr;
    reg wrst=1,rrst=1,we=0,re=0;
    reg [31:0] di=0;
    wire [31:0] dout;
    wire empty_flag,aempty,full_flag,afull,valid,overflow,underflow,wr_success,wr_rst_done,rd_rst_done;
    wire [9:0] rdusedw,wrusedw;
    fifo_pixel_async fifo(.*);
    integer written=0,read_count=0;
    bit produce=0,consume=0;
    integer target=5000;
    reg [31:0] rng=32'h5af20ab1;
    always @(negedge clkw) begin
        if(produce) begin we=wr_rst_done && rd_rst_done && !afull && written<target;di=32'h12340000+written;end
        else we=0;
    end
    always @(posedge clkw) if(!wrst && we && !full_flag) written=written+1;
    always @(negedge clkr) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        re=consume && wr_rst_done && rd_rst_done && !empty_flag && rng[1:0]!=0;
    end
    always @(posedge clkr) begin
        bit request;
        request=re && !empty_flag && rd_rst_done;
        #0.5;
        if(!rrst && consume) begin
            if(valid!==request) $fatal(1,"FIFO normal-mode valid latency: valid=%b request=%b",valid,request);
            if(valid) begin
                if(dout!==32'h12340000+read_count) $fatal(1,"FIFO order %0d got %h",read_count,dout);
                read_count=read_count+1;
            end
            if(underflow) $fatal(1,"FIFO unexpected underflow");
        end
    end
    always @(posedge clkw) if(!wrst && overflow) $fatal(1,"FIFO unexpected overflow");

    reg src_rst=1,dst_rst=1,src_valid=0,dst_ready=0;
    reg [31:0] src_data=0;
    wire src_ready,src_done,dst_valid;
    wire [31:0] dst_data;
    cdc_mailbox #(.WIDTH(32)) u_mailbox(.src_clk(clkw),.dst_clk(clkr),.*);
    integer delivered=0;
    reg stalled=0;
    reg [31:0] stalled_data;
    always @(posedge clkr) if(!dst_rst) begin
        if(stalled && (dst_valid!==1 || dst_data!==stalled_data)) $fatal(1,"mailbox changed held payload");
        if(dst_valid && dst_ready) begin
            if(dst_data!==(32'ha5000000^(delivered*32'h01010101))) $fatal(1,"mailbox torn/duplicate data %0d: %h",delivered,dst_data);
            delivered=delivered+1;
        end
        stalled=dst_valid&&!dst_ready;stalled_data=dst_data;
    end
    always @(negedge clkr) dst_ready=!dst_rst && rng[3:2]!=0;
    initial begin
        repeat(8) @(negedge clkw);wrst=0;rrst=0;src_rst=0;dst_rst=0;
        wait(wr_rst_done && rd_rst_done);produce=1;consume=1;
        for(integer i=0;i<128;i=i+1) begin
            @(negedge clkw);while(!src_ready) @(negedge clkw);
            src_data=32'ha5000000^(i*32'h01010101);src_valid=1;
            @(negedge clkw);src_valid=0;
        end
        wait(delivered==128 && read_count==target);
        produce=0;consume=0;
        repeat(10) @(negedge clkw);
        if(!empty_flag || wrusedw!=0 || rdusedw!=0 || written!=target) $fatal(1,"FIFO final counts");
        // Coordinated reset must discard an old tail and permit a fresh sequence.
        target=5100;produce=1;wait(written==5100);produce=0;
        @(negedge clkw);wrst=1;rrst=1;
        repeat(8) @(negedge clkw);written=0;read_count=0;target=257;wrst=0;rrst=0;
        wait(wr_rst_done && rd_rst_done);produce=1;consume=1;wait(read_count==257);
        $display("PASS tb_fifo_cdc: vendor asynchronous FIFO 5000 ordered words, flush/restart, 128 atomic mailboxes");
        $finish;
    end
    initial begin #3000000;$fatal(1,"tb_fifo_cdc timeout");end
endmodule
