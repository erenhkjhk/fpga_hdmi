// Anlogic HDMI TX: EG, 640x480p (~59.52381 Hz), RGB888, 48 kHz audio.
// Actual generated external clocks: pixel = 25 MHz; serial = 125 MHz.
// Only the protocol core and PHY are instantiated here.
`default_nettype none

module hdmi_tx_640x480 (
    input  wire        I_pixel_clk,
    input  wire        I_serial_clk,
    input  wire        I_rst,              // Active-high reset; clocks must be stable at release.

    // Video input, synchronous to I_pixel_clk; each active line must be continuous.
    input  wire        I_axis_s_user,      // First active pixel of a frame.
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,      // Last active pixel of each line.
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,
    output wire        O_video_locked,

    // Parallel audio samples, synchronous to I_pixel_clk (one stereo pair per valid).
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,

    // ACR values are supplied by the user logic, synchronous to I_pixel_clk.
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,

    // EDID control/data, synchronous to I_pixel_clk.
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,

    // Preserve the vendor PHY port convention. Pairing/electrical setup is board-specific.
    output wire        O_tmds_ch0_p,
    output wire        O_tmds_ch1_p,
    output wire        O_tmds_ch2_p,
    output wire        O_tmds_clk_p
);

    wire [9:0] S_ch0_tmds_data;
    wire [9:0] S_ch1_tmds_data;
    wire [9:0] S_ch2_tmds_data;
    wire [9:0] S_clk_tmds_data;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (800),
        .HSA               (96),
        .HFP               (16),
        .HBP               (48),
        .HACTIVE           (640),
        .VTOTAL            (525),
        .VSA               (2),
        .VFP               (10),
        .VBP               (33),
        .VACTIVE           (480),
        .VIDEO_VIC         (1),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        // 25_000_000 / (2 * 126) = 99,206.34921 Hz, below 100 kHz.
        .IIC_SCL_DIV       (126)
    ) u_hdmi_core (
        .I_pixel_clk       (I_pixel_clk),
        .I_rst             (I_rst),
        .I_edid_read_trig  (I_edid_read_trig),
        .O_edid_read_valid (O_edid_read_valid),
        .O_edid_read_data  (O_edid_read_data),
        .I_axis_s_user     (I_axis_s_user),
        .I_axis_s_valid    (I_axis_s_valid),
        .I_axis_s_last     (I_axis_s_last),
        .I_axis_s_data     (I_axis_s_data),
        .O_axis_s_ready    (O_axis_s_ready),
        .I_audio_valid     (I_audio_valid),
        .I_audio_left_data (I_audio_left_data),
        .I_audio_right_data(I_audio_right_data),
        .I_acr_valid       (I_acr_valid),
        .I_acr_cts         (I_acr_cts),
        .I_acr_n           (I_acr_n),
        .O_video_locked    (O_video_locked),
        .O_ddc_scl         (O_ddc_scl),
        .IO_ddc_sda        (IO_ddc_sda),
        .O_ch0_tmds_data   (S_ch0_tmds_data),
        .O_ch1_tmds_data   (S_ch1_tmds_data),
        .O_ch2_tmds_data   (S_ch2_tmds_data),
        .O_clk_tmds_data   (S_clk_tmds_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk       (I_pixel_clk),
        .I_serial_clk      (I_serial_clk),
        .I_rst             (I_rst),
        .I_tmds_channel_0  (S_ch0_tmds_data),
        .I_tmds_channel_1  (S_ch1_tmds_data),
        .I_tmds_channel_2  (S_ch2_tmds_data),
        .I_tmds_channel_clk(S_clk_tmds_data),
        .O_tmds_ch0_p      (O_tmds_ch0_p),
        .O_tmds_ch1_p      (O_tmds_ch1_p),
        .O_tmds_ch2_p      (O_tmds_ch2_p),
        .O_tmds_clk_p     (O_tmds_clk_p)
    );

endmodule

`default_nettype wire
