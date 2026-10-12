Option Explicit
Dim shell, files, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
scriptPath = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "installer-ui.ps1")
command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe") & Chr(34) & " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34) & " -Restore"
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
  shell.Popup "Unable to start LibreOfficePlus: " & Err.Description, 0, "LibreOfficePlus", 16
  WScript.Quit 1
End If
