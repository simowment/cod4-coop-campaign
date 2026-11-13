# CoD4 Coop Campaign launcher: host or join with a short join code. Lives next to iw3sp.exe.
#   Host: opens UDP 28970 on the router through UPnP (if the router allows it), shows join codes, starts the game.
#   Join: paste a code (or pick a game found on the LAN), checks the host answers, starts the game.
# Non-interactive helpers for tests:  -Encode 1.2.3.4:28970   -Decode CODE   -Discover   -Probe CODE
param([string]$Encode = "", [string]$Decode = "", [switch]$Discover, [string]$Probe = "")

$ErrorActionPreference = "Stop"
# run as "CoD4 Coop.bat" (the build embeds this script in a batch file) or directly as a .ps1
if ($env:COOP_GAMEDIR) { $GameDir = $env:COOP_GAMEDIR.TrimEnd([char]92) } else { $GameDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Port = 28970
$SettingsFile = Join-Path $GameDir "coop_launcher.json"

# ------------------------------------------------------------------------------------------------
# join codes: Crockford base32 of IPv4 (4 bytes) + port (2 bytes) -> 10 chars, shown as XXXXX-XXXXX
# ------------------------------------------------------------------------------------------------
$B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

function Encode-JoinCode([string]$ip, [int]$port) {
    $b = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
    [UInt64]$v = 0
    foreach ($x in $b) { $v = ($v -shl 8) -bor [UInt64]$x }
    $v = ($v -shl 16) -bor [UInt64]$port
    $s = ""
    for ($i = 0; $i -lt 10; $i++) { $s = $B32[[int]($v -band 31)] + $s; $v = $v -shr 5 }
    return $s.Substring(0, 5) + "-" + $s.Substring(5)
}

function Decode-JoinCode([string]$code) {
    $t = $code.Trim()
    if ($t -match '^\d{1,3}(\.\d{1,3}){3}(:\d+)?$') {            # plain IP[:port] also works
        $parts = $t.Split(':'); $p = $Port; if ($parts.Count -gt 1) { $p = [int]$parts[1] }
        return @{ ip = $parts[0]; port = $p }
    }
    $t = $t.ToUpper().Replace("-", "").Replace(" ", "").Replace("O", "0").Replace("I", "1").Replace("L", "1")
    if ($t.Length -ne 10) { return $null }
    [UInt64]$v = 0
    foreach ($ch in $t.ToCharArray()) {
        $d = $B32.IndexOf($ch); if ($d -lt 0) { return $null }
        $v = ($v -shl 5) -bor [UInt64]$d
    }
    $port = [int]($v -band 0xFFFF); $v = $v -shr 16
    $ip = "{0}.{1}.{2}.{3}" -f (($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)
    return @{ ip = $ip; port = $port }
}

# ------------------------------------------------------------------------------------------------
# network helpers
# ------------------------------------------------------------------------------------------------
function Get-LocalAddresses {
    # @{ lan = "192.168.x.y"; vpn = "100.x.y.z" (Tailscale/ZeroTier/Radmin/Hamachi) }
    $res = @{ lan = $null; vpn = $null; vpnName = $null }
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $a = $ua.Address.ToString()
            if ($a.StartsWith("169.254.")) { continue }
            $desc = ($ni.Name + " " + $ni.Description).ToLower()
            $isVpn = $desc -match 'tailscale|zerotier|radmin|hamachi|wireguard' -or $a -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.'
            if ($isVpn) { if (-not $res.vpn) { $res.vpn = $a; $res.vpnName = $ni.Name } }
            elseif ($ni.GetIPProperties().GatewayAddresses.Count -gt 0 -and -not $res.lan) { $res.lan = $a }
        }
    }
    return $res
}

# A UDP socket that ignores "port unreachable" replies: by default Windows turns them into a
# "connection was closed by the remote host" error on the next receive (SIO_UDP_CONNRESET), which crashed
# the Join tab whenever a probe hit a machine with no game running.
function New-ProbeSocket {
    $u = New-Object System.Net.Sockets.UdpClient 0
    try { [void]$u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}
    return $u
}

function Send-Probe([System.Net.Sockets.UdpClient]$u, [System.Net.IPEndPoint]$ep) {
    # 12-byte coop header: magic 'C4' (0x3443 LE), ver 1, type 6 (DISCOVER), rest zero
    $pkt = [byte[]](0x43, 0x34, 1, 6, 0, 0, 0, 0, 0, 0, 0, 0)
    try { [void]$u.Send($pkt, $pkt.Length, $ep) } catch {}
}

