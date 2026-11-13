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

# Launcher lobby, on the game port before the game runs (types: 6 discover, 7 info, 8 join, 9 state, 10 start)
function Send-Packet([System.Net.Sockets.UdpClient]$u, [System.Net.IPEndPoint]$ep, [int]$type, [string]$payload) {
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $pkt = New-Object byte[] (12 + $body.Length)
    $pkt[0] = 0x43; $pkt[1] = 0x34; $pkt[2] = 1; $pkt[3] = $type
    [Array]::Copy($body, 0, $pkt, 12, $body.Length)
    try { [void]$u.Send($pkt, $pkt.Length, $ep) } catch {}
}
function Receive-Packets([System.Net.Sockets.UdpClient]$u) {
    $out = @()
    while ($u.Available -gt 0) {
        $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
        try { $data = $u.Receive([ref]$from) } catch { continue }
        if ($data.Length -lt 12 -or $data[0] -ne 0x43 -or $data[1] -ne 0x34) { continue }
        $out += [pscustomobject]@{ type = [int]$data[3]; from = $from; text = [System.Text.Encoding]::UTF8.GetString($data, 12, $data.Length - 12) }
    }
    return $out
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

# Tailscale peers that are online (the tailnet is not reached by a LAN broadcast)
function Get-TailscalePeers {
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    $exe = if ($ts) { $ts.Source } elseif (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe") { "$env:ProgramFiles\Tailscale\tailscale.exe" } else { $null }
    if (-not $exe) { return @() }
    try {
        $st = (& $exe status --json 2>$null) -join "`n" | ConvertFrom-Json
        $ips = @()
        if ($st.Peer) { foreach ($pp in $st.Peer.PSObject.Properties) { $peer = $pp.Value
            if ($peer.Online) { $ip = @($peer.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0]; if ($ip) { $ips += $ip } } } }
        return $ips
    } catch { return @() }
}

function Find-LanGames {
    $u = New-ProbeSocket
    $u.EnableBroadcast = $true
    try {
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Broadcast, $Port))
        Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port))
        foreach ($ip in (Get-TailscalePeers)) { Send-Probe $u (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $Port)) }
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
    if ($env:COOP_NO_UPNP) { return $null }   # tests
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
using System; using System.IO; using System.IO.Compression; using System.Text; using System.Linq;
using System.Text.RegularExpressions; using System.Collections.Generic; using System.Collections.Concurrent;
using System.Threading; using System.Threading.Tasks;
public static class CoopFF {
    static readonly Encoding L1 = Encoding.GetEncoding(28591);
    static readonly ConcurrentDictionary<string, Dictionary<string, string>> Cache = new ConcurrentDictionary<string, Dictionary<string, string>>();
    // background install state, polled by the launcher window
    public static volatile string Status = "";
    public static volatile string Error = null;
    public static volatile bool Done = false;
    static int zonesDone, zonesTotal;
    static readonly Regex RawUnused = new Regex("\xff\xff\xff\xff(.{4})\xff\xff\xff\xff([a-zA-Z0-9_/\\\\.\\-]{3,120}\\.(?:gsc|csv|cfg|txt|menu|str|vision|atr|gdt|shock|arena|sun))\x00", RegexOptions.Singleline);
    // Stream-decompress a fastfile and pull out just the named rawfiles, stopping as soon as all are found.
    // A rawfile in the zone is: FF FF FF FF <u32 length> FF FF FF FF <name> 00 <length bytes>.
    static Dictionary<string, string> Rawfiles(string ff, string[] names) {
        string key = ff + "|" + string.Join(",", names);
        Dictionary<string, string> d;
        if (Cache.TryGetValue(key, out d)) return d;
        d = new Dictionary<string, string>();
        var pats = names.Select(n => L1.GetBytes(n + "\0")).ToArray();
        var want = new HashSet<int>(Enumerable.Range(0, names.Length));
        using (var fs = File.OpenRead(ff)) {
            var head = new byte[14];
            fs.Read(head, 0, 14);
            if (L1.GetString(head, 0, 8) != "IWffu100") throw new Exception("not an IW3 fastfile: " + ff);
            using (var ds = new DeflateStream(fs, CompressionMode.Decompress)) {
                const int CH = 1 << 22, KEEP = 512;
                var buf = new byte[CH + KEEP];
                int have = 0;                        // bytes valid in buf
                MemoryStream cap = null; int capLeft = 0; int capName = -1;
                while (want.Count > 0 || capLeft > 0) {
                    int n = ds.Read(buf, have, CH);
                    if (n <= 0) break;
                    int start = Math.Max(0, have - KEEP);
                    have += n;
                    int scanFrom = start;
                    if (capLeft > 0) {               // finishing a rawfile that crossed the chunk boundary
                        int take = Math.Min(capLeft, n);
                        cap.Write(buf, have - n, take); capLeft -= take;
                        if (capLeft == 0) { d[names[capName]] = L1.GetString(cap.ToArray()); want.Remove(capName); }
                        scanFrom = have - n + take;
                    }
                    for (int w = 0; w < names.Length && capLeft == 0; w++) {
                        if (!want.Contains(w)) continue;
                        byte[] pt = pats[w];
                        for (int q = Math.Max(scanFrom, 12); q + pt.Length <= have; q++) {
                            if (buf[q] != pt[0]) continue;
                            int m = 1; while (m < pt.Length && buf[q + m] == pt[m]) m++;
                            if (m < pt.Length) continue;
                            if (buf[q - 1] != 0xff || buf[q - 4] != 0xff || buf[q - 9] != 0xff || buf[q - 12] != 0xff) continue;
                            int len = buf[q - 8] | (buf[q - 7] << 8) | (buf[q - 6] << 16) | (buf[q - 5] << 24);
                            if (len <= 0 || len > 8000000) continue;
                            int dataAt = q + pt.Length;
                            int inBuf = Math.Min(len, have - dataAt);
                            cap = new MemoryStream(len); cap.Write(buf, dataAt, inBuf);
                            capLeft = len - inBuf; capName = w;
                            if (capLeft == 0) { d[names[w]] = L1.GetString(cap.ToArray()); want.Remove(w); }
                            break;
                        }
                    }
                    // keep the tail so names split across chunks are still found
                    int keep = Math.Min(KEEP, have);
                    Buffer.BlockCopy(buf, have - keep, buf, 0, keep);
                    have = keep;
                }
            }
        }
        Cache[key] = d;
        return d;
    }
    // Patch everything in the background: the fastfiles (one zlib stream each) are decompressed in parallel,
    // a few at a time to bound memory, then the anchored edits are applied and the scripts written.
    public static void StartInstall(string zoneDir, string modDir, string jsonPath, string markerHash) {
        Done = false; Error = null; Status = "starting";
        var th = new Thread(() => {
            try {
                var js = new System.Web.Script.Serialization.JavaScriptSerializer();
                js.MaxJsonLength = int.MaxValue;
                var root = (Dictionary<string, object>)js.DeserializeObject(File.ReadAllText(jsonPath));
                var patches = ((object[])root["patches"]).Cast<Dictionary<string, object>>().ToList();
                var zones = patches.SelectMany(pt => ((object[])pt["zones"]).Cast<string>()).Distinct().ToList();
                Needed = zones.ToDictionary(z => z, z => patches.Where(pt => ((object[])pt["zones"]).Cast<string>().Contains(z))
                                                               .Select(pt => (string)pt["file"]).ToArray());
                zonesTotal = zones.Count; zonesDone = 0;
                Status = "reading your game files: 0 of " + zonesTotal;
                Parallel.ForEach(zones, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Math.Min(4, Environment.ProcessorCount)) }, zn => {
                    Rawfiles(Path.Combine(zoneDir, zn + ".ff"), Needed[zn]);
                    int n = Interlocked.Increment(ref zonesDone);
                    Status = "reading your game files: " + n + " of " + zonesTotal;
                });
                Status = "adding the coop hooks";
                foreach (var pt in patches) {
                    string file = (string)pt["file"];
                    string t = Find(zoneDir, file, ((object[])pt["zones"]).Cast<string>().ToArray());
                    foreach (Dictionary<string, object> ed in (object[])pt["edits"])
                        t = Apply(file, t, (string)ed["anchor"], (string)ed["mode"], (string)ed["payload"]);
                    Write(Path.Combine(modDir, file.Replace('/', '\\')), t);
                }
                File.WriteAllText(Path.Combine(modDir, ".patched"), markerHash + "\r\n", Encoding.ASCII);
                Cache.Clear();
                Status = "done";
            } catch (Exception e) { Error = e.Message; }
            Done = true;
        });
        th.IsBackground = true;
        th.Start();
    }
    public static string Find(string zoneDir, string name, string[] zones) {
        foreach (string zn in zones) {
            string t;
            if (Needed.ContainsKey(zn) && Rawfiles(Path.Combine(zoneDir, zn + ".ff"), Needed[zn]).TryGetValue(name, out t)) return t;
        }
        throw new Exception(name + " not found in your game files (" + string.Join(", ", zones) + ")");
    }
    static Dictionary<string, string[]> Needed = new Dictionary<string, string[]>();
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
function Start-CoopInstall {
    $json = Join-Path $GameDir "Mods\coop\coop_patches.json"
    if (-not ("CoopFF" -as [type])) { Add-Type -TypeDefinition $CoopFFCode -ReferencedAssemblies System.Web.Extensions, System.Core }
    [CoopFF]::StartInstall((Join-Path $GameDir "zone\english"), (Join-Path $GameDir "Mods\coop"), $json, (Get-FileHash $json -Algorithm SHA256).Hash)
}
function Install-CoopScripts {
    Start-CoopInstall
    while (-not [CoopFF]::Done) { Start-Sleep -Milliseconds 100 }
    if ([CoopFF]::Error) { throw [CoopFF]::Error }
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
    if ($env:COOP_NO_GAME) { Add-Content -Path $env:COOP_NO_GAME -Value "GAME $extra"; return $null }   # tests
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

# --- host tab: open a lobby, share a code, friends join in the launcher, then launch everyone together
$lblMis = New-Object System.Windows.Forms.Label; $lblMis.Text = "Mission"; $lblMis.Location = "12,16"; $lblMis.AutoSize = $true
$cmbMis = New-Object System.Windows.Forms.ComboBox; $cmbMis.DropDownStyle = "DropDownList"; $cmbMis.Location = "100,13"; $cmbMis.Width = 360
foreach ($k in $Missions.Keys) { [void]$cmbMis.Items.Add($k); if ($Missions[$k] -eq $settings.mission) { $cmbMis.SelectedItem = $k } }
if (-not $cmbMis.SelectedItem) { $cmbMis.SelectedIndex = 1 }
$lblBots = New-Object System.Windows.Forms.Label; $lblBots.Text = "Bots"; $lblBots.Location = "12,50"; $lblBots.AutoSize = $true
$numBots = New-Object System.Windows.Forms.NumericUpDown; $numBots.Location = "100,47"; $numBots.Width = 50; $numBots.Minimum = 0; $numBots.Maximum = 3; $numBots.Value = [int]$settings.bots
$lblBots2 = New-Object System.Windows.Forms.Label; $lblBots2.Text = "AI squadmates, wearing"; $lblBots2.Location = "156,50"; $lblBots2.AutoSize = $true
$cmbBotSkin = New-SkinBox $settings.botskin "318,47" 142
$btnHost = New-Object System.Windows.Forms.Button; $btnHost.Text = "Open lobby"; $btnHost.Location = "100,80"; $btnHost.Size = "150,32"
$btnLaunch = New-Object System.Windows.Forms.Button; $btnLaunch.Text = "Launch game"; $btnLaunch.Location = "260,80"; $btnLaunch.Size = "150,32"; $btnLaunch.Enabled = $false
$txtCodes = New-Object System.Windows.Forms.TextBox; $txtCodes.Multiline = $true; $txtCodes.ReadOnly = $true; $txtCodes.Location = "12,120"; $txtCodes.Size = "450,84"
$txtCodes.Font = New-Object System.Drawing.Font("Consolas", 9); $txtCodes.Text = "Open a lobby: your join codes appear here, friends join, then you launch everyone together."
$btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text = "Copy join code"; $btnCopy.Location = "12,208"; $btnCopy.Size = "220,28"; $btnCopy.Enabled = $false
$btnCopy2 = New-Object System.Windows.Forms.Button; $btnCopy2.Text = "Copy other code"; $btnCopy2.Location = "242,208"; $btnCopy2.Size = "220,28"; $btnCopy2.Enabled = $false
$lblLobby = New-Object System.Windows.Forms.Label; $lblLobby.Text = "In the lobby"; $lblLobby.Location = "12,242"; $lblLobby.AutoSize = $true
$lstLobby = New-Object System.Windows.Forms.ListBox; $lstLobby.Location = "12,260"; $lstLobby.Size = "450,64"
$tabHost.Controls.AddRange(@($lblMis, $cmbMis, $lblBots, $numBots, $lblBots2, $cmbBotSkin, $btnHost, $btnLaunch, $txtCodes, $btnCopy, $btnCopy2, $lblLobby, $lstLobby))

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

$script:lobby = $null        # host lobby: socket + members (key "ip:port" -> name, endpoint, last seen)
$script:codes = @()           # @{ label; code } in order of preference
$btnHost.Add_Click({
    try {
        if ($script:lobby) { Close-Lobby; return }
        $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }
        $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.bots = [int]$numBots.Value
        $settings.skin = Get-SkinChoice $cmbSkin; $settings.botskin = Get-SkinChoice $cmbBotSkin; Save-Settings
        $btnHost.Enabled = $false; $txtCodes.Text = "Opening the game port on your router..."; $form.Refresh()
        $addr = Get-LocalAddresses
        $public = $null
        if ($addr.lan) { $public = Open-RouterPort $addr.lan }
        # Tailscale/VPN first: it works through any router; then the internet code (UPnP), then same network
        $script:codes = @()
        if ($addr.vpn) { $script:codes += @{ label = "$($addr.vpnName)"; code = (Encode-JoinCode $addr.vpn $Port) } }
        if ($public) { $script:codes += @{ label = "internet"; code = (Encode-JoinCode $public $Port) } }
        if ($addr.lan) { $script:codes += @{ label = "same network"; code = (Encode-JoinCode $addr.lan $Port) } }
        $lines = @()
        foreach ($c in $script:codes) { $lines += ("{0,-14} {1}" -f ($c.label + ":"), $c.code) }
        if (-not $public) { $lines += "(router did not open the port: use the $($addr.vpnName) code, or forward UDP $Port)" }
        if (-not $addr.vpn) { $lines += "(no Tailscale/ZeroTier found: friends outside your network need the internet code)" }
        $txtCodes.Text = ($lines -join "`r`n")
        $btnCopy.Enabled = $script:codes.Count -gt 0
        if ($script:codes.Count) { $btnCopy.Text = "Copy $($script:codes[0].label) code" }
        $btnCopy2.Enabled = $script:codes.Count -gt 1
        if ($script:codes.Count -gt 1) { $btnCopy2.Text = "Copy $($script:codes[1].label) code" }
        $u = New-Object System.Net.Sockets.UdpClient $Port
        try { [void]$u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}
        $script:lobby = @{ u = $u; members = [ordered]@{} }
        $btnHost.Text = "Close lobby"; $btnHost.Enabled = $true; $btnLaunch.Enabled = $true
        Update-LobbyList
    } catch {
        $txtCodes.Text = "Could not open the lobby: $($_.Exception.Message)`r`n(Is the game already running on this PC?)"
        $btnHost.Enabled = $true
    }
})
function Update-LobbyList {
    $lstLobby.Items.Clear()
    [void]$lstLobby.Items.Add("$($settings.name) (you, host)")
    for ($b = 1; $b -le [int]$numBots.Value; $b++) { [void]$lstLobby.Items.Add("Bot $b") }
    if ($script:lobby) { foreach ($m in $script:lobby.members.Values) { [void]$lstLobby.Items.Add($m.name) } }
}
function Close-Lobby {
    if ($script:lobby) { try { $script:lobby.u.Close() } catch {} }
    $script:lobby = $null
    Close-RouterPort
    $btnHost.Text = "Open lobby"; $btnLaunch.Enabled = $false; $btnCopy.Enabled = $false; $btnCopy2.Enabled = $false
    $lstLobby.Items.Clear(); $txtCodes.Text = "Lobby closed."
}
$lobbyTimer = New-Object System.Windows.Forms.Timer; $lobbyTimer.Interval = 150
$lobbyTimer.Add_Tick({
    try {
        if ($script:lobby) {
            $L = $script:lobby
            $now = Get-Date
            foreach ($pk in (Receive-Packets $L.u)) {
                $key = $pk.from.ToString()
                if ($pk.type -eq 6) {
                    Send-Packet $L.u $pk.from 7 ("{0}|lobby|{1}|4" -f $settings.name, (1 + $L.members.Count + [int]$numBots.Value))
                } elseif ($pk.type -eq 8) {
                    $nm = ($pk.text -replace '[|,~"]', '').Trim(); if (-not $nm) { $nm = "Player" }
                    $new = -not $L.members.Contains($key)
                    $L.members[$key] = @{ name = $nm; ep = $pk.from; seen = $now }
                    $nb = [int]$numBots.Value
                    $names = @($settings.name) + @(if ($nb -gt 0) { 1..$nb | ForEach-Object { "Bot $_" } }) + @($L.members.Values | ForEach-Object { $_.name })
                    Send-Packet $L.u $pk.from 9 ("{0}|{1}" -f $cmbMis.SelectedItem, ($names -join ","))
                    if ($new) { Update-LobbyList }
                }
            }
            $gone = @($L.members.Keys | Where-Object { ($now - $L.members[$_].seen).TotalSeconds -gt 6 })
            foreach ($k in $gone) { $L.members.Remove($k) }
            if ($gone.Count) { Update-LobbyList }
        }
        if ($script:joining) { Step-JoinLobby }
    } catch {}
})
$lobbyTimer.Start()
$numBots.Add_ValueChanged({ if ($script:lobby) { Update-LobbyList } })
$btnLaunch.Add_Click({
    if (-not $script:lobby) { return }
    $L = $script:lobby
    $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.bots = [int]$numBots.Value
    $settings.botskin = Get-SkinChoice $cmbBotSkin; Save-Settings
    # tell every friend in the lobby to start their game, then free the port for ours
    for ($r = 0; $r -lt 3; $r++) { foreach ($m in $L.members.Values) { Send-Packet $L.u $m.ep 10 "$Port" }; Start-Sleep -Milliseconds 60 }
    $wait = 1 + $L.members.Count + $settings.bots
    try { $L.u.Close() } catch {}
    $script:lobby = $null
    $btnLaunch.Enabled = $false; $btnHost.Enabled = $false; $btnHost.Text = "Open lobby"
    $txtCodes.Text = "Game starting for $wait players (you, $($settings.bots) bots, $($L.members.Count) friends).`r`nFriends can still join with the same code while you play."
    $botArg = ""; if ($settings.bots -gt 0) { $botArg = "+set coop_bot $($settings.bots)" }
    $script:hostingProc = Start-Game "+set coop_host 1 +set coop_wait $wait $botArg +set coop_startmap $($settings.mission)"
})

