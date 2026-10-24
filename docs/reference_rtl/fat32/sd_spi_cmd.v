// 命令层：发送 6 字节命令，等待 R1，再接收可选的 1 或 4 字节。
// 不控制 CS，不处理数据块；调用者必须在整个命令期间保持 CS=0。
module sd_spi_cmd #(
    parameter integer R1_MAX_BYTES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [5:0]  cmd_index,
    input  wire [31:0] cmd_arg,     //命令的4字节参数
    input  wire [7:0]  cmd_crc,    // CRC7 和结束位组成的完整末字节
    input  wire [2:0]  extra_len,  // 0=R1，1=R2，4=R3/R7
    output reg         done,
    output reg         timeout,    //接收r1超时的标志
    //响应字节
    output reg  [7:0]  r1,
    output reg  [31:0] extra,
    //下层spi_byte_master接口
    output reg         byte_start,
    output reg  [7:0]  byte_tx,
    input  wire [7:0]  byte_rx,
    input  wire        byte_busy,
    input  wire        byte_done
);
    localparam [2:0] IDLE=0, SEND=1, SEND_WAIT=2,
                     R1_SEND=3, R1_WAIT=4, EXTRA_SEND=5, EXTRA_WAIT=6;
    reg [2:0]  state;
    reg [47:0] packet; //本次启动要发送的命令，48bit，把8bit命令头，32bit参数，8bit CRC合并
    reg [2:0]  sent_count; //发送命令字节的计数器，记录6个字节
    reg [2:0]  extra_left;//本次命令需要接收除了r1以外几个额外响应字节锁存
    reg [31:0] poll_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            packet      <= 48'd0;
            sent_count  <= 3'd0;
            extra_left  <= 3'd0;
            poll_count  <= 32'd0;
            byte_start  <= 1'b0;
            byte_tx     <= 8'hFF;
            done        <= 1'b0;
            timeout     <= 1'b0;//接收r1超时标志，
            r1          <= 8'hFF;
            extra       <= 32'd0;
        end else begin
            byte_start <= 1'b0;
            done       <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    packet     <= {2'b01, cmd_index, cmd_arg, cmd_crc};
                    sent_count <= 3'd0;//在发送命令的时候，标注当前已经发送了多少个字节了，发送6个字节后就重置为0
                    extra_left <= extra_len;//记录本次的命令在发送后接收响应时除了接收r1字节外，还要接收几个字节
                    poll_count <= 32'd0;
                    r1         <= 8'hFF;
                    extra      <= 32'd0;
                    timeout    <= 1'b0;
                    state      <= SEND;
                end

                SEND: if (!byte_busy) begin
                    byte_tx    <= packet[47:40];
                    byte_start <= 1'b1;
                    state      <= SEND_WAIT;
                end

                SEND_WAIT: if (byte_done) begin
                    packet <= {packet[39:0], 8'hFF};
                    if (sent_count == 3'd5)
                        state <= R1_SEND;
                    else begin
                        sent_count <= sent_count + 1'b1;
                        state <= SEND;
                    end
                end

                R1_SEND: if (!byte_busy) begin
                    byte_tx    <= 8'hFF; // 读 MISO 也必须主动发送时钟
                    byte_start <= 1'b1;
                    state      <= R1_WAIT;
                end

                R1_WAIT: if (byte_done) begin
                //byte_rx[7] = 0，即接收到有效的r1了
                    if (!byte_rx[7]) begin
                        r1 <= byte_rx;//r1响应在被赋值之后，直到下一次命令层接收到启动信号start之前都不会改变
                        
                        if ((extra_left == 0) || (byte_rx[6:1] != 0)) begin
                        //（extra_left == 0）= 0 ，（byte_rx[6:1] != 0）= 1 r1没扩展，但有错误
                        //（extra_left == 0）= 1 ，（byte_rx[6:1] != 0）= 0 r1有扩展，虽然没错误
                        //（extra_left == 0）= 1 ，（byte_rx[6:1] != 0）= 1 r1有扩展，但有错误
                            done  <= 1'b1;
                            state <= IDLE;
                        end else begin
                        //r1有扩展并且没有错误，进入扩展字节的收发状态
                            state <= EXTRA_SEND;
                        end
                    end else if (poll_count == R1_MAX_BYTES - 1) begin
                    //byte_rx[7] = 1，poll_count == R1_MAX_BYTES - 1，即未接收到有效的r1，但是  达到了接收r1的超时次数
                        timeout <= 1'b1;//接收r1超时的标志
                        done    <= 1'b1;//本次发送命令完成
                        state   <= IDLE;
                    end else begin
                    //byte_rx[7] = 1，poll_count ！= R1_MAX_BYTES - 1，即未接收到有效的r1，但是也还未达到接收r1的超时次数
                        poll_count <= poll_count + 1'b
                        state <= R1_SEND;
                    end
                end

                EXTRA_SEND: if (!byte_busy) begin
                    byte_tx    <= 8'hFF;
                    byte_start <= 1'b1;
                    state      <= EXTRA_WAIT;
                end

                EXTRA_WAIT: if (byte_done) begin
                    extra <= {extra[23:0], byte_rx};//extra是暴露给上层控制层的接口，在被赋值之后，直到下一次命令层接收到start启动信号之前都不会改变
                    if (extra_left == 1) begin
                    //extra_left == 1 --> 在已经剩余一个扩展字节的时候，再次收到clk上升沿，则刚好收到了所需要的所有扩展字节
                        done  <= 1'b1;
                        state <= IDLE;
                    end else begin
                        extra_left <= extra_left - 1'b1;
                        state <= EXTRA_SEND;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
