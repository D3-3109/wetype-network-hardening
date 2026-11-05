<#
    WeType network lockdown (run elevated)
    - Create an Outbound/Block rule for every .exe under the WeType install root
    - Remove every Allow rule that points at a WeType program (both directions)
    - Ensure the Domain/Private/Public firewall profiles are all enabled
    Log is written to wetype-hardening.log next to this script.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'wetype-hardening.log'
$root = Join-Path $env:ProgramFiles 'Tencent\WeType'
$prefix = 'WeType-NetBlock'

function Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    $line | Tee-Object -FilePath $log -Append | Out-Null
}
function Fail([string]$m) {
    Log "ERROR: $m"
    Log 'EXIT_CODE=1'
    exit 1
}

'' | Out-File -FilePath $log -Encoding utf8
Log '=== WeType hardening start ==='

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'not elevated' }
Log 'elevated: yes'

if (-not (Test-Path -LiteralPath $root)) { Fail "install root missing: $root" }

# --- 1. Ensure firewall profiles are enabled ---
try {
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -ErrorAction Stop
    Log 'firewall profiles enabled: Domain, Private, Public'
} catch { Fail "enable firewall profiles: $($_)" }

# --- 2. Remove stale WeType-NetBlock rules (idempotent) ---
$old = @(Get-NetFirewallRule -DisplayName "$prefix*" -ErrorAction SilentlyContinue)
if ($old.Count -gt 0) {
    $old | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Log "removed $($old.Count) pre-existing $prefix rule(s)"
} else {
    Log "no pre-existing $prefix rules"
}

# --- 3. Enumerate executables and create outbound Block rules ---
$exes = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.exe -File -ErrorAction SilentlyContinue |
          Sort-Object FullName)
if ($exes.Count -eq 0) { Fail "no .exe under $root" }
Log "discovered $($exes.Count) executable(s) under $root"

foreach ($exe in $exes) {
    $rel = $exe.FullName.Substring($root.Length).TrimStart('\')
    $dn  = '{0}: {1}' -f $prefix, $rel
    try {
        New-NetFirewallRule -DisplayName $dn `
            -Direction Outbound -Action Block -Program $exe.FullName `
            -Profile Any -Enabled True `
            -Description 'Block WeType network egress (process-based)' -ErrorAction Stop | Out-Null
        Log "  + BLOCK outbound  $rel"
    } catch {
        Log "  ! failed $rel : $_"
    }
}

# --- 4. Remove every Allow rule pointing at a WeType program ---
$filters = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
             Where-Object { $_.Program -like '*\Tencent\WeType\*' })
$ids = @($filters | ForEach-Object { $_.InstanceID })

$candidates = @()
$candidates += @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $ids -contains $_.InstanceID })
$candidates += @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -match 'WeType' })
$candidates  = @($candidates | Sort-Object InstanceID -Unique)
$allowRules  = @($candidates | Where-Object { $_.Action -eq 'Allow' })

if ($allowRules.Count -eq 0) {
    Log 'no WeType Allow rules found'
} else {
    foreach ($r in $allowRules) {
        $prog = (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue).Program
        Log ('  - REMOVE Allow  "{0}"  Dir={1}  Enabled={2}  Program={3}' -f $r.DisplayName, $r.Direction, $r.Enabled, $prog)
        try {
            Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop
            Log '    removed'
        } catch {
            Log "    remove failed: $_"
        }
    }
}

# --- 5. Verification ---
Log '--- verification ---'
foreach ($p in @(Get-NetFirewallProfile)) {
    Log ('  profile {0,-8} Enabled={1} DefaultInbound={2}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction)
}

$vb = @(Get-NetFirewallRule -DisplayName "$prefix*" -ErrorAction SilentlyContinue)
$enabledBlock = @($vb | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' -and $_.Direction -eq 'Outbound' })
Log ("  {0} rules, {1} enabled outbound Block" -f $vb.Count, $enabledBlock.Count)

$vf = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -like '*\Tencent\WeType\*' })
$vids = @($vf | ForEach-Object { $_.InstanceID })
$vr = @()
$vr += @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $vids -contains $_.InstanceID })
$vr += @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'WeType' })
$vr  = @($vr | Sort-Object InstanceID -Unique)

$vAllow = @($vr | Where-Object { $_.Action -eq 'Allow' })
Log ("  WeType-related Allow rules remaining: {0}" -f $vAllow.Count)
foreach ($r in $vr) {
    $prog = (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue).Program
    Log ('    {0,-11} {1,-6} Enabled={2,-5} {3}  {4}' -f $r.Direction, $r.Action, $r.Enabled, $r.DisplayName, $prog)
}

Log '=== WeType hardening done ==='
Log 'EXIT_CODE=0'