$btnCopy.Add_Click({ if ($script:codes.Count) { [System.Windows.Forms.Clipboard]::SetText($script:codes[0].code); $btnCopy.Text = "Copied!" } })
$btnCopy2.Add_Click({ if ($script:codes.Count -gt 1) { [System.Windows.Forms.Clipboard]::SetText($script:codes[1].code); $btnCopy2.Text = "Copied!" } })

# host still in the launcher lobby: wait there (the timer keeps checking in) until they launch; else join the game
$script:joining = $null
function Join-HostOrLobby([string]$ip, [int]$port, $info) {
    if ($info.map -ne "lobby") {
        $lblJoinStatus.Text = "Joining $($info.host) ($($info.map), $($info.players) players)..."; $form.Refresh()
        Join-Address $ip $port; return
    }
    if ($script:joining) { try { $script:joining.u.Close() } catch {} }
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }; Save-Settings
    $script:joining = @{ u = (New-ProbeSocket); ep = (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)); ip = $ip; port = $port
                         host = $info.host; lastSend = [datetime]::MinValue; lastHeard = (Get-Date) }
    $lblJoinStatus.Text = "In $($info.host)'s lobby. Waiting for them to launch the game..."
}
function Step-JoinLobby {
    $J = $script:joining
    $now = Get-Date
    if (($now - $J.lastSend).TotalMilliseconds -gt 1000) { Send-Packet $J.u $J.ep 8 $settings.name; $J.lastSend = $now }
    foreach ($pk in (Receive-Packets $J.u)) {
        if ($pk.type -eq 9) {
            $J.lastHeard = $now
            $f = $pk.text.Split('|')
            $lblJoinStatus.Text = "In $($J.host)'s lobby ($($f[0])): $($f[1] -replace ',', ', ').`r`nWaiting for $($J.host) to launch the game..."
        } elseif ($pk.type -eq 10) {
            try { $J.u.Close() } catch {}
            $script:joining = $null
            $lblJoinStatus.Text = "$($J.host) launched the game: starting yours..."; $form.Refresh()
            Start-Sleep -Milliseconds 1500   # let the host's game take the port before we connect
            Join-Address $J.ip $J.port
            return
        }
    }
    if (($now - $J.lastHeard).TotalSeconds -gt 10) {
        try { $J.u.Close() } catch {}
        $script:joining = $null
        $lblJoinStatus.Text = "Lost the lobby ($($J.host) closed it?). Try joining again."
    }
}

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
        $settings.lastCode = $txtCode.Text.Trim(); Save-Settings
        Join-HostOrLobby $d.ip $d.port $r
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

