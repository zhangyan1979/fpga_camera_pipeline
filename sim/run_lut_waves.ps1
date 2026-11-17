# Run tb_stage_lut with log_wave so tb_stage_lut.wdb has real transitions.
# Open in Vivado:  xsim tb_stage_lut.wdb -gui
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH

$rtl = Get-ChildItem (Join-Path '..' 'rtl') -Filter *.v |
    Where-Object { $_.Name -notin @('clk_gen.v', 'ov5640_top.v') } |
    Sort-Object Name |
    ForEach-Object { (Join-Path '..' (Join-Path 'rtl' $_.Name)) }

& xvlog.bat @($rtl + 'tb_stage_lut.v')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

& xelab.bat -debug typical tb_stage_lut -s tb_stage_lut
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }

$out = & xsim.bat tb_stage_lut -wdb tb_stage_lut.wdb -tclbatch waves_runall.tcl 2>&1
$out | Select-String -Pattern 'FAIL|TEST PASS|ERROR' | ForEach-Object { $_.Line }

if (-not ($out | Select-String -Pattern 'TEST PASS')) {
    Write-Host $out
    throw 'tb_stage_lut did not reach TEST PASS'
}

Write-Host 'Wrote sim\tb_stage_lut.wdb (logged: tb, u_dut, u_geom)' -ForegroundColor Green
Write-Host 'GUI:  cd sim; xsim tb_stage_lut.wdb -gui' -ForegroundColor Cyan
Pop-Location