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

function Send-Probe([System.Net.Sockets.UdpClient]$u, [System.Net.IPEndPoint]$ep) {
    # 12-byte coop header: magic 'C4' (0x3443 LE), ver 1, type 6 (DISCOVER), rest zero
    $pkt = [byte[]](0x43, 0x34, 1, 6, 0, 0, 0, 0, 0, 0, 0, 0)
    [void]$u.Send($pkt, $pkt.Length, $ep)
}

function Read-Infos([System.Net.Sockets.UdpClient]$u, [int]$ms) {
    $found = @{}
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        if ($u.Available -gt 0) {
            $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
            $data = $u.Receive([ref]$from)
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
    $u = New-Object System.Net.Sockets.UdpClient 0
    $u.EnableBroadcast = $true
    try {
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Broadcast, $Port))
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port))
        return Read-Infos $u 1200
    } finally { $u.Close() }
}

function Probe-Host([string]$ip, [int]$port) {
    $u = New-Object System.Net.Sockets.UdpClient 0
    try {
        $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)
        for ($i = 0; $i -lt 3; $i++) { Send-Probe $u $ep; $r = Read-Infos $u 700; if ($r.Count) { return $r[0] } }
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

$settings = @{ name = $env:USERNAME; mission = "cargoship"; squad = 2; bots = 0; lastCode = "" }
if (Test-Path $SettingsFile) { try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } } catch {} }
function Save-Settings { try { $settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch {} }

function Start-Game([string]$extra) {
    $name = $settings.name -replace '[|~"]', ''
    $args = "+set fs_game mods/coop +set loc_warnings 0 +set coop_name `"$name`" $extra"
    return Start-Process -FilePath (Join-Path $GameDir "iw3sp.exe") -WorkingDirectory $GameDir -ArgumentList $args -PassThru
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "CoD4 Coop Campaign"; $form.Size = New-Object System.Drawing.Size(520, 460); $form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$font = New-Object System.Drawing.Font("Segoe UI", 10); $form.Font = $font

$lblName = New-Object System.Windows.Forms.Label; $lblName.Text = "Your name"; $lblName.Location = "16,16"; $lblName.AutoSize = $true
$txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = "110,13"; $txtName.Width = 380; $txtName.Text = $settings.name; $txtName.MaxLength = 24
$form.Controls.AddRange(@($lblName, $txtName))

$tabs = New-Object System.Windows.Forms.TabControl; $tabs.Location = "12,48"; $tabs.Size = "484,360"
$tabHost = New-Object System.Windows.Forms.TabPage; $tabHost.Text = "Host a game"
$tabJoin = New-Object System.Windows.Forms.TabPage; $tabJoin.Text = "Join a friend"
$tabs.TabPages.AddRange(@($tabHost, $tabJoin)); $form.Controls.Add($tabs)

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
$lblBots2 = New-Object System.Windows.Forms.Label; $lblBots2.Text = "AI squadmates (they count toward the squad)"; $lblBots2.Location = "156,86"; $lblBots2.AutoSize = $true
$btnHost = New-Object System.Windows.Forms.Button; $btnHost.Text = "Start hosting"; $btnHost.Location = "100,116"; $btnHost.Size = "160,34"
$txtCodes = New-Object System.Windows.Forms.TextBox; $txtCodes.Multiline = $true; $txtCodes.ReadOnly = $true; $txtCodes.Location = "12,158"; $txtCodes.Size = "450,116"
$txtCodes.Font = New-Object System.Drawing.Font("Consolas", 10); $txtCodes.Text = "Your join code appears here once you start hosting."
$btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text = "Copy join code"; $btnCopy.Location = "12,282"; $btnCopy.Size = "160,32"; $btnCopy.Enabled = $false
$tabHost.Controls.AddRange(@($lblMis, $cmbMis, $lblSq, $numSq, $lblSq2, $lblBots, $numBots, $lblBots2, $btnHost, $txtCodes, $btnCopy))

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
    $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.squad = [int]$numSq.Value; $settings.bots = [int]$numBots.Value; Save-Settings
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
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }; Save-Settings
    [void](Start-Game "+set coop_connect $($ip):$port")
    $form.Close()
}

$btnJoin.Add_Click({
    $d = Decode-JoinCode $txtCode.Text
    if (-not $d) { $lblJoinStatus.Text = "That does not look like a join code (10 letters/digits, like K7F2Q-9QXAM)."; return }
    $lblJoinStatus.Text = "Looking for the host..."; $form.Refresh()
    $r = Probe-Host $d.ip $d.port
    if (-not $r) { $lblJoinStatus.Text = "No answer from that host. Is their game running, and is the code right?"; return }
    $settings.lastCode = $txtCode.Text.Trim()
    $lblJoinStatus.Text = "Joining $($r.host) ($($r.map), $($r.players) players)..."; $form.Refresh()
    Join-Address $d.ip $d.port
})

$btnFind.Add_Click({
    $lstLan.Items.Clear(); [void]$lstLan.Items.Add("Searching..."); $form.Refresh()
    $script:lanGames = @(Find-LanGames)
    $lstLan.Items.Clear()
    if (-not $script:lanGames.Count) { [void]$lstLan.Items.Add("No games found on this network.") }
    foreach ($g in $script:lanGames) { [void]$lstLan.Items.Add("$($g.host)  -  $($g.map)  -  $($g.players) players  ($($g.ip))") }
})

$btnJoinLan.Add_Click({
    $i = $lstLan.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:lanGames.Count) { $lblJoinStatus.Text = "Pick a game from the list first."; return }
    $g = $script:lanGames[$i]; Join-Address $g.ip $g.port
})

$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabJoin -and $lstLan.Items.Count -eq 0) { $btnFind.PerformClick() } })

# keep the router port open while hosting; close it when the game exits or the launcher closes
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ if ($script:hostingProc -and $script:hostingProc.HasExited) { Close-RouterPort; $script:hostingProc = $null; $btnHost.Enabled = $true; $txtCodes.Text = "The game closed. Hosting stopped." } })
$timer.Start()
$form.Add_FormClosing({ if ($script:hostingProc) { Close-RouterPort } })

[void]$form.ShowDialog()
