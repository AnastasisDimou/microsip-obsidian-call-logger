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
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $ScriptPath) 'CallerLookup.ps1') -Destination $sandbox
    @"
{
  "callsFolder": "$($sandbox.Replace('\','\\'))\\Calls",
  "contactsFile": "$($sandbox.Replace('\','\\'))\\Contacts.xml",
  "callLogFile": "$($sandbox.Replace('\','\\'))\\call_log.db"
}
"@ | Set-Content -LiteralPath (Join-Path $sandbox 'config.json') -Encoding utf8
    $greekName = -join (@(0x039C,0x03B1,0x03C1,0x03AF,0x03B1,0x20,0x0393,0x03B5,0x03C9,0x03C1,0x03B3,0x03AF,0x03BF,0x03C5) | ForEach-Object { [char]$_ })
    ('<?xml version="1.0" encoding="UTF-8"?><contacts><contact name="' + $greekName + '" number="+30 210 123 4567"/></contacts>') |
        Set-Content -LiteralPath (Join-Path $sandbox 'Contacts.xml') -Encoding utf8

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TestSqliteWriter
{
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(IntPtr filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db, IntPtr sql, IntPtr callback, IntPtr argument, IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    private static IntPtr Utf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    public static void Execute(string path, string sql)
    {
        IntPtr db = IntPtr.Zero;
        IntPtr pathPointer = Utf8(path);
        IntPtr sqlPointer = IntPtr.Zero;
        try {
            if (sqlite3_open_v2(pathPointer, out db, 6, IntPtr.Zero) != 0)
                throw new InvalidOperationException("Could not create the SQLite test fixture.");
            sqlPointer = Utf8(sql);
            if (sqlite3_exec(db, sqlPointer, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0)
                throw new InvalidOperationException("Could not populate the SQLite test fixture.");
        }
        finally {
            if (db != IntPtr.Zero) sqlite3_close(db);
            if (sqlPointer != IntPtr.Zero) Marshal.FreeHGlobal(sqlPointer);
            Marshal.FreeHGlobal(pathPointer);
        }
    }
}
'@
    $callLogPath = Join-Path $sandbox 'call_log.db'
    $nowEpoch = [datetimeoffset]::Now.ToUnixTimeSeconds()
    [TestSqliteWriter]::Execute($callLogPath, @"
CREATE TABLE call_log (id INTEGER PRIMARY KEY AUTOINCREMENT, callId TEXT NOT NULL, number TEXT NOT NULL, name TEXT NOT NULL, type INTEGER, time INTEGER, duration INTEGER, info TEXT NOT NULL);
INSERT INTO call_log (callId, number, name, type, time, duration, info) VALUES ('test-1', '6941234567', 'Call Log Person', 1, $nowEpoch, 0, 'Call Ended');
"@)

    & (Join-Path $sandbox 'LogAnsweredCall.ps1') '"John Smith" <sip:+302101112222@example.invalid>'
    & (Join-Path $sandbox 'LogAnsweredCall.ps1') '+30 210 123 4567'
    & (Join-Path $sandbox 'LogAnsweredCall.ps1') 'sip:6941234567@example.invalid'
    # Keep the wrapper test as the sole active call so it exercises the
    # caller-number-omitted cmdCallEnd fallback without ambiguity.
    Get-ChildItem -LiteralPath (Join-Path $sandbox 'state') -Filter '*.json' -File |
        Remove-Item -Force
    & "$env:SystemRoot\System32\wscript.exe" //B //NoLogo (Join-Path $sandbox 'LaunchAnsweredCall.vbs') answer '+302109998888'

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
    $wrapperEpoch = ([datetimeoffset]::Parse([string]$wrapperState.startedAt)).ToUnixTimeSeconds()
    [TestSqliteWriter]::Execute($callLogPath, "INSERT INTO call_log (callId, number, name, type, time, duration, info) VALUES ('test-2', '+302109998888', 'Wrapper Person', 1, $wrapperEpoch, 0, 'Call Ended');")
    # MicroSIP 3.22.12 may omit the caller number from cmdCallEnd. With one
    # active answered call, the completion script must still finish it.
    & "$env:SystemRoot\System32\wscript.exe" //B //NoLogo (Join-Path $sandbox 'LaunchAnsweredCall.vbs') end
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $text = [System.IO.File]::ReadAllText($note.FullName, [System.Text.Encoding]::UTF8)
        if ($text -match '\*\*Duration:\*\* 1 hr 1 min \d+ sec') { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $arrow = [char]0x2192
    $middleDot = [char]0x00B7
    foreach ($pattern in @(
        "# Call 1",
        "# Call 2",
        "# Call 3",
        "# Call 4",
        " **Caller:** ``John Smith`` $middleDot **Phone:** ``+302101112222``",
        " **Caller:** ``$greekName`` $middleDot **Phone:** ``+30 210 123 4567``",
        " **Caller:** ``Call Log Person`` $middleDot **Phone:** ``6941234567``",
        " **Caller:** ``Wrapper Person`` $middleDot **Phone:** ``+302109998888``"
    )) {
        if (-not $text.Contains($pattern)) { throw "Expected output not found: $pattern" }
    }
    if ($text -match '(?m)^## Call \d+\s*$') {
        throw 'A call heading used two hash characters instead of one.'
    }
    $completedPattern = '(?s)# Call 4\r?\n\r?\n\*\*\d{2}:\d{2} ' +
        [regex]::Escape([string]$arrow) +
        ' \d{2}:\d{2} - 1 hr 1 min \d+ sec\*\*\r?\n\r?\n \*\*Caller:\*\* `Wrapper Person` ' +
        [regex]::Escape([string]$middleDot) +
        ' \*\*Phone:\*\* `\+302109998888`\r?\n\r?\n---'
    if ($text -notmatch $completedPattern) {
        throw 'Completed call did not use the requested numbered-section layout and human-readable duration.'
    }
    if ($text -match 'Transferred:') {
        throw 'Transfer logging was not removed.'
    }
    if ($text -match '<!-- microsip-call:') {
        throw 'An internal call-matching marker leaked into Markdown.'
    }
    [System.IO.File]::AppendAllText(
        $note.FullName,
        'User note with no final line break',
        [System.Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $sandbox 'LogAnsweredCall.ps1') '2105550123'
    $text = [System.IO.File]::ReadAllText($note.FullName, [System.Text.Encoding]::UTF8)
    if ($text -notmatch 'User note with no final line break\r?\n\r?\n# Call 5(?:\r?\n)') {
        throw 'A new call was not separated from user-written text by a blank line.'
    }
    $callerLines = @($text -split '\r?\n' | Where-Object { $_ -match '^ \*\*Caller:\*\*' })
    foreach ($callerLine in $callerLines) {
        if (-not $text.Contains($callerLine + [Environment]::NewLine + [Environment]::NewLine)) {
            throw 'A call entry was not followed by a blank line.'
        }
    }
    Write-Output 'All logger tests passed.'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
