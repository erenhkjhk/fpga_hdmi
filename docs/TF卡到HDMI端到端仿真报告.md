# TF卡→物理SDRAM→HDMI端到端播放仿真

日期：2026-10-25。仿真器为 **ModelSim Intel FPGA Starter Edition 2020.1（2020.02 / Feb 28 2020）**，使用 `D:/modelsim/modelsim_ase/win32aloem`，厂商库为 `D:/TD/sim_release/eg4`。

**结果：34/34项检查通过**，包含既有28项与新增6项。完整端到端用例运行至282.211100ms，ModelSim报告Errors=0；厂商模板的60条可选端口/宽度提示保留。10ms PROBE和修复前的失败记录不计入通过项。原始日志为 `sim/modelsim/results/tb_end_to_end.log`，机器汇总为 `sim/modelsim/results/summary.json`。

## 本轮结果

| 检查 | 实际结果 |
|---|---|
| 图片操作 | 3次完整帧提交：首图、下一张、上一张；自动轮播按键开、关均通过 |
| 物理HDMI画面顺序 | `204060`→`707070`→`C0A080`→`707070`→`204060`，两次渐变均通过 |
| 视频比对 | 全路径有效像素检查；物理HDMI非OSD区域880000个普通图片像素、160000个渐变像素一致 |
| 连续WAV | 12506对输入样本，串行HDMI恢复12506对，逐对完全相同，无缺失、重复或意外静音；覆盖6个完整2048对周期及下一周期 |
| 读卡与刷新 | 178个物理SPI扇区事务，10470次物理SDRAM刷新；卡模型记录7次WAV循环起点读取（含首次） |
| 协议检查 | TMDS边界、TERC4、包头及子包BCH、音频奇偶、ACR=6144/25000通过 |
| 新增定向用例 | 物理SDRAM、真实PLL＋物理SDRAM、缓存、真实SPI/WAV吞吐、接收端同码边界均通过 |

完整链路实际输出的中心颜色分别在76.365、160.365、177.165、261.165、277.965ms依次确认。音乐在两次切换、两次渐变及文件循环期间持续逐对检查。仿真配置和适用边界见后文。

输出图：[首图](../sim/modelsim/results/e2e_hdmi_a.png)、[中间渐变帧](../sim/modelsim/results/e2e_hdmi_half.png)、[第二张](../sim/modelsim/results/e2e_hdmi_b.png)。[HDMI恢复的WAV测试音频](../sim/modelsim/results/e2e_hdmi_audio.wav)为24bit/48kHz/双声道，包含从首对WAV起的12506对连续样本，约0.260542秒；不包含启动时的回退音及预缓冲静音。

## 完整链路与数据检查

- TF卡模型只通过CS/SCK/MOSI/MISO与完整顶层交互，实际运行SDHC初始化及CMD17单扇区读取。没有强制内部扇区接口、FAT文件流、SDRAM应用响应或FIFO数据。
- FAT32镜像包含两张2×2 RGB24 BMP，分别使用正、负高度及行填充。经实际 `ram_scale_line1`、双线性缩放和异步FIFO，写入完整640×480帧区；逐个检查所有有效图片像素。
- WAV为48kHz、24bit、有符号小端双声道。2048对不同样本循环，data起点位于扇区偏移510，文件簇链为7→9→11…，刻意覆盖跨扇区样本和分散簇。
- 图像和音频均经真实加密SDRAM控制器的RAS/CAS/WE/BA/ADDR/DM/DQ引脚访问4bank×2048row×256column×32bit存储模型。调度、刷新、四个实际异步FIFO、音频环和声道标记保持在链路中。
- 视频通过OSD合成器、真实加密HDMI协议核及ODDR PHY发出；接收端从四条物理TMDS输出定位符号，反解RGB、TERC4、包头及子包BCH、IEC60958奇偶和音频样本，检查ACR为N=6144、CTS=25000。
- 按键2切到下一张，按键1切回上一张，按键3开关自动轮播。HDMI画面中央必须按“首图→中间渐变→第二张→中间渐变→首图”顺序出现；非OSD区域逐像素检查，音频从第一对WAV样本起连续逐对比对，跨图片操作和文件循环不得丢失、重复或插入静音。

## 厂商模型和读延迟

原有七项RAM/ROM及FIFO模型结论仍见《扩展1至5_ModelSim仿真报告》。本轮重新运行了厂商IP、PLL、内存供数和FAT/WAV相关检查。

新增物理SDRAM测试实测MRS为 **BL=4、CL=3、顺序突发、非单字写**。应用读请求被采入后第10个周期输出有效信号和数据，下游同步逻辑在第11个周期消费。两种口径分别在时钟边沿后的稳定点和下游采样点检查，避免把采样差一拍误认为控制器与文档不符。

`tb_sdram_physical` 和 `tb_sdram_physical_pll` 均校验448个回读字、324个实际写入字，包含跨列/行边界、两帧区、音频区、最高地址、刷新后保持和逐字节屏蔽。后者直接加载实际生成的150MHz/180° PLL，验证真实相位关系下的DQ数据路径。

