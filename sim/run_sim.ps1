# =============================================================================
#  run_sim.ps1 — rebuild and run every testbench with xsim.
#
#  Run:  powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
#
#  Every sim/tb_*.v is run.  The four functional testbenches below need a
#  specific file list; anything else (a processing stage's testbench, say) is
#  compiled against the whole RTL tree minus the top level and the MMCM wrapper,
#  which need Xilinx primitives.  A run fails if a testbench does not reach a
#  "TEST PASS" line, so a stale snapshot can never be mistaken for a pass.
# =============================================================================
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH

$tests = @(
    @{ name = 'tb_pipeline'
       rtl  = @('ov5640_capture.v', 'afifo.v', 'fb_ddr.v', 'lcd_display.v') },
    @{ name = 'tb_lcd_timing'
       rtl  = @('lcd_display.v') },
    @{ name = 'tb_sccb'
       rtl  = @('i2c_bit_shift.v', 'i2c_control.v') },
    @{ name = 'tb_init_seq'
       rtl  = @('i2c_bit_shift.v', 'i2c_control.v', 'ov5640_init.v',
                'ov5640_init_table_rgb.v', 'sii9022_init.v', 'sii9022_init_table.v') },
    @{ name = 'tb_stage_contract'
       rtl  = @('img_geom.v', 'stage_mux.v') }
)

$default_rtl = Get-ChildItem (Join-Path '..' 'rtl') -Filter *.v |
    Where-Object { $_.Name -ne 'clk_gen.v' -and $_.Name -ne 'ov5640_top.v' } |
    Sort-Object Name |
    ForEach-Object { $_.Name }

# any testbench that is not in the table gets the default file list
foreach ($tbp in (Get-ChildItem -Filter 'tb_*.v' | Sort-Object Name)) {
    $known = $tests | Where-Object { $_.name -eq $tbp.BaseName }
    if (-not $known) {
        $tests += @{ name = $tbp.BaseName; rtl = $default_rtl }
    }
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

$failed = @()

foreach ($t in $tests) {
    Write-Host ("=== " + $t.name + " ===") -ForegroundColor Cyan

    $files = @()
    foreach ($f in $t.rtl) { $files += (Join-Path '..' (Join-Path 'rtl' $f)) }
    $files += ($t.name + '.v')

    Invoke-Tool xvlog.bat $files
    Invoke-Tool xelab.bat @('-debug', 'typical', $t.name, '-s', $t.name)

    $out = & xsim.bat $t.name -runall 2>&1
    $out | Select-String -Pattern 'capture:|DDR buffer|displayed frames|ddr words|underrun|frame [0-9]:|SCCB|write:|NACK|dly_max|camera:|hdmi:|words out|before first|largest|last stat|stage param|FAIL|TEST' |
        ForEach-Object { $_.Line }

    if (-not ($out | Select-String -Pattern 'TEST PASS')) {
        $failed += $t.name
        Write-Host ("FAILED: " + $t.name) -ForegroundColor Red
    }
}

Pop-Location

if ($failed.Count -gt 0) {
    Write-Host ("simulations failed: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "all simulations passed" -ForegroundColor Green
