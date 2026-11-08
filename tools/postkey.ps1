# Posts a key press to a game window without focusing it: postkey.ps1 <pid> [vk=0x0D]
param([int]$ProcId, [int]$Vk = 0x0D)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class PK { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); }
"@
$h = (Get-Process -Id $ProcId).MainWindowHandle
[void][PK]::PostMessage($h, 0x100, [IntPtr]$Vk, [IntPtr]1)
Start-Sleep -Milliseconds 60
[void][PK]::PostMessage($h, 0x101, [IntPtr]$Vk, [IntPtr]0xC0000001)
"posted vk $Vk to $h"
