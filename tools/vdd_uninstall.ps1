# Removes the Virtual Display Driver installed by vdd_install.ps1. Run elevated.
$log = Join-Path $env:TEMP "vdd_uninstall.log"
Set-Content -Path $log -Value "vdd uninstall $(Get-Date)"
$devs = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq "Virtual Display Driver" }
$infs = @()
foreach ($d in $devs) {
    $inf = (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $d.InstanceId }).InfName
    if ($inf) { $infs += $inf }
    Add-Content $log ("remove-device " + $d.InstanceId + ": " + (pnputil /remove-device "$($d.InstanceId)" | Out-String))
}
foreach ($inf in ($infs | Select-Object -Unique)) {
    Add-Content $log ("delete-driver " + $inf + ": " + (pnputil /delete-driver $inf /uninstall /force | Out-String))
}
Remove-Item "C:\VirtualDisplayDriver" -Recurse -Force -ErrorAction SilentlyContinue
Add-Content $log "done"
