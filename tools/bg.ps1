# Background test driver (needs the proxy's +set coop_background 1 mode).
#   bg.ps1 launch <tag> "<extra args>"   -> starts iw3sp off-screen, prints pid
#   bg.ps1 cmd <tag> "<console commands>"
#   bg.ps1 shot <tag> <out.png> [scale]  -> asks the game for a frame, converts BMP to PNG
#   bg.ps1 kill <pid>
param([string]$Op, [string]$Tag = "0", [string]$Arg = "", [double]$Scale = 0.6)
$game = "C:\Users\got\Downloads\Call.of.Duty.4.Modern.Warfare\Call of Duty 4-Modern Warfare"
switch ($Op) {
  "launch" {
    # test dvars (window size/position, in_mouse 0) are archived into the player's profile: back it up once
    Get-ChildItem "$game\players\profiles\*\config.cfg" -ErrorAction SilentlyContinue | ForEach-Object {
      if (-not (Test-Path "$($_.FullName).coop_test")) { Copy-Item $_.FullName "$($_.FullName).coop_test" }
    }
    $a = "allowdupe +set coop_background 1 +set in_mouse 0 +set loc_warnings 0 +set coop_tag $Tag +set r_fullscreen 0 +set r_mode 800x600 +set com_maxfps 60 +set vid_xpos 1920 +set vid_ypos 0 +set logfile 2 $Arg"
    $p = Start-Process -FilePath "$game\iw3sp.exe" -WorkingDirectory $game -ArgumentList $a -PassThru
    "pid=$($p.Id)"
  }
  "cmd" { Set-Content -Path "$game\coop_cmd_$Tag.txt" -Value $Arg -Encoding ascii; "queued" }
  "shot" {
    $bmp = "$game\coop_shot_$Tag.bmp"
    Remove-Item $bmp -ErrorAction SilentlyContinue
    Set-Content -Path "$game\coop_shot_$Tag.req" -Value "1" -Encoding ascii
    for ($i = 0; $i -lt 40 -and -not (Test-Path $bmp); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path $bmp)) { "no screenshot (game not rendering?)"; exit 1 }
    Start-Sleep -Milliseconds 300
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($bmp)
    $w = [int]($img.Width * $Scale); $h = [int]($img.Height * $Scale)
    $out = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($out); $g.DrawImage($img, 0, 0, $w, $h)
    $out.Save($Arg, [System.Drawing.Imaging.ImageFormat]::Png); $img.Dispose()
    "saved $Arg"
  }
  "kill" {
    Stop-Process -Id ([int]$Tag) -Force; Start-Sleep -Milliseconds 800
    if (-not (Get-Process iw3sp -ErrorAction SilentlyContinue)) {
      Get-ChildItem "$game\players\profiles\*\config.cfg.coop_test" -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item $_.FullName ($_.FullName -replace '\.coop_test$', '') -Force
      }
      "killed, player config restored"
    } else { "killed (other instances still running; config restored by the last kill)" }
  }
}
