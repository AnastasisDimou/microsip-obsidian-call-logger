[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $CallerId
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config.json'
$logDirectory = Join-Path $scriptRoot 'logs'
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
    if (-not $rawCallerId) { throw 'MicroSIP did not provide caller-ID information.' }

    $caller = Parse-CallerId $rawCallerId
    $callerName = $caller.Name
    if (-not $callerName) {
        $callerName = Find-ContactName $caller.Number ([Environment]::ExpandEnvironmentVariables([string]$config.contactsFile))
    }
    if (-not $callerName) { $callerName = 'Unknown caller' }

    $now = Get-Date
    $date = $now.ToString('dd-MM-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $time = $now.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $notePath = Join-Path $callsPath ($date + '.md')
    $dash = [char]0x2014
    $heading = "# Calls $dash $date`r`n`r`n"
    $entry = "- $time $dash $callerName $dash ``$($caller.Number)```r`n"

    [System.IO.Directory]::CreateDirectory($callsPath) | Out-Null
    if (-not [System.IO.File]::Exists($notePath)) {
        [System.IO.File]::WriteAllText($notePath, $heading, $utf8NoBom)
    }
    [System.IO.File]::AppendAllText($notePath, $entry, $utf8NoBom)
} catch {
    Write-DiagnosticError $_.Exception.Message
    exit 1
}
