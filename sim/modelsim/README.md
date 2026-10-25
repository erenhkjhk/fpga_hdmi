# ModelSim 2020.1 回归

本目录使用 **ModelSim Intel FPGA Starter Edition 2020.1**，默认安装路径为 `D:/modelsim/modelsim_ase/win32aloem`。不使用PATH中的Questa替代。

在项目根目录运行：

```powershell
./sim/modelsim/run.ps1 -All -Rebuild
./sim/modelsim/run.ps1 -EndToEnd -Rebuild
& 'C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' sim/modelsim/render_e2e_results.py
& 'C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' sim/modelsim/collect_results.py
```

可通过 `-ModelSim`、`-Td`、`-Python` 覆盖安装路径；`collect_results.py` 的画面导出需要 Pillow。

仅运行指定用例：

```powershell
./sim/modelsim/run.ps1 -Tests @('tb_vendor_ip','tb_bmp+CASE=3','tb_memory_integration+STREAM')
```

单独运行数字参考用例前，先用Python运行 `generate_vectors.py`，或先运行一次 `-All`。测试和资源路径均由脚本定位到项目根目录。运行目录为 `al_ip`，对应实际IP中的相对初始化路径。

厂商模型来自 `D:/TD/sim_release/eg4/*.v`，直接由ModelSim解读受保护内容；没有替换为自制RAM/FIFO模型。RTL `.v` 按Verilog编译，测试平台 `.sv` 按SystemVerilog编译。

EG4模型实测只识别配套 `.mif.dath` 初始化数据，当前 `.mif` 或 `.hex` 文件名会得到X。脚本在 `build/ip_sources` 中生成四个ROM wrapper的仿真副本，**仅将INIT_FILE文件名加上 `.dath`**，其他内容与原生成文件完全一致；生产IP及原初始化文件均保持原样。`tb_init_probe` 保存这项差异的原始实验；`tb_vendor_ip` 对四份ROM所有地址与资源逐字比对。

`build` 是可重新生成的工作库、wrapper副本和独立数字参考。`results` 保存原始日志、汇总JSON及实际OSD输出图。每个用例需要出现明确 `PASS`，同时没有Fatal/Error，脚本才判通过。ModelSim在 `$fatal` 后可能以进程退出码0结束，因此仅看退出码不够。

原有存储集成采用SDRAM应用接口的事务响应模型，FAT32集成采用扇区传输接口响应模型，分别提供局部定向覆盖。新增的 `tb_end_to_end` 则在完整顶层连接SPI卡引脚模型、SDRAM芯片引脚模型和HDMI串行接收端；两类测试的边界不同。

## TF→物理SDRAM→HDMI播放

```powershell
./sim/modelsim/run.ps1 -Tests tb_sdram_physical
./sim/modelsim/run.ps1 -EndToEnd
```

`generate_e2e_media.py` 生成FAT32超级软盘镜像：两个2×2 BMP（正、负高度及行填充），经真实双线RAM和双线性缩放输出完整640×480；BGM.WAV为48kHz/24bit/双声道，2048对样本循环，data偏移510，跨不连续簇。卡模型从CS/SCK/MOSI接收CMD0/8/55/41/58/59/17，通过MISO返回响应和扇区，检查初始化和请求LBA。没有强制或替换内部扇区、FAT、FIFO或SDRAM应用接口信号。

TD的 `EG_PHY_SDRAM_2M_32` 外壳没有公开存储行为。`sdram_2mx32_model.sv` 因此连接真实加密控制器的CLK/RAS/CAS/WE/BA/ADDR/DM/DQ，建模4bank×2048row×256column，按MRS设置BL/CL、支持字节屏蔽和预充电/刷新，检查bank状态及总线所有权。它是功能设备模型，不包含器件模拟电气特性、板级延迟及完整JEDEC时序验收。`tb_sdram_physical` 在多地址区、跨行和最高地址回读并检查刷新后的数据保持。

`hdmi_serial_sink.sv` 从四条物理TMDS单端输出寻找符号边界，反解RGB、TERC4、BCH包及立体声音频，检查音频顺序、IEC60958奇偶和ACR。测试同时逐像素检查送入合成器的完整640×480帧，检查物理HDMI上没有OSD遮挡区域的图片和中间渐变色。

