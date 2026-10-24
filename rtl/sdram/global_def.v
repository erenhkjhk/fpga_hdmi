// Fixed geometry: EG4S internal 2M x 32 SDRAM. Do not change independently.
`ifndef APUG011_GLOBAL_DEF_V
`define APUG011_GLOBAL_DEF_V

`define DATA_WIDTH 32
`define ADDR_WIDTH 21
`define DM_WIDTH 4
`define ROW_WIDTH 11
`define BA_WIDTH 2

// Must equal the actual Sdr_clk frequency. This does NOT configure the PLL.
`define SDR_CLK_HZ 150000000
`define SDR_CLK_PERIOD (1000000000 / `SDR_CLK_HZ)

// 64 ms / 2048 rows, expressed directly in clock cycles.
// 64-bit intermediate avoids overflow; no truncated nanosecond division.
// At 150 MHz: terminal count 4686, period 4687 clocks (<= 64 ms / 2048).
`define SELF_REFRESH_INTERVAL (((64'd64000 * `SDR_CLK_HZ) / (64'd1000000 * (64'd1 << `ROW_WIDTH))) - 64'd1)

`endif
