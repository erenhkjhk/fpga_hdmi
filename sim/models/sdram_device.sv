`timescale 1ns/1ps
// Functional external storage attached to the real controller's SDRAM pins.
// TD's EG_PHY_SDRAM_2M_32 simulation primitive has no storage behavior.
// Models ACT/PRE/MRS/REF, sequential burst, CAS latency and byte write masks.
// This is not a setup/hold, retention, electrical or speed-grade timing model.
module sdram_device (
    input wire clk,ras_n,cas_n,we_n,
    input wire [10:0] addr,
    input wire [1:0] ba,
    input wire [3:0] dm,
    inout wire [31:0] dq
);
    reg [31:0] memory[0:2097151];
    reg [10:0] row[0:3];
    reg [3:0] opened=0;
    integer burst_length=4,cas_latency=3,cycle=0,refresh_count=0;
    integer write_count=0,read_count=0;
    reg write_single=0;
    integer write_left=0,write_bank=0,write_col=0,write_start=0,write_len=0;
    reg write_autoprecharge=0;
    reg [31:0] read_data;
    reg read_drive=0;
    reg [31:0] scheduled_data[0:31];
    reg [31:0] scheduled_valid=0;
    assign dq=read_drive ? read_data : 32'bz;
    function automatic integer word_address(input integer bank,col);
        word_address=(row[bank]<<10)|(bank<<8)|(col&255);
    endfunction
    task write_word(input integer bank,col);
        integer a;
        begin
            a=word_address(bank,col);
            for(integer b=0;b<4;b=b+1) if(!dm[b]) memory[a][b*8+:8]=dq[b*8+:8];
            write_count=write_count+1;
        end
    endtask
    always @(posedge clk) begin : sdram_cycle
        integer slot,col,a,due;
        cycle=cycle+1;slot=cycle%32;
        read_drive<=#1 scheduled_valid[slot];
        read_data<=#1 scheduled_data[slot];scheduled_valid[slot]=0;
        if(write_left>0) begin
            col=(write_start&~(write_len-1))|((write_col)&(write_len-1));
            write_word(write_bank,col);write_col=write_col+1;write_left=write_left-1;
            if(write_left==0 && write_autoprecharge) opened[write_bank]=0;
        end
        if($test$plusargs("sdram_trace") && {ras_n,cas_n,we_n}!=3'b111)
            $display("SDRAM %t cmd=%b ba=%0d addr=%h dq=%h",$time,{ras_n,cas_n,we_n},ba,addr,dq);
        case({ras_n,cas_n,we_n})
            3'b011: begin row[ba]=addr;opened[ba]=1;end
            3'b010: begin if(addr[10]) opened=0;else opened[ba]=0;end
            3'b000: begin
                if(addr[3]) $fatal(1,"SDRAM model requires sequential burst");
                if(addr[2:0]>3) $fatal(1,"unsupported SDRAM burst mode");
                burst_length=1<<addr[2:0];cas_latency=addr[6:4];write_single=addr[9];
                if(cas_latency<2 || cas_latency>3) $fatal(1,"unsupported CAS latency");
            end
            3'b001: begin
                if(opened!=0) $fatal(1,"SDRAM REF with an open row");
                refresh_count=refresh_count+1;
            end
            3'b100: begin
                if(!opened[ba]) $fatal(1,"SDRAM WRITE without ACT");
                if(read_drive) $fatal(1,"SDRAM bus turnaround collision");
                write_bank=ba;write_start=addr[7:0];write_col=write_start+1;
                write_len=write_single ? 1 : burst_length;
                write_left=write_len-1;write_autoprecharge=addr[10];
                write_word(ba,write_start);
                if(write_left==0 && write_autoprecharge) opened[ba]=0;
            end
            3'b101: begin
                if(!opened[ba]) $fatal(1,"SDRAM READ without ACT");
                for(integer i=0;i<burst_length;i=i+1) begin
                    col=(addr[7:0]&~(burst_length-1))|((addr[7:0]+i)&(burst_length-1));
                    a=word_address(ba,col);due=(cycle+cas_latency+i)%32;
                    if(scheduled_valid[due]) $fatal(1,"SDRAM overlapping read burst");
                    scheduled_data[due]=memory[a];scheduled_valid[due]=1;
                end
                read_count=read_count+burst_length;
                if(addr[10]) opened[ba]=0;
            end
            3'b110: begin write_left=0;end // Burst terminate.
            default: begin end
        endcase
    end
endmodule