TD的 `EG_PHY_SDRAM_2M_32` 公开外壳没有存储行为，因此新建芯片功能模型，连接控制器物理引脚；保留真实控制器。模型检查bank开关、突发顺序、总线所有权及字节掩码，**不承担模拟电气特性、板级延迟或全部JEDEC时序验收**。

## 实际发现并修复的问题

旧的单扇区缓冲在一扇区一簇的分散WAV中交替读取数据扇区和同一个FAT扇区，重复FAT读取占用了大量5MHz SPI带宽。

独立真实SPI吞吐用例在 **330.046130ms** 发生断供，累计产生和消费均为28672个PCM字；完整端到端用例也在 **183.225500ms、第7232对WAV样本** 出现非预期静音。两者的预缓冲/消费者不同，因此暴露时刻不同。原始失败日志分别保留为 `tb_tf_wav_stream_before_fix.log` 和 `tb_end_to_end_before_fix.log`。

修复 `rtl/storage/sd_sector_buffer.v`：

- 将现有512字节推断RAM扩为两个512字节缓存项，以LBA为标签，优先选空项，否则替换最近未使用项。
- 命中直接发布已缓存扇区，保留原有load-done及同步读数据握手。持续顺序数据访问期间，可保留反复使用的FAT扇区。
- 缺失时先使替换项失效；只有512字节完整接收且SD事务成功结束才发布新标签。复位及SD错误使缓存失效。
- 两个文件上下文合计增加1024字节推断存储，沿用现有缓冲RAM写法；没有增加需要手动生成的新IP类型。

缓存定向检查完成8次整扇区比较，覆盖命中、LRU替换及复位后重新读卡。原FAT/WAV四轮循环仍逐字一致，物理扇区事务由19次降为17次。修复后的400ms真实SPI吞吐检查产生64696个PCM字，按48kHz消费36434字，跨16轮文件循环，无断供。该吞吐用例用队列计数隔离平均源带宽；真实有限FIFO、反压和SDRAM音频环由完整端到端用例检查。

另修正了接收端模型的保护带识别边界：合法RGB `AB55AB` 也可能产生与视频保护带相同的三路码字，活动视频区内必须把它们作为像素解码。新增640像素串行定向测试，先复现丢失这类像素的问题，再验证修复通过；该项只改进测试模型，不修改业务RTL。失败证据保留为 `tb_hdmi_serial_sink_before_fix.log`。

## 仿真配置和边界

长时完整用例的七项RAM/ROM、四个异步FIFO、SDRAM加密控制器、HDMI加密协议核及ODDR全部使用实际生成/厂商模型。仅PLL在独立 `e2e_work` 库中换为理想150MHz/180°、125MHz/25MHz输出，减少Starter版内部振荡器的事件开销。实际PLL的复位、锁定、频率和相位由原回归及新增物理SDRAM＋真实PLL用例单独验证。

为缩短等待，测试把渐变设为2帧间隔（逐帧经历0、128、256），音频低/高水位设为512/1024字，按键消抖和SD上电等待设为1ms。生产默认的60帧渐变、96000/192000字水位及其他默认值未改变。原内存集成仍验证60帧的61个系数点、音频环末地址回绕及完整307200像素的持续25 Mpixel/s供数。

测试还设置 `AUTO_DEFAULT=0`、`AUTO_INTERVAL_MS=200`，便于按预定顺序执行手动下一张/上一张；生产默认仍为1及5000ms。本次完整链路只检查自动轮播按键的开关动作，停留计时和自动发起切换由已有 `tb_slideshow` 定向用例覆盖。

输入BMP较小，完整输出及HDMI时序保持640×480、800×525总时序和25MHz像素时钟。该用例覆盖完整功能路径及实际数据一致性，不等同于所有卡片响应延迟、所有FAT碎片分布和所有BMP尺寸的性能验收；尺寸、文件异常及OSD定点数值仍由已有定向用例覆盖。

本轮没有进行综合、布局布线、板级时序收敛或上板验收，未处理工程登记及引脚约束。

## 复现和观察文件

在工程根目录运行：

```powershell
./sim/modelsim/run.ps1 -All -Rebuild
./sim/modelsim/run.ps1 -EndToEnd -Rebuild
& 'C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' sim/modelsim/render_e2e_results.py
& 'C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' sim/modelsim/collect_results.py
```

完整用例通过后，`render_e2e_results.py` 再次逐对核对物理HDMI恢复的音频，并生成：

- `sim/modelsim/results/e2e_hdmi_a.png`、`e2e_hdmi_half.png`、`e2e_hdmi_b.png`：从串行引脚解出的三张完整640×480画面，含实际OSD和频谱；不是另行绘制的效果图。
- `sim/modelsim/results/e2e_hdmi_audio.wav`：从HDMI音频包恢复的24bit/48kHz双声道连续音乐。
- `sim/modelsim/results/e2e_summary.json`：完整用例结果、恢复样本数及模型边界。
- `sim/modelsim/results/summary.json`：既有28项与新增6项检查的汇总。原始失败证据和10ms PROBE不计入通过项。

接收端字段映射的公开参考链接及详细运行方式见 `sim/modelsim/README.md`。
