<#
    Functional proof that process-based outbound Block really works.
    Steps: copy curl.exe to a temp dir -> add a Block rule -> fetch (should fail)
           -> remove the rule -> fetch again (should succeed) -> clean up.
    System state is restored to exactly what it was before the test.
#>
$ErrorActionPreference = 'Continue'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$log   = Join-Path $here 'wetype-block-proof.log'
$tmp   = Join-Path $env:TEMP 'wetype-block-proof'
$exe   = Join-Path $tmp 'curltest.exe'
$src   = Join-Path $env:SystemRoot 'System32\curl.exe'
$rule  = 'WeType-BlockProof-TEMP'

function Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    $line | Tee-Object -FilePath $log -Append | Out-Null
}

'' | Out-File -FilePath $log -Encoding utf8
Log '=== block proof start ==='

if (-not (Test-Path -LiteralPath $src)) { Log "SKIP: curl.exe not found"; Log 'EXIT_CODE=0'; exit 0 }

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item -LiteralPath $src -Destination $exe -Force
Log "copied test exe -> $exe"

function Try-Fetch([string]$tag) {
    $out = & $exe -s -o NUL -w '%{http_code}' --max-time 8 'https://www.baidu.com' 2>&1
    $code = $LASTEXITCODE
    Log ("  {0}: exit={1} http_code='{2}'" -f $tag, $code, ($out | Out-String).Trim())
    return $code
}

# 1. baseline before rule
$before = Try-Fetch 'baseline (no rule)'

# 2. add block rule
try {
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule -Direction Outbound -Action Block `
        -Program $exe -Profile Any -Enabled True -ErrorAction Stop | Out-Null
    Log "added temp block rule for $exe"
} catch {
    Log "ERROR adding temp rule: $_"
    Log 'EXIT_CODE=1'
    exit 1
}

# 3. test with rule
Start-Sleep -Milliseconds 500
$blocked = Try-Fetch 'with block rule'

# 4. remove rule and re-test
Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
Log 'removed temp block rule'
Start-Sleep -Milliseconds 500
$restored = Try-Fetch 'after rule removal'

# 5. cleanup
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Log 'cleaned up temp exe'

Log '--- verdict ---'
if ($before -eq 0 -and $blocked -ne 0 -and $restored -eq 0) {
    Log 'PASS: outbound blocked by rule, restored after removal -> process-level block works'
} elseif ($before -ne 0) {
    Log 'INCONCLUSIVE: baseline fetch failed (network or proxy issue), block cannot be validated this way'
} else {
    Log "CHECK: before=$before blocked=$blocked restored=$restored"
}

Log '--- temp rule must be gone ---'
$left = @(Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)
Log "  remaining temp rules: $($left.Count)"
Log '=== block proof done ==='
Log 'EXIT_CODE=0'