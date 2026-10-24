// 学习用 SDHC/SDXC SPI 单块读写控制器，Verilog-2001。
// 请求地址是 512 字节扇区号。无文件系统、无多块命令、无内部扇区 RAM。
// reset 后自动初始化；任何错误均锁定，需复位后重新初始化。
module sd_spi_card #(
    parameter integer CLK_HZ          = 50000000,
    parameter integer INIT_SPI_HZ     = 250000,
    parameter integer DATA_SPI_HZ     = 5000000,
    parameter integer POWER_WAIT_MS   = 20,    //初始化上电20ms
    parameter integer INIT_MAX_TRIES  = 4096,  //CMD55+ACMD41命令组合轮询检查初始化状态的超时次数上限
    parameter integer READY_MAX_BYTES = 32768, //确认sd可以正常接收命令的，即发送命令前发送FF，直到收到FF的计数器
    parameter integer TOKEN_MAX_BYTES = 262144, //读命令CMD17轮询读取读token的超时计数上限
    parameter integer BUSY_MAX_BYTES  = 1048576 //写命令轮询写忙状态的超时计数上限
) (
    input  wire        clk,
    input  wire        rst_n,

    // req_valid && req_ready 在 clk 上升沿同时为 1，接收一次请求。
    input  wire        req_valid,      //上级读写请求的有效标志
    output wire        req_ready,      //可以接收上级的读写请求准备标志
    input  wire        req_write,      // 0=读，1=写
    input  wire [31:0] req_lba,        // 扇区号，不是字节地址

    // 写数据：每个 w_valid && w_ready 上升沿接收一个字节，共 512 次。
    input  wire [7:0]  w_data,
    input  wire        w_valid,
    output wire        w_ready,

    // 读数据：r_valid=1 且 r_ready=0 时，数据和 last 保持不变。
    output reg  [7:0]  r_data,
    output wire        r_valid,
    input  wire        r_ready,
    output wire        r_last,

    output reg         init_done,      //初始化完成后拉高
    output wire        busy,
    output reg         done,           // 一次读/写成功完成时，脉冲一个 clk
    output reg         error,          // 粘滞错误标志，复位清除
    output reg  [7:0]  error_code,

    output reg         sd_cs_n,        //片选信号由控制层直接通入SD卡
    output wire        sd_sck,         
    output wire        sd_mosi,
    input  wire        sd_miso
);
    // 向上取整，确保生成的 SCK 不高于参数目标值。
    // 使用条件：目标频率>0，分频结果在 1..65535，POWER_CYCLES>=1。
    localparam integer INIT_DIV = (CLK_HZ + 2*INIT_SPI_HZ - 1)
                                  / (2*INIT_SPI_HZ);
    localparam integer DATA_DIV = (CLK_HZ + 2*DATA_SPI_HZ - 1)
                                  / (2*DATA_SPI_HZ);
    localparam integer POWER_CYCLES = (CLK_HZ / 1000) * POWER_WAIT_MS;
    wire [15:0] half_div = init_done ? DATA_DIV : INIT_DIV;

    localparam [7:0]
        //初始化相关状态
        S_POWER=0, S_CLOCKS=1, S_CLOCKS_CHECK=2,
        S_CMD0=3, S_CMD0_REPLY=4, S_CMD8=5, S_CMD8_REPLY=6,
        S_CMD55=7, S_CMD55_REPLY=8, S_ACMD41=9, S_ACMD41_REPLY=10,
        S_CMD58=11, S_CMD58_REPLY=12, S_CMD59=13, S_CMD59_REPLY=14,
        S_INIT_FINISH=15, 
        //空闲和读写接收命令reg接收
        S_IDLE=16, S_OP_REPLY=17,
        //写扇区相关状态
        S_READ_TOKEN=18, S_READ_TOKEN_CHECK=19,
        S_READ_DATA=20, S_READ_HAVE=21, S_READ_DELIVER=22,
        S_READ_CRC1=23, S_READ_CRC2=24, S_READ_FINISH=25,
        //读扇区相关状态
        S_WRITE_TOKEN=26, S_WRITE_FETCH=27, S_WRITE_SENT=28,
        S_WRITE_CRC1=29, S_WRITE_CRC2=30,
        S_WRITE_RESP=31, S_WRITE_RESP_CHECK=32,
        S_WRITE_BUSY=33, S_WRITE_BUSY_CHECK=34,
        S_WRITE_STATUS=35, S_WRITE_STATUS_REPLY=36,
        //共用的读写操作结束和错误状态
        S_OP_DONE=37, S_ERROR=38,
        //共用的字节和命令发送
        S_BYTE_START=40, S_BYTE_WAIT=41,
        S_CMD_SELECT=42, S_CMD_READY=43, S_CMD_WAIT=44;

    reg [7:0]  state;
    reg [7:0]  after_byte;
    reg [7:0]  after_cmd;
    reg [31:0] power_count;//上电初始化20ms计数寄存器
    reg [3:0]  clock_bytes;
    reg [31:0] init_tries;
    reg [31:0] poll_count;
    reg [8:0]  byte_index;
    reg        op_write;

    // main_*：控制层直接交换字节；cmd_*：命令层交换字节。
    
    //控制层-master层 交换字节和启动spi_byte_master
    reg        main_start;
    reg [7:0]  main_tx;
    //命令层-master层 交换字节和启动spi_byte_master
    wire       cmd_byte_start;
    wire [7:0] cmd_byte_tx;
    //控制层和命令层共用接收sd_spi_master的总线
    wire [7:0] byte_rx;
    wire       byte_busy;
    wire       byte_done;
    wire       cmd_owns_bus = (state == S_CMD_WAIT);
    