$btnFind.Add_Click({
    try {
        $lstLan.Items.Clear(); [void]$lstLan.Items.Add("Searching..."); $form.Refresh()
        $script:lanGames = @(Find-LanGames)
        $lstLan.Items.Clear()
        if (-not $script:lanGames.Count) { [void]$lstLan.Items.Add("No games found on this network.") }
        foreach ($g in $script:lanGames) {
            $where = if ($g.map -eq "lobby") { "in the lobby" } else { $g.map }
            $via = if ($g.ip -match '^100\.') { "Tailscale " } else { "" }
            [void]$lstLan.Items.Add("$($g.host)  -  $where  -  $($g.players) players  ($via$($g.ip))")
        }
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

$btnJoinLan.Add_Click({
    try {
        $i = $lstLan.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:lanGames.Count) { $lblJoinStatus.Text = "Pick a game from the list first."; return }
        $g = $script:lanGames[$i]; Join-HostOrLobby $g.ip $g.port $g
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
$form.Add_FormClosing({
    if ($script:lobby) { try { $script:lobby.u.Close() } catch {}; Close-RouterPort }
    elseif ($script:hostingProc) { Close-RouterPort }
    if ($script:joining) { try { $script:joining.u.Close() } catch {} }
})

# first-start setup runs in the background; the window stays responsive and shows the progress
$setupTimer = New-Object System.Windows.Forms.Timer; $setupTimer.Interval = 250
$setupTimer.Add_Tick({
    if (-not [CoopFF]::Done) { $txtCodes.Text = "First start: setting up the coop scripts from your own game files...`r`n" + [CoopFF]::Status; return }
    $setupTimer.Stop()
    if ([CoopFF]::Error) { $txtCodes.Text = "Setup failed: $([CoopFF]::Error)`r`nIs this the CoD4 1.0 game folder (iw3sp.exe, zone\english)?" }
    else { $txtCodes.Text = "Ready. Pick a mission and start hosting, or join a friend." }
    $btnHost.Enabled = $true; $btnJoin.Enabled = $true; $btnJoinLan.Enabled = $true
})
$form.Add_Shown({
    if (-not (Test-CoopInstalled)) {
        $btnHost.Enabled = $false; $btnJoin.Enabled = $false; $btnJoinLan.Enabled = $false
        try { Start-CoopInstall; $setupTimer.Start() }
        catch { $txtCodes.Text = "Setup failed: $($_.Exception.Message)"; $btnHost.Enabled = $true; $btnJoin.Enabled = $true; $btnJoinLan.Enabled = $true }
    }
})

# test hooks: drive the lobby headless (COOP_TEST_LOBBY=host|join:<code>, results to COOP_NO_GAME file)
if ($env:COOP_TEST_LOBBY) {
    $click = { param($b) $b.GetType().GetMethod("OnClick", [Reflection.BindingFlags]"NonPublic,Instance").Invoke($b, @([EventArgs]::Empty)) }
    $log = { param($t) Add-Content -Path $env:COOP_NO_GAME -Value $t }
    if ($env:COOP_TEST_LOBBY -eq "host") {
        & $click $btnHost
        & $log ("CODES " + ($txtCodes.Text -replace "`r`n", " / "))
        $end = (Get-Date).AddSeconds(40); $launched = $false
        while ((Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40
            if (-not $launched -and $script:lobby -and $script:lobby.members.Count -ge 1) {
                & $log ("LOBBY " + (@($lstLobby.Items) -join ", ")); Start-Sleep -Milliseconds 2500
                for ($k = 0; $k -lt 20; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
                & $click $btnLaunch; $launched = $true; & $log ("HOST " + ($txtCodes.Text -replace "`r`n", " / ")); break
            }
        }
    } else {
        $txtCode.Text = $env:COOP_TEST_LOBBY.Substring(5)
        & $click $btnJoin
        $end = (Get-Date).AddSeconds(40); $last = ""
        while ((Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40
            if ($lblJoinStatus.Text -ne $last) { $last = $lblJoinStatus.Text; & $log ("JOIN " + ($last -replace "`r`n", " / ")) }
            if ((Get-Content $env:COOP_NO_GAME -Raw) -match "GAME \+set coop_connect") { break }
        }
    }
    exit
}

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
