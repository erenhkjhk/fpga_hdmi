`timescale 1ns/1ps
// Read-only SDHC stimulus, SPI mode 0; models initialization and CMD17.
module sd_card_spi(input wire cs_n,sck,mosi,input wire reject_read,output reg miso=1);
    reg [7:0] rx=0,tx=8'hff,packet[0:5],reply[0:2047];
    integer bit_count=0,packet_count=0,head=0,tail=0,acmd41_count=0,commands=0;
    bit idle=1;
    task enqueue(input reg [7:0] value);begin reply[tail]=value;tail=tail+1;end endtask
    task command_received;
        integer command_id;
        reg [31:0] argument;
        begin
            command_id=packet[0]&63;argument={packet[1],packet[2],packet[3],packet[4]};commands=commands+1;
            if(!packet[5][0]) $fatal(1,"SD command lacks end bit");
            case(command_id)
                0: begin
                    if(packet[5]!=8'h95) $fatal(1,"CMD0 CRC");idle=1;enqueue(1);
                end
                8: begin
                    if(argument!=32'h1aa || packet[5]!=8'h87) $fatal(1,"CMD8 argument/CRC");
                    enqueue(1);enqueue(0);enqueue(0);enqueue(1);enqueue(8'haa);
                end
                55: enqueue(idle ? 1 : 0);
                41: begin
                    if(!argument[30]) $fatal(1,"ACMD41 must request SDHC");
                    acmd41_count=acmd41_count+1;if(acmd41_count>=2) idle=0;enqueue(idle ? 1 : 0);
                end
                58: begin enqueue(0);enqueue(8'hc0);enqueue(8'hff);enqueue(8'h80);enqueue(0);end
                59: enqueue(0);
                17: begin
                    if(argument!=32'h1234) $fatal(1,"SDHC block addressing wrong: %h",argument);
                    if(reject_read) enqueue(4);
                    else begin
                        enqueue(0);enqueue(8'hff);enqueue(8'hff);enqueue(8'hfe);
                        for(integer i=0;i<512;i=i+1) enqueue((i*13+8'h34)&255);
                        enqueue(8'h12);enqueue(8'h34);
                    end
                end
                default:$fatal(1,"unexpected SD command %0d",command_id);
            endcase
        end
    endtask
    always @(posedge cs_n) begin miso=1;bit_count=0;packet_count=0;head=0;tail=0;tx=8'hff;end
    always @(posedge sck) if(!cs_n) begin
        rx={rx[6:0],mosi};bit_count=bit_count+1;
        if(bit_count==8) begin
            bit_count=0;
            if(packet_count!=0 || rx[7:6]==2'b01) begin
                packet[packet_count]=rx;packet_count=packet_count+1;
                if(packet_count==6) begin packet_count=0;command_received();end
            end
        end
    end
    always @(negedge sck) if(!cs_n) begin
        if(bit_count==0) begin
            if(head<tail) begin tx=reply[head];head=head+1;end
            else tx=8'hff;
        end
        miso=tx[7-bit_count];
    end
endmodule
