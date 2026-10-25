# 256点DFT初始化资源

这些文件为五项扩展规划新增的数值资源，不是已经生成的安路IP。使用 `tools/build_spectrum_assets.py` 生成；没有修改已有OSD素材。

| 数据 | 位宽×深度 | TD中选择的初始化文件 | 目标组件名 |
|---|---|---|---|
| 旋转因子 | 32×256 | `td_init/dft_twiddle_q15_32x256.mif` | `rom_dft_twiddle` |
| 对称Hann窗 | 16×256 | `td_init/hann_q15_16x256.mif` | `rom_dft_window` |

旋转因子地址为 `(k*n) mod 256`。每个32位字的高16位为 `cos(2πa/256)`，低16位为 `-sin(2πa/256)`，均是16位二进制补码Q1.15。RTL切片后必须显式按有符号数解释。正一饱和到32767，负一为-32768。不要再次对低16位取负。

四个核对值：地址0为 `7FFF0000`，64为 `00008000`，128为 `80000000`，192为 `00007FFF`。

窗函数为 `0.5 - 0.5*cos(2πn/255)`，n=0..255；按同一Q1.15规则量化，首末项为0。采样窗乘积右移15位后仍为24位有符号PCM。这里使用对称窗，分母是255；不能混用分母256的周期窗参考数据。

BIN以小端无符号字存储补码位模式；HEX每行一个字；MIF包含全部256个地址。TD的Load Init File选择MIF，不选择BIN，也不把HEX改名成MIF。地址位宽8位。

`validation_report.json`记录文件SHA-256、量化误差、四象限值和一个2437.5 Hz正弦的DFT峰值检查。检查通过只说明系数文件与数值约定一致，不说明硬件MAC、流水线或时序已通过验证。

重新生成命令：

```powershell
& 'C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/build_spectrum_assets.py
```
