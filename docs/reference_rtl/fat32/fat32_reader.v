// ============================================================================
// FAT32 只读文件读取器，Verilog-2001，所有接口均属于 clk 时钟域。
//
// 范围：512 字节扇区；1/2 个 FAT；根目录；ASCII 8.3 短文件名；顺序读取。
// 支持裸 FAT32 卷和 MBR 中类型为 0B/0C 的主分区，支持碎片文件。
// 不支持 FAT12/16、exFAT、GPT、扩展分区、子目录路径和长文件名解析。
//
// 学习顺序：挂载 -> 扫描目录 -> 查 FAT 簇链 -> 输出文件 -> 共用访存状态。
// 每一次磁盘访问都是“加载一个完整扇区”，所有解析只访问缓存。
// 运行时的格式检查和错误处理属于功能逻辑，不是仿真/测试代码。
// ============================================================================
module fat32_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        card_ready,

    // open_name 按显示顺序放在高位到低位，固定 11 字节，无点、无 '\0'。
    // 例如 DATA.BIN -> "DATA    BIN"，README.TXT -> "README  TXT"。
    // 使用大写 ASCII；文件名主体和扩展名分别补空格到 8/3 字节。
    input  wire        open_valid,
    output wire        open_ready,
    input  wire [87:0] open_name,   //11字节短文件名，高位是显示顺序的第一个字符
    output reg         open_done,   // 找到文件并接受其元数据，单周期脉冲
    output reg  [31:0] file_size,

    output reg  [7:0]  file_data,
    output wire        file_valid,
    input  wire        file_ready,
    output wire        file_last,
    output reg         file_done,   // 全部文件字节已被用户接收，单周期脉冲
    output reg         mount_done,
    output wire        busy,
    output reg         error,
    output reg  [7:0]  error_code,

    // 与 sd_sector_buffer 的整扇区加载接口。
    output wire        load_valid,
    input  wire        load_ready,
    output reg  [31:0] load_lba,
    input  wire        load_done,
    input  wire        buffer_error, ////////

    // 与 sd_sector_buffer 的同步字节读接口。
    output wire        buf_rd_en,
    output reg  [8:0]  buf_rd_addr,
    input  wire [7:0]  buf_rd_data,
    input  wire        buf_rd_valid
    //读取扇区与读取缓存字节是两层独立操作：**解析一个扇区的512个字节不等于向SD卡发512次扇区读取。** 扇区只加载一次，随后逐字节读本地RAM。
);
    localparam [7:0]
        S_WAIT_CARD=0, S_BOOT_BEGIN=1, S_BOOT_READ=2, S_BOOT_CAPTURE=3,
        S_BOOT_CHECK=4, S_PART_SELECT=5, S_MOUNT=6, S_IDLE=7,
        S_DIR_SECTOR=10, S_DIR_BEGIN=11, S_DIR_ENTRY=12,
        S_DIR_READ=13, S_DIR_CAPTURE=14, S_DIR_CHECK=15, S_DIR_NEXT=16,
        S_FILE_SECTOR=20, S_FILE_BEGIN=21, S_FILE_READ=22,
        S_FILE_HAVE=23, S_FILE_SEND=24, S_FILE_DONE=25,
        S_FAT_LOAD=30, S_FAT_BEGIN=31, S_FAT_READ=32,
        S_FAT_CAPTURE=33, S_FAT_CHECK=34,
        S_LOAD_REQ=40, S_LOAD_WAIT=41, S_BYTE_REQ=42, S_BYTE_WAIT=43,
        S_FAULT=255;

    localparam [7:0]
        E_IO=8'h01, E_NO_VOLUME=8'h02, E_BAD_BPB=8'h03,
        E_BAD_NAME=8'h04, E_NOT_FOUND=8'h05, E_FIRST_CLUSTER=8'h06,//E_BAD_NAME文件名错误
        E_CHAIN_SHORT=8'h07, E_BAD_CLUSTER=8'h08,
        E_CHAIN_LIMIT=8'h09, E_STATE=8'hFF;

    reg [7:0] state;
    reg [7:0] after_load;
    reg [7:0] after_byte;
    reg [7:0] read_value;

    // ---------- 挂载时使用的 BPB / MBR 临时寄存器 ----------
    reg        probing_sector_zero;
    reg        tried_partition;
    reg [2:0]  partition_index; // 0..3 为四个主分区表项，4 表示搜索结束
    reg [31:0] volume_base;
    reg [31:0] partition_sectors;
    reg [8:0]  boot_offset;
    reg [7:0]  jump_first, jump_third, signature_low, signature_high;
    reg [15:0] bpb_bytes_per_sector;
    reg [7:0]  bpb_sectors_per_cluster;
    reg [15:0] bpb_reserved;
    reg [7:0]  bpb_fat_count;
    reg [15:0] bpb_root_entries;
    reg [15:0] bpb_total16;
    reg [15:0] bpb_fat16;
    reg [31:0] bpb_total32;
    reg [31:0] bpb_fat32;
    reg [15:0] bpb_ext_flags;
    reg [15:0] bpb_fs_version;
    reg [31:0] bpb_root_cluster;

    reg [7:0]  mbr_status [0:3];
    reg [7:0]  mbr_type   [0:3];
    reg [31:0] mbr_start  [0:3];
    reg [31:0] mbr_length [0:3];
    integer reset_index;

    // ---------- 挂载成功后保留的卷参数 ----------
    reg [31:0] fat_base_lba;  // 已按 ExtFlags 选定的 FAT 的绝对 LBA
    reg [31:0] data_base_lba;
    reg [31:0] cluster_count;
    reg [31:0] last_cluster;
    reg [31:0] root_cluster;
    reg [7:0]  sectors_per_cluster;
    reg [2:0]  cluster_shift;

    // ---------- 文件 / 目录遍历上下文 ----------
    reg [87:0] target_name;//所要打开的文件名字寄存器
    reg [31:0] current_cluster;
    reg [7:0]  sector_in_cluster;
    reg [31:0] clusters_seen;
    reg        fat_for_directory;
    reg [8:0]  entry_offset;
    reg [4:0]  entry_byte;
    reg [87:0] entry_name;
    reg [7:0]  entry_attr;
    reg [31:0] entry_cluster;
    reg [31:0] entry_size;
    reg [8:0]  file_offset;
    reg [31:0] bytes_left;
    reg [1:0]  fat_byte;
    reg [31:0] fat_entry;

    // 扇区数必须为 2 的幂，因此“乘每簇扇区数”可写成左移。
    //function sector_shift的作用是根据每簇的扇区数计算移位值
    //通常的一个簇包含8个扇区使得sector_shift = geometry_shift = cluster_shift = 3
    function [2:0] sector_shift;
        input [7:0] value;
        begin
            case (value)
                8'd1: sector_shift=0;   8'd2: sector_shift=1;
                8'd4: sector_shift=2;   8'd8: sector_shift=3;
                8'd16: sector_shift=4;  8'd32: sector_shift=5;
                8'd64: sector_shift=6;  8'd128: sector_shift=7;
                default: sector_shift=0; // 非法值由 BPB 检查拒绝
            endcase
        end
    endfunction

    // 接口约定使用大写 ASCII 8.3，支持 ~ 等合法短文件名字符。
    // 这里同时排除路径分隔符、点号、空主体和字段中间的空格。
    // 这是输入格式检查，不进行长文件名到短文件名的自动转换。
    function short_name_ok;
    //检查 open_name 是否符合这个模块规定的 FAT32 8.3 短文件名格式。
        input [87:0] value;
        integer k;
        reg [7:0] ch;
        reg padding;//padding 可以理解为“是否已经进入补空格区域”。
        begin
            short_name_ok = 1'b1;//默认通过检查，但是有一项不合格就会不通过
            padding = 1'b0;
            for (k=0; k<11; k=k+1) begin
                if (k == 8) padding = 1'b0;//扫描到扩展名开头时，要重新允许非空格字符出现。也就是取消认为“认为当前在补空格“
                ch = value[87-k*8 -: 8];
                if (ch == 8'h20) begin
                //一旦读取到时空格也就是ASCII的空格码，就拉高padding，认为当前进入补充空格的阶段
                    padding = 1'b1;
                    if (k == 0) short_name_ok = 1'b0;//如果是主提开头就是空格，这是不合法的
                end else begin
                    if (padding || (ch < 8'h21) || (ch > 8'h7E)
                        || ((ch >= 8'h61) && (ch <= 8'h7A)))
                        short_name_ok = 1'b0;//在补充空格阶段读取到非空格||字符不在合法的字符范围内，都不会通过检查
                    case (ch)
                        8'h22, 8'h2A, 8'h2B, 8'h2C, 8'h2E, 8'h2F,
                        8'h3A, 8'h3B, 8'h3C, 8'h3D, 8'h3E, 8'h3F,
                        8'h5B, 8'h5C, 8'h5D, 8'h7C: short_name_ok = 1'b0;//排除 FAT 短文件名中不允许的字符
                        default: begin end
                    endcase
                end
            end
        end
    endfunction

    // ---------- 地址和容量计算 ----------
    // 加法保留第 33 位，不能先发生 32 位回绕，再判断地址是否合法。
    wire [2:0] geometry_shift = sector_shift(bpb_sectors_per_cluster);
    //判断每簇扇区数为 1～128 之间的 2 的幂
    wire spc_ok = (bpb_sectors_per_cluster != 0)
                  && (bpb_sectors_per_cluster <= 8'd128)
                  && ((bpb_sectors_per_cluster & (bpb_sectors_per_cluster-8'd1)) == 0);
    //fat表所占的扇区数之和，如果有两个fat表，那么就是每个fat扇区数乘以2得到总扇区数
    wire [32:0] all_fat_sectors = (bpb_fat_count == 2)
                                 ? {bpb_fat32, 1'b0} : {1'b0, bpb_fat32};
    //overhead_sectors保留扇区 + 所有 FAT 表占用的扇区
    wire [32:0] overhead_sectors = {17'd0, bpb_reserved} + all_fat_sectors;
    //geometry_clusters=数据区的扇区数/每簇扇区数=数据区的簇数
    wire [32:0] geometry_clusters = ({1'b0, bpb_total32} - overhead_sectors)
                                   >> geometry_shift;
    //fat_entry_capacity = fat表一共有几个表项，一共表项占用4个字节，将fat表的扇区 bpb_fat32左移7位，            相当于乘以128
    wire [38:0] fat_entry_capacity = {bpb_fat32, 7'd0}; // 512/4=128 项/扇区
    wire [32:0] volume_end = {1'b0, volume_base} + {1'b0, bpb_total32};//fat32分区的结束LBA地址
    //geometry_data_base = 数据区的起始扇区地址
    wire [32:0] geometry_data_base = {1'b0, volume_base} + overhead_sectors;
    //geometry_fat_base计算实际使用的FAT表的起始扇区LBA = FAT32分卷起始位置+保留区+如果使用FAT1，就要加上FAT0占用的扇区数量
    wire [32:0] geometry_fat_base = {1'b0, volume_base} + {17'd0, bpb_reserved}
                    + ((bpb_ext_flags[7] && (bpb_ext_flags[3:0] == 1))
                       ? {1'b0, bpb_fat32} : 33'd0);
    //         当前选择的 FAT 表是否合法          
    wire active_fat_ok = !bpb_ext_flags[7]
                        || ({4'd0, bpb_ext_flags[3:0]} < bpb_fat_count);
    wire boot_signature_ok = (signature_low == 8'h55) && (signature_high == 8'hAA);
    //判断扇区是否具有引导扇区常见的结束签名

    // FAT 类型按数据簇数量识别，不单独依赖“FAT32   ”字符串或分区类型。
    // 本例将有效数据簇限制在 2..0FFFFFEF，避开 FAT 保留值范围。
    wire geometry_ok = boot_signature_ok
        && ((jump_first == 8'hE9) || ((jump_first == 8'hEB) && (jump_third == 8'h90)))
        //检查引导代码开头的跳转指令
        && (bpb_bytes_per_sector == 16'd512) && spc_ok//本项目支持512字节为一个扇区，并且每簇扇区数为 1～128 之间的 2 的幂
        && (bpb_reserved != 0) && ((bpb_fat_count == 1) || (bpb_fat_count == 2))//本项目只支持 1 份或 2 份 FAT
        && (bpb_root_entries == 0) && (bpb_total16 == 0) && (bpb_fat16 == 0)//FAT32要求这些都为0
        && (bpb_fs_version == 0) && (bpb_fat32 != 0) && active_fat_ok//本项目支持版本0，并且fat表扇区数量不为0，
        && ({1'b0, bpb_total32} > overhead_sectors)//fat32分卷总扇区数量，大于保留扇区+fat表扇区
        && (geometry_clusters >= 33'd65525) && (geometry_clusters <= 33'h00FFFFFEE)//保证数据区簇的数量符合fat32
        && (fat_entry_capacity >= (geometry_clusters + 33'd2))//确保 FAT 表有足够的表项描述所有可能的数据簇。

        && (bpb_root_cluster >= 2) && ({1'b0, bpb_root_cluster} <= geometry_clusters+33'd1)//确保根目录簇号不能小于 2，并且根目录簇号不能超过最后一个有效数据簇号
        && (volume_end <= 33'h100000000)//检查卷的结束边界是否超过 32 位 LBA 地址空间的上限。
        && (probing_sector_zero || (bpb_total32 <= partition_sectors));
    
    
    
    wire [8:0] mbr_relative = boot_offset - 9'd446;
    wire [1:0] mbr_slot = mbr_relative[5:4];
    wire [1:0] selected_partition = partition_index[1:0];
    wire [32:0] partition_end = {1'b0, mbr_start[selected_partition]}
                               + {1'b0, mbr_length[selected_partition]};
    //真正的当前要加载的扇区的绝对LBA = 数据区的起始LBA + 当前所在簇的偏移（减去2是由于数据区从簇2开始，左移3位乘以8得到该簇的0偏移） + 要访问的扇区在该簇内的偏移                   
    wire [32:0] current_sector_lba = {1'b0, data_base_lba}
          + (({1'b0, current_cluster} - 33'd2) << cluster_shift)
          + {25'd0, sector_in_cluster};
          
    wire [31:0] next_cluster = {4'd0, fat_entry[27:0]};
    wire [31:0] found_cluster = {4'd0, entry_cluster[27:0]};

    assign open_ready = (state == S_IDLE) && mount_done && !buffer_error;
    assign busy       = !open_ready;
    assign file_valid = (state == S_FILE_SEND) && !buffer_error;
    assign file_last  = file_valid && (bytes_left == 1);
    assign load_valid = (state == S_LOAD_REQ) && !buffer_error;
    assign buf_rd_en  = (state == S_BYTE_REQ) && !buffer_error;

    // task 只安排下一次动作，不会立即完成磁盘或 RAM 读取。
    // after_load / after_byte 是两级固定返回状态寄存器，不是软件调用栈。
    //read_sector 的任务是加载一个指定LBA的扇区到下层的RAM之中，并且转移到指定的状态中
    task read_sector;
        input [31:0] lba;
        input [7:0] next_state;
        begin
            load_lba   <= lba;
            after_load <= next_state;
            state      <= S_LOAD_REQ;
        end
    endtask
    //raed_byte的任务是读取下层ram指定地址的字节放到read_value，之后转移到指定的状态
    task read_byte;
        input [8:0] address;
        input [7:0] next_state;
        begin
            buf_rd_addr <= address;
            after_byte  <= next_state;
            state       <= S_BYTE_REQ;
        end
    endtask
    //
    task report_error;
        input [7:0] code;//错误码
        input fatal;//致命错误标志
        //fatal = 1'b1：致命错误，退出正常工作流程，进入 S_FAULT。
        //fatal = 1'b0：非致命错误，只结束当前操作，返回 S_IDLE，保留已挂载的文件系统参数。
        begin
            error      <= 1'b1;
            error_code <= code;
            if (fatal) begin
            //如果是致命错误，就完全取消自动挂载完成标志
                mount_done <= 1'b0;
                state <= S_FAULT;
            end else begin
                // 文件级错误保留挂载参数；下一次 open 握手清除错误。
                state <= S_IDLE;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_WAIT_CARD;
            after_load <= S_WAIT_CARD;
            after_byte <= S_WAIT_CARD;
            read_value <= 0;
            load_lba <= 0;
            buf_rd_addr <= 0;
            open_done <= 0;
            file_size <= 0;
            file_data <= 0;
            file_done <= 0;
            mount_done <= 0;
            error <= 0;
            error_code <= 0;
            probing_sector_zero <= 1;
            tried_partition <= 0;
            partition_index <= 0;
            volume_base <= 0;
            partition_sectors <= 0;
            boot_offset <= 0;
            jump_first <= 0;
            jump_third <= 0;
            signature_low <= 0;
            signature_high <= 0;
            bpb_bytes_per_sector <= 0;
            bpb_sectors_per_cluster <= 0;
            bpb_reserved <= 0;
            bpb_fat_count <= 0;
            bpb_root_entries <= 0;
            bpb_total16 <= 0;
            bpb_fat16 <= 0;
            bpb_total32 <= 0;
            bpb_fat32 <= 0;
            bpb_ext_flags <= 0;
            bpb_fs_version <= 0;
            bpb_root_cluster <= 0;
            fat_base_lba <= 0;
            data_base_lba <= 0;
            cluster_count <= 0;
            last_cluster <= 0;
            root_cluster <= 0;
            sectors_per_cluster <= 0;
            cluster_shift <= 0;
            target_name <= 0;
            current_cluster <= 0;
            sector_in_cluster <= 0;
            clusters_seen <= 0;
            fat_for_directory <= 0;
            entry_offset <= 0;
            entry_byte <= 0;
            entry_name <= 0;
            entry_attr <= 0;
            entry_cluster <= 0;
            entry_size <= 0;
            file_offset <= 0;
            bytes_left <= 0;
            fat_byte <= 0;
            fat_entry <= 0;
            for (reset_index=0; reset_index<4; reset_index=reset_index+1) begin
                mbr_status[reset_index] <= 0;
                mbr_type[reset_index] <= 0;
                mbr_start[reset_index] <= 0;
                mbr_length[reset_index] <= 0;
            end
        end else begin
            open_done <= 1'b0;
            file_done <= 1'b0;
            if (buffer_error) begin
                // 包括卡初始化失败、读扇区失败和缓存接收格式异常。
                report_error(E_IO, 1'b1);
            end else begin
                case (state)
                    // ========================================================
                    // 1. 自动挂载：先尝试 LBA0 是裸卷，再尝试 MBR 主分区。
                    // ========================================================
                    S_WAIT_CARD: if (card_ready) read_sector(32'd0, S_BOOT_BEGIN);
                    S_BOOT_BEGIN: begin
                        // 每读一个候选引导扇区，都重新初始化 BPB 临时字段。
                        // MBR 表项只在 LBA0 扫描时收集，后面不能覆盖它们。
                        boot_offset <= 0;
                        jump_first <= 0; //引导扇区偏移 0 的字节
                        jump_third <= 0; //引导扇区偏移 2 的字节
                        //signature_low signature_high引导扇区最后两个字节，它们分别保存偏移 510 和 511 的字节。
                        signature_low <= 0;
                        signature_high <= 0;
                        bpb_bytes_per_sector <= 0;//16位的寄存器，BPB 偏移 11～12保存每个扇区的字节数。对应 FAT32 常见值为 512，也就是 16'd512 或十六进制 0x0200。代码读取偏移 11 时保存低 8 位，偏移 12 时保存高 8 位：
                        bpb_sectors_per_cluster <= 0;//BPB 偏移 13保存每个簇包含多少个扇区。例如，值为 8，表示一个簇有 8 个扇区
                        bpb_reserved <= 0;//BPB 偏移 14～15保存 FAT 区之前的保留扇区数量。
                        bpb_fat_count <= 0;//BPB 偏移 16保存 FAT 表的份数，通常为 2，也可以是 1。
                        bpb_root_entries <= 0;//BPB 偏移 17～18保存固定根目录项的数量。在 FAT12/FAT16 中，这个字段通常非零；在 FAT32 中，通常为 0，因为根目录本身使用普通数据簇来存储。
                        bpb_total16 <= 0;//BPB 偏移 19～20保存旧格式的 16 位总扇区数。
                        bpb_fat16 <= 0;//BPB 偏移 22～23保存旧格式的 16 位 FAT 表大小。FAT32 使用 bpb_fat32 记录每份 FAT 表的扇区数，因此这个旧字段在本项目要求为 0。
                        bpb_total32 <= 0;//BPB 偏移 32～35保存整个 FAT32 卷的总扇区数
                        bpb_fat32 <= 0;//BPB 偏移 36～39保存每一份 FAT 表占用的扇区数。例如，值为 1000，表示一份 FAT 表有 1000 个扇区。
                        bpb_ext_flags <= 0;//BPB 偏移 40～41保存 FAT32 的扩展标志，用来判断 FAT 表是否启用镜像，以及是否指定使用某一份 FAT。其中：- bit 7 为 0：通常表示 FAT 镜像处于启用状态。- bit 7 为 1：表示镜像被禁用，此时低 4 位指定活动 FAT 的编号
                        bpb_fs_version <= 0;//BPB 偏移 42～43保存 FAT32 文件系统版本号。本项目要求版本为 0
                        bpb_root_cluster <= 0;//BPB 偏移 44～47保存根目录的起始簇号。例如，假设值为 2，表示根目录从第 2 号数据簇开始。FAT32 的根目录不是固定放在一个特定扇区，而是放在数据区的簇链中。
                        state <= S_BOOT_READ;
                    end
                    S_BOOT_READ: read_byte(boot_offset, S_BOOT_CAPTURE);
                    S_BOOT_CAPTURE: begin
                        // BPB 中所有多字节数均为小端：低地址放低 8 位。
                        // 偏移使用十进制，与 FAT32 文档中的 BPB 字段对应。
                        case (boot_offset)
                            0: jump_first <= read_value;
                            2: jump_third <= read_value;
                            11: bpb_bytes_per_sector[7:0] <= read_value;
                            12: bpb_bytes_per_sector[15:8] <= read_value;
                            13: bpb_sectors_per_cluster <= read_value;
                            14: bpb_reserved[7:0] <= read_value;
                            15: bpb_reserved[15:8] <= read_value;
                            16: bpb_fat_count <= read_value;
                            17: bpb_root_entries[7:0] <= read_value;
                            18: bpb_root_entries[15:8] <= read_value;
                            19: bpb_total16[7:0] <= read_value;
                            20: bpb_total16[15:8] <= read_value;
                            22: bpb_fat16[7:0] <= read_value;
                            23: bpb_fat16[15:8] <= read_value;
                            32: bpb_total32[7:0] <= read_value;
                            33: bpb_total32[15:8] <= read_value;
                            34: bpb_total32[23:16] <= read_value;
                            35: bpb_total32[31:24] <= read_value;
                            36: bpb_fat32[7:0] <= read_value;
                            37: bpb_fat32[15:8] <= read_value;
                            38: bpb_fat32[23:16] <= read_value;
                            39: bpb_fat32[31:24] <= read_value;
                            40: bpb_ext_flags[7:0] <= read_value;
                            41: bpb_ext_flags[15:8] <= read_value;
                            42: bpb_fs_version[7:0] <= read_value;
                            43: bpb_fs_version[15:8] <= read_value;
                            44: bpb_root_cluster[7:0] <= read_value;
                            45: bpb_root_cluster[15:8] <= read_value;
                            46: bpb_root_cluster[23:16] <= read_value;
                            47: bpb_root_cluster[31:24] <= read_value;
                            510: signature_low <= read_value;
                            511: signature_high <= read_value;
                            default: begin end
                        endcase
                        if (probing_sector_zero && (boot_offset >= 446)
                            && (boot_offset <= 509)) begin
                            // MBR 的四项表从 446 开始，每项 16 字节。
                            // 只使用状态、类型、起始 LBA 和长度，不使用 CHS。
                            case (mbr_relative[3:0])
                                0: mbr_status[mbr_slot] <= read_value;
                                4: mbr_type[mbr_slot] <= read_value;
                                8: mbr_start[mbr_slot][7:0] <= read_value;
                                9: mbr_start[mbr_slot][15:8] <= read_value;
                                10: mbr_start[mbr_slot][23:16] <= read_value;
                                11: mbr_start[mbr_slot][31:24] <= read_value;
                                12: mbr_length[mbr_slot][7:0] <= read_value;
                                13: mbr_length[mbr_slot][15:8] <= read_value;
                                14: mbr_length[mbr_slot][23:16] <= read_value;
                                15: mbr_length[mbr_slot][31:24] <= read_value;
                                default: begin end
                            endcase
                        end
                        if (boot_offset == 511) state <= S_BOOT_CHECK;
                        //已经读取了DBR的所有512个字节了，现在进入检查阶段
                        else begin
                            //读取DBR地址加1
                            boot_offset <= boot_offset + 1'b1;
                            state <= S_BOOT_READ;
                        end
                    end
                    //
                    S_BOOT_CHECK: begin
                        if (geometry_ok) state <= S_MOUNT;
                        //geometry_ok 不只是判断某个参数是否正确，而是决定能不能把当前扇区认定为一个符合支持范围的 FAT32 卷，并开始使用它的地址参数。
                        else if (probing_sector_zero && !boot_signature_ok)
                            report_error(E_NO_VOLUME, 1'b1);
                        else state <= S_PART_SELECT;
                    end
                    S_PART_SELECT: begin
                        if (partition_index == 4) begin
                            report_error(tried_partition ? E_BAD_BPB : E_NO_VOLUME, 1'b1);
                        end else begin
                            // 当前候选不符合条件时，下一周期查看下一项；
                            // 若候选 BPB 不支持，也会回到这里继续下一项。
                            partition_index <= partition_index + 1'b1;
                            if (((mbr_status[selected_partition] == 8'h00)
                                 || (mbr_status[selected_partition] == 8'h80))
                                && ((mbr_type[selected_partition] == 8'h0B)
                                 || (mbr_type[selected_partition] == 8'h0C))
                                && (mbr_start[selected_partition] != 0)
                                && (mbr_length[selected_partition] != 0)
                                && (partition_end <= 33'h100000000)) begin
                                volume_base <= mbr_start[selected_partition];
                                partition_sectors <= mbr_length[selected_partition];
                                probing_sector_zero <= 1'b0;
                                tried_partition <= 1'b1;
                                read_sector(mbr_start[selected_partition], S_BOOT_BEGIN);
                            end
                        end
                    end
                    S_MOUNT: begin
                    //S_MOUNT 中的 7 个寄存器：保存后续运行过程中经常要用的参数，供目录搜索、读取文件和查询 FAT 表使用。
                        fat_base_lba <= geometry_fat_base[31:0];//保存当前实际选用的 FAT 表的绝对扇区起始地址
                        data_base_lba <= geometry_data_base[31:0];//保存数据区的绝对起始扇区地址，也就是簇号 2 对应的第一个扇区地址
                        cluster_count <= geometry_clusters[31:0];//保存数据区中有效数据簇的数量。
                        last_cluster <= geometry_clusters[31:0] + 32'd1;//保存最后一个有效数据簇的编号。
                        root_cluster <= bpb_root_cluster;//保存 BPB 中解析出来的根目录起始簇号。
                        sectors_per_cluster <= bpb_sectors_per_cluster;//保存每个簇包含多少个扇区。
                        cluster_shift <= geometry_shift;//由每个簇含有8个扇区产生的3的移位长度
                        mount_done <= 1'b1;//表示FAT32的自动挂载已经完成了
                        state <= S_IDLE;
                        //让状态机进入空闲状态，等待上层请求打开文件。
                    end

                    // ========================================================
                    // 2. 每个 open 都从根目录起始簇重新查找。
                    // ========================================================
                    S_IDLE: if (open_valid && open_ready) begin
                    //assign open_ready = (state == S_IDLE) && mount_done && !buffer_error;
                        error <= 1'b0;
                        error_code <= 8'h00;
                        //将上一次操作的错误信息都清除，为打开新的文件做准备
                        file_size <= 0;//准备记录打开文件的大小
                        if (!short_name_ok(open_name)) begin
                        //检查文件名是否合法，函数回传0，则说明文件名出错，进行报错
                            report_error(E_BAD_NAME, 1'b0);//文件名格式错误，并且是非致命的错误
                        end else begin
                            target_name <= open_name;
                            current_cluster <= root_cluster;//root_cluster 是挂载时从 BPB 中解析并保存的根目录起始簇号。current_cluster表示当前访问的簇
                            sector_in_cluster <= 0;//从当前簇的第一个扇区开始一个簇可能包含多个扇区。例如，每簇有 8 个扇区，簇内偏移就是 0～7。初始化为 0，表示从根目录起始簇的第一个扇区开始扫描。sector_in_cluster表示要访问当前所访问的簇内的第几个扇区偏移的扇区
                            clusters_seen <= 1;//初始化已访问簇计数，表示正访问根目录的第一个簇
                            state <= S_DIR_SECTOR;
                        end
                    end
                    S_DIR_SECTOR: read_sector(current_sector_lba[31:0], S_DIR_BEGIN);//执行加载扇区的任务，放在了下层的RAM里面
                    S_DIR_BEGIN: begin
                        entry_offset <= 0;
                        state <= S_DIR_ENTRY;
                    end
                    S_DIR_ENTRY: begin
                        entry_byte <= 0;
                        entry_name <= 0;
                        entry_attr <= 0;
                        entry_cluster <= 0;
                        entry_size <= 0;
                        state <= S_DIR_READ;
                    end
                    S_DIR_READ: read_byte(entry_offset + {4'd0, entry_byte}, S_DIR_CAPTURE);
                    S_DIR_CAPTURE: begin
                        if (entry_byte < 11)
                            entry_name <= {entry_name[79:0], read_value};
                        case (entry_byte)
                            11: entry_attr <= read_value;
                            20: entry_cluster[23:16] <= read_value; // 首簇高 16 位
                            21: entry_cluster[31:24] <= read_value;
                            26: entry_cluster[7:0] <= read_value;   // 首簇低 16 位
                            27: entry_cluster[15:8] <= read_value;
                            28: entry_size[7:0] <= read_value;
                            29: entry_size[15:8] <= read_value;
                            30: entry_size[23:16] <= read_value;
                            31: entry_size[31:24] <= read_value;
                            default: begin end
                        endcase
                        if (entry_byte == 31) state <= S_DIR_CHECK;
                        else begin
                            entry_byte <= entry_byte + 1'b1;
                            state <= S_DIR_READ;
                        end
                    end
                    S_DIR_CHECK: begin
                        if (entry_name[87:80] == 8'h00) begin
                            // 00 表示目录项序列已结束，不必继续查后面的扇区。
                            report_error(E_NOT_FOUND, 1'b0);
                        end else if ((entry_name[87:80] != 8'hE5)
                            && ((entry_attr & 8'h18) == 0) && (entry_name == target_name)) begin
                            // E5=已删除；属性 08=卷标、10=子目录。
                            // LFN 属性 0F 也包含 08，因此会自然跳过。
                            // 只读/隐藏/系统/归档属性不妨碍读取普通文件。
                            if ((entry_size != 0)
                                && ((found_cluster < 2) || (found_cluster > last_cluster))) begin
                                report_error(E_FIRST_CLUSTER, 1'b0);
                            end else begin
                                file_size <= entry_size;
                                bytes_left <= entry_size;
                                open_done <= 1'b1;
                                if (entry_size == 0) begin
                                    // 空文件可以没有分配簇，绝不能去读“簇 0”。
                                    state <= S_FILE_DONE;
                                end else begin
                                    current_cluster <= found_cluster;
                                    sector_in_cluster <= 0;
                                    clusters_seen <= 1;
                                    state <= S_FILE_SECTOR;
                                end
                            end
                        end else state <= S_DIR_NEXT;
                    end
                    S_DIR_NEXT: begin
                        if (entry_offset != 9'd480) begin
                            entry_offset <= entry_offset + 9'd32;
                            state <= S_DIR_ENTRY;
                        end else if (sector_in_cluster < sectors_per_cluster - 8'd1) begin
                            sector_in_cluster <= sector_in_cluster + 1'b1;
                            state <= S_DIR_SECTOR;
                        end else begin
                            fat_for_directory <= 1'b1;
                            state <= S_FAT_LOAD;
                        end
                    end

                    // ========================================================
                    // 3. 文件输出：扇区内递增字节，簇内递增扇区，簇间查 FAT。
                    // ========================================================
                    S_FILE_SECTOR: read_sector(current_sector_lba[31:0], S_FILE_BEGIN);
                    S_FILE_BEGIN: begin
                        file_offset <= 0;
                        state <= S_FILE_READ;
                    end
                    S_FILE_READ: read_byte(file_offset, S_FILE_HAVE);
                    S_FILE_HAVE: begin
                        file_data <= read_value;
                        state <= S_FILE_SEND;
                    end
                    S_FILE_SEND: if (file_ready) begin
                        // 此状态 file_valid=1，只有握手后才消耗当前字节。
                        // 因此下游反压时 data/last 均保持稳定，不会丢字节。
                        bytes_left <= bytes_left - 1'b1;
                        if (bytes_left == 1) begin
                            state <= S_FILE_DONE;
                        end else if (file_offset != 9'd511) begin
                            file_offset <= file_offset + 1'b1;
                            state <= S_FILE_READ;
                        end else if (sector_in_cluster < sectors_per_cluster - 8'd1) begin
                            sector_in_cluster <= sector_in_cluster + 1'b1;
                            state <= S_FILE_SECTOR;
                        end else begin
                            fat_for_directory <= 1'b0;
                            state <= S_FAT_LOAD;
                        end
                    end
                    S_FILE_DONE: begin
                        file_done <= 1'b1;
                        state <= S_IDLE;
                    end

                    // ========================================================
                    // 4. 共用 FAT 查询：一个 512 字节扇区容纳 128 个 4 字节项。
                    //    FAT 扇区 = FAT 起点 + (簇号 >> 7)
                    //    项内偏移 = (簇号低 7 位 << 2)，表项取低 28 位。
                    // ========================================================
                    S_FAT_LOAD: read_sector(fat_base_lba + (current_cluster >> 7), S_FAT_BEGIN);
                    S_FAT_BEGIN: begin
                        fat_byte <= 0;
                        fat_entry <= 0;
                        state <= S_FAT_READ;
                    end
                    S_FAT_READ: read_byte({current_cluster[6:0], 2'b00}
                                          + {7'd0, fat_byte}, S_FAT_CAPTURE);
                    S_FAT_CAPTURE: begin
                        case (fat_byte)
                            0: fat_entry[7:0] <= read_value;
                            1: fat_entry[15:8] <= read_value;
                            2: fat_entry[23:16] <= read_value;
                            3: fat_entry[31:24] <= read_value;
                        endcase
                        if (fat_byte == 3) state <= S_FAT_CHECK;
                        else begin
                            fat_byte <= fat_byte + 1'b1;
                            state <= S_FAT_READ;
                        end
                    end
                    S_FAT_CHECK: begin
                        if (next_cluster >= 32'h0FFFFFF8) begin
                            // 目录链读完但没找到：NOT_FOUND。
                            // 文件尚有 bytes_left 却读到链尾：链短于目录声明。
                            report_error(fat_for_directory ? E_NOT_FOUND : E_CHAIN_SHORT, 1'b0);
                        end else if ((next_cluster < 2) || (next_cluster > last_cluster)
                                     || (next_cluster >= 32'h0FFFFFF0)) begin
                            // 包括空闲簇 0、保留值、坏簇 0FFFFFF7 和越界簇。
                            report_error(E_BAD_CLUSTER, 1'b0);
                        end else if ((next_cluster == current_cluster)
                                     || (clusters_seen >= cluster_count)) begin
                            // 检出自环，并用卷内簇总数约束遍历次数，避免无限寻找。
                            // 这不是完整的一致性检查，也不记录每个访问过的簇。
                            report_error(E_CHAIN_LIMIT, 1'b0);
                        end else begin
                            current_cluster <= next_cluster;
                            clusters_seen <= clusters_seen + 1'b1;
                            sector_in_cluster <= 0;
                            state <= fat_for_directory ? S_DIR_SECTOR : S_FILE_SECTOR;
                        end
                    end

                    // ========================================================
                    // 5. 共用握手：请求保持到被接受，响应到达后再返回调用状态。
                    // ========================================================
                    S_LOAD_REQ: if (load_ready) state <= S_LOAD_WAIT;
                    //S_LOAD_REQ状态从属于task read_sector，在这个状态中，拉高了load_valid，同时也保持了要加载的扇区load_lba ，然后去采样下层的输出的load_ready，这符合AXI4straem的规则
                    //assign load_valid = (state == S_LOAD_REQ) && !buffer_error;
                    S_LOAD_WAIT: if (load_done) state <= after_load;
                    //等待扇区的加载完成，然后将状态转移至由调用task read_sector时设定的扇区加载完成之后要去到的状态
                    S_BYTE_REQ: state <= S_BYTE_WAIT;
                    //assign buf_rd_en  = (state == S_BYTE_REQ) && !buffer_error;
                    S_BYTE_WAIT: if (buf_rd_valid) begin
                        read_value <= buf_rd_data;
                        state <= after_byte;
                    end
                    
                    S_FAULT: state <= S_FAULT;
                    default: report_error(E_STATE, 1'b1);
                endcase
            end
        end
    end
endmodule
