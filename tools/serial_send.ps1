# =============================================================================
#  serial_send.ps1 — type characters into the CH343P console and print the
#  answer.  Opens the port, writes, then keeps reading for -ReadSeconds.
#
#  Run:  powershell -File tools/serial_send.ps1 -Text "i" -ReadSeconds 3
# =============================================================================
param(
    [string]$Port = 'COM3',
    [string]$Text = 'h',
    [int]$Baud = 115200,
    [int]$ReadSeconds = 3
)

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 300
$sp.Open()
Start-Sleep -Milliseconds 150
$sp.Write($Text)

$deadline = (Get-Date).AddSeconds($ReadSeconds)
while ((Get-Date) -lt $deadline) {
    try {
        Write-Output $sp.ReadLine().TrimEnd("`r", "`n")
    } catch {
        if (-not $sp.IsOpen) { break }      # device went away
        # ReadTimeout is normal between status lines
    }
}
if ($sp.IsOpen) { $sp.Close() }
