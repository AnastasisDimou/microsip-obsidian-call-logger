Option Explicit

Dim shell, callerId, i, scriptDir, loggerPath, command
Set shell = CreateObject("WScript.Shell")

callerId = ""
For i = 0 To WScript.Arguments.Count - 1
    If Len(callerId) > 0 Then callerId = callerId & " "
    callerId = callerId & WScript.Arguments(i)
Next

shell.Environment("Process")("MICROSIP_CALLER_ID") = callerId
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
loggerPath = scriptDir & "\LogAnsweredCall.ps1"
command = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe" & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    Chr(34) & loggerPath & Chr(34)

shell.Run command, 0, False
