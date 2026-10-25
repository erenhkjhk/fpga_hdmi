# 五项扩展IP逐项配置清单

实施更新：七项IP已由用户生成并用于RTL集成，以下参数保留作为配置记录。行RAM实际模块名为 `ram_scale_line1`，参数未变，无需重新生成。复位和读延迟已按实际厂商模型动态核对，见 [ModelSim仿真报告](扩展1至5_ModelSim仿真报告.md)；初版静态记录见 [集成说明](五项扩展RTL集成说明.md)。

这份清单对应 [五项扩展架构规划](五项扩展架构规划.md)，以TF卡WAV、上电运行时间、双线性缩放、淡入淡出、32柱DFT频谱为目标。

**现在需要人工生成7个组件定义：4个ROM、3个RAM。现有两个PLL及fifo_pixel_async不需要重新生成。** RAM定义各生成一次，后续RTL各实例化两次。以下是待生成参数，不代表已经存在这些厂商IP。

## 目录和生成总表

本次规划及初始化文件位于当前工作区：

```text
C:\Users\30909\.codex\worktrees\main-work\fpga_hdmi_project
```

建议每个IP保存到 `al_ip/<Component Name>/`，例如 `al_ip/rom_osd_font/rom_osd_font.v`；在TD创建组件时选择对应目录。传统生成器若直接在所选目录生成 `.v/.vhd/.ipc`，保留这些文件；新版生成器若另外生成XML、RTL子目录及TCL，也完整保留。不要只复制wrapper.v。

若你在 `D:\fpga_hdmi_project` 的TD工程操作，先把本次新增规划和 `assets/spectrum` 同步过去，并保持 `assets/osd` 初始化文件存在；两处路径不能混为同一个目录。本轮没有将文件复制到D盘，也没有改工程登记。

| Component Name | 类型 | 位宽×深度（字） | 地址位宽 | 后续实例数 | 实际连接时钟 | Implement Option |
|---|---|---:|---:|---:|---|---|
| rom_osd_font | Single Port ROM | 8×8192 | 13 | 1 | 25 MHz | EMB32K |
| rom_anlogic_logo | Single Port ROM | 16×8192 | 13 | 1 | 25 MHz | EMB32K |
| rom_dft_twiddle | Single Port ROM | 32×256 | 8 | 1 | 50 MHz | EMB9K(Timing Opt) |
| rom_dft_window | Single Port ROM | 16×256 | 8 | 1 | 50 MHz | EMB9K(Timing Opt) |
| ram_scale_line1 | Single Port RAM | 24×2048 | 11 | 2 | 50 MHz | EMB9K(Timing Opt) |
| ram_blend_block | Single Port RAM | 24×64 | 6 | 2 | 150 MHz | EMB9K(Timing Opt) |
| ram_audio_window | Single Port RAM | 24×256 | 8 | 2 | 50 MHz | EMB9K(Timing Opt) |

“深度”填字数8192/2048/256/64，不填地址位数13/11/8/6。时钟频率是RTL实际连接要求；截图中的RAM/ROM界面没有频率输入框，不需要寻找或增加此项。

这里选Single Port RAM是有意的：源图行缓存、转场块缓存、DFT样本缓存都是两个物理实例交替或分阶段读写，不需要在同一个实例上同时写一处、读另一处。

## 四个ROM：按ROM截图填写

对应截图：`docs/ROM/30aba828-ee2a-4899-830b-93711fcdfbca.png`。同一张界面分别生成四次，只改变组件名、实现类型、宽深及初始化文件。

| 界面字段 | rom_osd_font | rom_anlogic_logo | rom_dft_twiddle | rom_dft_window |
|---|---|---|---|---|
| Component Name | rom_osd_font | rom_anlogic_logo | rom_dft_twiddle | rom_dft_window |
| Device | EG4 / EG4S20BG256 | 同左 | 同左 | 同左 |
| Debug Enable (Port B is disabled in debug mode) | 不勾选 | 不勾选 | 不勾选 | 不勾选 |
| Pack Enable | 不勾选 | 不勾选 | 不勾选 | 不勾选 |
| Implement Option | **EMB32K** | **EMB32K** | **EMB9K(Timing Opt)** | **EMB9K(Timing Opt)** |
| Memory Type | Single Port ROM | Single Port ROM | Single Port ROM | Single Port ROM |
| Port A Options / Width | **8** | **16** | **32** | **16** |
| Port A Options / Depth | **8192** | **8192** | **256** | **256** |
| Port A / Output Register | **Register without Ocea** | **Register without Ocea** | **Register without Ocea** | **Register without Ocea** |
| Port B Options | 灰色禁用，不配置 | 同左 | 同左 | 同左 |
| Memory Initialization / Load Init File | 勾选 | 勾选 | 勾选 | 勾选 |
| Mif File | 下表F1 | 下表F2 | 下表F3 | 下表F4 |
| Fill Memory Initialization Values | 不勾选 | 不勾选 | 不勾选 | 不勾选 |
| Fill all with 0 / Fill all with 1 | 不使用 | 不使用 | 不使用 | 不使用 |

