"""Syntax / name / port / width audit only; no simulation or synthesis.

Opaque vendor implementations are represented by declarations in memory.
These declarations are never saved as project RTL and do not model behavior.
"""
from pathlib import Path
import re
import sys
import argparse
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
args_parser = argparse.ArgumentParser(description=__doc__)
args_parser.add_argument('--pyslang-path', type=Path, help='Optional installed pyslang package directory')
args_parser.add_argument('--td-root', type=Path, default=Path('D:/TD'))
args = args_parser.parse_args()
if args.pyslang_path:
    sys.path.insert(0, str(args.pyslang_path.resolve()))
(ROOT/'tmp').mkdir(exist_ok=True)
import pyslang
from pyslang.syntax import SyntaxTree
from pyslang.parsing import ParserOptions, PreprocessorOptions, LexerOptions
from pyslang.ast import Compilation, CompilationOptions

language = pyslang.LanguageVersion.v1364_2005
options = pyslang.Bag()
parser = ParserOptions(); parser.languageVersion = language
preprocessor = PreprocessorOptions(); preprocessor.languageVersion = language
preprocessor.additionalIncludePaths = [str(ROOT / 'rtl/sdram')]
lexer = LexerOptions(); lexer.languageVersion = language
comp_options = CompilationOptions()
comp_options.languageVersion = language
comp_options.topModules = {'fpga_hdmi_top'}
options.parserOptions = parser
options.preprocessorOptions = preprocessor
options.lexerOptions = lexer
options.compilationOptions = comp_options
manager = pyslang.SourceManager()
compilation = Compilation(options)
trees = []

def add_text(text, label, path=''):
    if '`timescale' not in text:
        text = '`timescale 1ns/1ps\n' + text
    tree = SyntaxTree.fromText(text, manager, label, path, options)
    trees.append(tree)
    compilation.addSyntaxTree(tree)

# Audit exactly the registered source set, not a guessed subset.
source_lines = (ROOT/'rtl/sources.f').read_text().splitlines()
paths = [ROOT/line for line in source_lines if line and not line.startswith('+')]
assert len(paths) == len(set(paths)), 'Duplicate sources.f entry'
assert all(p.is_file() for p in paths), 'Missing sources.f file'
expected = set((ROOT/'rtl').rglob('*.v')) - {ROOT/'rtl/sdram/global_def.v'}
assert expected == {p for p in paths if p.is_relative_to(ROOT/'rtl')}, 'RTL source-list mismatch'
project_text = (ROOT/'project1.al').read_text(encoding='utf-8-sig')
project = ET.fromstring(project_text.replace('UsedInP&R', 'UsedInP&amp;R'))
assert project.findtext('TOP_MODULE/MODULE') == 'fpga_hdmi_top'
assert project.findtext('TOP_MODULE/LABEL') == 'fpga_hdmi_top'
project_files = [x.attrib['Path'] for x in project.findall('.//Source_Files/*/File')]
assert len(project_files) == len(set(project_files)), 'Duplicate TD source entry'
assert all((ROOT/p).is_file() for p in project_files), 'Missing TD project file'
registered_rtl = {ROOT/x.attrib['Path'] for x in project.findall('.//Source_Files/Verilog/File')}
assert registered_rtl == expected | {ROOT/'rtl/sdram/global_def.v'}, 'TD Verilog registration mismatch'
for entry in project.findall('.//Source_Files/*/File'):
    if entry.attrib['Path'] != 'rtl/sdram/global_def.v':
        attrs = {a.attrib['Name']: a.attrib['Val'] for a in entry.findall('FileInfo/Attr')}
        assert attrs.get('UsedInSyn') == 'true', 'Required design file is disabled'
        assert attrs.get('AutoExcluded') != 'true', 'Stale automatic exclusion from previous top'

for name in ('ram_scale_line', 'ram_fade_block', 'rom_osd_font', 'rom_anlogic_logo'):
    ipc_path = ROOT/f'al_ip/{name}.ipc'
    ipc = ET.parse(ipc_path)
    assert ipc.findtext('.//Device') == 'EG4S20BG256'
    assert ipc.find('.//GeneratedFiles/Verilog').attrib['Enable'] == 'true'
    assert ipc.find('.//GeneratedFiles/VHDL').attrib['Enable'] == 'false'
    assert f'al_ip/{name}.ipc' in project_files
    assert f'al_ip/{name}.v' not in project_files  # IP entry owns its generated RTL
    assert ROOT/f'al_ip/{name}.v' in paths
    init = ipc.findtext('.//init_file')
    if init:
        assert (ipc_path.parent/init).is_file()
        assert (ipc_path.parent/(init+'.dath')).is_file()

