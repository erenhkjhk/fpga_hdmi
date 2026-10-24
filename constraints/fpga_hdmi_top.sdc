# Tang Dynasty 6.2; units: ns. See constraints/README.md for budgets/limits.
# This file constrains the existing RTL/IP; it does not change PLL parameters.

# Manual pp.21-22: 50 MHz oscillator on R7.
create_clock -name clk_50m -period 20.000 -waveform {0.000 10.000} [get_ports {clk_50m}]

# Derive frequencies AND phases from actual EG_PHY_PLL parameters.
# SDRAM: 150 MHz at 0/180 degrees; HDMI: 125 MHz serial / 25 MHz pixel.
derive_clocks
rename_clock -name clk_sdram [get_clocks {u_pll_sdram/pll_inst.clkc[0]}]
rename_clock -name clk_sdram_180 [get_clocks {u_pll_sdram/pll_inst.clkc[1]}]
rename_clock -name clk_hdmi_serial [get_clocks {u_pll_hdmi/pll_inst.clkc[0]}]
rename_clock -name clk_pixel [get_clocks {u_pll_hdmi/pll_inst.clkc[1]}]

# Initial design margin, not oscillator/PLL jitter specified by the board manual.
set_clock_uncertainty -setup 0.200 [get_clocks {clk_50m clk_sdram clk_sdram_180 clk_hdmi_serial clk_pixel}]
set_clock_uncertainty -hold 0.100 [get_clocks {clk_50m clk_sdram clk_sdram_180 clk_hdmi_serial clk_pixel}]

# These clocks share the 50 MHz reference. Do not cut whole clock groups:
# pixel->serial transfers and SDRAM 0->180 degree paths must remain timed.
# Internal CDC/FIFO paths also remain timed conservatively; there is no blanket
# exception on ASYNC_REG, vendor hierarchy, or the mailbox multi-bit payload.

# Human-operated inputs have no synchronous external launch clock. Only the
# external input paths are excepted; synchronizer interstage paths remain timed.
# KEY4 is an asynchronous reset request; local reset release remains timed.
set_false_path -from [get_ports {key_n[0] key_n[1] key_n[2] key_n[3] switch[0] switch[1] switch[2] switch[3]}]

# SPI mode 0: the RTL samples MISO / presents MOSI on clock-enable events, all
# registers clocked at 50 MHz. Fastest SCK=5 MHz, half period=5 system cycles.
# SCK is a registered OUTPUT, not a fabric clock. Its phase restarts each byte,
# so a fictitious fixed-phase divide-by-10 generated clock would be misleading.
# 80 ns external budget includes SCK launch/board/card return or receiver setup;
# the remaining 20 ns is reserved for the FPGA I/O data path. These are initial
# engineering budgets, not TF-card timing values from the board manual.
set_input_delay -clock [get_clocks {clk_50m}] -max 80.000 [get_ports {sd_miso}]
set_input_delay -clock [get_clocks {clk_50m}] -min 0.000 [get_ports {sd_miso}]
set_multicycle_path -setup -end 5 -from [get_ports {sd_miso}]
set_multicycle_path -hold -end 4 -from [get_ports {sd_miso}]
set_output_delay -clock [get_clocks {clk_50m}] -max 80.000 [get_ports {sd_mosi sd_cs_n}]
set_output_delay -clock [get_clocks {clk_50m}] -min 0.000 [get_ports {sd_mosi sd_cs_n}]
set_multicycle_path -setup -end 5 -to [get_ports {sd_mosi sd_cs_n}]
set_multicycle_path -hold -end 4 -to [get_ports {sd_mosi sd_cs_n}]
# Keep SCK itself within 10 ns of its 50 MHz launch edge.
set_output_delay -clock [get_clocks {clk_50m}] -max 10.000 [get_ports {sd_sck}]
set_output_delay -clock [get_clocks {clk_50m}] -min 0.000 [get_ports {sd_sck}]

# DDC SDA returns asynchronously from the sink (about 99.2 kHz SCL). There is
# no top-level DDC input clock. Keep internal core paths timed; cut input only.
set_false_path -from [get_ports {ddc_sda}]
# Output budget: within one 25 MHz cycle, not an I2C setup/hold specification.
set_output_delay -clock [get_clocks {clk_pixel}] -max 0.000 [get_ports {ddc_scl ddc_sda}]
set_output_delay -clock [get_clocks {clk_pixel}] -min 0.000 [get_ports {ddc_scl ddc_sda}]

# 125 MHz DDR => 4 ns serial UI. Bound serializer clock-to-pad data path to
# 2 ns; this is a local implementation budget, not an HDMI eye/skew guarantee.
# No false path is applied to the 25 MHz -> 125 MHz serializer data transfers.
set_max_delay -datapath_only -from [get_clocks {clk_hdmi_serial}] -to [get_ports {tmds_ch0_p tmds_ch1_p tmds_ch2_p tmds_clk_p}] 2.000

# LEDs are observation outputs without a receiver capture clock.
set_false_path -to [get_ports {status_led[0] status_led[1] status_led[2] status_led[3]}]

# No external SDRAM I/O delays: SDRAM uses the in-package primitive. Both PLL
# clocks and controller data/control paths remain analyzed by the device tools.
