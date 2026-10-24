"""Functional regression using ModelSim Intel FPGA Starter Edition 2020.1."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/'sim'
OUT=SIM/'out'

def command(argv, log, cwd=ROOT/'al_ip', timeout=120):
    start=time.monotonic()
    try:
        p=subprocess.run([str(x) for x in argv], cwd=cwd, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, timeout=timeout)
        output=p.stdout
        code=p.returncode
    except subprocess.TimeoutExpired as exc:
        output=(exc.stdout or b'').decode(errors='replace') if isinstance(exc.stdout,bytes) else (exc.stdout or '')
        output+='\nERROR: wall-clock timeout\n'; code=124
    (OUT/log).write_text(output,encoding='utf-8')
    return code, output, round(time.monotonic()-start,2)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--modelsim-bin',type=Path,default=Path('D:/modelsim/modelsim_ase/win32aloem'))
    ap.add_argument('--td-root',type=Path,default=Path('D:/TD'))
    ap.add_argument('--test',action='append',help='Testbench name, repeat to select multiple; default: all')
    ap.add_argument('--skip-compile',action='store_true')
    ap.add_argument('--timeout',type=int,default=600,help='Maximum wall-clock seconds per testbench')
    ap.add_argument('--waves',action='store_true',help='Record selected DUT/control signals in each WLF')
    args=ap.parse_args();OUT.mkdir(exist_ok=True)
    bd=args.modelsim_bin
    code,version,_=command([bd/'vsim.exe','-version'],'version.log')
    if code or '2020.1' not in version or 'STARTER EDITION' not in version:
        raise RuntimeError('Requested ModelSim Intel FPGA Starter Edition 2020.1 was not found: '+version)
    tests=args.test or [p.stem for p in sorted(SIM.glob('tb_*.sv'))]
    if not args.skip_compile:
        from generate_vectors import generate
        generate()
        compile_commands=[]
        if not (OUT/'work').exists(): compile_commands.append([bd/'vlib.exe',OUT/'work'])
        vendor=sorted((args.td_root/'sim_release/eg4').glob('*.v'))
        assert vendor, 'No Anlogic EG4 simulation library found'
        # Vendor/RTL .v files use Verilog ("do" is a legal port); only benches use SV.
        sources=[ROOT/l for l in (ROOT/'rtl/sources.f').read_text().splitlines() if l and not l.startswith('+')]
        compile_commands.append([bd/'vlog.exe','-work',OUT/'work',
            '+incdir+'+str(ROOT/'rtl/sdram'),*vendor,*sources])
        compile_commands.append([bd/'vlog.exe','-work',OUT/'work','-sv',
            '+incdir+'+str(SIM),'+incdir+'+str(OUT),*sorted((SIM/'models').glob('*.sv')),
            *sorted(SIM.glob('tb_*.sv'))])
        for i,cmd in enumerate(compile_commands):
            code,output,_=command(cmd,f'compile_{i}.log')
            if code or re.search(r'\*\* (?:Error|Fatal):',output):
                print(output[-10000:]);raise RuntimeError('Compilation failed; see sim/out')
    results=[]
    for test in tests:
        if not re.fullmatch(r'tb_[A-Za-z0-9_]+',test): raise ValueError(test)
        print('RUN',test,flush=True)
        do_command=('set capture_waves 1; ' if args.waves else '')+'do {'+(SIM/'run.do').as_posix()+'}'
        code,output,seconds=command([bd/'vsim.exe','-c','-lib',OUT/'work',test,
            '-l',OUT/(test+'.transcript'),'-wlf',OUT/(test+'.wlf'),
            '-do',do_command],test+'.log',timeout=args.timeout)
        passed=(code==0 and 'PASS '+test in output
                and not re.search(r'\*\* (?:Error|Fatal):',output))
        results.append(dict(test=test,passed=passed,seconds=seconds,exit_code=code))
        print(('PASS' if passed else 'FAIL'),test,seconds,'s',flush=True)
        if not passed: print(output[-7000:],flush=True)
    report=dict(simulator=version.strip(),base_commit=subprocess.check_output(
        ['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),tests=results)
    (OUT/'results.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return 0 if all(x['passed'] for x in results) else 1

if __name__=='__main__':
    sys.exit(main())
