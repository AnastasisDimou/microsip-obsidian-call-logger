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
    $durationParts = [System.Collections.Generic.List[string]]::new()
    if ($hours -gt 0) { $durationParts.Add("$hours hr") }
    if ($minutes -gt 0) { $durationParts.Add("$minutes min") }
    if ($remainingSeconds -gt 0 -or $durationParts.Count -eq 0) {
        $durationParts.Add("$remainingSeconds sec")
    }
    $duration = $durationParts -join ' '
    $endTime = $endedAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $middleDot = [char]0x00B7
    $marker = "<!-- microsip-call:$($match.State.id) -->"
    $pendingLine = [string]$match.State.pendingLine
    $callerLine = [string]$match.State.callerLine
    if (-not $callerLine) {
        $callerLine = "  **Caller:** ``$($match.State.callerName)`` $middleDot **Phone:** ``$($match.State.number)``"
    }
    $completed = "- **Answered:** $($match.State.startTime) $middleDot **Ended:** $endTime $middleDot **Duration:** $duration  "

    $notePath = [string]$match.State.notePath
    if (-not [System.IO.File]::Exists($notePath)) { throw "Daily note is missing: $notePath" }
    $lines = [System.IO.File]::ReadAllLines($notePath, [System.Text.Encoding]::UTF8)
    $lineList = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) { $lineList.Add($line) }
    $found = $false
    for ($i = $lineList.Count - 1; $i -ge 0; $i--) {
        # Marker matching supports calls that began on an older script version.
        if (($pendingLine -and $lineList[$i] -eq $pendingLine) -or $lineList[$i].Contains($marker)) {
            $lineList[$i] = $completed
            if ($i + 1 -ge $lineList.Count -or $lineList[$i + 1] -ne $callerLine) {
                $lineList.Insert($i + 1, $callerLine)
            }
            $found = $true
            break
        }
    }
    if (-not $found) { throw "Pending call entry was not found in the daily note." }

    [System.IO.File]::WriteAllLines($notePath, $lineList.ToArray(), $utf8NoBom)
    Remove-Item -LiteralPath $match.File -Force
} catch {
    Write-DiagnosticError $_.Exception.Message
    exit 1
}
