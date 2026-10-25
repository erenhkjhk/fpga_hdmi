`timescale 1ns/1ps
module tb_init_probe;
 reg clk=0;always #10 clk=~clk;
 wire [31:0] h,d,m;
 EG_LOGIC_BRAM #(.MODE("SP"),.DATA_WIDTH_A(32),.ADDR_WIDTH_A(8),.DATA_DEPTH_A(256),.REGMODE_A("OUTREG"),.IMPLEMENT("9K(FAST)"),.INIT_FILE("../assets/spectrum/dft_twiddle_q15_32x256.hex")) xh
 (.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.addra(8'd0),.dia(32'd0),.doa(h));
 EG_LOGIC_BRAM #(.MODE("SP"),.DATA_WIDTH_A(32),.ADDR_WIDTH_A(8),.DATA_DEPTH_A(256),.REGMODE_A("OUTREG"),.IMPLEMENT("9K(FAST)"),.INIT_FILE("../assets/spectrum/td_init/dft_twiddle_q15_32x256.mif.dath")) xd
 (.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.addra(8'd0),.dia(32'd0),.doa(d));
 EG_LOGIC_BRAM #(.MODE("SP"),.DATA_WIDTH_A(32),.ADDR_WIDTH_A(8),.DATA_DEPTH_A(256),.REGMODE_A("OUTREG"),.IMPLEMENT("9K(FAST)"),.INIT_FILE("../assets/spectrum/td_init/dft_twiddle_q15_32x256.mif")) xm
 (.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.addra(8'd0),.dia(32'd0),.doa(m));
 initial begin #2000;$display("INIT_PROBE hex=%h dath=%h mif=%h",h,d,m);
 if(d!==32'h7fff0000) $fatal(1,"Vendor .dath initialization failed");
 $display("PASS: tb_init_probe");$finish;end
endmodule
