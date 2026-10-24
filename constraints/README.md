# HX4S20 引脚与时序约束

日期：2026-10-24。适用于 `EG4S20BG256`、顶层 `fpga_hdmi_top`，HDMI 输出使用用户确认的 **B 口**。

- `hx4s20_hdmi_b.adc`：23 个顶层端口位的引脚和电平设置，另由 TD 自动占用 4 个差分负端。
- `fpga_hdmi_top.sdc`：板载时钟、实际 PLL 派生时钟、I/O 工程预算及外部异步输入例外。
- 两文件登记在 `project1.al` 的 `ADC_FILE` / `SDC_FILE`，属于 `constraint_1`，综合和实现使用标记均启用。`rtl/sources.f` 是 HDL 编译清单，不加入 ADC/SDC。

## 来源与引脚表

板级来源为 [HX4S20开发板手册-HDL版2410(1).pdf](../docs/HX4S20开发板手册-HDL版2410(1).pdf)，以下页码为手册印刷页码。本轮同时查看了对应原理图，未只依赖 PDF 文字提取。用户提供的 PDF 保持原样。

| RTL 端口 | 手册信号 | FPGA 引脚 | 电平标准 | 手册页码 |
|---|---|---|---|---|
| `clk_50m` | CLK，50 MHz | R7 | LVCMOS33 | 21–22，图2-24 |
| `key_n[0]` | KEY1，上一张 | A2 | LVCMOS33 | 18–19，图2-20 |
| `key_n[1]` | KEY2，下一张 | B2 | LVCMOS33 | 18–19，图2-20 |
| `key_n[2]` | KEY3，自动开关 | B1 | LVCMOS33 | 18–19，图2-20 |
| `key_n[3]` | KEY4，系统复位 | C1 | LVCMOS33 | 18–19，图2-20 |
| `switch[0]` | SW1，亮度低位 | C8 | LVCMOS33 | 18，图2-19 |
| `switch[1]` | SW2，亮度高位 | C7 | LVCMOS33 | 18，图2-19 |
| `switch[2]` | SW3，对比度低位 | C6 | LVCMOS33 | 18，图2-19 |
| `switch[3]` | SW4，对比度高位 | C5 | LVCMOS33 | 18，图2-19 |
| `sd_cs_n` | SD_DAT3 / CS | A12 | LVCMOS33 | 19–20，图2-22 |
| `sd_sck` | SD_CLK | A14 | LVCMOS33 | 20 |
| `sd_mosi` | SD_CMD / MOSI | A13 | LVCMOS33 | 20 |
| `sd_miso` | SD_DAT0 / MISO | B14 | LVCMOS33 | 20 |
| `tmds_ch0_p` | HDMIB_D0_P | G5，负端 G6 | LVDS33 | 11，图2-11 |
| `tmds_ch1_p` | HDMIB_D1_P | F1，负端 F2 | LVDS33 | 11 |
| `tmds_ch2_p` | HDMIB_D2_P | E1，负端 D1 | LVDS33 | 11 |
| `tmds_clk_p` | HDMIB_CLK_P | C3，负端 C2 | LVDS33 | 12 |
| `ddc_scl` | HDMIB_SCL | P2 | LVCMOS33 | 11 |
| `ddc_sda` | HDMIB_SDA | R2 | LVCMOS33 | 11 |
| `status_led[0]` | LED1，就绪 | A4 | LVCMOS33 | 6，图2-3 |
| `status_led[1]` | LED2，忙 | A3 | LVCMOS33 | 6 |
| `status_led[2]` | LED3，自动轮播 | C10 | LVCMOS33 | 6 |
| `status_led[3]` | LED4，错误 | B12 | LVCMOS33 | 6 |

按键低有效，LED 高有效；SW1–4 向上为 1、向下为 0。因此无需更改 RTL，`STATUS_LED_ACTIVE_LOW=0`、`SWITCH_INVERT_MASK=0` 保持默认。SW1、SW3 向上而 SW2、SW4 向下时，两组编码均为 01，对应原亮度和原对比度。

**按键供电勘误（用户于 2026-10-24 确认）。** 手册图2-20 中物理 KEY1/KEY2 的 `VCC_1V5` 上拉标签错误，实板上拉电压为 3.3 V。以用户确认的实际电路为准，四个按键均使用 `LVCMOS33`、`PULLTYPE=NONE`，保留外部上拉。用户已修正 ADC；现有综合日志和物理 I/O 报告也记录了 A2/B2 的 LVCMOS33 设置。PDF 原件未修改。

