' ============================================================
'  WeType WebView2 Suppressor - silent launcher
'
'  Runs PowerShell completely hidden and WAITS for it, so the
'  scheduled task's state reflects the real runtime.
'
'  Default: 5-minute watch window after logon, then exits.
'  No permanent background process is left running.
'
'  Window style 0 = hidden, no console window is ever created.
' ============================================================
Option Explicit

Dim fso, shell, here, ps1, cmd, rc
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "webview-suppress.ps1")

If Not fso.FileExists(ps1) Then
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden" _
    & " -ExecutionPolicy Bypass -File """ & ps1 & """ -WatchMinutes 5 -Interval 10"

rc = shell.Run(cmd, 0, True)

WScript.Quit rc
