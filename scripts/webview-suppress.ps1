<#
    WeType WebView2 Suppressor

    PURPOSE
      WeType preloads 12 msedgewebview2.exe processes for its voice-summary
      page (about 560 MB). If the user never uses voice input, those processes
      are pure waste.

    HOW
      Find msedgewebview2.exe processes whose ancestor chain resolves to
      wetype_update.exe, then terminate them. Other programs' WebView2
      instances (e.g. magpie / ZCode) are never touched, even though they
      share the same executable path.

    MODES
      Default   Watch window after logon: check every -Interval seconds for
                -WatchMinutes minutes, then exit. No permanent process.
      -Once     Single pass, then exit.
      -Loop     Persistent loop (legacy behaviour, must be stopped manually).
      -DryRun   Report only, never terminate.

    EXIT CODE
      0 normal
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [int]$WatchMinutes = 5,
    [int]$Interval = 10,
    [switch]$DryRun,
    [switch]$Loop
)

$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'wetype-webview-suppress.log'

function Write-Log([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { $line | Out-File -FilePath $log -Append -Encoding utf8 } catch { }
    Write-Output $line
}

# Single-instance guard for long-running modes only.
if ($Loop -or (-not $Once -and $WatchMinutes -gt 0)) {
    $mine = $PID
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object {
            $_.ProcessId -ne $mine -and
            $_.CommandLine -like '*webview-suppress.ps1*' -and
            $_.CommandLine -notlike '*Get-CimInstance*'
        })
    if ($others.Count -gt 0) {
        Write-Log ("another instance already running (pid={0}), exiting" -f ($others.ProcessId -join ','))
        exit 0
    }
}

# Collect msedgewebview2 processes owned by wetype_update.exe (via ancestor walk).
function Get-WeTypeWebViewProcesses {
    $cache = @{}
    $result = @()
    foreach ($p in @(Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq 0) { continue }
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
        if (-not $proc) { continue }
        $parent = [int]$proc.ParentProcessId
        $guard = 0
        $owner = $null
        while ($guard -lt 10 -and $parent) {
            if ($cache.ContainsKey($parent)) {
                $anc = $cache[$parent]
            } else {
                $anc = Get-CimInstance Win32_Process -Filter "ProcessId=$parent"
                $cache[$parent] = $anc
            }
            if (-not $anc) { break }
            if ($anc.Name -eq 'wetype_update.exe') {
                $owner = 'wetype_update.exe'
                break
            }
            if ($anc.Name -ne 'msedgewebview2.exe') { break }
            $parent = [int]$anc.ParentProcessId
            $guard++
        }
        if ($owner) {
            $result += [pscustomobject]@{
                Id         = $p.Id
                WorkingSet = $p.WorkingSet64
                Started    = $p.StartTime
            }
        }
    }
    return $result
}

function Invoke-Suppress {
    $targets = @(Get-WeTypeWebViewProcesses)
    if ($targets.Count -eq 0) { return 0 }

    $mb = ($targets | Measure-Object WorkingSet -Sum).Sum / 1MB
    Write-Log ("found {0} WeType WebView2 process(es), {1:N1} MB" -f $targets.Count, $mb)

    if ($DryRun) {
        foreach ($t in $targets) {
            Write-Log ("  DRYRUN would kill pid={0} ws={1:N1} MB started={2:HH:mm:ss}" -f `
                $t.Id, ($t.WorkingSet/1MB), $t.Started)
        }
        return 0
    }

    $killed = 0
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.Id -Force -ErrorAction Stop
            $killed++
        } catch { }
    }
    Write-Log ("terminated {0}/{1}" -f $killed, $targets.Count)
    return $killed
}

# Persistent loop mode (legacy).
if ($Loop) {
    Write-Log 'suppressor loop started (persistent mode)'
    while ($true) {
        Invoke-Suppress | Out-Null
        Start-Sleep -Seconds $Interval
    }
}

# Single-shot mode.
if ($Once -or $WatchMinutes -le 0) {
    Write-Log 'suppressor run (single shot)'
    Invoke-Suppress | Out-Null
    Write-Log 'done'
    exit 0
}

# Default: bounded watch window after logon.
# WeType starts at logon too, so a short window covers the case where WeType
# launches slightly later than this script.
Write-Log ("suppressor watch window started ({0} min, interval {1}s)" -f $WatchMinutes, $Interval)
$deadline = (Get-Date).AddMinutes($WatchMinutes)
$totalKilled = 0
while ((Get-Date) -lt $deadline) {
    $totalKilled += (Invoke-Suppress)
    Start-Sleep -Seconds $Interval
}
Write-Log ("watch window ended, total terminated: {0}" -f $totalKilled)
exit 0