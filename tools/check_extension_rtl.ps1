param(
    [string]$Iverilog = 'iverilog',
    [string]$VendorDeclarations = 'D:/TD/arch/eagle_macro.v'
)
# Syntax and elaboration only. No vvp, simulation stimulus, synthesis, or timing run.
# Vendor encrypted bodies remain opaque; actual public wrappers are included.
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
Push-Location $sourceRoot
try {
    if (-not (Test-Path -LiteralPath $VendorDeclarations)) {
        throw "Missing TD primitive declarations: $VendorDeclarations"
    }
    $sources = @(Get-Content 'rtl/sources.f' | Where-Object {
        $_ -and -not $_.StartsWith('+') -and
        $_ -notlike '*.enc.v' -and $_ -notlike '*soft_fifo_*.v'
    })
    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing source: $source" }
    }
    $common = @('-g2005', '-t', 'null', '-s', 'fpga_hdmi_top', '-I', 'rtl/sdram', $VendorDeclarations)
    # First pass ensures -i cannot conceal a misspelled project module name.
    $opaque = @('soft_fifo_832789485777', 'sdr_as_ram', 'hdmi_1_4b_transmitter_core_wrapper')
    $inventory = & $Iverilog @common @sources 2>&1
    foreach ($message in $inventory) {
        if ("$message" -match 'Unknown module type:\s+(\w+)') {
            if ($Matches[1] -notin $opaque) { throw "Unexpected unresolved module: $($Matches[1])" }
        }
    }
    & $Iverilog '-i' @common @sources
    if ($LASTEXITCODE -ne 0) { throw 'RTL syntax/elaboration failed.' }
    Write-Output 'PASS: project RTL and generated public IP wrappers elaborate (Verilog-2005).'
    Write-Output 'Opaque bodies: HDMI core, SDRAM core, Soft FIFO. TD primitive declarations have no behavior.'
    Write-Output 'No simulation, synthesis, placement, routing, or timing validation was performed.'
}
finally { Pop-Location }
