<#
.SYNOPSIS
  Opens the BTP connectivity tunnel for an on-premise ABAP system.
  Idempotent-ish: safe to re-run; if the tunnel is already up on the local port it will just
  open another cf ssh process (close old windows/processes manually with stop-relay.ps1 if restarting).

.NOTES
  Fill in $AppName / $RemoteHost below for your own BTP app and region (or set the
  CF_APP_NAME / CONNECTIVITY_PROXY_HOST env vars instead of editing this file).
  $AppName  is the name of a BTP app bound to the connectivity service in your subaccount.
  $RemoteHost is the connectivity proxy host for your region, of the form
  connectivityproxy.internal.cf.<region>.hana.ondemand.com -- find it in that app's
  connectivity service binding / destination configuration.
#>

$CfExe       = if ($env:CF_EXE) { $env:CF_EXE } else { 'cf' }
$AppName     = if ($env:CF_APP_NAME) { $env:CF_APP_NAME } else { '<YOUR_CF_APP_NAME>' }
$RemoteHost  = if ($env:CONNECTIVITY_PROXY_HOST) { $env:CONNECTIVITY_PROXY_HOST } else { '<YOUR_CONNECTIVITY_PROXY_HOST>' }
$RemotePort  = 20003
$LocalPort   = 20003

if ($AppName -eq '<YOUR_CF_APP_NAME>' -or $RemoteHost -eq '<YOUR_CONNECTIVITY_PROXY_HOST>') {
    Write-Host "[tunnel] ERROR - edit `$AppName/`$RemoteHost in this script (or set CF_APP_NAME/CONNECTIVITY_PROXY_HOST env vars) before running it."
    exit 1
}

Write-Host "[tunnel] opening cf ssh -L $LocalPort`:$RemoteHost`:$RemotePort via $AppName ..."
Start-Process -FilePath $CfExe -ArgumentList @(
    'ssh', $AppName, '-N', '-L', "$LocalPort`:$RemoteHost`:$RemotePort"
) -WindowStyle Normal

Start-Sleep -Seconds 3
$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect('127.0.0.1', $LocalPort)
    Write-Host "[tunnel] up: 127.0.0.1:$LocalPort -> $RemoteHost`:$RemotePort"
} catch {
    Write-Host "[tunnel] WARNING - could not confirm port $LocalPort yet, check the opened cf ssh window."
} finally {
    $client.Dispose()
}
