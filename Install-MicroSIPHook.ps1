[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $MicroSipIni = "$env:APPDATA\MicroSIP\MicroSIP.ini",
    [string] $ScriptPath = "$env:USERPROFILE\Scripts\MicroSIP\LogAnsweredCall.ps1"
)

$ErrorActionPreference = 'Stop'
$MicroSipIni = [System.IO.Path]::GetFullPath($MicroSipIni)
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
if (-not (Test-Path -LiteralPath $MicroSipIni)) { throw "MicroSIP INI not found: $MicroSipIni" }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Logger script not found: $ScriptPath" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$MicroSipIni.backup-$stamp"
$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$command = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

if ($PSCmdlet.ShouldProcess($MicroSipIni, "Back up to $backup and configure cmdCallAnswer")) {
    Copy-Item -LiteralPath $MicroSipIni -Destination $backup
    $lines = [System.IO.File]::ReadAllLines($MicroSipIni)
    $found = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^cmdCallAnswer=') {
            $lines[$i] = 'cmdCallAnswer=' + $command
            $found = $true
        }
    }
    if (-not $found) { $lines += 'cmdCallAnswer=' + $command }
    [System.IO.File]::WriteAllLines($MicroSipIni, $lines, [System.Text.UTF8Encoding]::new($true))
    Write-Output "Configured: $MicroSipIni"
    Write-Output "Backup: $backup"
}
