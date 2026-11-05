$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'block-proof.ps1'
$p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -Wait `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$target`"")
"elevated exit code: $($p.ExitCode)"
exit $p.ExitCode