function Read-Infos([System.Net.Sockets.UdpClient]$u, [int]$ms) {
    $found = @{}
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        if ($u.Available -gt 0) {
            $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
            try { $data = $u.Receive([ref]$from) } catch { continue }  # a stray ICMP error: keep listening
            if ($data.Length -gt 12 -and $data[0] -eq 0x43 -and $data[1] -eq 0x34 -and $data[3] -eq 7) {
                $f = [System.Text.Encoding]::ASCII.GetString($data, 12, $data.Length - 12).Split('|')
                $key = $from.Address.ToString() + ":" + $from.Port
                $found[$key] = [pscustomobject]@{ ip = $from.Address.ToString(); port = $from.Port; host = $f[0]; map = $f[1]; players = "$($f[2])/$($f[3])" }
            }
        } else { Start-Sleep -Milliseconds 40 }
    }
    return @($found.Values)
}

function Find-LanGames {
    $u = New-ProbeSocket
    $u.EnableBroadcast = $true
    try {
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Broadcast, $Port))
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port))
        return Read-Infos $u 1200
    } finally { $u.Close() }
}

function Probe-Host([string]$ip, [int]$port) {
    $u = New-ProbeSocket
    try {
        $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)
        # @(...): one answer comes back as a single object, which has no .Count in Windows PowerShell 5.1
        for ($i = 0; $i -lt 3; $i++) { Send-Probe $u $ep; $r = @(Read-Infos $u 700); if ($r.Count) { return $r[0] } }
        return $null
    } finally { $u.Close() }
}

# UPnP: ask the router to forward UDP $Port to this PC. Returns the public IP, or $null.
function Open-RouterPort([string]$lanIp) {
    try {
        $nat = New-Object -ComObject HNetCfg.NATUPnP
        $maps = $nat.StaticPortMappingCollection
        if ($null -eq $maps) { return $null }       # router without UPnP (or UPnP off)
        try { $maps.Remove($Port, "UDP") } catch {}
        $m = $maps.Add($Port, "UDP", $Port, $lanIp, $true, "CoD4 Coop")
        if ($m -and $m.ExternalIPAddress) { return $m.ExternalIPAddress }
    } catch {}
    return $null
}

function Close-RouterPort {
    try { $nat = New-Object -ComObject HNetCfg.NATUPnP; $maps = $nat.StaticPortMappingCollection; if ($maps) { $maps.Remove($Port, "UDP") } } catch {}
}

# ------------------------------------------------------------------------------------------------
# test helpers (no window)
# ------------------------------------------------------------------------------------------------
if ($Encode) { $p = $Encode.Split(':'); $pp = $Port; if ($p.Count -gt 1) { $pp = [int]$p[1] }; Encode-JoinCode $p[0] $pp; exit 0 }
if ($Decode) { $d = Decode-JoinCode $Decode; if ($d) { "$($d.ip):$($d.port)" } else { "invalid" }; exit 0 }
if ($Discover) { Find-LanGames | ForEach-Object { "$($_.host) | $($_.map) | $($_.players) | $($_.ip):$($_.port)" }; exit 0 }
if ($Probe) { $d = Decode-JoinCode $Probe; $r = Probe-Host $d.ip $d.port; if ($r) { "$($r.host) | $($r.map) | $($r.players)" } else { "no answer" }; exit 0 }

