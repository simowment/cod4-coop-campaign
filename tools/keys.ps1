param([int]$ProcId, [string]$Keys, [int]$DelayMs = 150)
# Focus the game window and send keystrokes (SendKeys syntax, e.g. "Coop{ENTER}", "~" or "{ESC}").
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class F { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@
$p = Get-Process -Id $ProcId
[void][F]::ShowWindow($p.MainWindowHandle, 9)
[void][F]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 400
foreach ($k in ($Keys -split '\|')) {
    [System.Windows.Forms.SendKeys]::SendWait($k)
    Start-Sleep -Milliseconds $DelayMs
}
"sent"
