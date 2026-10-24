"""Generate independent BMP and image-pipeline references; standard Python only."""
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parents[1]
V=ROOT/'sim/out/vectors'

def source_pixel(x,y):
    return ((x*43+y*17+11)&255,(x*7+y*67+23)&255,(x*59+y*3+191)&255)

def bmp(w,h,bottom):
    stride=(w*3+3)&~3
    size=54+stride*h
    header=struct.pack('<2sIHHI',b'BM',size,0,0,54)+struct.pack('<IiiHHIIiiII',40,w,h if bottom else -h,1,24,0,stride*h,0,0,0,0)
    data=bytearray(header)
    for fy in range(h):
        y=h-1-fy if bottom else fy
        for x in range(w): data.extend(reversed(source_pixel(x,y)))
        data.extend(b'\x00'*(stride-3*w))
    return data

def scaled(w,h,bottom,path):
    # Four positive weights, independent of the RTL's shared signed lerp engine.
    xs=[divmod(x*(w-1),639) for x in range(640)]
    with path.open('w') as f:
        for y in range(480):
            iy,ry=divmod(y*(h-1),479);fy=ry*256//479
            y0=h-1-iy if bottom else iy
            y1=h-1-min(iy+1,h-1) if bottom else min(iy+1,h-1)
            for ix,rx in xs:
                fx=rx*256//639;ix1=min(ix+1,w-1)
                p=[source_pixel(ix,y0),source_pixel(ix1,y0),source_pixel(ix,y1),source_pixel(ix1,y1)]
                rgb=[((p[0][c]*(256-fx)*(256-fy)+p[1][c]*fx*(256-fy)
                     +p[2][c]*(256-fx)*fy+p[3][c]*fx*fy+32768)//65536) for c in range(3)]
                f.write('00%02x%02x%02x\n'%tuple(rgb))

def generate():
    V.mkdir(parents=True,exist_ok=True)
    calls=[]
    for name,w,h,bottom in [('one',1,1,True),('tiny',2,3,False),('odd',641,481,True),
                           ('wide',4096,1,False),('tall',1,4096,True),('identity',640,480,False)]:
        data=bmp(w,h,bottom);(V/(name+'.bmp')).write_bytes(data)
        scaled(w,h,bottom,V/(name+'.hex'))
        calls.append(f'run_case("{name}",{len(data)},0,1);')
    base=bmp(3,2,False)
    bad=[]
    for name,offset,value,code in [('bad_signature',0,b'NO',1),('bad_width',18,struct.pack('<i',4097),2),
          ('zero_height',22,b'\x00'*4,2),('bad_compression',30,struct.pack('<I',1),2),
          ('offset_overflow',10,struct.pack('<I',0xfffffff0),3)]:
        data=base[:];data[offset:offset+len(value)]=value;bad.append((name,data,len(data),code))
    bad.append(('early_eof',base[:-4],len(base),4))
    for name,data,size,code in bad:
        (V/(name+'.bmp')).write_bytes(data)
        calls.append(f'run_case("{name}",{size},{code},0);')
    (V/'bmp_cases.vh').write_text('\n'.join(calls)+'\n',encoding='ascii')
    generate_osd()

def color(v,code):
    n=(v-128)*((code>>2)+1)
    r=(abs(n)+1)//2 * (-1 if n<0 else 1)
    return max(0,min(255,r+128+32*((code&3)-1)))

def blend(bg,fg,alpha):
    return tuple(((256-alpha)*b+alpha*f+128)//256 for b,f in zip(bg,fg))

def generate_osd():
    font=[int(x,16) for x in (ROOT/'assets/osd/osd_font_8x8192.hex').read_text().split()]
    logo=[int(x,16) for x in (ROOT/'assets/osd/anlogic_logo_argb4444.hex').read_text().split()]
    chars=(ROOT/'assets/osd/font_cn_chars.txt').read_text(encoding='utf-8').strip()
    def ink(text,x,y):
        for c in text:
            width=8 if ord(c)<128 else 16
            if x<width:
                a=ord(c)*16+y if width==8 else 2048+chars.index(c)*32+y*2+x//8
                return bool(font[a] & (128>>(x%8)))
            x-=width
        return False
    for frame,(scroll,code,uptime,status) in enumerate([(0,5,'00:00:00',1),(799,10,'12:34:56',7),(0,15,'99:59:59',8)]):
        b=32*((code&3)-1);c=((code>>2)+1)/2
        state='错误' if status&8 else '转场' if status&4 else '加载' if status&2 else '显示'
        texts=[('运行 '+uptime,16,16),('亮度:%+03d 对比:%.1fx'%(b,c),16,384),
               ('轮播:'+('开' if status&1 else '关')+' 状态:'+state,16,404),
               ('图片:00012/00345',16,424)]
        with (V/f'osd_{frame}.hex').open('w') as f:
            for y in range(480):
                for x in range(640):
                    rgb=tuple(color(v,code) for v in source_pixel(x,y)) if frame!=2 else (0,0,0)
                    if (8<=x<168 and 8<=y<40) or (8<=x<320 and 376<=y<448) or y>=456:
                        rgb=blend(rgb,(16,32,48),128)
                    if 496<=x<624 and 8<=y<72:
                        word=logo[(y-8)*128+x-496];a=word>>12
                        fg=tuple(((word>>shift)&15)*17 for shift in (8,4,0))
                        rgb=blend(rgb,fg,256 if a==15 else a*17)
                    for text,tx,ty in texts:
                        if x>=tx and ty<=y<ty+16 and ink(text,x-tx,y-ty):
                            rgb=blend(rgb,(240,245,255),240)
                    scroll_x=(x+scroll)%800
                    if 460<=y<476 and scroll_x<160 and ink('安路 FPGA 多媒体展示',scroll_x,y-460):
                        rgb=blend(rgb,(110,231,255),240)
                    f.write('%02x%02x%02x\n'%rgb)

if __name__=='__main__': generate()
