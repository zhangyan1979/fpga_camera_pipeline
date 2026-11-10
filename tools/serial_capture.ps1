# =============================================================================
#  serial_capture.ps1 — read the CH343P console for a fixed time and save it.
#
#  Run:  powershell -ExecutionPolicy Bypass -File tools/serial_capture.ps1 `
#            -Port COM3 -Seconds 30 -Out ps/console.txt
# =============================================================================
param(
    [string]$Port = 'COM3',
    [int]$Seconds = 30,
    [string]$Out = 'console.txt',
    [int]$Baud = 115200
)

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 500

$lines = New-Object System.Collections.Generic.List[string]
$sp.Open()
$deadline = (Get-Date).AddSeconds($Seconds)

while ((Get-Date) -lt $deadline) {
    try {
        $l = $sp.ReadLine().TrimEnd("`r", "`n")
        $lines.Add($l)
        Write-Output $l
    } catch {
        if (-not $sp.IsOpen) { break }      # device went away
        # ReadTimeout is normal between status lines
    }
}
if ($sp.IsOpen) { $sp.Close() }

[System.IO.File]::WriteAllLines((Join-Path (Get-Location) $Out), $lines,
                                (New-Object System.Text.UTF8Encoding($false)))
Write-Output "--- captured $($lines.Count) lines to $Out"
