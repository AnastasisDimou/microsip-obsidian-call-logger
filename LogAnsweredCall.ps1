[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $CallerId
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config.json'
$logDirectory = Join-Path $scriptRoot 'logs'
$stateDirectory = Join-Path $scriptRoot 'state'
$errorLog = Join-Path $logDirectory 'errors.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-DiagnosticError {
    param([string] $Message)
    try {
        [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($errorLog, $line, $utf8NoBom)
    } catch {
        # Logging must never obscure the original failure.
    }
}

function Clean-MarkdownText {
    param([string] $Value, [string] $Fallback)
    $clean = ($Value -replace '[\r\n]+', ' ' -replace '[`|]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return $Fallback }
    return $clean
}

function Get-NumberKeys {
    param([string] $Number)
    $digits = $Number -replace '\D', ''
    if (-not $digits) { return @() }

    $keys = [System.Collections.Generic.List[string]]::new()
    $keys.Add($digits)

    # Treat Greek +30/0030 and 10-digit national forms as equivalent.
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

. (Join-Path $scriptRoot 'CallerLookup.ps1')

function Parse-CallerId {
    param([string] $Raw)

    $rawValue = $Raw.Trim()
    $name = ''
    $number = ''

    if ($rawValue -match '^\s*"(?<name>[^"]+)"\s*<\s*(?:sip:|sips:|tel:)?(?<number>[^@;>]+)') {
        $name = $Matches.name
        $number = $Matches.number
    } elseif ($rawValue -match '^\s*(?<name>[^<]+?)\s*<\s*(?:sip:|sips:|tel:)?(?<number>[^@;>]+)') {
        $name = $Matches.name
        $number = $Matches.number
    } elseif ($rawValue -match '^\s*<\s*(?:sip:|sips:|tel:)?(?<number>[^@;>]+)') {
        $number = $Matches.number
    } elseif ($rawValue -match '^\s*(?:sip:|sips:|tel:)?(?<number>[^@\s;>]+)@[^>\s]+') {
        $number = $Matches.number
    } elseif ($rawValue -match '^(?<name>.*?\D)\s+(?<number>\+?[\d][\d\s().-]*\d)\s*$') {
        $name = $Matches.name
        $number = $Matches.number
    } elseif ($rawValue -match '(?<number>\+?[\d][\d\s().-]*\d|\d+)') {
        $number = $Matches.number
    } else {
        $number = $rawValue
    }

    [pscustomobject]@{
        Name   = (Clean-MarkdownText $name '')
        Number = (Clean-MarkdownText $number 'Unknown number')
    }
}

function Find-ContactName {
    param([string] $Number, [string] $ContactsPath)
    if (-not $ContactsPath -or -not (Test-Path -LiteralPath $ContactsPath)) { return '' }

    $wanted = @(Get-NumberKeys $Number)
    if ($wanted.Count -eq 0) { return '' }

    [xml] $contacts = [System.IO.File]::ReadAllText($ContactsPath)
    foreach ($contact in $contacts.DocumentElement.ChildNodes) {
        if ($contact.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        foreach ($field in @('number', 'phone', 'mobile')) {
            $candidate = $contact.GetAttribute($field)
            if (-not $candidate) { continue }
            $candidateKeys = @(Get-NumberKeys $candidate)
            if (@($wanted | Where-Object { $candidateKeys -contains $_ }).Count -gt 0) {
                foreach ($nameField in @('name', 'firstname', 'lastname')) {
                    $value = $contact.GetAttribute($nameField)
                    if ($value) {
                        if ($nameField -eq 'firstname') {
                            $last = $contact.GetAttribute('lastname')
                            return (Clean-MarkdownText (($value, $last -join ' ').Trim()) '')
                        }
                        return (Clean-MarkdownText $value '')
                    }
                }
            }
        }
    }
    return ''
}

try {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Missing configuration file: $configPath"
    }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $callsPath = [System.IO.Path]::GetFullPath([string]$config.callsFolder)
    if (-not [System.IO.Path]::IsPathRooted($callsPath)) {
        throw 'callsFolder must be an absolute path.'
    }

    $rawCallerId = ($CallerId -join ' ').Trim()
    if (-not $rawCallerId) {
        $rawCallerId = [Environment]::GetEnvironmentVariable('MICROSIP_CALLER_ID', 'Process')
    }
    if (-not $rawCallerId) { throw 'MicroSIP did not provide caller-ID information.' }

    $caller = Parse-CallerId $rawCallerId
    $callerName = $caller.Name
    if (-not $callerName) {
        $callerName = Find-ContactName $caller.Number ([Environment]::ExpandEnvironmentVariables([string]$config.contactsFile))
    }
    if (-not $callerName) {
        $callerName = Find-RecentCallLogName $caller.Number (Get-MicroSipCallLogPath $config) ([datetimeoffset]::Now)
    }
    if (-not $callerName) { $callerName = 'Unknown caller' }

    $now = Get-Date
    $date = $now.ToString('dd-MM-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $time = $now.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $notePath = Join-Path $callsPath ($date + '.md')
    $arrow = [char]0x2192
    $middleDot = [char]0x00B7
    $callId = [guid]::NewGuid().ToString('N')

    [System.IO.Directory]::CreateDirectory($callsPath) | Out-Null
    [System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    if (-not [System.IO.File]::Exists($notePath)) {
        [System.IO.File]::WriteAllText($notePath, '', $utf8NoBom)
    }
    $existingText = [System.IO.File]::ReadAllText($notePath, [System.Text.Encoding]::UTF8)
    $callNumbers = @([regex]::Matches($existingText, '(?m)^#{1,2} Call (?<number>\d+)\s*$') | ForEach-Object {
        [int]$_.Groups['number'].Value
    })
    if ($callNumbers.Count -gt 0) {
        $callNumber = 1 + ($callNumbers | Measure-Object -Maximum).Maximum
    } else {
        # Continue numbering correctly when today's note began with the older
        # list format before this version was installed.
        $callNumber = 1 + [regex]::Matches($existingText, '(?m)^\s{1,2}\*\*Caller:\*\*').Count
    }
    $callHeading = "# Call $callNumber"
    $pendingLine = "**$time $arrow in progress - in progress**"
    $callerLine = " **Caller:** ``$callerName`` $middleDot **Phone:** ``$($caller.Number)``"
    $entryPrefix = ''
    if ($existingText.Length -gt 0) {
        if ($existingText -match '(?:\r\n|\n|\r)$') {
            # One final line break ends the last line; a second creates the
            # blank line that separates user notes from the next call.
            if ($existingText -notmatch '(?:\r\n|\n|\r)[ \t]*(?:\r\n|\n|\r)$') {
                $entryPrefix = "`r`n"
            }
        } elseif ($existingText -match '(?:\r\n|\n|\r)[ \t]*$') {
            # A whitespace-only final line is already the requested gap, but
            # it still needs to be terminated before the heading is written.
            $entryPrefix = "`r`n"
        } else {
            $entryPrefix = "`r`n`r`n"
        }
    }
    $entry = "$entryPrefix$callHeading`r`n`r`n$pendingLine`r`n`r`n$callerLine`r`n`r`n---`r`n`r`n"
    [System.IO.File]::AppendAllText($notePath, $entry, $utf8NoBom)

    $state = [ordered]@{
        id         = $callId
        startedAt  = $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        startTime  = $time
        notePath   = $notePath
        callerName = $callerName
        number     = $caller.Number
        numberKeys = @(Get-NumberKeys $caller.Number)
        formatVersion = 2
        callHeading = $callHeading
        pendingLine = $pendingLine
        callerLine = $callerLine
    }
    $stateJson = $state | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText((Join-Path $stateDirectory "$callId.json"), $stateJson, $utf8NoBom)
} catch {
    Write-DiagnosticError $_.Exception.Message
    exit 1
}
