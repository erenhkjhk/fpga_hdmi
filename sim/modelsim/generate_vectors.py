"""Independent numeric references; no RTL/vendor model replacement."""
from pathlib import Path
import math
import json

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / 'build' / 'vectors'
OUT.mkdir(parents=True, exist_ok=True)
def words(path):
    return [int(x, 16) for x in path.read_text().split()]
def signed(x, bits):
    return x-(1<<bits) if x & (1<<(bits-1)) else x
def save(name, values, digits):
    (OUT/name).write_text(''.join(f'{v:0{digits}x}\n' for v in values))

win=words(ROOT/'assets/spectrum/hann_q15_16x256.hex')
tw=words(ROOT/'assets/spectrum/dft_twiddle_q15_32x256.hex')
report={}
for case in range(5):
    if case==0: samples=[0]*256
    elif case==1: samples=[2097152]*256
    elif case==2: samples=[round(4194304*math.sin(2*math.pi*20*n/256)) for n in range(256)]
    elif case==3: samples=[round(2097152*(math.sin(2*math.pi*7*n/256)+math.cos(2*math.pi*77*n/256))) for n in range(256)]
    else: samples=[-8388608 if n%2 else 8388607 for n in range(256)]
    windowed=[(s*w)>>15 for s,w in zip(samples,win)]
    powers=[]
    for k in range(128):
        real=sum(x*signed(tw[(k*n)%256]>>16,16) for n,x in enumerate(windowed))>>29
        imag=sum(x*signed(tw[(k*n)%256]&65535,16) for n,x in enumerate(windowed))>>29
        powers.append(real*real+imag*imag if k else 0)
    heights=[]
    for b in range(32):
        energy=sum(powers[b*4:b*4+4]);level=energy.bit_length()-1 if energy else 0
        heights.append(max(0,min(120,level*5-50)))
    save(f'dft_samples_{case}.hex',[s&0xffffff for s in samples],6)
    save(f'dft_heights_{case}.hex',heights,2)
    report[str(case)]={'heights':heights,'peak_bar':max(range(32),key=heights.__getitem__)}
(OUT/'reference.json').write_text(json.dumps(report,indent=2))
print(f'Generated DFT numeric references: {OUT}')

# Independent OSD scene description, rendered using the supplied glyph assets.
font=words(ROOT/'assets/osd/osd_font_8x8192.hex')
logo=words(ROOT/'assets/osd/anlogic_logo_argb4444.hex')
cn=(ROOT/'assets/osd/font_cn_chars.txt').read_text(encoding='utf-8').strip()
def text_pixel(text, x, y):
    cursor=0
    for char in text:
        width=8 if ord(char)<128 else 16
        if cursor<=x<cursor+width:
            bit=7-((x-cursor)%8)
            addr=ord(char)*16+y if width==8 else 2048+cn.index(char)*32+y*2+(x-cursor)//8
            return (font[addr]>>bit)&1
        cursor+=width
    return 0
texts=[(8,8,'运行12:34:56'),(8,344,'WAV'),(8,368,'亮度:-32  对比:1.25x'),
       (8,388,'轮播: 开  状态: 显示'),(8,408,'图片:00012/00034'),(0,456,'安路 FPGA 多媒体展示')]
def adjusted(c,b=2,k=1):
    return max(0,min(255,((c-128)*[4,5,3,6][k]+2)//4+128+[0,32,-32,64][b]))
pixels=[]
for y in range(480):
    for x in range(640):
        rgb=[adjusted((3*x+y)%256),adjusted((x+5*y)%256),adjusted((x^y)&255)]
        if 320<=x<632 and 320<=y<440:
            bar=(x-320)*32//312;off=(x-320)*32%312;height=bar*4%121
            if off<240 and 440-y<=height:
                color=[191,96,48] if y<360 else [24,156,132]
                rgb=[c//4+f for c,f in zip(rgb,color)]
            if height and 440-y==height:rgb=[255,240,160]
        if 4<=x<296 and 364<=y<430:rgb=[c//4 for c in rgb]
        if 272<=x<284 and 344<=y<356 and x-272<=(y-344 if y<350 else 355-y):rgb=[96,240,144]
        if 504<=x<632 and 8<=y<72:
            value=logo[(y-8)*128+x-504];alpha=value>>12
            rgb=[(c*(15-alpha)+((value>>s)&15)*17*alpha+7)//15 for c,s in zip(rgb,[8,4,0])]
        for tx,ty,text in texts:
            if ty<=y<ty+16 and x>=tx and text_pixel(text,x-tx,y-ty):rgb=[255]*3;break
        pixels.append((rgb[0]<<16)|(rgb[1]<<8)|rgb[2])
save('osd_frame.hex',pixels,6)
print('Generated complete 640x480 OSD scene reference.')
