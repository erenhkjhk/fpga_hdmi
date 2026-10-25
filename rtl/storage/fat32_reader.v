// Project copy adapted from docs/reference_rtl/fat32/fat32_reader.v
// FAT32, 512-byte sectors, SDHC/SDXC. Index opens regular root *.BMP entries.
// Counts candidates at mount; validates actual BMP format in bmp24_decoder.
// Directory chains and file chains both follow FAT, including fragmented files.
`timescale 1ns/1ps
`default_nettype none
module fat32_reader #(parameter NAMED_FILE=0, parameter [87:0] SHORT_NAME="BGM     WAV") (
    input wire bookmark_valid, loop_restart,
    input wire [31:0] loop_length,
    input  wire        clk,
    input  wire        rst_n,
    input  wire        card_ready,
    input  wire        open_valid,
    output wire        open_ready,
    input  wire [15:0] open_index,
    output reg  [15:0] image_count,
    output reg         catalog_ready,
    output reg         open_done,
    output reg  [31:0] file_size,
    output reg  [7:0]  file_data,
    output wire        file_valid,
    input  wire        file_ready,
    output wire        file_last,
    output reg         file_done,
    output reg         mount_done,
    output wire        busy,
    output reg         error,
    output reg  [7:0]  error_code,
    output wire        load_valid,
    input  wire        load_ready,
    output reg  [31:0] load_lba,
    input  wire        load_done,
    input  wire        buffer_error,
    output wire        buf_rd_en,
    output reg  [8:0]  buf_rd_addr,
    input  wire [7:0]  buf_rd_data,
    input  wire        buf_rd_valid
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
        E_BAD_NAME=8'h04, E_NOT_FOUND=8'h05, E_FIRST_CLUSTER=8'h06,
        E_CHAIN_SHORT=8'h07, E_BAD_CLUSTER=8'h08,
        E_CHAIN_LIMIT=8'h09, E_STATE=8'hFF;
    reg [7:0] state;
    reg [7:0] after_load;
    reg [7:0] after_byte;
    reg [7:0] read_value;
    reg        probing_sector_zero;
    reg        tried_partition;
    reg [2:0]  partition_index;
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
    reg [31:0] fat_base_lba;
    reg [31:0] data_base_lba;
    reg [31:0] cluster_count;
    reg [31:0] last_cluster;
    reg [31:0] root_cluster;
    reg [7:0]  sectors_per_cluster;
    reg [2:0]  cluster_shift;
    reg [15:0] target_index, matched_index;
    reg scanning_catalog;
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
    reg bookmark_saved,seek_first;
    reg [31:0] bookmark_cluster,bookmark_length;
    reg [7:0] bookmark_sector;
    reg [8:0] bookmark_offset;
    reg cached_file;
    reg [31:0] cached_cluster, cached_size;
    reg [1:0]  fat_byte;
    reg [31:0] fat_entry;
    function [2:0] sector_shift;
        input [7:0] value;
        begin
            case (value)
                8'd1: sector_shift=0;   8'd2: sector_shift=1;
                8'd4: sector_shift=2;   8'd8: sector_shift=3;
                8'd16: sector_shift=4;  8'd32: sector_shift=5;
                8'd64: sector_shift=6;  8'd128: sector_shift=7;
                default: sector_shift=0;
            endcase
        end
    endfunction
    wire [2:0] geometry_shift = sector_shift(bpb_sectors_per_cluster);
    wire spc_ok = (bpb_sectors_per_cluster != 0)
                  && (bpb_sectors_per_cluster <= 8'd128)
                  && ((bpb_sectors_per_cluster & (bpb_sectors_per_cluster-8'd1)) == 0);
    wire [32:0] all_fat_sectors = (bpb_fat_count == 2)
                                 ? {bpb_fat32, 1'b0} : {1'b0, bpb_fat32};
    wire [32:0] overhead_sectors = {17'd0, bpb_reserved} + all_fat_sectors;
    wire [32:0] geometry_clusters = ({1'b0, bpb_total32} - overhead_sectors)
                                   >> geometry_shift;
    wire [38:0] fat_entry_capacity = {bpb_fat32, 7'd0};
    wire [32:0] volume_end = {1'b0, volume_base} + {1'b0, bpb_total32};
    wire [32:0] geometry_data_base = {1'b0, volume_base} + overhead_sectors;
    wire [32:0] geometry_fat_base = {1'b0, volume_base} + {17'd0, bpb_reserved}
                    + ((bpb_ext_flags[7] && (bpb_ext_flags[3:0] == 1))
                       ? {1'b0, bpb_fat32} : 33'd0);
    wire active_fat_ok = !bpb_ext_flags[7]
                        || ({4'd0, bpb_ext_flags[3:0]} < bpb_fat_count);
    wire boot_signature_ok = (signature_low == 8'h55) && (signature_high == 8'hAA);
    wire geometry_ok = boot_signature_ok
        && ((jump_first == 8'hE9) || ((jump_first == 8'hEB) && (jump_third == 8'h90)))
        && (bpb_bytes_per_sector == 16'd512) && spc_ok
        && (bpb_reserved != 0) && ((bpb_fat_count == 1) || (bpb_fat_count == 2))
        && (bpb_root_entries == 0) && (bpb_total16 == 0) && (bpb_fat16 == 0)
        && (bpb_fs_version == 0) && (bpb_fat32 != 0) && active_fat_ok
        && ({1'b0, bpb_total32} > overhead_sectors)
        && (geometry_clusters >= 33'd65525) && (geometry_clusters <= 33'h00FFFFFEE)
        && (fat_entry_capacity >= (geometry_clusters + 33'd2))
        && (bpb_root_cluster >= 2) && ({1'b0, bpb_root_cluster} <= geometry_clusters+33'd1)
        && (volume_end <= 33'h100000000)
        && (probing_sector_zero || (bpb_total32 <= partition_sectors));
    wire [8:0] mbr_relative = boot_offset - 9'd446;
    wire [1:0] mbr_slot = mbr_relative[5:4];
    wire [1:0] selected_partition = partition_index[1:0];
    wire [32:0] partition_end = {1'b0, mbr_start[selected_partition]}
                               + {1'b0, mbr_length[selected_partition]};
    wire [32:0] current_sector_lba = {1'b0, data_base_lba}
          + (({1'b0, current_cluster} - 33'd2) << cluster_shift)
          + {25'd0, sector_in_cluster};
    wire [31:0] next_cluster = {4'd0, fat_entry[27:0]};
    wire [31:0] found_cluster = {4'd0, entry_cluster[27:0]};
    assign open_ready = (state == S_IDLE) && mount_done && catalog_ready && !buffer_error;
    assign busy       = !open_ready;
    assign file_valid = (state == S_FILE_SEND) && !buffer_error;
    assign file_last  = file_valid && (bytes_left == 1);
    assign load_valid = (state == S_LOAD_REQ) && !buffer_error;
    assign buf_rd_en  = (state == S_BYTE_REQ) && !buffer_error;
    task read_sector;
        input [31:0] lba;
        input [7:0] next_state;
        begin
            load_lba   <= lba;
            after_load <= next_state;
            state      <= S_LOAD_REQ;
        end
    endtask
    task read_byte;
        input [8:0] address;
        input [7:0] next_state;
        begin
            buf_rd_addr <= address;
            after_byte  <= next_state;
            state       <= S_BYTE_REQ;
        end
    endtask
    task finish_catalog;
        begin
            scanning_catalog <= 1'b0;
            catalog_ready <= 1'b1;
            state <= S_IDLE;
        end
    endtask
    task report_error;
        input [7:0] code;
        input fatal;
        begin
            error      <= 1'b1;
            error_code <= code;
            if (fatal) begin
                mount_done <= 1'b0;
                catalog_ready <= 1'b0;
                state <= S_FAULT;
            end else begin
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
            bookmark_saved<=0;seek_first<=0;bookmark_cluster<=0;bookmark_length<=0;bookmark_sector<=0;bookmark_offset<=0;
            cached_file<=0;cached_cluster<=0;cached_size<=0;
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
            target_index <= 0;
            matched_index <= 0;
            scanning_catalog <= 0;
            image_count <= 0;
            catalog_ready <= 0;
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
                report_error(E_IO, 1'b1);
            end else if(NAMED_FILE && loop_restart && bookmark_saved) begin
                current_cluster<=bookmark_cluster;sector_in_cluster<=bookmark_sector;
                bytes_left<=bookmark_length;clusters_seen<=1;seek_first<=1;
                state<=S_FILE_SECTOR;
            end else begin
                if(NAMED_FILE && bookmark_valid && state==S_FILE_SEND && file_ready) begin
                    bookmark_saved<=1;bookmark_cluster<=current_cluster;
                    bookmark_sector<=sector_in_cluster;bookmark_offset<=file_offset;
                    bookmark_length<=loop_length;
                end
                case (state)
                    S_WAIT_CARD: if (card_ready) read_sector(32'd0, S_BOOT_BEGIN);
                    S_BOOT_BEGIN: begin
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
                        state <= S_BOOT_READ;
                    end
                    S_BOOT_READ: read_byte(boot_offset, S_BOOT_CAPTURE);
                    S_BOOT_CAPTURE: begin
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
                        else begin
                            boot_offset <= boot_offset + 1'b1;
                            state <= S_BOOT_READ;
                        end
                    end
                    S_BOOT_CHECK: begin
                        if (geometry_ok) state <= S_MOUNT;
                        else if (probing_sector_zero && !boot_signature_ok)
                            report_error(E_NO_VOLUME, 1'b1);
                        else state <= S_PART_SELECT;
                    end
                    S_PART_SELECT: begin
                        if (partition_index == 4) begin
                            report_error(tried_partition ? E_BAD_BPB : E_NO_VOLUME, 1'b1);
                        end else begin
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
                        fat_base_lba <= geometry_fat_base[31:0];
                        data_base_lba <= geometry_data_base[31:0];
                        cluster_count <= geometry_clusters[31:0];
                        last_cluster <= geometry_clusters[31:0] + 32'd1;
                        root_cluster <= bpb_root_cluster;
                        sectors_per_cluster <= bpb_sectors_per_cluster;
                        cluster_shift <= geometry_shift;
                        mount_done <= 1'b1;
                        catalog_ready <= 1'b0;
                        image_count <= 16'd0;
                        scanning_catalog <= 1'b1;
                        current_cluster <= bpb_root_cluster;
                        sector_in_cluster <= 0;
                        clusters_seen <= 1;
                        state <= S_DIR_SECTOR;
                    end
                    S_IDLE: if (open_valid && open_ready) begin
                        error <= 1'b0;
                        error_code <= 8'h00;
                        file_size <= 0;
                        if(NAMED_FILE && cached_file) begin
                            file_size<=cached_size;bytes_left<=cached_size;open_done<=1;
                            current_cluster<=cached_cluster;sector_in_cluster<=0;clusters_seen<=1;
                            state<=S_FILE_SECTOR;
                        end else if (open_index >= image_count) begin
                            report_error(E_BAD_NAME, 1'b0);
                        end else begin
                            target_index <= open_index;
                            matched_index <= 0;
                            scanning_catalog <= 1'b0;
                            current_cluster <= root_cluster;
                            sector_in_cluster <= 0;
                            clusters_seen <= 1;
                            state <= S_DIR_SECTOR;
                        end
                    end
                    S_DIR_SECTOR: read_sector(current_sector_lba[31:0], S_DIR_BEGIN);
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
                            20: entry_cluster[23:16] <= read_value;
                            21: entry_cluster[31:24] <= read_value;
                            26: entry_cluster[7:0] <= read_value;
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
                    // Enumerate regular root-directory BMP short entries in disk order.
                    S_DIR_CHECK: begin
                        if (entry_name[87:80] == 8'h00) begin
                            if (scanning_catalog) finish_catalog;
                            else report_error(E_NOT_FOUND, 1'b0);
                        end else if ((entry_name[87:80] != 8'hE5)
                            && ((entry_attr & 8'h18) == 0)
                            && (NAMED_FILE ? entry_name==SHORT_NAME : entry_name[23:0]==24'h424D50)
                            && (entry_size >= (NAMED_FILE ? 32'd12 : 32'd54))
                            && (found_cluster >= 2) && (found_cluster <= last_cluster)) begin
                            if (scanning_catalog) begin
                                image_count <= image_count + 1'b1;
                                if (image_count == 16'hFFFE) finish_catalog;
                                else state <= S_DIR_NEXT;
                            end else if (matched_index == target_index) begin
                                if(NAMED_FILE) begin cached_file<=1;cached_cluster<=found_cluster;cached_size<=entry_size;end
                                file_size <= entry_size;
                                bytes_left <= entry_size;
                                open_done <= 1'b1;
                                current_cluster <= found_cluster;
                                sector_in_cluster <= 0;
                                clusters_seen <= 1;
                                state <= S_FILE_SECTOR;
                            end else begin
                                matched_index <= matched_index + 1'b1;
                                state <= S_DIR_NEXT;
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
                    S_FILE_SECTOR: read_sector(current_sector_lba[31:0], S_FILE_BEGIN);
                    S_FILE_BEGIN: begin
                        file_offset <= seek_first ? bookmark_offset : 9'd0;
                        seek_first<=0;
                        state <= S_FILE_READ;
                    end
                    S_FILE_READ: read_byte(file_offset, S_FILE_HAVE);
                    S_FILE_HAVE: begin
                        file_data <= read_value;
                        state <= S_FILE_SEND;
                    end
                    S_FILE_SEND: if (file_ready) begin
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
                            default: begin end
                        endcase
                        if (fat_byte == 3) state <= S_FAT_CHECK;
                        else begin
                            fat_byte <= fat_byte + 1'b1;
                            state <= S_FAT_READ;
                        end
                    end
                    S_FAT_CHECK: begin
                        if (next_cluster >= 32'h0FFFFFF8) begin
                            if (fat_for_directory && scanning_catalog) finish_catalog;
                            else report_error(fat_for_directory ? E_NOT_FOUND : E_CHAIN_SHORT, 1'b0);
                        end else if ((next_cluster < 2) || (next_cluster > last_cluster)
                                     || (next_cluster >= 32'h0FFFFFF0)) begin
                            report_error(E_BAD_CLUSTER, 1'b0);
                        end else if ((next_cluster == current_cluster)
                                     || (clusters_seen >= cluster_count)) begin
                            report_error(E_CHAIN_LIMIT, 1'b0);
                        end else begin
                            current_cluster <= next_cluster;
                            clusters_seen <= clusters_seen + 1'b1;
                            sector_in_cluster <= 0;
                            state <= fat_for_directory ? S_DIR_SECTOR : S_FILE_SECTOR;
                        end
                    end
                    S_LOAD_REQ: if (load_ready) state <= S_LOAD_WAIT;
                    S_LOAD_WAIT: if (load_done) state <= after_load;
                    S_BYTE_REQ: state <= S_BYTE_WAIT;
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

`default_nettype wire