opaque_paths = []
for path in paths:
    text = path.read_text(encoding='utf-8-sig')
    text = re.sub(r'`pragma protect begin_protected.*?`pragma protect end_protected',
                  '', text, flags=re.S)
    # Some public headers place their endmodule inside the opaque block.
    if len(re.findall(r'^\s*module\b',text,re.M)) > len(re.findall(r'^\s*endmodule\b',text,re.M)):
        text += '\nendmodule\n'
    if not re.search(r'\bmodule\b', text):
        opaque_paths.append(path.relative_to(ROOT).as_posix())
        continue
    add_text(text, path.relative_to(ROOT).as_posix(), str(path))

fifo_text = (ROOT / 'al_ip/fifo_pixel_async/fifo_pixel_async.v').read_text()
fifo_name = re.search(r'\b(soft_fifo_\d+)\b', fifo_text).group(1)
params = re.findall(r'\.([A-Z][A-Z0-9_]+)\(([^()]*)\)', fifo_text)
header = fifo_text[fifo_text.index('module fifo_pixel_async'):fifo_text.index(');')+2]
header = header.replace('module fifo_pixel_async',
    'module ' + fifo_name + ' #(\n' + ',\n'.join('parameter '+k+'='+v for k,v in params)+ '\n)')
add_text('`timescale 1ns/1ps\n' + header + '\nendmodule\n', 'opaque_fifo_declarations')

vendor_dir = args.td_root / 'sim_release/eg4'
for name, filename in [('EG_PHY_PLL','eg_phy_pll.v'),
                       ('EG_LOGIC_BUFG','eg_logic_clk.v'),
                       ('EG_LOGIC_ODDR','eg_logic_io.v'),
                       ('EG_PHY_SDRAM_2M_32','eg_phy_sdram_2m_32.v')]:
    text = (vendor_dir/filename).read_text(errors='replace')
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    module = re.search(r'\bmodule\s+'+name+r'\b.*?\bendmodule\b',text,re.S).group(0)
    if name == 'EG_PHY_PLL':
        module = module[:module.index('real refclk_cycle_reg')]
    head = module[:module.index(';')+1]
    declarations = re.findall(r'\b(?:input|output|inout|parameter)\s+[^;]+;',module)
    add_text('`timescale 1ns/1ps\n'+head+'\n'+'\n'.join(declarations)+'\nendmodule\n',
             'vendor_declarations_'+name)

# BRAM body is opaque in sim_release; use the actual public architecture
# declaration. No behavioral models, encrypted internals, netlist, or backend.
macro_text = (args.td_root/'arch/eagle_macro.v').read_text(errors='replace')
macro_text = re.sub(r'/\*.*?\*/|//[^\n]*', '', macro_text, flags=re.S)
bram = re.search(r'\bmodule\s+EG_LOGIC_BRAM\b.*?\bendmodule\b',macro_text,re.S).group(0)
add_text(bram, 'vendor_declarations_EG_LOGIC_BRAM')

diagnostics = compilation.getAllDiagnostics()
report = pyslang.DiagnosticEngine.reportAll(manager, diagnostics)
(ROOT/'tmp/rtl_static_diagnostics.txt').write_text(report, encoding='utf-8')
errors = [d for d in diagnostics if d.isError()]
print('Verilog-2005 source units:', len(paths))
print('Opaque files without public modules:', len(opaque_paths))
print('Declaration-only vendor units:', 6)
print('TD Verilog entries:', len(registered_rtl))
td_ip_count = len(project.findall('.//Source_Files/IP_FILE/File'))
td_constraint_count = sum(len(project.findall(f'.//Source_Files/{kind}/File'))
                          for kind in ('ADC_FILE', 'SDC_FILE'))
print('TD IP entries:', td_ip_count)
print('TD constraint entries:', td_constraint_count)
print('Static errors:', len(errors))
print('Total static diagnostics:', len(diagnostics))
print(report)
(ROOT/'tmp/static_rtl_summary.json').write_text(json.dumps(dict(source_files=len(paths), td_verilog_files=len(registered_rtl), td_ip_files=td_ip_count, td_constraint_files=td_constraint_count, errors=len(errors), diagnostics=len(diagnostics), opaque_files=opaque_paths), indent=2),encoding='utf-8')
raise SystemExit(bool(errors))