初始化文件均已存在，路径相对于项目根目录：

| 编号 | Mif File选择文件 | 内容 |
|---|---|---|
| F1 | `assets/osd/td_init/osd_font_8x8192.mif` | 合并ASCII及中文字库 |
| F2 | `assets/osd/td_init/anlogic_logo_argb4444.mif` | 128×64 Logo，ARGB4444 |
| F3 | `assets/spectrum/td_init/dft_twiddle_q15_32x256.mif` | 高16位cos、低16位负sin，Q1.15 |
| F4 | `assets/spectrum/td_init/hann_q15_16x256.mif` | 256点对称Hann窗，Q1.15 |

当前工作区中F3的完整路径示例：

```text
C:\Users\30909\.codex\worktrees\main-work\fpga_hdmi_project\assets\spectrum\td_init\dft_twiddle_q15_32x256.mif
```

用Select选择MIF，不能选PNG、BIN、HEX或旧DATH。不要用“Fill all with 0”替代Load Init File。生成器若产生DATH，让TD从选定MIF重新生成；保留新的附带文件，避免使用以前配置遗留的路径。

Logo与字库用EMB32K是为了给行缓存、FIFO及HDMI核保留9K块。不是照截图默认的EMB9K(Area opt)全部生成，也不是改变资源文件的数据格式。

**ROM时钟与复位约定：** 选择额外输出寄存器以便流水线实现；不选Ocea版本，预计不需要输出寄存器使能端口。若生成文件导出 `rsta`，接相应域的高有效复位，作用是复位输出寄存器，不改写ROM内容。截图没有独立Reset Type字段，因此不虚构一个需要用户选择的复位选项；具体RESETMODE以生成文件为准。

预计接口语义为 `addra / clka / doa`，以及输出寄存器对应的复位端口。ROM通常本身已同步读，增加输出寄存器后不能再当作组合查表使用。后续会核实实际总读延迟并对齐RGB、坐标和帧行标志，不在当前阶段盲定为一拍。

## 三个RAM：按四张RAM截图逐页填写

每次生成一个定义。截图的 `ram_scale_line1` 名称及16位示例不是全部照抄：本方案保持RGB888和24位PCM，所以三个RAM的Width都改成 **24**。

对应截图：

- Basic：`docs/RAM/56a89127-2404-44ab-a855-2674d0f433b5.png`
- Port A Options：`docs/RAM/769d167b-4ead-4a01-b516-d6203329c24c.png`
- Port B Options：`docs/RAM/1b3aa230-fc64-4325-8082-fdeef6c15687.png`
- Other Options：`docs/RAM/fd28b839-e01b-4784-b3ec-f6186356e289.png`

顶部字段：

| 字段 | ram_scale_line1 | ram_blend_block | ram_audio_window |
|---|---|---|---|
| Component Name | ram_scale_line1 | ram_blend_block | ram_audio_window |
| Device | EG4 / EG4S20BG256 | 同左 | 同左 |
| Debug Enable (Port B is disabled in debug mode) | 不勾选 | 不勾选 | 不勾选 |
| Packable | 不勾选 | 不勾选 | 不勾选 |

Basic页：

| 字段 | 三个RAM均使用的值 |
|---|---|
| Implement Option | **EMB9K(Timing Opt)** |
| Memory Type | **Single Port RAM** |
| Byte Write Enable | **None**，不用8/9位分字节写 |

Port A Options页：

| 字段 | ram_scale_line1 | ram_blend_block | ram_audio_window |
|---|---|---|---|
| Memory Size / Width | **24** | **24** | **24** |
| Memory Size / Depth | **2048** | **64** | **256** |
| Operating Mode | **No Change** | **No Change** | **No Change** |
| Operating Enable | **Use Cea** | **Use Cea** | **Use Cea** |
| Output Register | **Register without Ocea** | **Register without Ocea** | **Register without Ocea** |
| Port Enable | **Use Wea**，Single Port模式中若灰色即保留该状态 | 同左 | 同左 |

Port B Options页：全部保持灰色禁用。**不要为了填B口而切换Dual Port或Simple Dual Port。** 不设置Width/Depth、Mode、Enable及Output Register。

Other Options页：

| 字段 | 三个RAM均使用的值 |
|---|---|
| Memory Initialization | **None** |
| Load Init File / Mif File | 不选择，留空 |
| Fill Memory Initialization values | 不选择 |
| Fill all with 0 / Fill all with 1 | 不选择 |

**RAM时钟与复位约定：** `clka` 分别接50/150/50 MHz；`cea`由后续控制器在有效操作期间使能，`wea`区分写/读。Output Register选择without Ocea后，不能依赖额外ocea门控读结果，控制器应按实际延迟产生独立valid。

