"""Collect completed per-test ModelSim logs; do not rerun or waive failures."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/'sim';OUT=SIM/'out'
rtl=[ROOT/p for p in (ROOT/'rtl/sources.f').read_text().splitlines() if p and not p.startswith('+')]
rtl.append(ROOT/'rtl/sdram/global_def.v')
results=[]
for bench in sorted(SIM.glob('tb_*.sv')):
    name=bench.stem;log=OUT/(name+'.log');text=log.read_text(encoding='utf-8') if log.exists() else ''
    deps=rtl+[bench]
    if name in ('tb_sdram_vendor','tb_frame_store'): deps.append(SIM/'models/sdram_device.sv')
    if name=='tb_sd_spi':deps.append(SIM/'models/sd_card_spi.sv')
    fresh=log.exists() and all(p.stat().st_mtime<=log.stat().st_mtime for p in deps)
    passed=fresh and '# 2020.1' in text and bool(re.search(r'PASS '+re.escape(name)+r'(?=[:\s])',text))
    passed=passed and not re.search(r'\*\* (?:Error|Fatal):',text)
    marker=next((l.lstrip('# ') for l in text.splitlines() if 'PASS '+name in l),'No PASS marker')
    fingerprint=hashlib.sha256()
    for p in sorted(deps):fingerprint.update(p.read_bytes())
    results.append(dict(test=name,passed=bool(passed),fresh=bool(fresh),detail=marker,
                        checked_sources_sha256=fingerprint.hexdigest(),log=str(log.relative_to(ROOT))))
    print(('PASS' if passed else 'FAIL'),name,('' if fresh else '(missing/stale log)'))
report=dict(simulator='ModelSim Intel FPGA Starter Edition 2020.1',collection='per-test completed logs',
            base_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),tests=results)
(OUT/'summary.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(f"{sum(r['passed'] for r in results)}/{len(results)} passed")
sys.exit(0 if results and all(r['passed'] for r in results) else 1)
