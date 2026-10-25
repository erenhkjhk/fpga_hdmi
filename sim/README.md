# ModelSim 2020.1 功能仿真

使用 **ModelSim Intel FPGA Starter Edition 2020.1**，本机路径为 `D:/modelsim/modelsim_ase/win32aloem`。脚本检查 `vsim -version`，不依赖PATH中可能存在的新版Questa。安路库来自 `D:/TD/sim_release/eg4`，首次仿真基准为 `5f29f03`；本次流水线优化基于 `extension-1-4-prep` 的 `f8bf19e`，结果按阶段记录于 [RESULTS.md](RESULTS.md)。

本目录只用于功能仿真，没有加入 `project1.al` 或 `rtl/sources.f`。测试、驱动和参考数据生成代码保留在Git中；编译库、日志、参考数据、WLF及图像统一在被忽略的 `sim/out`。

## 运行

从项目工作树根目录执行（需要Python 3）：

```powershell
python sim/run.py
```

脚本生成BMP/OSD参考数据，编译真实厂商库、工程Verilog和SystemVerilog测试台，逐项调用ModelSim 2020.1批处理运行。Verilog设计与厂商库不使用 `-sv`，避免原厂 `do` 端口名被当成SystemVerilog关键字；仅测试台使用SystemVerilog。

指定安装位置、选择测试、复用已有编译结果或记录波形：

```powershell
python sim/run.py --modelsim-bin D:/modelsim/modelsim_ase/win32aloem --td-root D:/TD
python sim/run.py --test tb_bmp_scaler
python sim/run.py --skip-compile --test tb_video_osd
python sim/run.py --skip-compile --waves --test tb_color_audio
python sim/collect_results.py
```

`--test` 可重复指定。修改源码或测试台后应重新编译，不能使用 `--skip-compile` 运行旧库。`--timeout` 是每项测试的墙钟超时，默认600秒；流水线增加了缩放计算拍数，本次完整回归使用 `python sim/run.py --timeout 1200`，缩放和帧缓存测试均需要数分钟，其余测试较短，具体取决于机器。测试台内部也有仿真时间看门狗。

每项同时要求进程成功、出现准确的 `PASS tb_名称`、日志没有Error/Fatal，不能仅凭ModelSim退出码判断通过。`run.do` 设置错误/中断处理；测试失败时脚本返回非零。`results.json` 为本次执行的选定测试结果。`collect_results.py` 检查所有测试台的已有日志、通过标记、错误及源码修改时间，生成全部测试的 `summary.json`；缺失、过期或失败日志都会返回非零。

## 覆盖

| 测试台 | 检查内容 |
|---|---|
| `tb_ip_smoke` | 实际行RAM同步读写，字库/Logo各8192字逐字比对 |
| `tb_bmp_scaler` | 1×1、2×3、641×481、4096×1、1×4096、640×480，正负高度、填充、随机背压、坏头/尺寸/偏移/EOF、权重/乘法/累加阶段取消、乘法阶段复位及重启 |
| `tb_color_audio` | 16档组合×256组RGB，舍入饱和与元数据，480对I2S样本、48 kHz间隔及10次ACR |
| `tb_fifo_cdc` | 实际异步FIFO数据顺序/普通读延迟、跨域复位重启，128条带背压mailbox消息 |
| `tb_display_control` | 拨码稳定检测、65535编号、整帧快照、运行时间秒进位及99:59:59回绕 |
| `tb_slideshow` | 上/下一张事件、循环、最新方向保留、失败跳图、转场后停留、自动开关和致命故障 |
| `tb_sdram_vendor` | 实际厂商控制器配合器件模型，两区域64字读写、方向切换、手动刷新后数据保持 |
| `tb_frame_store` | 实际控制器/FIFO/块RAM，两幅完整加载、底向上、全部65档Alpha、区域保护、取消、25 MHz连续读取、刷新和超时、全部返回/写入计数及流水线排空 |
| `tb_video_osd` | 实际ROM、调色及OSD三级流水，三帧逐像素比对、透明度、文字/参数/Logo、滚动回绕与元数据 |
| `tb_video_stream` | 640×480像素、800×525周期、坐标/帧首/行尾对齐，欠读后下一帧恢复 |
| `tb_fat32` | 裸卷和MBR、碎片根目录/文件链、目录枚举顺序、文件反压、越界索引后恢复 |
| `tb_sd_spi` | CMD0/8/55/41/58/59/17、250 kHz/5 MHz、512字节、反压和读拒绝错误 |

功能测试细节见 [RESULTS.md](RESULTS.md)。本次流水线修改另行运行了综合核查，见 [流水线优化记录](../docs/流水线优化与综合核查.md)；没有运行布局布线或烧录。

## 厂商库与仿真适配

全部工程 `.v`、PLL、Soft FIFO和四个新RAM/ROM都使用原文件，未生成替代IP或修改参数源。行RAM、转场RAM、ROM及Soft FIFO执行真实安路仿真模型。

厂商初始化代码只对 `.dat/.dath` 后缀执行读取，直接给它工程中的 `.mif` 会得到未知ROM数据。因此仅在测试台中用 `defparam` 把两个ROM内部的 `INIT_FILE` 指向**已有** `.mif.dath`，并与原HEX逐字比较。硬件包装、MIF、DATH和素材保持原样。仿真运行目录固定为 `al_ip`，使其相对初始化路径成立。

本机 `EG_PHY_SDRAM_2M_32` 是只有端口的空仿真单元，没有存储行为。`models/sdram_device.sv` 在真实控制器的SDRAM引脚上补充器件行为：2M×32、ACT/PRE/MRS/REF、顺序突发、CAS延迟和字节写屏蔽。它不替换控制器，不是完整器件时序/电气/保持时间模型。

`models/sd_card_spi.sv` 是只读SDHC协议激励；FAT32测试另有扇区接口激励。`tb_video_stream` 使用一拍FIFO响应激励，而真实FIFO在独立测试和帧缓存链中运行。运行时间测试加速了毫秒tick，100小时回绕采用测试台边界值注入；转场中部分帧边界加速，但关键Alpha帧完整读取并以25 MHz连续消费。

当前为模块及数据链功能回归，未执行完整TF卡文件到HDMI/TMDS的整机端到端仿真；PLL、HDMI协议核、DDC/EDID、串行PHY、电气与时序收敛没有动态自检结论。

## 输出与波形

- `out/compile_*.log`：编译日志。
- `out/tb_*.log`、`.transcript`：各项运行日志。
- `out/results.json`、`out/summary.json`：本次执行及全部已有日志汇总。
- `out/tb_*.wlf`：加 `--waves` 后记录所选控制/数据波形，避免记录大型存储数组。
- `out/osd_actual_0/1/2.ppm`：从DUT实际输出RGB写出的仿真帧；可用Pillow转为PNG。这些是仿真结果，不是素材静态预览。

在GUI查看测试台（先完成编译，从项目根目录进入 `al_ip`）：

```powershell
Set-Location al_ip
& 'D:/modelsim/modelsim_ase/win32aloem/vsim.exe' -gui -lib ../sim/out/work tb_video_osd -do 'do ../sim/waves.do'
```

然后在Transcript中执行 `run -all`，也可按需单步运行。GUI波形入口为 `waves.do`；批处理入口为 `run.do`。
