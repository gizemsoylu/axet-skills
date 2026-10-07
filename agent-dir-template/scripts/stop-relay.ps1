<#
.SYNOPSIS
  Reliably stops the ABAP ADT relay (node) and the BTP connectivity tunnel (cf ssh).

.WHY (read this if you're tempted to write an ad-hoc Get-CimInstance/Stop-Process one-liner)
  1. Process tree: these are launched as background shell -> powershell.exe -File ... ->
     node.exe / cf.exe. On Windows this is NOT a single job object, so killing only the
     top-level powershell.exe wrapper leaves node.exe/cf.exe running as an orphan that
     still holds its port. Always resolve and kill the REAL node.exe/cf.exe PID (and its
     own child tree, e.g. cf ssh's helper process), not just the launcher.
  2. Handle inheritance: if a relay/tunnel process was ever started with -NoNewWindow
     without full stdin/stdout/stderr redirection (an older bug in start-relay.ps1), it
     inherits this session's console pipe handles. While such a process is alive, ANY
     other foreground command run later in the same session can hang waiting for that
     pipe to reach EOF -- even a command that has nothing to do with the relay. If a
     plain command looks "stuck" for no reason, suspect a leftover relay/tunnel process
     from an older script version and kill it with this script from a fresh tool call.
  3. Avoid Get-CimInstance/Get-WmiObject Win32_Process here: WMI can intermittently hang
     with no timeout on some machines. This script identifies PIDs by PORT OWNERSHIP
     (Get-NetTCPConnection, which talks to netio, not WMI) instead of scanning/matching
     every process's CommandLine. It also runs under a hard wall-clock timeout so it
     cannot hang the caller indefinitely even if something unexpected blocks.
#>

$RelayPort  = 4599
$TunnelPort = 20003
$TimeoutSec = 15

$job = Start-Job -ScriptBlock {
    param($RelayPort, $TunnelPort)

    $pids = @()
    foreach ($port in @($RelayPort, $TunnelPort)) {
        try {
            $conns = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
            if ($conns) { $pids += $conns.OwningProcess }
        } catch {}
    }
    $pids = $pids | Sort-Object -Unique

    # Fallback: Get-Process (Win32 API, not WMI -- fast and does not hang) in case the
    # process is alive but hasn't bound its port yet (e.g. still resolving the destination).
    if (-not $pids) {
        $byName = @(Get-Process -Name 'node','cf' -ErrorAction SilentlyContinue)
        $pids = $byName | Select-Object -ExpandProperty Id
    }

    $result = @()
    foreach ($p in $pids) {
        try {
            & taskkill.exe /PID $p /T /F 2>$null | Out-Null
            $result += $p
        } catch {}
    }
    return $result
} -ArgumentList $RelayPort, $TunnelPort

$finished = Wait-Job -Job $job -Timeout $TimeoutSec
if (-not $finished) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Host "[stop-relay] WARNING - internal lookup/kill did not finish within ${TimeoutSec}s and was aborted."
    Write-Host "[stop-relay] This should not normally happen (port-based lookup avoids WMI). If it recurs, the machine's networking stack (Get-NetTCPConnection) may itself be degraded -- as a last resort use Resource Monitor / TCPView to find the PID bound to port $RelayPort or $TunnelPort and kill it manually."
    exit 1
}

$killedPids = Receive-Job -Job $job
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

if (-not $killedPids) {
    Write-Host "[stop-relay] nothing running (no process bound to port $RelayPort or $TunnelPort, and no node/cf process found)."
} else {
    Write-Host "[stop-relay] killed PID(s): $($killedPids -join ', ')"
    Write-Host "[stop-relay] confirmed stopped."
}
