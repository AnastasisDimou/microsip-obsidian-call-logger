[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $CallerId
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDirectory = Join-Path $scriptRoot 'state'
$logDirectory = Join-Path $scriptRoot 'logs'
$errorLog = Join-Path $logDirectory 'errors.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-DiagnosticError {
    param([string] $Message)
    try {
        [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($errorLog, $line, $utf8NoBom)
    } catch {}
}

function Get-NumberKeys {
    param([string] $Number)
    $digits = $Number -replace '\D', ''
    if (-not $digits) { return @() }
    $keys = [System.Collections.Generic.List[string]]::new()
    $keys.Add($digits)
    if ($digits.StartsWith('0030') -and $digits.Length -eq 14) {
        $keys.Add($digits.Substring(4))
    } elseif ($digits.StartsWith('30') -and $digits.Length -eq 12) {
        $keys.Add($digits.Substring(2))
    } elseif ($digits.Length -eq 10) {
        $keys.Add('30' + $digits)
        $keys.Add('0030' + $digits)
    }
    return @($keys | Select-Object -Unique)
}

try {
    # cmdCallEnd also fires for outgoing and unanswered calls. Without answer
    # state there is intentionally nothing to update.
    if (-not (Test-Path -LiteralPath $stateDirectory)) { exit 0 }

    $rawCallerId = ($CallerId -join ' ').Trim()
    if (-not $rawCallerId) {
        $rawCallerId = [Environment]::GetEnvironmentVariable('MICROSIP_CALLER_ID', 'Process')
    }
    $endKeys = @(Get-NumberKeys $rawCallerId)
    if ($endKeys.Count -eq 0) { exit 0 }

    $candidates = foreach ($file in Get-ChildItem -LiteralPath $stateDirectory -Filter '*.json' -File) {
        try {
            $state = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $matches = @($state.numberKeys | Where-Object { $endKeys -contains [string]$_ }).Count -gt 0
            if ($matches) {
                [pscustomobject]@{
                    File  = $file.FullName
                    State = $state
                    Start = [datetimeoffset]::Parse([string]$state.startedAt, [Globalization.CultureInfo]::InvariantCulture)
                }
            }
        } catch {
            Write-DiagnosticError "Could not read call state '$($file.Name)': $($_.Exception.Message)"
        }
    }
    $match = $candidates | Sort-Object Start -Descending | Select-Object -First 1
    if (-not $match) { exit 0 }

    $endedAt = [datetimeoffset]::Now
    $seconds = [int][Math]::Max(0, [Math]::Floor(($endedAt - $match.Start).TotalSeconds))
    $hours = [int][Math]::Floor($seconds / 3600)
    $minutes = [int][Math]::Floor(($seconds % 3600) / 60)
    $remainingSeconds = $seconds % 60
    $duration = '{0:D2}:{1:D2}:{2:D2}' -f $hours, $minutes, $remainingSeconds
    $endTime = $endedAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $dash = [char]0x2014
    $marker = "<!-- microsip-call:$($match.State.id) -->"
    $completed = "- Answered: $($match.State.startTime) $dash Ended: $endTime $dash Duration: $duration $dash $($match.State.callerName) $dash ``$($match.State.number)`` $marker"

    $notePath = [string]$match.State.notePath
    if (-not [System.IO.File]::Exists($notePath)) { throw "Daily note is missing: $notePath" }
    $lines = [System.IO.File]::ReadAllLines($notePath, [System.Text.Encoding]::UTF8)
    $found = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Contains($marker)) {
            $lines[$i] = $completed
            $found = $true
            break
        }
    }
    if (-not $found) { throw "Call marker was not found in daily note: $($match.State.id)" }

    [System.IO.File]::WriteAllLines($notePath, $lines, $utf8NoBom)
    Remove-Item -LiteralPath $match.File -Force
} catch {
    Write-DiagnosticError $_.Exception.Message
    exit 1
}
