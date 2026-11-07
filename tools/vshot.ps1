param([string]$Out, [int]$X = 1920, [int]$Y = 0, [int]$W = 800, [int]$H = 600)
# Capture the virtual monitor region (test instances live there, never on the user's screens).
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out"
