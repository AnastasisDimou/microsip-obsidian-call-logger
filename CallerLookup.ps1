if (-not ('MicroSipSqliteReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class MicroSipCallLogEntry
{
    public string Number { get; set; }
    public string Name { get; set; }
    public long Time { get; set; }
}

public static class MicroSipSqliteReader
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteDone = 101;
    private const int SqliteOpenReadOnly = 1;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(IntPtr filename, out IntPtr db, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, IntPtr sql, int length, out IntPtr statement, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr statement, int column);

    private static IntPtr Utf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    private static string ColumnText(IntPtr statement, int column)
    {
        IntPtr pointer = sqlite3_column_text(statement, column);
        int length = sqlite3_column_bytes(statement, column);
        if (pointer == IntPtr.Zero || length == 0) return String.Empty;
        byte[] bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    public static MicroSipCallLogEntry[] ReadRecent(string path)
    {
        IntPtr db = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        IntPtr pathPointer = IntPtr.Zero;
        IntPtr sqlPointer = IntPtr.Zero;
        var entries = new List<MicroSipCallLogEntry>();
        try {
            pathPointer = Utf8(path);
            if (sqlite3_open_v2(pathPointer, out db, SqliteOpenReadOnly, IntPtr.Zero) != SqliteOk)
                return entries.ToArray();
            sqlite3_busy_timeout(db, 1000);
            sqlPointer = Utf8("SELECT number, name, time FROM call_log ORDER BY time DESC LIMIT 100");
            if (sqlite3_prepare_v2(db, sqlPointer, -1, out statement, IntPtr.Zero) != SqliteOk)
                return entries.ToArray();
            int result;
            while ((result = sqlite3_step(statement)) == SqliteRow) {
                entries.Add(new MicroSipCallLogEntry {
                    Number = ColumnText(statement, 0),
                    Name = ColumnText(statement, 1),
                    Time = sqlite3_column_int64(statement, 2)
                });
            }
            if (result != SqliteDone) return new MicroSipCallLogEntry[0];
            return entries.ToArray();
        }
        finally {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (db != IntPtr.Zero) sqlite3_close(db);
            if (sqlPointer != IntPtr.Zero) Marshal.FreeHGlobal(sqlPointer);
            if (pathPointer != IntPtr.Zero) Marshal.FreeHGlobal(pathPointer);
        }
    }
}
'@
}

function Get-MicroSipCallLogPath {
    param($Config)
    $configured = ''
    if ($Config -and $Config.PSObject.Properties.Name -contains 'callLogFile') {
        $configured = [Environment]::ExpandEnvironmentVariables([string]$Config.callLogFile)
    }
    if ($configured) { return $configured }
    return (Join-Path $env:APPDATA 'MicroSIP\call_log.db')
}

function Find-RecentCallLogName {
    param(
        [string] $Number,
        [string] $CallLogPath,
        [datetimeoffset] $ReferenceTime = [datetimeoffset]::Now
    )
    if (-not $CallLogPath -or -not (Test-Path -LiteralPath $CallLogPath)) { return '' }
    $wanted = @(Get-NumberKeys $Number)
    if ($wanted.Count -eq 0) { return '' }

    try {
        $referenceSeconds = $ReferenceTime.ToUnixTimeSeconds()
        foreach ($entry in [MicroSipSqliteReader]::ReadRecent([System.IO.Path]::GetFullPath($CallLogPath))) {
            # The history row is created near ring/answer time. A narrow window
            # prevents an old call from supplying a stale name for a reused ID.
            if ([Math]::Abs($referenceSeconds - $entry.Time) -gt 1800) { continue }
            $candidateKeys = @(Get-NumberKeys $entry.Number)
            if (@($wanted | Where-Object { $candidateKeys -contains $_ }).Count -eq 0) { continue }
            $candidateName = (Clean-MarkdownText $entry.Name '')
            if (-not $candidateName -or $candidateName -notmatch '[\p{L}]') { return '' }
            return $candidateName
        }
    } catch {
        # Call logging must continue if MicroSIP has the database locked or if
        # an older Windows installation does not provide winsqlite3.dll.
        return ''
    }
    return ''
}
