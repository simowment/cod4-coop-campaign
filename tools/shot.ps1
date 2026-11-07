param([int]$ProcId = 0, [string]$Out = "shot.png", [string]$Title = "Call of Duty 4")
# Screenshot the game's render window (exact title), not the "Console" window. Brings it to the front first
# so the capture is the game and not whatever is behind it.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class W {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
 [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 public static IntPtr Find(uint pid, string title) {
  IntPtr found = IntPtr.Zero;
  EnumWindows(delegate(IntPtr h, IntPtr l) {
   uint p; GetWindowThreadProcessId(h, out p);
   if (p != pid || !IsWindowVisible(h)) return true;
   var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
   if (sb.ToString() == title) { found = h; return false; }
   return true; }, IntPtr.Zero);
  return found; } }
"@
if ($ProcId -eq 0) { $ProcId = (Get-Process iw3sp | Select-Object -First 1).Id }
$h = [W]::Find([uint32]$ProcId, $Title)
if ($h -eq [IntPtr]::Zero) { "no visible '$Title' window for pid $ProcId"; exit 1 }
[void][W]::ShowWindow($h, 9); [void][W]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400
$r = New-Object W+RECT
[void][W]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L; $hh = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out ${w}x${hh}"
