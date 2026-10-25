"""Export observations decoded from physical HDMI pins; reject bad WAV words."""
from pathlib import Path
import json
import re
import wave
from PIL import Image

root = Path(__file__).resolve().parent
results = root/'results'
log = (results/'tb_end_to_end.log').read_text(errors='replace')
assert 'PASS: tb_end_to_end TF SPI' in log and not re.search(r'\*\* (Fatal|Error):', log), 'E2E has not passed'
for name in ('a','half','b'):
    words = [int(v,16) for v in (results/f'e2e_hdmi_{name}.hex').read_text().split()]
    assert len(words)==640*480
    image = Image.new('RGB',(640,480))
    image.putdata([((v>>16)&255,(v>>8)&255,v&255) for v in words])
    image.save(results/f'e2e_hdmi_{name}.png')

words = [int(v,16) for v in (results/'e2e_hdmi_audio.hex').read_text().split()]
assert len(words)>=4096
pcm = bytearray()
for i, word in enumerate(words):
    value = (((i%2048)*7919+12345)&0x3fffff)-0x200000
    left, right = (word>>24)&0xffffff, word&0xffffff
    assert (left,right)==(value&0xffffff,(-value)&0xffffff), (i,hex(word))
    pcm += left.to_bytes(3,'little')+right.to_bytes(3,'little')
with wave.open(str(results/'e2e_hdmi_audio.wav'),'wb') as wav:
    wav.setnchannels(2);wav.setsampwidth(3);wav.setframerate(48000);wav.writeframes(pcm)

marker = re.search(r'^# (PASS: tb_end_to_end TF SPI.*)$',log,re.M).group(1)
record = dict(simulator='ModelSim Intel FPGA Starter Edition 2020.1',passed=True,
    result=marker,audio_pairs=len(words),audio_seconds=len(words)/48000,
    images=[f'e2e_hdmi_{n}.png' for n in ('a','half','b')],
    scope='SPI SDHC + FAT32 + real BRAM/FIFOs + encrypted SDRAM controller and HDMI + physical DQ/TMDS',
    qualification='Ideal PLL output clocks; 2-frame crossfade; 512/1024-word audio watermarks. Production defaults unchanged.')
(results/'e2e_summary.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(marker)
print(f'Physical HDMI observations: three 640x480 PNGs, {len(words)} stereo WAV pairs')