# ------------------------------------------------------------------------------------------------
# first start: the coop hooks go into the stock scripts, which are read from the player's own game
# files (no game files are shipped). coop_patches.json lists anchored edits; .patched records the
# hash of the edit list that was applied, so a new release re-applies them.
# ------------------------------------------------------------------------------------------------
$CoopFFCode = @'
using System; using System.IO; using System.IO.Compression; using System.Text;
using System.Text.RegularExpressions; using System.Collections.Generic;
public static class CoopFF {
    static readonly Encoding L1 = Encoding.GetEncoding(28591);
    static readonly Dictionary<string, Dictionary<string, string>> Cache = new Dictionary<string, Dictionary<string, string>>();
    static readonly Regex Raw = new Regex("\xff\xff\xff\xff(.{4})\xff\xff\xff\xff([a-zA-Z0-9_/\\\\.\\-]{3,120}\\.(?:gsc|csv|cfg|txt|menu|str|vision|atr|gdt|shock|arena|sun))\x00", RegexOptions.Singleline);
    static Dictionary<string, string> Rawfiles(string ff) {
        Dictionary<string, string> d;
        if (Cache.TryGetValue(ff, out d)) return d;
        byte[] b = File.ReadAllBytes(ff);
        if (L1.GetString(b, 0, 8) != "IWffu100") throw new Exception("not an IW3 fastfile: " + ff);
        var ms = new MemoryStream();
        using (var ds = new DeflateStream(new MemoryStream(b, 14, b.Length - 14), CompressionMode.Decompress)) ds.CopyTo(ms);
        string z = L1.GetString(ms.ToArray());
        d = new Dictionary<string, string>();
        foreach (Match m in Raw.Matches(z)) {
            string l = m.Groups[1].Value;
            int len = l[0] | (l[1] << 8) | (l[2] << 16) | (l[3] << 24);
            if (len > 0 && len < 8000000 && m.Index + m.Length + len <= z.Length)
                d[m.Groups[2].Value.Replace('\\', '/')] = z.Substring(m.Index + m.Length, len);
        }
        Cache[ff] = d;
        return d;
    }
    public static string Find(string zoneDir, string name, string[] zones) {
        foreach (string zn in zones) {
            var d = Rawfiles(Path.Combine(zoneDir, zn + ".ff"));
            string t;
            if (d.TryGetValue(name, out t)) return t;
        }
        throw new Exception(name + " not found in your game files (" + string.Join(", ", zones) + ")");
    }
    public static string Apply(string file, string text, string anchor, string mode, string payload) {
        var ms = Regex.Matches(text, anchor, RegexOptions.Multiline);
        if (ms.Count != 1) throw new Exception("patch anchor for " + file + " matched " + ms.Count + " times");
        Match m = ms[0];
        if (mode == "after") return text.Substring(0, m.Index + m.Length) + payload + text.Substring(m.Index + m.Length);
        if (mode == "before") return text.Substring(0, m.Index) + payload + text.Substring(m.Index);
        if (mode == "replace") return text.Substring(0, m.Index) + payload + text.Substring(m.Index + m.Length);
        throw new Exception("bad patch mode " + mode);
    }
    public static void Write(string path, string text) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllText(path, text, L1);
    }
}
'@
function Test-CoopInstalled {
    $json = Join-Path $GameDir "Mods\coop\coop_patches.json"
    if (-not (Test-Path $json)) { return $true }
    $marker = Join-Path $GameDir "Mods\coop\.patched"
    return ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq (Get-FileHash $json -Algorithm SHA256).Hash))
}
function Install-CoopScripts {
    $json = Join-Path $GameDir "Mods\coop\coop_patches.json"
    if (-not ("CoopFF" -as [type])) { Add-Type -TypeDefinition $CoopFFCode }
    $p = [IO.File]::ReadAllText($json) | ConvertFrom-Json
    $zoneDir = Join-Path $GameDir "zone\english"
    foreach ($e in $p.patches) {
        $t = [CoopFF]::Find($zoneDir, $e.file, [string[]]$e.zones)
        foreach ($ed in $e.edits) { $t = [CoopFF]::Apply($e.file, $t, $ed.anchor, $ed.mode, $ed.payload) }
        [CoopFF]::Write((Join-Path $GameDir ("Mods\coop\" + $e.file)), $t)
    }
    Set-Content -Path (Join-Path $GameDir "Mods\coop\.patched") -Value (Get-FileHash $json -Algorithm SHA256).Hash -Encoding ascii
}
if ($env:COOP_INSTALL_ONLY) { Install-CoopScripts; "installed"; exit }

# ------------------------------------------------------------------------------------------------
# window
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Missions = [ordered]@{
    "F.N.G. (killhouse)" = "killhouse"; "Crew Expendable (cargoship)" = "cargoship"; "The Coup (coup)" = "coup";
    "Blackout (blackout)" = "blackout"; "Charlie Don't Surf (armada)" = "armada"; "The Bog (bog_a)" = "bog_a";
    "Hunted (hunted)" = "hunted"; "Death From Above (ac130)" = "ac130"; "War Pig (bog_b)" = "bog_b";
    "Shock and Awe (airlift)" = "airlift"; "Aftermath (aftermath)" = "aftermath"; "Safehouse (village_assault)" = "village_assault";
    "All Ghillied Up (scoutsniper)" = "scoutsniper"; "One Shot, One Kill (sniperescape)" = "sniperescape";
    "Heat (village_defend)" = "village_defend"; "The Sins of the Father (ambush)" = "ambush"; "Ultimatum (icbm)" = "icbm";
    "All In (launchfacility_a)" = "launchfacility_a"; "No Fighting in the War Room (launchfacility_b)" = "launchfacility_b";
    "Game Over (jeepride)" = "jeepride"; "Mile High Club (airplane)" = "airplane"
}

$settings = @{ name = $env:USERNAME; mission = "cargoship"; squad = 2; bots = 0; skin = ""; botskin = ""; lastCode = "" }
if (Test-Path $SettingsFile) { try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } } catch {} }
function Save-Settings { try { $settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch {} }

# A windowed game whose saved position is off every screen (or with mouse input off) looks like it never started.
function Get-WindowFix {
    $fix = "+set in_mouse 1"
    $cfg = Get-ChildItem (Join-Path $GameDir "players\profiles\*\config.cfg") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cfg) { return $fix }
    $t = Get-Content $cfg.FullName -Raw
    $x = 3; $y = 22
    if ($t -match 'seta vid_xpos "(-?\d+)"') { $x = [int]$Matches[1] }
    if ($t -match 'seta vid_ypos "(-?\d+)"') { $y = [int]$Matches[1] }
    $onScreen = $false
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $s.WorkingArea
        if ($x -ge $b.Left -and $x -le $b.Right - 200 -and $y -ge $b.Top -and $y -le $b.Bottom - 200) { $onScreen = $true }
    }
    if (-not $onScreen) { $fix += " +set vid_xpos 3 +set vid_ypos 22" }
    return $fix
}

