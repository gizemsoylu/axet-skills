# Windows-only. For macOS/Linux use start-relay.sh instead.
param()

# Loads SAP_USER, SAP_PASS and S4_DEST from sap_cred.env (copy it from
# sap_cred.env.example and fill in your own values first).
$lines = Get-Content "$PSScriptRoot/sap_cred.env"
foreach ($line in $lines) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
    }
}

$env:AGENT_DIR = $PSScriptRoot
$env:PERSONAL_SAP_USER = $env:SAP_USER
$env:PERSONAL_SAP_PASSWORD = $env:SAP_PASS
$env:RELAY_PORT = '4599'
# Point this at your cf.exe if it isn't on PATH, e.g.:
#   $env:CF_EXE = 'C:/path/to/cf.exe'
$env:CF_EXE = if ($env:CF_EXE) { $env:CF_EXE } else { 'cf' }

# IMPORTANT: redirect stdin/stdout/stderr to files instead of using -NoNewWindow without
# redirection. -NoNewWindow makes the child inherit this process's console input/output
# handles; since node runs forever as a listening server, that handle/pipe never closes,
# which hangs any tool (e.g. job_output -wait, or a plain pipe read) waiting for this
# launcher's streams to reach EOF -- even though the launcher script itself has already
# returned and the child is an orphan by then. Redirecting all three keeps this script's
# own streams free to close immediately and lets the launching shell exit cleanly.
$logFile = "$PSScriptRoot/relay.log"
$stdinFile = "$PSScriptRoot/relay.stdin"
if (-not (Test-Path $stdinFile)) { New-Item -ItemType File -Path $stdinFile | Out-Null }
$proc = Start-Process -FilePath 'node' -ArgumentList "`"$PSScriptRoot/scripts/abap-adt-relay.mjs`"" `
    -PassThru -NoNewWindow -RedirectStandardInput $stdinFile `
    -RedirectStandardOutput $logFile -RedirectStandardError "$PSScriptRoot/relay.err.log"
Write-Host "[relay] started in background, pid=$($proc.Id) (log: $logFile)"