//cmd_*命令相关信号，全部都有接入到sd_spi_cmd u_sd_cmd，专门负责命令字节的发送和命令响应的接收
    reg        cmd_start;
    reg [5:0]  cmd_index;
    reg [31:0] cmd_arg;
    reg [7:0]  cmd_crc;
    reg [2:0]  cmd_extra_len;
    wire       cmd_done;
    wire       cmd_timeout;//接收r1
    wire [7:0] cmd_r1; //r1字节
    wire [31:0] cmd_extra; // 响应扩展字节

    assign req_ready = (state == S_IDLE) && init_done && !error;
    assign busy      = !req_ready;
    assign w_ready   = (state == S_WRITE_FETCH);
    assign r_valid   = (state == S_READ_DELIVER);
    assign r_last    = r_valid && (byte_index == 9'd511);

    spi_byte_master u_spi_byte (
        .clk(clk), .rst_n(rst_n), .half_div(half_div),
        //spi_byte_master作为一个字节收发机，根据当前的总线归属权cmd_owns_bus，决定start应该由sd_spi_card用来收发数据字节触发，还是由sd_spi_cmd用来传输命令字节触发
        .start(cmd_owns_bus ? cmd_byte_start : main_start),
        //根据总线的归属，决定当前 传输的是命令字节cmd_byte_tx，还是数据字节main_tx
        .tx_data(cmd_owns_bus ? cmd_byte_tx : main_tx),
        
        .rx_data(byte_rx), .busy(byte_busy), .done(byte_done),
        
        .spi_sck(sd_sck), .spi_mosi(sd_mosi), .spi_miso(sd_miso)
    );

    sd_spi_cmd u_sd_cmd (
        .clk(clk), .rst_n(rst_n), .start(cmd_start),
        .cmd_index(cmd_index), .cmd_arg(cmd_arg), .cmd_crc(cmd_crc),
        .extra_len(cmd_extra_len), .done(cmd_done), .timeout(cmd_timeout),
        .r1(cmd_r1), .extra(cmd_extra),
        //sd_spi_cmd 与下层 spi_byte_master接口
        .byte_start(cmd_byte_start), .byte_tx(cmd_byte_tx),
        .byte_rx(byte_rx), .byte_busy(byte_busy), .byte_done(byte_done)
    );

    // 以下 task 只展开为寄存器赋值，不包含等待、延时或软件式子程序。
    // 真正的等待由 S_BYTE_START/S_BYTE_WAIT 等状态完成。
    
    //由控制层驱动spi_master进行的一次字节收发
    //exchange_byte自己的流程里面是不包含拉低片选cs的，单纯给出sck，mosi，接收miso而已
    task exchange_byte;
        input [7:0] value;
        input [7:0] next_state;
        begin
            main_tx    <= value;//更新将要通过spi_master传输的字节
            after_byte <= next_state;//寄存在完成这一次字节传输之后的下一个状态
            state      <= S_BYTE_START;//进入公用的传输字节状态
        end
    endtask
    //由控制层驱动sd_spi_cmd进行一次命令的发送
    //总体效果：拉高片选，发送命令，接收响应（响应的正确检查以及片选的拉高都交给之后的流程，不会由issue_command及其后续状态来做）
    task issue_command;
        input [5:0] index;
        input [31:0] argument;
        input [7:0] crc_byte;
        input [2:0] response_bytes;
        input [7:0] next_state;
        begin
            cmd_index     <= index;//命令头
            cmd_arg       <= argument;//命令参数
            cmd_crc       <= crc_byte;//CRC校验
            cmd_extra_len <= response_bytes;//期望收到除了r1响应字节以外，额外的字节数
            after_cmd     <= next_state;//
            poll_count    <= 32'd0;
            state         <= S_CMD_SELECT;//
        end
    endtask
  //拉高片选，并且摇动8个周期的时钟，最后返回所指定的状态
    task release_card;
        input [7:0] next_state;
        begin
            sd_cs_n <= 1'b1;
            // 取消片选后再发送 8 个时钟，MOSI 保持为 1。
            exchange_byte(8'hFF, next_state);
        end
    endtask
    //拉高错误标志，并且输出错误码，将初始化完成标志取消
    task fail;
        input [7:0] code;
        begin
            error      <= 1'b1;
            error_code <= code;
            init_done  <= 1'b0;
            release_card(S_ERROR);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_POWER;
            after_byte    <= S_POWER;
            after_cmd     <= S_POWER;
            
            power_count   <= 32'd0;    //上电初始化20ms计数寄存器
            clock_bytes   <= 4'd0;     
            init_tries    <= 32'd0;    //CMD55+ACMD41组合轮询检查初始化次数
            poll_count    <= 32'd0;
            byte_index    <= 9'd0;    
            op_write      <= 1'b0;
            main_start    <= 1'b0;    
            main_tx       <= 8'hFF;
            //
            cmd_start     <= 1'b0;
            cmd_index     <= 6'd0;
            cmd_arg       <= 32'd0;
            cmd_crc       <= 8'h01;
            cmd_extra_len <= 3'd0;
            
            r_data        <= 8'd0;
            sd_cs_n       <= 1'b1;
            init_done     <= 1'b0;
            done          <= 1'b0;
            error         <= 1'b0;
            error_code    <= 8'h00;
        end else begin
            main_start <= 1'b0;//控制层直接启动sd_spi_byte_master
            cmd_start  <= 1'b0;//控制层启动sd_spi_cmd
            done       <= 1'b0;//一次读写完成信号，传递给控制层上层

            case (state)
                // ---------- 上电及初始化 ----------
                S_POWER: begin
                    if (power_count == POWER_CYCLES - 1)
                    //power_count == POWER_CYCLES - 1，即达到上电计数的20ms实践，进入提供80个时钟状态
                        state <= S_CLOCKS;
                    else
                        power_count <= power_count + 1'b1;
                end

                S_CLOCKS: exchange_byte(8'hFF, S_CLOCKS_CHECK);
                S_CLOCKS_CHECK: begin
                    // CS=1、MOSI=1，共发送 10*8=80 个时钟。
                    if (clock_bytes == 4'd9)
                    //clock_bytes == 4'd9，每次进入判断的时候，采样值是除去最近一次传输的已传输次数
                        state <= S_CMD0;
                    else begin
                        clock_bytes <= clock_bytes + 1'b1;
                        state <= S_CLOCKS;
                    end
                end

                S_CMD0: issue_command(6'd0, 32'd0, 8'h95, 3'd0, S_CMD0_REPLY);
                S_CMD0_REPLY: begin
                    if (cmd_r1 == 8'h01) release_card(S_CMD8);
                    else fail(8'h02);
                end
                //issue_command的第四个参数extra_len为4表明CMD8命令的响应除了r1字节还有4个额外的扩展字节
                S_CMD8: issue_command(6'd8, 32'h000001AA, 8'h87, 3'd4, S_CMD8_REPLY);
                //若发送的参数是 0x000001AA（CRC 0x87），常见 SD v2 及以上卡通常返回01 00 00 01 AA
                S_CMD8_REPLY: begin
                    if ((cmd_r1 == 8'h01) && (cmd_extra[11:0] == 12'h1AA))
                        release_card(S_CMD55);
                    else fail(8'h03);
                end

                S_CMD55: issue_command(6'd55, 32'd0, 8'h01, 3'd0, S_CMD55_REPLY);
                S_CMD55_REPLY: begin
                    if ((cmd_r1 == 8'h01) || (cmd_r1 == 8'h00))
                        release_card(S_ACMD41);
                    else fail(8'h04);
                end

                S_ACMD41: issue_command(6'd41, 32'h40000000, 8'h01, 3'd0, S_ACMD41_REPLY);
                S_ACMD41_REPLY: begin
                    if (cmd_r1 == 8'h00) begin
                        release_card(S_CMD58);
                    end else if ((cmd_r1 == 8'h01) && (init_tries < INIT_MAX_TRIES - 1)) begin
                    //cmd_r1 ==8'h01成立则说明sd卡还没有进入空闲模式 ，并且初始化尝试次数还有达到设定上限
                        init_tries <= init_tries + 1'b1;
                        release_card(S_CMD55); // 每次 ACMD41 前都重新发 CMD55
                    end else fail(8'h05);
                end

                S_CMD58: issue_command(6'd58, 32'd0, 8'h01, 3'd4, S_CMD58_REPLY);
                 /*发送 `7A 00 00 00 00 01`，收到R1及4字节OCR。当前实现分两级判断：
                  1. R1必须为00，OCR bit31必须为1，否则报06。
                  2. OCR bit30（CCS）必须为1，否则报07，拒绝进入后续扇区读写。
                  这一步落实了本模块“仅支持高容量块寻址卡”的范围。它只做上述位检查，没有进一步读取容量或检查所有OCR字段，因此不能把通过CMD58理解为卡的所有能力均已确认。*/
                S_CMD58_REPLY: begin
                    if ((cmd_r1 != 8'h00) || !cmd_extra[31]
                        fail(8'h06);
                    else if (!cmd_extra[30])
                        fail(8'h07); // CCS=0：SDSC 不在本教学例子的范围内
                    else release_card(S_CMD59);
                end

                // SPI 模式下明确关闭 CRC 校验；保留协议要求的 CRC 字节位置。
                S_CMD59: issue_command(6'd59, 32'd0, 8'h01, 3'd0, S_CMD59_REPLY);
                S_CMD59_REPLY: begin
                    if (cmd_r1 == 8'h00) release_card(S_INIT_FINISH);
                    else fail(8'h08);
                end

                S_INIT_FINISH: begin
                    init_done <= 1'b1; // 下一个字节才使用较快的分频参数
                    state <= S_IDLE;
                end

                // ---------- 接收一次扇区请求 ----------
                S_IDLE: if (req_valid && req_ready) begin
                //assign req_ready = (state == S_IDLE) && init_done && !error;
                    op_write   <= req_write;
                    byte_index <= 9'd0;
                    issue_command(req_write ? 6'd24 : 6'd17,
                                  req_lba, 8'h01, 3'd0, S_OP_REPLY);
                end

                S_OP_REPLY: begin
                    poll_count <= 32'd0;//这一次的超时计数器清零主要是为了计数读命令轮询读取读 token的超时计数
                    if (cmd_r1 != 8'h00) fail(8'h10);//读写命令后不需要马上拉高cs，不像前面的初始化命令
                    else if (op_write)
                        exchange_byte(8'hFF, S_WRITE_TOKEN); // 命令响应和数据间的时钟
                    else state <= S_READ_TOKEN;
                    // 这里不释放 CS，后续数据属于同一次事务。
                end

                // ---------- CMD17 单块读 ----------
                S_READ_TOKEN: exchange_byte(8'hFF, S_READ_TOKEN_CHECK);
                S_READ_TOKEN_CHECK: begin
                  //通过FF轮询收到的字节 为 读token FE
                    if (byte_rx == 8'hFE) begin
                        state <= S_READ_DATA;
                  //通过FF轮询收到的字节 不为 读token FE && 收到的字节 非 填充字节FF
                    end else if (byte_rx != 8'hFF) begin
                        fail(8'h12); // 非填充字节且非起始令牌
                  //通过FF轮询收到的字节 不为 读token FE && 收到的字节 是 填充字节FF && 超时计数poll_count 已 达到上限TOKEN_MAX_BYTES
                    end else if (poll_count == TOKEN_MAX_BYTES - 1) begin
                        fail(8'h11);
                  //通过FF轮询收到的字节 不为 读token FE && 收到的字节 是 填充字节FF && 超时计数poll_count 未 达到上限TOKEN_MAX_BYTES
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        state <= S_READ_TOKEN;//返回上一个状态继续发送FF去轮询接收令牌token
                    end
                end

                S_READ_DATA: exchange_byte(8'hFF, S_READ_HAVE);//exchange_byte的任务发送一个字节，至于接收到的字节怎么处理交给，其第二个参数的状态
                S_READ_HAVE: begin
                    r_data <= byte_rx;
                    state <= S_READ_DELIVER;
                end
                S_READ_DELIVER: if (r_ready) begin
                    // r_valid 由本状态产生；未握手时暂停 SCK 并保持数据。
                    //    assign r_valid   = (state == S_READ_DELIVER);也就是说进入该状态之后，马上就会拉高r_valid信号，向上层表示我有数据可以传输，并且要保持住，一直等到上层接收走当前的数据，也就是去采样上层ready信号，然后才去继续传输下一个数据
                    //    assign r_last    = r_valid && (byte_index == 9'd511);
                    if (byte_index == 9'd511)
                        state <= S_READ_CRC1;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= S_READ_DATA;
                    end
                end

                S_READ_CRC1: exchange_byte(8'hFF, S_READ_CRC2);//这里读完一个扇区之后，发送FF，而SD卡则会发送CRC1和CRC2，但是这些数据是无用的，因为我们SPI模式不需要CRC
                S_READ_CRC2: exchange_byte(8'hFF, S_READ_FINISH);//因此就算接收了CRC字节我们不做任何处理直接丢弃
                S_READ_FINISH: release_card(S_OP_DONE);

                // ---------- CMD24 单块写 ----------
                S_WRITE_TOKEN: exchange_byte(8'hFE, S_WRITE_FETCH);//发送写token
                S_WRITE_FETCH: if (w_valid) begin
                    // w_ready 由本状态产生；本上升沿把 w_data 保存到 main_tx。
                    //每次进入 S_WRITE_FETCH都瞬间把w_ready拉高
                    //    assign w_ready   = (state == S_WRITE_FETCH);
                    exchange_byte(w_data, S_WRITE_SENT);
                end
                S_WRITE_SENT: begin
                    if (byte_index == 9'd511)
                        state <= S_WRITE_CRC1;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= S_WRITE_FETCH;
                    end
                end
                
                //连续发送两个FF的CRC1和CRC2
                S_WRITE_CRC1: exchange_byte(8'hFF, S_WRITE_CRC2);
                S_WRITE_CRC2: begin
                    poll_count <= 32'd0;//这一次的超时计数器放在S_WRITE_RESP去清零更好
                    exchange_byte(8'hFF, S_WRITE_RESP);
                end
                //读取数据响应令牌目标是接收到05
                S_WRITE_RESP: exchange_byte(8'hFF, S_WRITE_RESP_CHECK);
                S_WRITE_RESP_CHECK: begin
                //接收到FF不视为数据接受
                    if (byte_rx == 8'hFF) begin
                        if (poll_count == TOKEN_MAX_BYTES - 1)
                            fail(8'h13);
                        else begin
                            poll_count <= poll_count + 1'b1;
                            state <= S_WRITE_RESP;
                        end
                        //读取到SD接受数据成功的05将进入写忙阶段，等待数据写入
                    end else if (byte_rx[4:0] == 5'b00101) begin
                        poll_count <= 32'd0;
                        state <= S_WRITE_BUSY;
                    end else fail(8'h14);
                end
                //写忙阶段：等待卡退出忙状态：继续发送 0xFF 并读取 MISO，期间卡通常回 0x00；读到 0xFF 表示卡就绪。应设置超时，避免无限等待。
                S_WRITE_BUSY: exchange_byte(8'hFF, S_WRITE_BUSY_CHECK);
                S_WRITE_BUSY_CHECK: begin
                      //成功接收到FF
                    if (byte_rx == 8'hFF) begin
                        release_card(S_WRITE_STATUS);//拉高片选，摇动8个时钟周期
                        //没有接受到FF && 达到超时上限
                    end else if (poll_count == BUSY_MAX_BYTES - 1) begin
                        fail(8'h15);
                        //没有接受到FF && 未到超时上限
                    end else begin
                        poll_count <= poll_count + 1'b1;
                        state <= S_WRITE_BUSY;
                    end
                end

                // CMD13 的 SPI 响应为 R2：R1 + 一个状态字节。
                S_WRITE_STATUS: issue_command(6'd13, 32'd0, 8'h01, 3'd1, S_WRITE_STATUS_REPLY);
                S_WRITE_STATUS_REPLY: begin
                    if ((cmd_r1 == 8'h00) && (cmd_extra[7:0] == 8'h00))
                        release_card(S_OP_DONE);
                    else fail(8'h16);
                end

                S_OP_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                S_ERROR: state <= S_ERROR;

                // ---------- 共用的字节交换和命令调用 ----------
                S_BYTE_START: if (!byte_busy) begin
                    main_start <= 1'b1;
                    state <= S_BYTE_WAIT;
                end
                S_BYTE_WAIT: if (byte_done) state <= after_byte;//注意这里仅仅只是收到字节就进入指定好的状态，不会在这里对收到的字节进行处理。如果关心这个字节，就要在after_byte中进行处理

                S_CMD_SELECT: begin
                    sd_cs_n <= 1'b0;//拉低片选
                    exchange_byte(8'hFF, S_CMD_READY);//总体效果是发送8个时钟，之后进入S_CMD_READY
                end
                //S_CMD_READY的主要意图是，发送FF然后目标接收到一个FF从而确认SD卡处于正常可以接收的状态，但为什么这可以确认正常呢？
                S_CMD_READY: begin
                    if (byte_rx == 8'hFF) begin
                    //顺利收到一个FF字节，可以启动命令的发送，并且进入等待S_CMD_WAIT
                        cmd_start <= 1'b1;//控制层驱动命令层的一次启动line126，意味着正式开始发送命令
                        state <= S_CMD_WAIT;
                    end else if (poll_count == READY_MAX_BYTES - 1) begin
                    //没有成功收到一个FF字节，并且达到超时上限，进入错误17
                        fail(8'h17);
                    end else begin
                    //没有成功收到一个FF字节，但是还未达到超时上限，继续发送FF
                        poll_count <= poll_count + 1'b1;
                        exchange_byte(8'hFF, S_CMD_READY);
                    end
                end
                //S_CMD_WAIT的意图是接收命令发送结束的cmd_done标志（脉冲），同时与cmd_done 同一个周期送来的还有本次所发送命令的响应r1和扩展部分。
                //r1和扩展部分需要进入在进入task前就设置好的after_cmd状态进行进一步的检查和判断
                S_CMD_WAIT: if (cmd_done) begin
                    if (cmd_timeout) fail(8'h01);//命令层接收r1超时标志，如果超时，则是和cmd_done信号同时拉高一个周期，超时进入错误01
                    else state <= after_cmd;//整个issue_cmd task正常收尾，进入指定的响应检查状态
                end

                default: fail(8'hFF);
            endcase
        end
    end
endmodule
