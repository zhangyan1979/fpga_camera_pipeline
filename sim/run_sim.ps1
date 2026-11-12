# =============================================================================
#  run_sim.ps1 — rebuild and run the testbenches with xsim.
#
#  Run:  powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
#
#  tb_pipeline    full video path (camera model -> capture -> DDR engine with an
#                 AXI slave memory model -> panel timing -> scoreboard)
#  tb_lcd_timing  full-size 1056 x 526 panel timing at 33.333 MHz
#  tb_sccb        SCCB write path: byte sequence, ACK/NACK, extra delay, SCL rate
# =============================================================================
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

Write-Host "=== tb_pipeline ===" -ForegroundColor Cyan
Invoke-Tool xvlog.bat @('..\rtl\ov5640_capture.v', '..\rtl\afifo.v', '..\rtl\fb_ddr.v', '..\rtl\lcd_display.v', 'tb_pipeline.v')
Invoke-Tool xelab.bat @('-debug', 'typical', 'tb_pipeline', '-s', 'tb_pipe')
& xsim.bat tb_pipe -runall 2>&1 | Select-String -Pattern 'capture:|DDR buffer|displayed frames|ddr words|underrun|TEST' |
    ForEach-Object { $_.Line }

Write-Host "=== tb_lcd_timing ===" -ForegroundColor Cyan
Invoke-Tool xvlog.bat @('..\rtl\lcd_display.v', 'tb_lcd_timing.v')
Invoke-Tool xelab.bat @('-debug', 'typical', 'tb_lcd_timing', '-s', 'tb_tim')
& xsim.bat tb_tim -runall 2>&1 | Select-String -Pattern 'frame [0-9]:|TEST' |
    ForEach-Object { $_.Line }

Write-Host "=== tb_sccb ===" -ForegroundColor Cyan
Invoke-Tool xvlog.bat @('..\rtl\i2c_bit_shift.v', '..\rtl\i2c_control.v', 'tb_sccb.v')
Invoke-Tool xelab.bat @('-debug', 'typical', 'tb_sccb', '-s', 'tb_sccb')
& xsim.bat tb_sccb -runall 2>&1 | Select-String -Pattern 'SCCB|write:|NACK|dly_max|TEST' |
    ForEach-Object { $_.Line }

Write-Host "=== tb_init_seq ===" -ForegroundColor Cyan
Invoke-Tool xvlog.bat @('..\rtl\i2c_bit_shift.v', '..\rtl\i2c_control.v', '..\rtl\ov5640_init.v',
                       '..\rtl\ov5640_init_table_rgb.v', '..\rtl\sii9022_init.v', '..\rtl\sii9022_init_table.v',
                       'tb_init_seq.v')
Invoke-Tool xelab.bat @('-debug', 'typical', 'tb_init_seq', '-s', 'tb_init')
& xsim.bat tb_init -runall 2>&1 | Select-String -Pattern 'camera:|hdmi:|FAIL|TEST' |
    ForEach-Object { $_.Line }

Pop-Location
