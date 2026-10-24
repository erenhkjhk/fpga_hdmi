// ============================================================================
// 512 字节扇区缓存：连接现有 sd_spi_card 与 FAT32 控制器。
//
// 一次加载的过程：
//   load_valid && load_ready -> 提交 SD 读请求 -> 收满 512 字节
//   -> 等 SD 层 done（此时 CRC 字节和片选收尾已结束）-> load_done。
//
// 缓存采用同步读：发出 rd_en/rd_addr 后，rd_valid 和 rd_data 一起返回。
// 加载新扇区会覆盖旧扇区，调用者必须先用完旧内容再发起下一次加载。
// 不清零 RAM 数组；buf_valid=0 时禁止使用其中的数据，方便推断块 RAM。
// 本模块只产生读请求，读写方向由集成顶层固定为 req_write=0。
// ============================================================================
//本模块接收上层加载一个扇区的请求，驱动下层得到扇区的512字节流输入，并存储在RAM中，供给上层读取RAM
module sd_sector_buffer (
    input  wire        clk,
    input  wire        rst_n,
    //与上层连接信号
    /*`load_valid && load_ready` 在时钟上升沿同时为1才接受请求。
    该沿锁存LBA、清接收计数、清 `buf_valid`，开始新的一次加载。*/
    /*`buf_valid` 是保持状态，`load_done` 是事件脉冲。
     完成之后 `load_done` 下一拍清零，但 `buf_valid` 保持1，直到下一次加载、复位或相关错误使它失效。*/
    input  wire        load_valid,    //上层请求加载一个扇区，需要保持到与load_ready握手
    output wire        load_ready,    //当前空闲且无错误，可以接受请求
    input  wire [31:0] load_lba,
    output reg         load_done,      //成功加载后的单周期脉冲
    output reg         error,          //本次加载扇区产生了错误的标志
    output reg  [7:0]  error_code, // 01=SD 层错误，02=字节数或 last 异常
    output reg         buf_valid,  //表明RAM里有一份已完成加载的有效扇区的标志
    //
    input  wire        rd_en,
    input  wire [8:0]  rd_addr,
    output reg  [7:0]  rd_data,
    output reg         rd_valid,
    //与下层sd_spi_card的读写请求"数据流"
    output wire        sd_req_valid,  //连接sd_spi_card，一次读写请求的有效信号，也可以看作是
    input  wire        sd_req_ready,  //连接下层的sd_spi_card，拉高说明下层可以接收请求了
    output reg  [31:0] sd_req_lba,    //想要读写的逻辑扇区号LBA
    //与下层sd_spi_card连接，接收512字节也就是一个扇区的字节流
    input  wire [7:0]  sd_r_data,
    input  wire        sd_r_valid,
    output wire        sd_r_ready,
    input  wire        sd_r_last,
    //与下层的sd_spi_card连接，接收完成和错误
    input  wire        sd_done,  //这是完成一次读取扇区之后收到的一个周期的脉冲信号
    input  wire        sd_error  //下层上报的错误标志
);
    localparam [1:0] S_IDLE=0, S_REQUEST=1, S_RECEIVE=2, S_ERROR=3;
    reg [1:0] state;
    reg [9:0] receive_count; // 要能表示“已经收到 512 字节”，不能只用 9 位
    reg [7:0] memory [0:511];//8位宽，512个存储单元的RAM

    wire receive_byte = sd_r_valid && sd_r_ready;    //与下层sd_spi_card传输字节的握手成功标志
    //因此需同时满足：缓存有效、控制器空闲、没有新加载请求、没有错误。尤其是 `!load_valid` 表示**新加载优先于读取旧缓存**。同一沿同时提出load与rd请求时，会接受加载，而不会为这次rd请求产生有效返回。
    wire read_enable = rd_en && buf_valid && (state == S_IDLE)
                       && !load_valid && !sd_error && !error;

    assign load_ready   = (state == S_IDLE) && !error && !sd_error;  //错误传递，本层和下层的错误发生时，不能准备接收上层的请求
    assign sd_req_valid = (state == S_REQUEST) && !sd_error;  //当下层发生错误，不能对下层进行请求
    assign sd_r_ready   = (state == S_RECEIVE) && (receive_count < 10'd512)
                          && !sd_error;//下层错误发生时，不能去准备接收下层的数据

    // RAM 数据端口没有复位要求；只有 rd_valid 决定读数据是否有效。
    always @(posedge clk) begin
        if (receive_byte)
            memory[receive_count[8:0]] <= sd_r_data;//receive_count[8:0]来指定将读取的数据放在哪个存储单元
        if (read_enable)   
            rd_data <= memory[rd_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            receive_count <= 10'd0;
            sd_req_lba    <= 32'd0;
            load_done     <= 1'b0;
            error         <= 1'b0;  //错误标志清除，粘滞错误标志，仅在复位的时候才会清除
            error_code    <= 8'h00; //错误信息清除，也是仅在复位的时候才会清除
            buf_valid     <= 1'b0;  
            rd_valid      <= 1'b0;
        end else begin
            load_done <= 1'b0;
            rd_valid  <= read_enable;
            if (sd_error) begin
              //先检查下层有没有错误，一旦出错就
                error      <= 1'b1;
                error_code <= 8'h01;
                buf_valid  <= 1'b0; //错误发生
                rd_valid   <= 1'b0; //错误发生坚决不能传递RAM数据
                state      <= S_ERROR;
            end else begin
                case (state)
                    S_IDLE: if (load_valid && load_ready) begin
                        //assign load_ready   = (state == S_IDLE) && !error && !sd_error;
                        //只要处于空闲状态，这意味着随时可以进行一次扇区的加载，所以通过assign直接拉高空闲信
                        //表明随时可以和上层的valid进行匹配握手
                        sd_req_lba    <= load_lba; //把上层要求读取的扇区传递给下层
                        receive_count <= 10'd0;
                        buf_valid     <= 1'b0; //这里将其赋值0是因为，这里接收到一次新的加载扇区的请求了，马上要把新的扇区数据覆盖这个RAM了，这个期间不能让RAM有效，阻止上层模块去读取它
                        state         <= S_REQUEST;
                        //数据流的接收方，需要去判断握手，也就是valid&&ready，并且把数据锁存
                        //数据流的发出方，只要尽管去把数据和valid有效信号放一起，同时也还可以去判断是否接收，也就是判断ready，以便于进行下一步，比如换下一个数据
                        //ready信号和valid信号经常是由组合逻辑产生，也就是assign
                    end
                    S_REQUEST: if (sd_req_ready) state <= S_RECEIVE;
                    //assign sd_req_valid = (state == S_REQUEST) && !sd_error;
                    //一旦进入向下层发送请求的状态就直接拉高sd_req_valid请求有效信号，等待下层的ready进行握手
                    //下层接收扇区号LBA数据
                    S_RECEIVE: begin
                    //assign sd_r_ready   = (state == S_RECEIVE) && (receive_count < 10'd512)&& !sd_error;
                        if (receive_byte) begin
                            //wire receive_byte = sd_r_valid && sd_r_ready; 握手成功
                            receive_count <= receive_count + 1'b1;
                            // last 只能出现在下标 511，既不能提前，也不能缺少。
                            if (sd_r_last != (receive_count == 10'd511)) begin
                                error      <= 1'b1;
                                error_code <= 8'h02;
                                state      <= S_ERROR;
                            end
                        end
                        // 现有 SD 层的 done 晚于最后一个数据字节及 CRC 收尾。
                        //sd_spi_card还要读取两个CRC位置字节、释放片选并补充时钟。缓存此时虽然有512字节，SD事务尚未结束，不能立即宣布本次加载完成并让上层发下一请求。
                        // 若其他SD实现让最后字节和done在同一沿有效，这里仍看到旧计数511，会报02。当前集成的SD层done在收尾之后产生，满足这个要求。
                        if (sd_done) begin
                            if (receive_count == 10'd512) begin
                                buf_valid <= 1'b1;   //拉高表明当前的RAM是有效的，已经正确地加载了一个扇区的数据了，在不产生error的情况下，这一次的RAM有效会保持到复位或是下一次的load请求
                                load_done <= 1'b1;   //表示一次load扇区已经完成的标志
                                state     <= S_IDLE;
                            end else begin
                                error      <= 1'b1;
                                error_code <= 8'h02;
                                state      <= S_ERROR;
                            end
                        end
                    end
                    S_ERROR: state <= S_ERROR;    //进入error状态就一直卡着
                    default: begin
                        error      <= 1'b1;
                        error_code <= 8'h02;
                        buf_valid  <= 1'b0;
                        state      <= S_ERROR;
                    end
                endcase
            end
        end
    end
endmodule
