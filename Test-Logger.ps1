[CmdletBinding()]
param([string] $ScriptPath)

$ErrorActionPreference = 'Stop'
if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot 'LogAnsweredCall.ps1' }
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('microsip-call-logger-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    Copy-Item -LiteralPath $ScriptPath -Destination $sandbox
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $ScriptPath) 'LaunchAnsweredCall.vbs') -Destination $sandbox
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $ScriptPath) 'CompleteAnsweredCall.ps1') -Destination $sandbox
    @"
{
  "callsFolder": "$($sandbox.Replace('\','\\'))\\Calls",
  "contactsFile": "$($sandbox.Replace('\','\\'))\\Contacts.xml"
}
"@ | Set-Content -LiteralPath (Join-Path $sandbox 'config.json') -Encoding utf8
    $greekName = -join (@(0x039C,0x03B1,0x03C1,0x03AF,0x03B1,0x20,0x0393,0x03B5,0x03C9,0x03C1,0x03B3,0x03AF,0x03BF,0x03C5) | ForEach-Object { [char]$_ })
    ('<?xml version="1.0" encoding="UTF-8"?><contacts><contact name="' + $greekName + '" number="+30 210 123 4567"/></contacts>') |
        Set-Content -LiteralPath (Join-Path $sandbox 'Contacts.xml') -Encoding utf8

    & (Join-Path $sandbox 'LogAnsweredCall.ps1') '"John Smith" <sip:+302101112222@example.invalid>'
    & (Join-Path $sandbox 'LogAnsweredCall.ps1') '+30 210 123 4567'
    & (Join-Path $sandbox 'LogAnsweredCall.ps1') 'sip:6941234567@example.invalid'
    & "$env:SystemRoot\System32\wscript.exe" //B //NoLogo (Join-Path $sandbox 'LaunchAnsweredCall.vbs') answer 'Wrapper Person <sip:+302109998888@example.invalid>'

    $note = Get-ChildItem -LiteralPath (Join-Path $sandbox 'Calls') -Filter '*.md' -File
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $text = [System.IO.File]::ReadAllText($note.FullName, [System.Text.Encoding]::UTF8)
        if ($text.Contains('+302109998888')) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $wrapperStateFile = Get-ChildItem -LiteralPath (Join-Path $sandbox 'state') -Filter '*.json' -File |
            Where-Object {
                $candidateState = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $candidateState.number -eq '+302109998888'
            } | Select-Object -First 1
        if ($wrapperStateFile) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    if (-not $wrapperStateFile) { throw 'Wrapper answer state was not created.' }
    $wrapperState = [System.IO.File]::ReadAllText($wrapperStateFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $wrapperState.startedAt = [datetimeoffset]::Now.AddSeconds(-3666).ToString('o')
    [System.IO.File]::WriteAllText(
        $wrapperStateFile.FullName,
        ($wrapperState | ConvertTo-Json -Depth 3),
        [System.Text.UTF8Encoding]::new($false)
    )
    & "$env:SystemRoot\System32\wscript.exe" //B //NoLogo (Join-Path $sandbox 'LaunchAnsweredCall.vbs') end '+302109998888'
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $text = [System.IO.File]::ReadAllText($note.FullName, [System.Text.Encoding]::UTF8)
        if ($text -match '\*\*Duration:\*\* 1 hr 1 min \d+ sec') { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $expectedDate = Get-Date -Format 'dd-MM-yyyy'
    $dash = [char]0x2014
    $middleDot = [char]0x00B7
    foreach ($pattern in @(
        "# Calls $dash $expectedDate",
        "**Caller:** ``John Smith`` $middleDot **Phone:** ``+302101112222``",
        "**Caller:** ``$greekName`` $middleDot **Phone:** ``+30 210 123 4567``",
        "**Caller:** ``Unknown caller`` $middleDot **Phone:** ``6941234567``",
        "**Caller:** ``Wrapper Person`` $middleDot **Phone:** ``+302109998888``"
    )) {
        if (-not $text.Contains($pattern)) { throw "Expected output not found: $pattern" }
    }
    if ($text -notmatch '(?s)- \*\*Answered:\*\* \d{2}:\d{2}.+?\*\*Ended:\*\* \d{2}:\d{2}.+?\*\*Duration:\*\* 1 hr 1 min \d+ sec  \r?\n  \*\*Caller:\*\* `Wrapper Person`') {
        throw 'Completed call did not use the requested two-line layout and human-readable duration.'
    }
    if ($text -match 'Transferred:') {
        throw 'Transfer logging was not removed.'
    }
    if ($text -match '<!-- microsip-call:') {
        throw 'An internal call-matching marker leaked into Markdown.'
    }
    $callerLines = @($text -split '\r?\n' | Where-Object { $_ -match '^  \*\*Caller:\*\*' })
    foreach ($callerLine in $callerLines) {
        if (-not $text.Contains($callerLine + [Environment]::NewLine + [Environment]::NewLine)) {
            throw 'A call entry was not followed by a blank line.'
        }
    }
    Write-Output 'All logger tests passed.'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
