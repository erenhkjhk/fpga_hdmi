`timescale 1ns / 1ps

// EG4S internal SDRAM wrapper. No arbitration, buffering or clock crossing.
// Fixed 2M x 32 geometry; application addresses are WORD addresses.
module sdram_ram_wrapper #(
    parameter SELF_REFRESH_OPEN = 1'b1
) (
    input wire Sdr_clk,
    input wire Sdr_clk_sft,
    input wire Rst,
    output wire Sdr_init_done,
    output wire Sdr_init_ref_vld,
    output wire Sdr_busy,
    input wire App_ref_req,
    input wire App_wr_en,
    input wire [20:0] App_wr_addr,
    input wire [31:0] App_wr_din,
    input wire [3:0] App_wr_dm,
    input wire App_rd_en,
    input wire [20:0] App_rd_addr,
    output wire Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
    wire sdram_clk, sdr_ras, sdr_cas, sdr_we;
    wire [1:0] sdr_ba;
    wire [10:0] sdr_addr;
    wire [3:0] sdr_dm;
    wire [31:0] sdr_dq;

    sdr_as_ram #(.self_refresh_open(SELF_REFRESH_OPEN)) u_controller (
        .Sdr_clk(Sdr_clk), .Sdr_clk_sft(Sdr_clk_sft), .Rst(Rst),
        .Sdr_init_done(Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld), .Sdr_busy(Sdr_busy),
        .App_ref_req(App_ref_req),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr),
        .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .SDRAM_CLK(sdram_clk), .SDR_RAS(sdr_ras),
        .SDR_CAS(sdr_cas), .SDR_WE(sdr_we),
        .SDR_BA(sdr_ba), .SDR_ADDR(sdr_addr),
        .SDR_DM(sdr_dm), .SDR_DQ(sdr_dq)
    );

    EG_PHY_SDRAM_2M_32 u_sdram (
        .clk(sdram_clk), .ras_n(sdr_ras), .cas_n(sdr_cas),
        .we_n(sdr_we), .addr(sdr_addr), .ba(sdr_ba), .dq(sdr_dq),
        .cs_n(1'b0), .cke(1'b1),
        .dm0(sdr_dm[0]), .dm1(sdr_dm[1]),
        .dm2(sdr_dm[2]), .dm3(sdr_dm[3])
    );
endmodule
