# OSD字模与Logo资源

本目录包含扩展1、4所需字模、Logo像素数据及预览。标语为“安路 FPGA 多媒体展示”，时间显示上电运行时间。两个ROM已由用户在TD生成，当前 `rtl/video/video_osd.v` 直接使用这些ROM；本轮集成未改变素材或初始化数据。实现与静态核对范围见 [RTL设计说明](../../docs/RTL设计说明.md)。

## 直接使用的数据

| 文件 | 用途 | 数据规模 |
|---|---|---:|
| `osd_font_8x8192.hex` / `.bin` | 合并字库 | 8192个8位字，二进制8192字节 |
| `font_ascii_8x16.hex` / `.bin` | ASCII单独字库 | 128个码位，每字16字节，共2048字节 |
| `font_cn_16x16.hex` / `.bin` | 中文单独字库 | 28个有效字，容量128字，共4096字节 |
| `anlogic_logo_argb4444.hex` / `.bin` | Logo像素数据 | 8192个16位字，二进制16384字节 |
| `anlogic_logo_128x64.png` | 与Logo像素数据一致的透明PNG | 128×64，RGBA |
| `td_init/osd_font_8x8192.mif` | TD字库ROM初始化文件 | WIDTH=8，DEPTH=8192 |
| `td_init/anlogic_logo_argb4444.mif` | TD Logo ROM初始化文件 | WIDTH=16，DEPTH=8192 |
| `font_map.json` / `font_cn_map.csv` | 字符序号、Unicode及ROM地址映射 | 中文序号从0开始 |
| `font_cn_chars.txt` | 中文字序 | UTF-8，一行28个字符 |
| `osd_strings.json` / `osd_text.txt` | 标语、参数和状态文字 | UTF-8 |

HEX采用无文件头、无地址标记、每行一个十六进制字的通用格式：字库每行2位HEX，Logo每行4位HEX。根据用户补充的EG4 ROM界面及本机TD 6.2手册，已另外生成`td_init`目录内的两个MIF，供ROM的`Load Init File` / `Mif File`选项选择。MIF完整声明宽度、深度、地址和数据进制，显式列出0x0000至0x1FFF的全部8192个地址；没有简单改名HEX文件。TD人工生成的两个ROM及其MIF/DATH已在准备阶段静态核对通过，迁移时保留`al_ip`与`assets`的相对层级。

## 字模编码

- ASCII为8×16，中文为16×16，均为1bit前景掩码。
- 1表示文字前景，0表示透明背景；颜色和图层Alpha由后续RTL决定。
- 每个字先上行后下行；一行内从左向右；字节最高位为最左像素。
- ASCII每行1字节；中文每行2字节，先左8像素，再右8像素。
- ASCII码0至31、32空格及127均为空白，其余94个可打印字符有字形。
- 中文当前28字，其余100个中文字槽填0。

中文字序固定为：

```text
安路多媒体展示运行亮度对比轮播开状态显图片关加载转场错误
```

合并字库寻址：

```text
ASCII: address = code * 16 + row
       code=0..127, row=0..15

中文:  address = 2048 + index * 32 + row * 2 + half
       index=0..27, row=0..15, half=0(左字节)/1(右字节)

0x0000..0x07FF  ASCII，共2048字节
0x0800..0x17FF  中文槽，共4096字节；未用槽为0
0x1800..0x1FFF  预留，共2048字节，全部为0
```

例如“安”是中文序号0，起始地址0x0800；“路”是序号1，起始地址0x0820。中文字不能直接用Unicode码点当作ROM地址。

ASCII使用本机Consolas Regular，以13px字号放入8×16固定格，基线y=12；中文使用本机SimSun（宋体）16px，固定16×16格，采用单色栅格化。原字体文件没有复制进项目；`font_map.json`记录了源字体名称和SHA-256。图集和演示图由已打包数据解码生成，和ROM字节一致。

## Logo编码

`source/anlogic_logo_original.png`是用户原图的原样副本。`source/anlogic_logo_cutout.png`是使用imagegen完成去白背景的透明底派生图；具体提示词保存在同目录的`logo_processing.txt`。

从透明图保留比例缩放、居中放入128×64画布，再量化为ARGB4444：

```text
word[15:12] = Alpha
word[11:8]  = Red
word[7:4]   = Green
word[3:0]   = Blue
address    = y * 128 + x
```

从上到下、从左到右存储。Alpha=0完全透明，Alpha=15完全不透明，其他值为部分透明。透明像素数据统一为0。颜色/Alpha从4位恢复到8位时乘17。

Logo BIN采用小端16位字：每个像素先低字节、再高字节。HEX按数值写成四位十六进制，与机器字节序无关。例如0xF123表示A=15、R=1、G=2、B=3，在BIN中存为0x23、0xF1。

宽标志在128×64画布中会有上下透明留白。源文件保留较大分辨率，便于后续重新转换。

## 预览

- `font_ascii_8x16.png`：无间隔ASCII原尺寸图集，16列×8行，每格8×16。
- `font_cn_16x16.png`：无间隔中文原尺寸图集，16列×8行，每格16×16，空槽为黑。
- `preview/font_ascii_labeled.png`：放大字形和ASCII十六进制码。
- `preview/font_cn_labeled.png`：放大中文字形、序号、Unicode与字库起始地址。
- `preview/logo_alpha_6x.png`：棋盘底放大预览，棋盘格只存在于此预览，未写入Logo资源。
- `preview/osd_preview_640x480.png` / `osd_preview_2x.png`：使用实际字模、量化后Logo制作的静态排版预览；不是RTL仿真或上板截图，不代表动态效果已实现。

## 重新生成和检查

在项目根目录、具备Pillow的Python环境执行：

```powershell
python tools/build_osd_assets.py
```

也可指定`--ascii-font`、`--cn-font`和`--output`。重新运行使用保存的透明Logo，不重新请求图像生成。若更换字体，其栅格化结果也可能改变，请重新查看预览。

脚本检查字符覆盖、字库长度、地址布局、预留区清零、HEX/BIN一致性、掩码编码、Logo的HEX/BIN/PNG一致性，以及两个MIF的宽度、深度、地址连续性和数据内容。结果保存到`validation_report.json`；`asset_manifest.json`列出资源参数、大小与SHA-256。这些是素材数据检查，不涉及RTL仿真、综合或硬件验证。
