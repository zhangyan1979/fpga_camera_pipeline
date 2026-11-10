# =============================================================================
#  verify.ps1 — hardware self-check while the preview is running.
#
#  Run:  powershell -ExecutionPolicy Bypass -File tools/verify.ps1
#
#  1. dumps frame buffer 0 twice, one second apart, and checks that the picture
#     changes (the camera is live)
#  2. freezes the frame, dumps twice and checks that it does NOT change
#  3. resumes, cycles the backlight and prints the status word
#
#  Everything is saved under docs/.
# =============================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
New-Item -ItemType Directory -Force -Path docs | Out-Null

$xsct = 'D:\Xilinx\Vitis\2023.2\bin\xsct.bat'

function Dump-Frame([string]$out) {
    & $xsct ps/dump_fb.tcl 0 | Out-Null
    Copy-Item ps/fb_dump.bin $out -Force
}

function Compare-Frames([string]$a, [string]$b) {
    $ha = (Get-FileHash $a -Algorithm SHA256).Hash
    $hb = (Get-FileHash $b -Algorithm SHA256).Hash
    return ($ha -eq $hb)
}

Write-Host "1. live check: two dumps one second apart" -ForegroundColor Cyan
Dump-Frame docs/live_a.bin
Start-Sleep -Milliseconds 1200
Dump-Frame docs/live_b.bin
$same = Compare-Frames docs/live_a.bin docs/live_b.bin
if ($same) { Write-Host "   FAIL: the frame did not change" -ForegroundColor Red }
else       { Write-Host "   OK: the frame changed (camera is live)" -ForegroundColor Green }

Write-Host "2. freeze check" -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "f" -ReadSeconds 1 | Out-Null
Start-Sleep -Milliseconds 1500
Dump-Frame docs/frozen_a.bin
Start-Sleep -Milliseconds 1200
Dump-Frame docs/frozen_b.bin
$same = Compare-Frames docs/frozen_a.bin docs/frozen_b.bin
if ($same) { Write-Host "   OK: the frozen frame is stable" -ForegroundColor Green }
else       { Write-Host "   FAIL: the frame kept changing while frozen" -ForegroundColor Red }

Write-Host "3. resume, backlight and status" -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "f" -ReadSeconds 1 | Out-Null
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "b" -ReadSeconds 1 | Out-Null
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "b" -ReadSeconds 1 | Out-Null
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "i" -ReadSeconds 2
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "b" -ReadSeconds 1 | Out-Null
powershell -ExecutionPolicy Bypass -File tools/serial_send.ps1 -Text "b" -ReadSeconds 1 | Out-Null

Write-Host "4. render the dumps" -ForegroundColor Cyan
python tools/fb2png.py docs/live_a.bin docs/frame.png
python tools/fb2png.py docs/frozen_a.bin docs/frame_frozen.png

Pop-Location
