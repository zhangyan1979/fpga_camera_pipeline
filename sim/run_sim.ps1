# =============================================================================
#  run_sim.ps1 — rebuild and run both testbenches with xsim.
#
#  Run:  powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
#
#  tb_pipeline    full video path (camera model -> capture -> DDR engine with an
#                 AXI slave memory model -> panel timing -> scoreboard)
#  tb_lcd_timing  full-size 1056 x 526 panel timing at 33.333 MHz
# =============================================================================
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH

Write-Host "=== tb_pipeline ===" -ForegroundColor Cyan
& xvlog.bat ..\rtl\ov5640_capture.v ..\rtl\afifo64.v ..\rtl\fb_ddr.v ..\rtl\lcd_display.v tb_pipeline.v | Out-Null
& xelab.bat -debug typical tb_pipeline -s tb_pipe | Out-Null
& xsim.bat tb_pipe -runall 2>&1 | Select-String -Pattern 'capture:|DDR buffer|displayed frames|ddr words|underrun|TEST' |
    ForEach-Object { $_.Line }

Write-Host "=== tb_lcd_timing ===" -ForegroundColor Cyan
& xvlog.bat ..\rtl\lcd_display.v tb_lcd_timing.v | Out-Null
& xelab.bat -debug typical tb_lcd_timing -s tb_tim | Out-Null
& xsim.bat tb_tim -runall 2>&1 | Select-String -Pattern 'frame [0-9]:|TEST' |
    ForEach-Object { $_.Line }

Pop-Location