HDMI 四对使用器件的真差分 `LVDS33`，只约束 P 端；现有 PHY 的四个 P 输出无需增加 N 端 RTL。已通过本机 TD 6.2 的只读 `import_device` / `query_current_package -lvds` 核对上述 P/N 对，`query_current_package -clock_io` 确认 R7 为全局时钟输入。器件数据库的 `LVDS33` 支持 OUTPUT、`TrueDifference=true`，不使用仿真单元替代 I/O。只锁 P 端、由工具分配 N 端也与[安路官方差分 I/O 说明](https://tech.anlogic.com/Cn/Index/listView/catid/12/m/Cn/tp/1/p/5.html)一致。

SDRAM 使用 `EG_PHY_SDRAM_2M_32` 合封接口，没有外露的顶层 SDRAM 端口，不分配普通 BGA GPIO。HPD/CEC、HDMI A、TF DAT1/DAT2、外部 I2S、JTAG 和配置 Flash 不在当前顶层中，不虚构端口约束。HDMI B 接显示器；DDC 保持原 HDMI 核的 SCL 输出、SDA 三态结构，内部弱上拉不作为外部 DDC 电气兼容性的证明。

## 时钟与例外

SDC 命令依据本机 TD 6.2 模板和 `D:/TD/doc/SWUG/SWUG200_Timing_Constraints_User_Guide.pdf`：`derive_clocks` 读取实际 PLL 参数并推导频率、相位，再按两个 `pll_inst.clkc[0/1]` 重命名。

| SDC 时钟 | 源 | 频率 / 周期 | 相位 |
|---|---|---|---|
| `clk_50m` | 板载 R7 | 50 MHz / 20 ns | 0° |
| `clk_sdram` | `u_pll_sdram/pll_inst.clkc[0]` | 150 MHz / 6.666… ns | 0° |
| `clk_sdram_180` | `u_pll_sdram/pll_inst.clkc[1]` | 150 MHz / 6.666… ns | 180° |
| `clk_hdmi_serial` | `u_pll_hdmi/pll_inst.clkc[0]` | 125 MHz / 8 ns | 0° |
| `clk_pixel` | `u_pll_hdmi/pll_inst.clkc[1]` | 25 MHz / 40 ns | 0° |

不把派生时钟重新声明成独立主时钟，不对这些共同参考源的时钟使用整组异步切除。尤其保留 25→125 MHz 并串转换、150 MHz 0°/180° SDRAM 路径的时序分析。本项目 SDC 对内部 CDC 和 mailbox 载荷保守计时；FIFO 另由 TD 自动加载原厂 IP Tcl，对 Gray 指针跨域路径施加 datapath-only max delay。未根据加密内部猜测寄存器名并添加宽泛 false path。今后若要放宽 CDC，必须在实际网表核对同步器首级、握手载荷稳定时间以及 FIFO 的原厂约束，不能直接切掉整个模块或时钟域。

外部按键、拨码无同步发射时钟，例外仅从这些输入端口出发；同步器后级与消抖逻辑继续计时。KEY4 是异步复位请求，本地同步释放链不整体豁免。DDC SDA 为低速异步返回，仅输入方向 false path，输出方向仍有预算。LED 没有外部采样时钟，仅其输出路径豁免。

## I/O 工程预算与验证范围

手册提供连接关系，没有 TF 卡 tCO、PCB 走线延迟、晶振抖动或 HDMI 接收端眼图参数。以下数值明确是本项目的初始约束预算，需要今后结合器件数据与实现结果复核，不能视作已验证的板级时序参数。

| 项目 | 初始预算及依据 |
|---|---|
| 时钟不确定度 | setup 0.2 ns、hold 0.1 ns，预留工程余量 |
| TF MISO | 最快 5 MHz 时钟半周期 100 ns；外部路径预算 max 80 ns / min 0 ns，5 拍 setup / 4 拍 hold，保留 20 ns FPGA 输入预算 |
| TF MOSI / CS | 同样使用 100 ns 半周期、外部 max 80 ns / min 0 ns；5/4 配对多周期仅应用于相应输出端口 |
| TF SCK | 单独保留 10 ns 的 FPGA 输出预算，不将 SCK 定义为内部工作时钟 |
| DDC 输出 | 25 MHz 域一拍输出预算，未宣称建立/保持及上升时间满足 I2C 电气规范 |
| TMDS | 125 MHz DDR 对应 4 ns UI；串行时钟至四路输出的 datapath max 2 ns，保留内部像素至串行域分析；这不是 HDMI 接收端时序模型或四对间 skew/眼图保证 |

SPI 的实际 `spi_byte_master` 在 50 MHz 上按 clock enable 工作，每字节重新启动分频计数，相对系统时钟并非唯一固定相位。SDC 用实际最快半周期的成对多周期约束，不创建固定相位的“5 MHz 内部时钟”；250 kHz 初始化阶段比此预算宽松。MISO、MOSI 与 CS 的预算含 SCK 发射延迟、卡/板路径或接收建立余量；未对内部 SPI 状态机、分频器或数据通路添加多周期。更改 SPI 最大频率、采样边沿或使能结构时需同步重审这些约束。

最初约束编辑阶段完成端口覆盖、引脚唯一性、差分负端保留、器件属性、Tcl 语法、工程登记和 PLL 参数静态核对。随后用户运行了 TD 流程；2026-10-24 对现有日志的只读复核确认约束已加载、I/O 分配正确，但综合和布线后均有时序违例，尚未收敛。具体资源、路径与告警见 [综合及现有实现结果核查](../docs/综合及现有实现结果核查.md)。本次复核没有重跑综合、仿真、布局布线或烧录，未更改 RTL、IP 和 SDC 数值。