function Start-Game([string]$extra) {
    $name = $settings.name -replace '[|~"]', ''
    $skinArgs = ""
    if ($settings.skin) { $skinArgs += " +set coop_myskin $($settings.skin)" }
    if ($settings.botskin) { $skinArgs += " +set coop_botskin $($settings.botskin)" }
    $args = "+set fs_game mods/coop +set loc_warnings 0 +set coop_name `"$name`"$skinArgs $(Get-WindowFix) $extra"
    return Start-Process -FilePath (Join-Path $GameDir "iw3sp.exe") -WorkingDirectory $GameDir -ArgumentList $args -PassThru
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "CoD4 Coop Campaign"; $form.Size = New-Object System.Drawing.Size(520, 460); $form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$font = New-Object System.Drawing.Font("Segoe UI", 10); $form.Font = $font

$lblName = New-Object System.Windows.Forms.Label; $lblName.Text = "Your name"; $lblName.Location = "16,16"; $lblName.AutoSize = $true
$txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = "110,13"; $txtName.Width = 170; $txtName.Text = $settings.name; $txtName.MaxLength = 24
# skins in the installed skin pack (tools/skin): everyone in the session needs the same pack to see them
$skinFile = Join-Path $GameDir "Mods\coop\skins.txt"
function Read-SkinNames { if (Test-Path $skinFile) { return @(Get-Content $skinFile | Where-Object { $_.Trim() }) } return @() }
$script:SkinNames = @(Read-SkinNames)
function Fill-SkinBox($b, [string]$current) {
    $b.Items.Clear()
    [void]$b.Items.Add("Soldier (default)")
    foreach ($n in $script:SkinNames) { [void]$b.Items.Add(($n -replace '^coop_', '')) }
    $b.SelectedIndex = 0
    for ($i = 0; $i -lt $script:SkinNames.Count; $i++) { if ($script:SkinNames[$i] -eq $current) { $b.SelectedIndex = $i + 1 } }
}
function New-SkinBox([string]$current, [string]$loc, [int]$w) {
    $b = New-Object System.Windows.Forms.ComboBox; $b.DropDownStyle = "DropDownList"; $b.Location = $loc; $b.Width = $w
    Fill-SkinBox $b $current
    return $b
}
function Get-SkinChoice($b) { if ($b.SelectedIndex -le 0) { return "" } return $script:SkinNames[$b.SelectedIndex - 1] }
$lblSkin = New-Object System.Windows.Forms.Label; $lblSkin.Text = "Skin"; $lblSkin.Location = "292,16"; $lblSkin.AutoSize = $true
$cmbSkin = New-SkinBox $settings.skin "330,13" 160
$form.Controls.AddRange(@($lblName, $txtName, $lblSkin, $cmbSkin))

$tabs = New-Object System.Windows.Forms.TabControl; $tabs.Location = "12,48"; $tabs.Size = "484,360"
$tabHost = New-Object System.Windows.Forms.TabPage; $tabHost.Text = "Host a game"
$tabJoin = New-Object System.Windows.Forms.TabPage; $tabJoin.Text = "Join a friend"
$tabSkins = New-Object System.Windows.Forms.TabPage; $tabSkins.Text = "Skins"
$tabs.TabPages.AddRange(@($tabHost, $tabJoin, $tabSkins)); $form.Controls.Add($tabs)

# --- host tab
$lblMis = New-Object System.Windows.Forms.Label; $lblMis.Text = "Mission"; $lblMis.Location = "12,16"; $lblMis.AutoSize = $true
$cmbMis = New-Object System.Windows.Forms.ComboBox; $cmbMis.DropDownStyle = "DropDownList"; $cmbMis.Location = "100,13"; $cmbMis.Width = 360
foreach ($k in $Missions.Keys) { [void]$cmbMis.Items.Add($k); if ($Missions[$k] -eq $settings.mission) { $cmbMis.SelectedItem = $k } }
if (-not $cmbMis.SelectedItem) { $cmbMis.SelectedIndex = 1 }
$lblSq = New-Object System.Windows.Forms.Label; $lblSq.Text = "Wait for"; $lblSq.Location = "12,52"; $lblSq.AutoSize = $true
$numSq = New-Object System.Windows.Forms.NumericUpDown; $numSq.Location = "100,49"; $numSq.Width = 50; $numSq.Minimum = 1; $numSq.Maximum = 4; $numSq.Value = [int]$settings.squad
$lblSq2 = New-Object System.Windows.Forms.Label; $lblSq2.Text = "players before the mission starts"; $lblSq2.Location = "156,52"; $lblSq2.AutoSize = $true
$lblBots = New-Object System.Windows.Forms.Label; $lblBots.Text = "Bots"; $lblBots.Location = "12,86"; $lblBots.AutoSize = $true
$numBots = New-Object System.Windows.Forms.NumericUpDown; $numBots.Location = "100,83"; $numBots.Width = 50; $numBots.Minimum = 0; $numBots.Maximum = 3; $numBots.Value = [int]$settings.bots
$lblBots2 = New-Object System.Windows.Forms.Label; $lblBots2.Text = "AI squadmates, wearing"; $lblBots2.Location = "156,86"; $lblBots2.AutoSize = $true
$cmbBotSkin = New-SkinBox $settings.botskin "318,83" 142
$btnHost = New-Object System.Windows.Forms.Button; $btnHost.Text = "Start hosting"; $btnHost.Location = "100,116"; $btnHost.Size = "160,34"
$txtCodes = New-Object System.Windows.Forms.TextBox; $txtCodes.Multiline = $true; $txtCodes.ReadOnly = $true; $txtCodes.Location = "12,158"; $txtCodes.Size = "450,116"
$txtCodes.Font = New-Object System.Drawing.Font("Consolas", 10); $txtCodes.Text = "Your join code appears here once you start hosting."
$btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text = "Copy join code"; $btnCopy.Location = "12,282"; $btnCopy.Size = "160,32"; $btnCopy.Enabled = $false
$tabHost.Controls.AddRange(@($lblMis, $cmbMis, $lblSq, $numSq, $lblSq2, $lblBots, $numBots, $lblBots2, $cmbBotSkin, $btnHost, $txtCodes, $btnCopy))

# --- join tab
$lblCode = New-Object System.Windows.Forms.Label; $lblCode.Text = "Join code"; $lblCode.Location = "12,16"; $lblCode.AutoSize = $true
$txtCode = New-Object System.Windows.Forms.TextBox; $txtCode.Location = "100,13"; $txtCode.Width = 220; $txtCode.Text = $settings.lastCode
$btnJoin = New-Object System.Windows.Forms.Button; $btnJoin.Text = "Join"; $btnJoin.Location = "330,11"; $btnJoin.Size = "130,30"
$lblLan = New-Object System.Windows.Forms.Label; $lblLan.Text = "Games on your network"; $lblLan.Location = "12,56"; $lblLan.AutoSize = $true
$lstLan = New-Object System.Windows.Forms.ListBox; $lstLan.Location = "12,80"; $lstLan.Size = "450,150"
$btnFind = New-Object System.Windows.Forms.Button; $btnFind.Text = "Refresh"; $btnFind.Location = "12,236"; $btnFind.Size = "110,30"
$btnJoinLan = New-Object System.Windows.Forms.Button; $btnJoinLan.Text = "Join selected"; $btnJoinLan.Location = "130,236"; $btnJoinLan.Size = "130,30"
$lblJoinStatus = New-Object System.Windows.Forms.Label; $lblJoinStatus.Location = "12,276"; $lblJoinStatus.Size = "450,44"
$tabJoin.Controls.AddRange(@($lblCode, $txtCode, $btnJoin, $lblLan, $lstLan, $btnFind, $btnJoinLan, $lblJoinStatus))

$script:hostingProc = $null
$script:mainCode = ""
$script:lanGames = @()

$btnHost.Add_Click({
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }
    $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.squad = [int]$numSq.Value; $settings.bots = [int]$numBots.Value
    $settings.skin = Get-SkinChoice $cmbSkin; $settings.botskin = Get-SkinChoice $cmbBotSkin; Save-Settings
    $btnHost.Enabled = $false; $txtCodes.Text = "Opening the game port on your router..."; $form.Refresh()
    $addr = Get-LocalAddresses
    $lines = @()
    $public = $null
    if ($addr.lan) { $public = Open-RouterPort $addr.lan }
    if ($public) {
        $script:mainCode = Encode-JoinCode $public $Port
        $lines += "Internet join code:  $($script:mainCode)"
        $lines += "  (send this to your friends; your router opened UDP $Port)"
    }
    if ($addr.vpn) {
        $c = Encode-JoinCode $addr.vpn $Port; if (-not $script:mainCode) { $script:mainCode = $c }
        $lines += "VPN ($($addr.vpnName)) code:  $c"
    }
    if ($addr.lan) {
        $c = Encode-JoinCode $addr.lan $Port; if (-not $script:mainCode) { $script:mainCode = $c }
        $lines += "Same-network code:  $c   (or friends just pick you under 'Games on your network')"
    }
    if (-not $public) {
        $lines += ""
        $lines += "Your router did not open the port automatically (UPnP off or unsupported)."
        $lines += "Internet play then needs a VPN like Tailscale, or a manual UDP $Port forward."
    }
    $txtCodes.Text = ($lines -join "`r`n")
    $btnCopy.Enabled = [bool]$script:mainCode
    $botArg = ""; if ($settings.bots -gt 0) { $botArg = "+set coop_bot $($settings.bots)" }
    $script:hostingProc = Start-Game "+set coop_host 1 +set coop_wait $($settings.squad) $botArg +set coop_startmap $($settings.mission)"
})

$btnCopy.Add_Click({ if ($script:mainCode) { [System.Windows.Forms.Clipboard]::SetText($script:mainCode); $btnCopy.Text = "Copied!" } })

function Join-Address([string]$ip, [int]$port) {
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }
    $settings.skin = Get-SkinChoice $cmbSkin; Save-Settings
    [void](Start-Game "+set coop_connect $($ip):$port")
    $form.Close()
}

$btnJoin.Add_Click({
    try {
        $d = Decode-JoinCode $txtCode.Text
        if (-not $d) { $lblJoinStatus.Text = "That does not look like a join code (10 letters/digits, like K7F2Q-9QXAM)."; return }
        $lblJoinStatus.Text = "Looking for the host..."; $form.Refresh()
        $r = Probe-Host $d.ip $d.port
        if (-not $r) { $lblJoinStatus.Text = "No answer from that host. Is their game running, and is the code right?"; return }
        $settings.lastCode = $txtCode.Text.Trim()
        $lblJoinStatus.Text = "Joining $($r.host) ($($r.map), $($r.players) players)..."; $form.Refresh()
        Join-Address $d.ip $d.port
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

$btnFind.Add_Click({
    try {
        $lstLan.Items.Clear(); [void]$lstLan.Items.Add("Searching..."); $form.Refresh()
        $script:lanGames = @(Find-LanGames)
        $lstLan.Items.Clear()
        if (-not $script:lanGames.Count) { [void]$lstLan.Items.Add("No games found on this network.") }
        foreach ($g in $script:lanGames) { [void]$lstLan.Items.Add("$($g.host)  -  $($g.map)  -  $($g.players) players  ($($g.ip))") }
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

$btnJoinLan.Add_Click({
    try {
        $i = $lstLan.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:lanGames.Count) { $lblJoinStatus.Text = "Pick a game from the list first."; return }
        $g = $script:lanGames[$i]; Join-Address $g.ip $g.port
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

# --- skins tab: add any humanoid model (rigged or not), preview, remove. Runs the skin tools (Python) ---
$SkinTool = Join-Path $GameDir "Mods\coop\skintool\addskin.py"
$PreviewDir = Join-Path $GameDir "coop_skins\work\previews"
$lstSkins = New-Object System.Windows.Forms.ListBox; $lstSkins.Location = "12,12"; $lstSkins.Size = "150,200"
$picSkin = New-Object System.Windows.Forms.PictureBox; $picSkin.Location = "172,12"; $picSkin.Size = "290,200"; $picSkin.SizeMode = "Zoom"; $picSkin.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48)
$btnAddSkin = New-Object System.Windows.Forms.Button; $btnAddSkin.Text = "Add character..."; $btnAddSkin.Location = "12,218"; $btnAddSkin.Size = "150,30"
$btnRemoveSkin = New-Object System.Windows.Forms.Button; $btnRemoveSkin.Text = "Remove"; $btnRemoveSkin.Location = "12,252"; $btnRemoveSkin.Size = "150,28"
$chkFlip = New-Object System.Windows.Forms.CheckBox; $chkFlip.Text = "faces away (auto-rig)"; $chkFlip.Location = "172,220"; $chkFlip.AutoSize = $true
$txtSkinLog = New-Object System.Windows.Forms.TextBox; $txtSkinLog.Multiline = $true; $txtSkinLog.ReadOnly = $true; $txtSkinLog.ScrollBars = "Vertical"; $txtSkinLog.Location = "172,244"; $txtSkinLog.Size = "290,80"; $txtSkinLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSkinLog.Text = "Any humanoid model: GLB, glTF, DAE, OBJ (FBX needs Blender). Rigged or not: models without a skeleton are rigged automatically (stand in a T- or A-pose). Friends need the same skins to see them."
$tabSkins.Controls.AddRange(@($lstSkins, $picSkin, $btnAddSkin, $btnRemoveSkin, $chkFlip, $txtSkinLog))
function Refresh-Skins {
    $script:SkinNames = @(Read-SkinNames)
    $lstSkins.Items.Clear()
    foreach ($n in $script:SkinNames) { [void]$lstSkins.Items.Add(($n -replace '^coop_', '')) }
    Fill-SkinBox $cmbSkin $settings.skin
    Fill-SkinBox $cmbBotSkin $settings.botskin
}
function Find-Python {
    foreach ($c in @("py", "python")) { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { return $g.Source } }
    return $null
}
$lstSkins.Add_SelectedIndexChanged({
    $i = $lstSkins.SelectedIndex; if ($i -lt 0) { return }
    $png = Join-Path $PreviewDir ($script:SkinNames[$i] + ".png")
    if ($picSkin.Image) { $picSkin.Image.Dispose(); $picSkin.Image = $null }
    if (Test-Path $png) { $bytes = [IO.File]::ReadAllBytes($png); $picSkin.Image = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes))) }
})
$script:skinProc = $null; $script:skinOut = $null
function Start-SkinTool([string[]]$toolArgs) {
    $py = Find-Python
    if (-not $py) { $txtSkinLog.Text = "Python 3 is needed for skins (python.org), with: pip install numpy pillow"; return }
    if (-not (Test-Path $SkinTool)) { $txtSkinLog.Text = "Skin tools not installed (run tools/build.py)."; return }
    $script:skinOut = [IO.Path]::GetTempFileName()
    $pre = @(); if ((Split-Path $py -Leaf) -eq "py.exe") { $pre = @("-3") }
    $quoted = ($pre + @("`"$SkinTool`"") + ($toolArgs | ForEach-Object { "`"$_`"" })) -join " "
    $env:COOP_GAMEDIR = $GameDir
    $script:skinProc = Start-Process -FilePath $py -ArgumentList $quoted -NoNewWindow -PassThru -RedirectStandardOutput $script:skinOut -RedirectStandardError "$($script:skinOut).err"
    $btnAddSkin.Enabled = $false; $btnRemoveSkin.Enabled = $false
    $txtSkinLog.Text = "Working... (the first time also sets up the tools, about a minute)"
}
$skinTimer = New-Object System.Windows.Forms.Timer; $skinTimer.Interval = 400
$skinTimer.Add_Tick({
    if (-not $script:skinProc) { return }
    $log = ""
    try { $log = [IO.File]::ReadAllText($script:skinOut) } catch {}
    $lines = @($log -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^(Loaded|Building|Writing|Created|Reading|Processing|Unloaded|Finished)' })
    if ($lines.Count) { $txtSkinLog.Text = ($lines | Select-Object -Last 6) -join "`r`n" }
    if ($script:skinProc.HasExited) {
        $err = ""; try { $err = [IO.File]::ReadAllText("$($script:skinOut).err") } catch {}
        if ($log -notmatch "(?m)^OK" -and $err) { $txtSkinLog.Text += "`r`n" + (($err -split "`r?`n" | Select-Object -Last 4) -join "`r`n") }
        $script:skinProc = $null
        $btnAddSkin.Enabled = $true; $btnRemoveSkin.Enabled = $true
        $sel = $null; if ($log -match "(?m)^OK (coop_\w+)") { $sel = $Matches[1] }
        Refresh-Skins
        if ($sel) { $k = [array]::IndexOf($script:SkinNames, $sel); if ($k -ge 0) { $lstSkins.SelectedIndex = $k } }
    }
})
$skinTimer.Start()
$btnAddSkin.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "3D characters|*.glb;*.gltf;*.dae;*.obj;*.fbx|All files|*.*"
    if ($dlg.ShowDialog() -ne "OK") { return }
    $name = ([IO.Path]::GetFileNameWithoutExtension($dlg.FileName) -replace '[^A-Za-z0-9_]', '_').ToLower().Trim('_')
    if (-not $name) { $name = "skin" }
    $a = @("add", $dlg.FileName, $name); if ($chkFlip.Checked) { $a += "--flip" }
    Start-SkinTool $a
})
$btnRemoveSkin.Add_Click({
    $i = $lstSkins.SelectedIndex; if ($i -lt 0) { $txtSkinLog.Text = "Pick a skin in the list first."; return }
    Start-SkinTool @("remove", $script:SkinNames[$i])
})
Refresh-Skins

