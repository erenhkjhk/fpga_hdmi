"""Deterministic FAT32 superfloppy, two BMPs and fragmented 24-bit stereo WAV.

Only allocated sectors are exported. The SPI model rejects accesses outside
this list, so a wrong LBA cannot silently receive a zero-filled good sector.
"""
from pathlib import Path
import struct, hashlib, json

BUILD = Path(__file__).resolve().parent / 'build'
BUILD.mkdir(exist_ok=True)
sectors = {}
def le32(buf, at, value): struct.pack_into('<I', buf, at, value)
def le16(buf, at, value): struct.pack_into('<H', buf, at, value)
boot = bytearray(512)
boot[:3] = bytes.fromhex('eb5890')
le16(boot, 11, 512)
boot[13] = 1
le16(boot, 14, 32)
boot[16] = 1
le32(boot, 32, 66070)
le32(boot, 36, 513)
le32(boot, 44, 2)
boot[510:] = b'\x55\xaa'
sectors[0] = boot
fat = bytearray(512)
for cluster in (0, 1, 2, 3, 4): le32(fat, cluster*4, 0x0fffffff)
directory = bytearray(512)

def entry(index, name, cluster, size):
    start = index*32
    directory[start:start+11] = name
    directory[start+11] = 32
    le16(directory, start+26, cluster)
    le32(directory, start+28, size)

def bmp(rgb, bottom_up):
    # 2x2 BI_RGB with row padding; sign differs between pictures.
    b = bytearray(70)
    b[:2] = b'BM'
    le32(b, 2, len(b)); le32(b, 10, 54); le32(b, 14, 40)
    struct.pack_into('<iiHH', b, 18, 2, 2 if bottom_up else -2, 1, 24)
    le32(b, 34, 16)
    r,g,bl = rgb
    for row in range(2): b[54+row*8:60+row*8] = bytes([bl,g,r])*2
    return b

for idx, (rgb, bottom_up) in enumerate([((32,64,96), True), ((192,160,128), False)]):
    pic = bmp(rgb, bottom_up)
    sectors[546+idx] = pic + bytes(512-len(pic))
    entry(idx, f'PIC{idx}    BMP'.encode(), 3+idx, len(pic))

def sample(n):
    # Nontrivial deterministic signed signal; 2048 stereo pairs per loop.
    value = ((n*7919+12345)&0x3fffff)-0x200000
    return value, -value

pcm = b''.join((v&0xffffff).to_bytes(3,'little') for n in range(2048) for v in sample(n))
# Put data at offset510, forcing a PCM word across the first sector boundary.
fmt = struct.pack('<HHIIHH', 1,2,48000,288000,6,24)
chunks = b'JUNK'+struct.pack('<I',458)+bytes(458)+b'fmt '+struct.pack('<I',16)+fmt
chunks += b'data'+struct.pack('<I',len(pcm))+pcm
wav = b'RIFF'+struct.pack('<I',len(chunks)+4)+b'WAVE'+chunks
assert wav[502:506] == b'data' and len(wav)==510+len(pcm)
clusters = [7+2*i for i in range((len(wav)+511)//512)]
for i, cluster in enumerate(clusters):
    le32(fat, cluster*4, clusters[i+1] if i+1<len(clusters) else 0x0fffffff)
    block = wav[i*512:(i+1)*512]
    sectors[543+cluster] = block + bytes(512-len(block))
entry(2, b'BGM     WAV', clusters[0], len(wav))
sectors[32] = fat
sectors[545] = directory
ordered = sorted(sectors)
assert len(ordered)<=128
image = b''.join(sectors[lba] for lba in ordered)
image += bytes(65536-len(image))
(BUILD/'e2e_card.mem').write_text('\n'.join(f'{b:02x}' for b in image)+'\n', encoding='ascii')
(BUILD/'e2e_card.lba').write_text('\n'.join(f'{lba:08x}' for lba in ordered+[0xffffffff]*(128-len(ordered)))+'\n', encoding='ascii')
(BUILD/'e2e_media.json').write_text(json.dumps(dict(sectors=ordered,wav_bytes=len(wav),
    pcm_pairs=2048,pcm_data_offset=510,pcm_sha256=hashlib.sha256(pcm).hexdigest()),indent=2)+'\n')
print(f'E2E media: {len(ordered)} sparse sectors, two BMPs, {len(wav)}-byte fragmented WAV')
