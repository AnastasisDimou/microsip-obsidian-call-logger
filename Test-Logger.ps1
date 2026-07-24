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
    & "$env:SystemRoot\System32\wscript.exe" //B //NoLogo (Join-Path $sandbox 'LaunchAnsweredCall.vbs') end '+302109998888'
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $text = [System.IO.File]::ReadAllText($note.FullName, [System.Text.Encoding]::UTF8)
        if ($text -match 'Duration: \d{2}:\d{2}:\d{2}.+Wrapper Person') { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $expectedDate = Get-Date -Format 'dd-MM-yyyy'
    $dash = [char]0x2014
    foreach ($pattern in @(
        "# Calls $dash $expectedDate",
        "``John Smith`` $dash ``+302101112222``",
        "``$greekName`` $dash ``+30 210 123 4567``",
        "``Unknown caller`` $dash ``6941234567``",
        "``Wrapper Person`` $dash ``+302109998888``"
    )) {
        if (-not $text.Contains($pattern)) { throw "Expected output not found: $pattern" }
    }
    if ($text -notmatch 'Answered: \d{2}:\d{2}.+Ended: \d{2}:\d{2}.+Duration: \d{2}:\d{2}:\d{2}.+Wrapper Person') {
        throw 'Completed call did not include answer time, end time, and HH:mm:ss duration.'
    }
    if ($text -match 'Transferred:') {
        throw 'Transfer logging was not removed.'
    }
    if ($text -match '<!-- microsip-call:') {
        throw 'An internal call-matching marker leaked into Markdown.'
    }
    $callLines = @($text -split '\r?\n' | Where-Object { $_ -match '^- Answered:' })
    foreach ($callLine in $callLines) {
        if (-not $text.Contains($callLine + [Environment]::NewLine + [Environment]::NewLine)) {
            throw 'A call entry was not followed by a blank line.'
        }
    }
    Write-Output 'All logger tests passed.'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