$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabJoin -and $lstLan.Items.Count -eq 0) { $btnFind.PerformClick() } })

# keep the router port open while hosting; close it when the game exits or the launcher closes
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ if ($script:hostingProc -and $script:hostingProc.HasExited) { Close-RouterPort; $script:hostingProc = $null; $btnHost.Enabled = $true; $txtCodes.Text = "The game closed. Hosting stopped." } })
$timer.Start()
$form.Add_FormClosing({ if ($script:hostingProc) { Close-RouterPort } })

$form.Add_Shown({
    if (-not (Test-CoopInstalled)) {
        $btnHost.Enabled = $false; $btnJoin.Enabled = $false; $btnJoinLan.Enabled = $false
        $txtCodes.Text = "First start: adding the coop hooks to the game scripts from your own game files (under a minute)..."
        $form.Refresh()
        try { Install-CoopScripts; $txtCodes.Text = "Ready. Pick a mission and start hosting, or join a friend." }
        catch { $txtCodes.Text = "Setup failed: $($_.Exception.Message)`r`nIs this the CoD4 1.0 game folder (iw3sp.exe, zone\english)?" }
        $btnHost.Enabled = $true; $btnJoin.Enabled = $true; $btnJoinLan.Enabled = $true
    }
})

# test hook: render a tab to a PNG without showing the window (COOP_LAUNCHER_SNAPSHOT=<png>[|tab index])
if ($env:COOP_LAUNCHER_SNAPSHOT) {
    $parts = $env:COOP_LAUNCHER_SNAPSHOT -split '\|'
    if ($parts.Count -gt 1) { $tabs.SelectedIndex = [int]$parts[1] }
    if ($lstSkins.Items.Count) { $lstSkins.SelectedIndex = 0 }
    $mk = [System.Windows.Forms.Control].GetMethod("CreateHandle", [Reflection.BindingFlags]"NonPublic,Instance")
    function Make-Handles($c) { $mk.Invoke($c, $null); foreach ($x in $c.Controls) { Make-Handles $x } }
    Make-Handles $form
    $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    $bmp.Save($parts[0]); exit
}
[void]$form.ShowDialog()
