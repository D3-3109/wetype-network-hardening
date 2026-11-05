<#
    Register the WeType WebView2 suppressor as a logon task.

    Behaviour
      - Runs once at logon, watches for 5 minutes, then exits.
      - No permanent background process is left running.

    Why a watch window instead of a single shot
      WeType also starts at logon. If this task fires before WeType has
      finished launching, a single-shot pass would find nothing and the
      preloaded WebView2 processes would survive. The 5-minute window covers
      that ordering race and exits on its own.
#>
$ErrorActionPreference = 'Stop'

$taskName = 'WeType-WebView2-Suppress'
$vbs      = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'start-suppress.vbs'

if (-not (Test-Path -LiteralPath $vbs)) { throw "vbs not found: $vbs" }

# Remove any previous registration and stray processes.
$old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($old) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    'removed previous task'
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*webview-suppress.ps1*' -and $_.CommandLine -notlike '*Get-CimInstance*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$principal = New-ScheduledTaskPrincipal `
    -UserId  "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -Hidden

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Terminate WeType-preloaded msedgewebview2.exe (voice summary page). Logon watch window only; exits after 5 minutes.' | Out-Null

$t = Get-ScheduledTask -TaskName $taskName
"registered: {0}  state={1}" -f $t.TaskName, $t.State
"  action  : {0} {1}" -f $t.Actions[0].Execute, $t.Actions[0].Arguments
"  trigger : {0}" -f ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName })
"  hidden  : {0}" -f $t.Settings.Hidden
"  runlevel: {0}" -f $t.Principal.RunLevel