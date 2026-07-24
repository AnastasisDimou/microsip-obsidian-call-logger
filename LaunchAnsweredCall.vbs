Option Explicit

Dim shell, callerId, i, scriptDir, loggerPath, command, eventName, firstCallerArg
Set shell = CreateObject("WScript.Shell")

eventName = "answer"
firstCallerArg = 0
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "answer" Or LCase(WScript.Arguments(0)) = "end" Then
        eventName = LCase(WScript.Arguments(0))
        firstCallerArg = 1
    End If
End If

callerId = ""
For i = firstCallerArg To WScript.Arguments.Count - 1
    If Len(callerId) > 0 Then callerId = callerId & " "
    callerId = callerId & WScript.Arguments(i)
Next

shell.Environment("Process")("MICROSIP_CALLER_ID") = callerId
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
If eventName = "end" Then
    loggerPath = scriptDir & "\CompleteAnsweredCall.ps1"
Else
    loggerPath = scriptDir & "\LogAnsweredCall.ps1"
End If
command = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe" & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    Chr(34) & loggerPath & Chr(34)

shell.Run command, 0, False
