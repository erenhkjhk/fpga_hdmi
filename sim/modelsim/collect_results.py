"""Collect actual ModelSim pass/failure markers and render observed OSD pixels."""
from pathlib import Path
import argparse
import json
import re
from PIL import Image

parser=argparse.ArgumentParser()
parser.add_argument('--allow-incomplete',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parent
results=root/'results'
specs=['tb_vendor_ip','tb_pll','tb_init_probe']
specs += [f'tb_bmp+CASE={i}' for i in range(7)]
specs += [f'tb_wav+CASE={i}' for i in range(5)]
specs += ['tb_controls','tb_slideshow','tb_osd','tb_pcm']
specs += [f'tb_dft+CASE={i}' for i in range(5)]
specs += ['tb_fat_media','tb_memory_integration','tb_memory_integration+STREAM','tb_top_smoke',
          'tb_sdram_physical','tb_sdram_physical_pll','tb_sector_cache','tb_tf_wav_stream','tb_hdmi_serial_sink','tb_end_to_end']
records=[]
for spec in specs:
    path=results/(spec.replace('+','_').replace('=','_')+'.log')
    if spec=='tb_top_smoke' and not path.exists():path=results/'tb_top_smoke_early.log'
    text=path.read_text(errors='replace') if path.exists() else ''
    marker=re.search(r'^# (PASS: '+re.escape(spec.split('+')[0])+r'.*)$',text,re.M)
    errors=re.findall(r'^.*\*\* (?:Fatal|Error):.*$',text,re.M)
    passed=bool(marker) and not errors
    records.append({'test':spec,'passed':passed,'log':str(path.relative_to(root)),
        'result':marker.group(1) if marker else None,'errors':errors,
        'warnings':len(re.findall(r'\*\* Warning:',text))})
raw=results/'osd_observed.hex'
if raw.exists():
    words=[int(line.strip(),16) for line in raw.read_text().splitlines() if line and not line.startswith('//')]
    if len(words)!=640*480:raise RuntimeError('Incomplete OSD observation')
    image=Image.new('RGB',(640,480))
    image.putdata([((v>>16)&255,(v>>8)&255,v&255) for v in words])
    image.save(results/'osd_observed.png')
summary={'simulator':'ModelSim Intel FPGA Starter Edition 2020.1',
    'total':len(records),'passed':sum(r['passed'] for r in records),'tests':records}
(results/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False),encoding='utf-8')
print(f"{summary['passed']}/{summary['total']} ModelSim cases passed")
for record in records:
    if not record['passed']:print('PENDING/FAILED:',record['test'],record['errors'])
if not args.allow_incomplete and summary['passed']!=summary['total']:raise SystemExit(1)
