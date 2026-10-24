`timescale 1ns/1ps
module tb_ip_smoke;
    reg clk=0;
    always #10 clk=~clk;
    reg [23:0] di=0;
    reg [11:0] wa=0,ra=0;
    reg we=0;
    wire [23:0] q;
    reg [12:0] addr=0;
    wire [7:0] font;
    wire [15:0] logo;
    reg [7:0] font_ref[0:8191];
    reg [15:0] logo_ref[0:8191];
    ram_scale_line ram(.dia(di),.addra(wa),.clka(clk),.wea(we),.addrb(ra),.clkb(clk),.dob(q));
    rom_osd_font font_rom(.addra(addr),.clka(clk),.doa(font));
    rom_anlogic_logo logo_rom(.addra(addr),.clka(clk),.doa(logo));
    // The vendor simulator reads HEX only when the suffix is .dath. Keep the
    // generated hardware wrappers/MIF unchanged; select their existing DATH.
    defparam font_rom.inst.INIT_FILE="../assets/osd/td_init/osd_font_8x8192.mif.dath";
    defparam logo_rom.inst.INIT_FILE="../assets/osd/td_init/anlogic_logo_argb4444.mif.dath";
    integer i;
    initial begin
        $readmemh("../assets/osd/osd_font_8x8192.hex",font_ref);
        $readmemh("../assets/osd/anlogic_logo_argb4444.hex",logo_ref);
        repeat(4) @(negedge clk);
        di=24'h123456;wa=4095;we=1;
        @(negedge clk);we=0;ra=4095;
        @(negedge clk);
        if(q !== 24'h123456) $fatal(1,"line RAM synchronous read failed: %h",q);
        for(i=0;i<8192;i=i+1) begin
            addr=i;
            @(negedge clk);
            if(font !== font_ref[i]) $fatal(1,"font ROM mismatch at %0d: %h != %h",i,font,font_ref[i]);
            if(logo !== logo_ref[i]) $fatal(1,"logo ROM mismatch at %0d: %h != %h",i,logo,logo_ref[i]);
        end
        $display("PASS tb_ip_smoke: real vendor RAM read and all 8192 font/logo words");
        $finish;
    end
    initial begin #1000000; $fatal(1,"tb_ip_smoke timeout"); end
endmodule