`tb_sdram_physical_pll` 进一步把相同的448字数据/字节屏蔽/刷新后保持检查连接到真实生成PLL，验证150MHz与180°输出下的引脚数据通路。实测接口输出延迟10周期，下游寄存器在第11周期消费。

长用例使用单独的 `build/e2e_work` 库：仅PLL wrapper换为理想150MHz/180°、125/25MHz功能时钟，避免Starter版重复模拟PLL内部高频振荡器。生成的七项RAM/ROM、四个异步FIFO、SDRAM加密控制核、HDMI加密协议核和ODDR PHY均保留。PLL真实模型由普通 `work` 库的 `tb_pll`、`tb_top_smoke` 单独验证，不得将 `-EndToEnd` 库用于PLL鉴定。

测试覆盖按键2下一张、按键1上一张及按键3开关；将转场参数由默认60帧缩短为2帧间隔，仍逐帧覆盖0、128、256系数。音频环低/高阈值由默认96000/192000字缩短为512/1024字，按键消抖为1ms、SD上电等待为1ms。生产默认值不变；默认60帧全系数及音频环回绕继续由原定向用例验证。所有像素、音频、SPI及SDRAM时钟频率保持正常值，完整640×480帧未缩小。

完整链路测试以 `AUTO_DEFAULT=0`、`AUTO_INTERVAL_MS=200` 固定手动操作顺序，只验证按键3的开关；生产默认仍为1及5000ms，自动停留/切换时序由 `tb_slideshow` 覆盖。

`tb_tf_wav_stream` 隔离真实5MHz SPI、FAT与WAV，以有限预缓冲模拟持续48kHz消费，运行400ms并逐字校验输入，避免长HDMI测试掩盖平均读卡带宽不足。`tb_sector_cache` 对两个缓存项执行命中、LRU替换、复位失效和8次完整512字节比较。

这轮发现并修复了扇区重复读取导致的音频断供。`sd_sector_buffer` 的原单扇区推断RAM扩为两个缓存项，两个文件上下文合计增加1024字节推断存储；没有新增需手动生成的IP类型。只读设计在复位或SD错误时失效缓存，完整接收512字节并成功结束后才发布标签。失败证据保留为 `tb_tf_wav_stream_before_fix.log`、`tb_end_to_end_before_fix.log`，不计入通过结果。

`render_e2e_results.py` 只接受通过的端到端日志，并重新逐对核验从物理HDMI包恢复的音频，导出24bit/48kHz双声道WAV及三张完整640×480 PNG。图像来自串行引脚解码，没有单独绘制效果图；中间帧、首图和第二张图各保存一次。`tb_end_to_end+PROBE` 是10ms启动诊断，不能替代完整用例或计入端到端通过数。

接收端字段映射参考公开实现的 [packet_assembler](https://github.com/hdl-util/hdmi/blob/master/src/packet_assembler.sv)、[audio_sample_packet](https://github.com/hdl-util/hdmi/blob/master/src/audio_sample_packet.sv) 和 [audio_clock_regeneration_packet](https://github.com/hdl-util/hdmi/blob/master/src/audio_clock_regeneration_packet.sv)。测试平台独立执行反解码、BCH和IEC60958奇偶检查，不调用发射核内部包字段。

`tb_hdmi_serial_sink` 用640个物理串行像素验证解码边界，特别包含与保护带具有相同码字的合法RGB `AB55AB`，防止接收端在活动视频区错误丢弃像素。

`tb_memory_integration+STREAM` 预填两帧，模拟中间转场帧，以持续25 Mpixel/s（含整帧307200个像素、不插行消隐）验证FIFO供数。常规 `tb_memory_integration` 则实际写入两幅完整图片，并校验61个转场系数点及每点128个像素。音频环的空读写指针预置到最后一个64字块，以有限运行时间覆盖跨末地址回绕。

真实厂商模板会报告Soft FIFO受保护的可选端口未连接，以及PLL动态配置端口宽度提示。日志保留这些提示；未通过修改或屏蔽生成文件消除。活动数据通路的复位、容量、顺序、声道标记及输出均由断言检查。
