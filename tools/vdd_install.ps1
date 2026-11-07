# Installs the Virtual Display Driver (MttVDD) as a root-enumerated device - what "devcon install" does.
# Run elevated:  powershell -ExecutionPolicy Bypass -File vdd_install.ps1 <folder with MttVDD.inf>
param([string]$Dir)
$ErrorActionPreference = "Stop"
$log = Join-Path $env:TEMP "vdd_install.log"
function L($m) { Add-Content -Path $log -Value $m; $m }
Set-Content -Path $log -Value "vdd install $(Get-Date)"
New-Item -ItemType Directory -Force "C:\VirtualDisplayDriver" | Out-Null
Copy-Item "$Dir\vdd_settings.xml" "C:\VirtualDisplayDriver\vdd_settings.xml" -Force
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Dev {
 [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
 [DllImport("setupapi.dll", SetLastError=true)] public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid g, IntPtr hwnd);
 [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiCreateDeviceInfoW(IntPtr set, string name, ref Guid g, string desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA d);
 [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref SP_DEVINFO_DATA d, int prop, byte[] buf, int size);
 [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA d);
 [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
 [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwnd, string hwid, string inf, int flags, out bool reboot);
}
"@
$guid = [Guid]"4D36E968-E325-11CE-BFC1-08002BE10318"
$hwid = "Root\MttVDD"
$set = [Dev]::SetupDiCreateDeviceInfoList([ref]$guid, [IntPtr]::Zero)
$dd = New-Object Dev+SP_DEVINFO_DATA; $dd.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($dd)
if (-not [Dev]::SetupDiCreateDeviceInfoW($set, "Display", [ref]$guid, $null, [IntPtr]::Zero, 1, [ref]$dd)) { L "CreateDeviceInfo failed $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }
$bytes = [Text.Encoding]::Unicode.GetBytes($hwid + "`0`0")
if (-not [Dev]::SetupDiSetDeviceRegistryPropertyW($set, [ref]$dd, 1, $bytes, $bytes.Length)) { L "SetHardwareId failed"; exit 1 }
if (-not [Dev]::SetupDiCallClassInstaller(0x19, $set, [ref]$dd)) { L "DIF_REGISTERDEVICE failed $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }
[void][Dev]::SetupDiDestroyDeviceInfoList($set)
$reboot = $false
$ok = [Dev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $hwid, (Join-Path $Dir "MttVDD.inf"), 1, [ref]$reboot)
L "UpdateDriver ok=$ok err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()) reboot=$reboot"
