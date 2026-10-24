`timescale 1ns/1ps
module tb_fat32;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,card_ready=1,open_valid=0;
    reg [15:0] open_index=0;
    wire open_ready,catalog_ready,open_done,file_valid,file_last,file_done,mount_done,busy,error;
    wire [15:0] image_count;
    wire [31:0] file_size,load_lba;
    wire [7:0] file_data,error_code;
    reg file_ready=0,load_done=0,buffer_error=0,buf_rd_valid=0;
    wire load_valid,buf_rd_en;
    wire [8:0] buf_rd_addr;
    reg [7:0] buf_rd_data=0;
    reg loading=0;
    wire load_ready=!loading;
    fat32_reader dut(.*);
    bit partitioned=0;
    integer sector=0,load_wait=0,bytes_seen=0,expected_file=0;
    reg [31:0] rng=32'h51a7beef;
    reg stalled=0;
    reg [8:0] held_byte;
    function automatic [7:0] directory_byte(input integer which,offset);
        string name;
        integer cluster,size;
        begin
            name=(which==0) ? "FIRST   BMP" : "SECOND  BMP";
            cluster=(which==0) ? 3 : 6;size=(which==0) ? 700 : 54;
            if(offset<11) directory_byte=name[offset];
            else if(offset==11) directory_byte=8'h20;
            else if(offset>=26 && offset<28) directory_byte=cluster>>((offset-26)*8);
            else if(offset>=28) directory_byte=size>>((offset-28)*8);
            else directory_byte=0;
        end
    endfunction
    function automatic [7:0] sector_byte(input integer lba,offset);
        integer rel,entry,value;
        begin
            rel=lba-(partitioned ? 2048 : 0);sector_byte=0;
            if(partitioned && lba==0) begin
                if(offset==450) sector_byte=8'h0c;
                if(offset>=454 && offset<458) sector_byte=2048>>((offset-454)*8);
                if(offset>=458 && offset<462) sector_byte=70000>>((offset-458)*8);
                if(offset==510) sector_byte=8'h55;
                if(offset==511) sector_byte=8'haa;
            end else if(rel==0) begin
                case(offset)
                    0:sector_byte=8'heb;2:sector_byte=8'h90;
                    12:sector_byte=2;13:sector_byte=1;14:sector_byte=32;16:sector_byte=1;
                    32:sector_byte=8'h70;33:sector_byte=8'h11;34:sector_byte=1;
                    36:sector_byte=8'h26;37:sector_byte=2;44:sector_byte=2;
                    510:sector_byte=8'h55;511:sector_byte=8'haa;
                    default:sector_byte=0;
                endcase
            end else if(rel==32) begin
                entry=offset/4;
                value=(entry==2) ? 5 : (entry==3) ? 9 : 32'h0fffffff;
                sector_byte=value>>((offset%4)*8);
            end else if(rel==582) begin
                if(offset<32) sector_byte=directory_byte(0,offset);
                else if(offset%32==0) sector_byte=8'he5; // No end marker: must follow root FAT chain.
            end else if(rel==585) begin // root cluster 5 (fragmented from cluster 2)
                if(offset<32) sector_byte=directory_byte(1,offset);
            end else if(rel==583) sector_byte=(offset*29+17)&255;
            else if(rel==589) sector_byte=((512+offset)*29+17)&255;
            else if(rel==586) sector_byte=(offset*7+66)&255;
            else $fatal(1,"unexpected sector request LBA=%0d rel=%0d",lba,rel);
        end
    endfunction
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};file_ready=(rng[2:0]!=0);
    end
    always @(posedge clk) begin
        load_done<=0;buf_rd_valid<=0;
        if(!rst_n) begin loading<=0;load_wait<=0;end
        else begin
            if(load_valid && load_ready) begin loading<=1;load_wait<=7;sector<=load_lba;end
            if(loading) begin
                if(load_wait==0) begin loading<=0;load_done<=1;end
                else load_wait<=load_wait-1;
            end
            if(buf_rd_en) begin
                if(loading) $fatal(1,"FAT read before sector load complete");
                buf_rd_valid<=1;buf_rd_data<=sector_byte(sector,buf_rd_addr);
            end
            if(stalled && (file_valid!==1 || {file_last,file_data}!==held_byte)) $fatal(1,"FAT file data changed under backpressure");
            stalled=file_valid&&!file_ready;held_byte={file_last,file_data};
            if(file_valid && file_ready) begin
                if(file_data!==8'((bytes_seen*(expected_file ? 7 : 29)+(expected_file ? 66 : 17))&255))
                    $fatal(1,"FAT file %0d byte=%0d got %h",expected_file,bytes_seen,file_data);
                if(file_last !== (bytes_seen==(expected_file ? 53 : 699))) $fatal(1,"FAT file_last wrong");
                bytes_seen=bytes_seen+1;
            end
        end
    end
    task open_file(input integer index);
        begin
            wait(open_ready);@(negedge clk);open_index=index;open_valid=1;bytes_seen=0;expected_file=index;
            @(negedge clk);open_valid=0;
            wait(file_done || error);@(negedge clk);
            if(error || bytes_seen!=(index ? 54 : 700) || file_size!=(index ? 54 : 700))
                $fatal(1,"FAT open/stream failed index=%0d bytes=%0d size=%0d code=%h",index,bytes_seen,file_size,error_code);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(integer mode=0;mode<2;mode=mode+1) begin
            if(mode==1) begin
                @(negedge clk);rst_n=0;partitioned=1;stalled=0;
                repeat(5) @(negedge clk);rst_n=1;
            end
            wait(catalog_ready || error);@(negedge clk);
            if(error || image_count!=2 || !mount_done) $fatal(1,"FAT catalog/root fragment failed code=%h",error_code);
            open_file(1);open_file(0);
            wait(open_ready);@(negedge clk);open_index=2;open_valid=1;
            @(negedge clk);open_valid=0;wait(error);@(negedge clk);
            if(error_code!=4 || !mount_done) $fatal(1,"FAT out-of-range index handling");
            open_file(1);
        end
        $display("PASS tb_fat32: raw/MBR FAT32, fragmented root and file chains, directory order, backpressure, invalid index recovery");
        $finish;
    end
    initial begin #20000000;$fatal(1,"tb_fat32 timeout state=%0d code=%h",dut.state,error_code);end
endmodule
