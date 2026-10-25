param(
 [string[]]$Tests=@(),
 [string]$ModelSim='D:/modelsim/modelsim_ase/win32aloem',
 [string]$Td='D:/TD', [switch]$Rebuild, [switch]$All, [switch]$EndToEnd,
 [string]$Python='C:/Users/30909/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
)
$ErrorActionPreference='Stop'
if($All -and $EndToEnd) { throw 'Run -All with real PLLs, then -EndToEnd in its separate clock-model library.' }
if(-not $All -and $Tests.Count -eq 0) {
 if($EndToEnd) { $Tests=@('tb_end_to_end') } else { $Tests=@('tb_vendor_ip') }
}
if($EndToEnd -and ($Tests -match '^tb_(pll|top_smoke|sdram_physical_pll)(\+|$)')) {
 throw 'PLL qualification must use the normal library with actual generated PLL models.'
}
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$library=Join-Path $PSScriptRoot 'build/work'
if($EndToEnd) { $library=Join-Path $PSScriptRoot 'build/e2e_work' }
$results=Join-Path $PSScriptRoot 'results'
$compilePrefix=''
if($EndToEnd) { $compilePrefix='e2e_' }
New-Item -ItemType Directory -Force (Split-Path $library),$results | Out-Null
function Invoke-Compile([string[]]$Arguments,[string]$Log) {
 & "$ModelSim/vlog.exe" @Arguments *> $Log
 if($LASTEXITCODE -ne 0) { Get-Content $Log -Tail 40; throw "Compile failed: $Log" }
}
Push-Location $root
try {
 if($All) {
  & $Python "$PSScriptRoot/generate_vectors.py"
  if($LASTEXITCODE -ne 0) { throw 'Reference generation failed.' }
  $Tests=@('tb_vendor_ip','tb_pll','tb_init_probe')+
    @(0..6 | ForEach-Object { "tb_bmp+CASE=$_" })+
    @(0..4 | ForEach-Object { "tb_wav+CASE=$_" })+
    @('tb_controls','tb_slideshow','tb_osd','tb_pcm')+
    @(0..4 | ForEach-Object { "tb_dft+CASE=$_" })+
    @('tb_fat_media','tb_memory_integration','tb_memory_integration+STREAM','tb_top_smoke','tb_sdram_physical','tb_sdram_physical_pll','tb_sector_cache','tb_tf_wav_stream','tb_hdmi_serial_sink')
 }
 $version=& "$ModelSim/vsim.exe" -version
 Write-Output $version
 if("$version" -notmatch '2020.1') { throw 'ModelSim 2020.1 required.' }
 if($Rebuild -or -not (Test-Path "$library/_info")) {
  & "$ModelSim/vlib.exe" $library
  $vendor=@(Get-ChildItem "$Td/sim_release/eg4/*.v" | Select-Object -ExpandProperty FullName)
  Invoke-Compile (@('-work',$library)+$vendor) "$results/${compilePrefix}vendor_compile.log"
 }
 $sources=@(Get-Content rtl/sources.f | Where-Object { $_ -and -not $_.StartsWith('+') })
 if($EndToEnd -or ($Tests -match '^tb_(tf_wav_stream|end_to_end)(\+|$)')) {
  & $Python "$PSScriptRoot/generate_e2e_media.py"
  if($LASTEXITCODE -ne 0) { throw 'E2E media generation failed.' }
 }
 if($EndToEnd) {
  $sources=@($sources | Where-Object { $_ -notmatch '^al_ip/pll_(sdram|hdmi)\.v$' })+
    @("$PSScriptRoot/models/pll_functional.v")
 }
 # The real EG4 model recognizes .dath, but not the TD GUI's .mif filename.
 # Compile byte-for-byte wrapper copies with ONLY that filename redirected to
 # the generated companion .mif.dath. Production wrappers remain untouched.
 $ipCopies=Join-Path $PSScriptRoot 'build/ip_sources'
 New-Item -ItemType Directory -Force $ipCopies | Out-Null
 $sources=@(foreach($source in $sources) {
  if($source -match '^al_ip/rom_.*\.v$') {
   $raw=Get-Content $source -Raw
   $match=[regex]::Match($raw,'\.INIT_FILE\("([^"]+\.mif)"\)')
   if(-not $match.Success) { throw "Unexpected ROM initialization declaration: $source" }
   $init=$match.Groups[1].Value+'.dath'
   if(-not (Test-Path (Join-Path (Join-Path $root 'al_ip') $init))) { throw "Missing init: $init" }
   $copy=Join-Path $ipCopies (Split-Path $source -Leaf)
   [IO.File]::WriteAllText($copy,$raw.Replace($match.Value,'.INIT_FILE("'+$init+'")'))
   $copy
  } else { $source }
 })
 # Generated PLL port 'do' is a SystemVerilog keyword; compile .v as Verilog.
 Invoke-Compile (@('-work',$library,'+incdir+rtl/sdram')+$sources) "$results/${compilePrefix}rtl_compile.log"
 $benches=@(Get-ChildItem "$PSScriptRoot/models/*.sv","$PSScriptRoot/tests/*.sv" | Select-Object -ExpandProperty FullName)
 Invoke-Compile (@('-sv','-work',$library)+$benches) "$results/${compilePrefix}tests_compile.log"
 foreach($spec in $Tests) {
  $parts=$spec.Split('+');$test=$parts[0]
  $plus=@($parts | Select-Object -Skip 1 | ForEach-Object { '+'+$_ })
  $name=$spec.Replace('+','_').Replace('=','_')
  $doFile=Join-Path $PSScriptRoot "build/$name.do"
  @('onerror {quit -code 2}','onbreak {quit -code 3}',
    'while {1} {run 1 ms; puts "PROGRESS simulation time: [now]"; flush stdout}',
    'quit -code 0') | Set-Content $doFile -Encoding ascii
  Push-Location (Join-Path $root 'al_ip')
  try {
   & "$ModelSim/vsim.exe" -c -onfinish exit -lib $library $test glbl @plus -l "$results/$name.log" -do $doFile *> "$results/$name.console.log"
   $code=$LASTEXITCODE
  } finally { Pop-Location }
  $text=Get-Content "$results/$name.log" -Raw
  if($code -ne 0 -or $text -notmatch "PASS: $test" -or $text -match '\*\* (Fatal|Error):') {
   Get-Content "$results/$name.log" -Tail 45; throw "Simulation failed: $spec (exit $code)"
  }
  Write-Output "PASS: $spec"
 }
} finally { Pop-Location }