截图没有独立RAM Reset Type控件。若实际生成文件有 `rsta`，接各域高有效复位并核实RESETMODE；没有的端口不凭空连接。RAM内容不要求上电清零，也不在复位时逐地址清零；控制器复位有效行号、块编号及采满标志，写满有效数据后才允许读取。No Change只是同地址写入时输出行为的选择，不提供自动数据有效标志。

后续各定义的两个实例分别是：

| 定义 | 实例用途 |
|---|---|
| ram_scale_line1 | 源图相邻两行，轮换更新；每行两相邻像素分拍读取 |
| ram_blend_block | 旧图64像素块、新图64像素块；同时读出后配对混合 |
| ram_audio_window | 采样窗A、采样窗B；一个采样、另一个DFT |

## 现有PLL及FIFO：复用清单

以下是已有实际生成文件的参数核对记录，**不在本轮待生成的7项之内**。

| 已有定义 | 现有参数 | 后续使用 |
|---|---|---|
| pll_sdram | 输入50 MHz；C0=150 MHz/0°；C1=150 MHz/180°；reset、extlock已启用 | 沿用存储和移相时钟 |
| pll_hdmi | 输入50 MHz；实际C0=125 MHz/0°；C1=25 MHz/0°；reset、extlock已启用 | 沿用视频/PHY时钟及48 kHz节拍基准 |
| fifo_pixel_async | 32位写/读，配置深度1024/1024，ASYNC，ERAM/EMB9K(Timing Opt)，2级同步 | 原两实例保留，另加两个音频实例 |

`fifo_pixel_async`其余既有参数：

| 界面/参数 | 既有值 |
|---|---|
| RAM Option | ERAM |
| Implement Option | EMB9K(Timing Opt)，MEMORY_TYPE=4 |
| Clock Mode | ASYNC，COMMON_CLK_EN=0 |
| Synchronization Stages | 2 |
| Write Width / Read Width | 32 / 32 |
| Write Depth / Read Depth | 1024 / 1024 |
| Show Ahead Option | Disable |
| Out Reg | Disable / NOREG |
| Almost Full Num | 896 |
| Almost Empty Num | 256 |
| Reset Type | ASYNC Reset / RST_TYPE=1 |
| 异步复位同步释放选项 | 既有ASYNC_RST_SYNC_RELS=0，外层按域处理释放 |
| Dout Reset Value | 0 |
| wrusedw / rdusedw | 10位 |
| 实际可用容量 | 1023个32位字，不能按1024字计算满容量 |

| FIFO实例用途 | 写时钟 | 读时钟 | 数据 |
|---|---:|---:|---|
| 原图片加载 | 50 MHz | 150 MHz | 00+RGB888 |
| 原视频输出 | 150 MHz | 25 MHz | 00+RGB888 |
| 新音频写入 | 50 MHz | 150 MHz | 左/右各一个32位字 |
| 新音频播放 | 150 MHz | 25 MHz | 左/右各一个32位字 |

两个新实例分别拥有独立存储及复位状态；不是与视频共享同一个FIFO实例。均使用普通模式的re/valid握手，两侧复位及wr_rst_done/rd_rst_done处理与现有工程保持一致。

无需12.288 MHz音频PLL：WAV解析直接得到并行PCM，在25 MHz域用分数累加器产生平均48 kHz提交节拍，ACR使用实际25 MHz对应的N/CTS。当前时间戳也不需要RTC IP。

无需FFT IP：本方案采用自研256点DFT。无需另外生成乘法器、除法器或图标ROM IP；这些运算按共享RTL流水线实现，小型图形按坐标绘制。未来若布局结果要求调整实现，再提出具体新增IP参数，不预先生成未被选定的核。

## 建议生成顺序与返回核对

1. 先生成 `rom_osd_font`、`rom_anlogic_logo`，选择现有OSD MIF。
2. 生成 `ram_scale_line1`、`ram_blend_block`、`ram_audio_window`，不选初始化文件。
3. 生成 `rom_dft_twiddle`、`rom_dft_window`，选择新准备的频谱MIF。
4. 保留TD生成的全部目录及初始化附带文件，告知实际所在工作区及路径；截图可补充，实际生成文件是核对依据。

随后AI读取实际文件核对：组件名、宽度/深度/地址范围、存储类型、输出寄存器、使能和复位端口、初始化路径、系数字序、读延迟；再据此确定外层valid和控制信号流水线。不会用手写wrapper冒充TD实际生成文件，也不会在本轮绕过人工生成流程。

每生成一项，查看Estimated resource usage。若TD拒绝某个宽深组合，或当前版本选项与截图有变化，保留报错和现有文件再核对，不自行改成16位、换成另一类存储器或去掉输出寄存器。预估资源不等于已经通过完整设计综合。
