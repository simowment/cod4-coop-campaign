# CoD4 Coop Campaign launcher: host or join with a short join code. Lives next to iw3sp.exe.
#   Host: opens UDP 28970 on the router through UPnP (if the router allows it), shows join codes, starts the game.
#   Join: paste a code (or pick a game found on the LAN), checks the host answers, starts the game.
# Non-interactive helpers for tests:  -Encode 1.2.3.4:28970   -Decode CODE   -Discover   -Probe CODE
param([string]$Encode = "", [string]$Decode = "", [switch]$Discover, [string]$Probe = "")

$ErrorActionPreference = "Stop"
# run as "CoD4 Coop.bat" (the build embeds this script in a batch file) or directly as a .ps1
if ($env:COOP_GAMEDIR) { $GameDir = $env:COOP_GAMEDIR.TrimEnd([char]92) } else { $GameDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Port = 28970
if ($env:COOP_TEST_PORT) { $Port = [int]$env:COOP_TEST_PORT }   # tests only, never set for players
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
        return Merge-Games @(Read-Infos $u 1200)
    } finally { $u.Close() }
}
# one host answers once per way it was reached (loopback + LAN, LAN + Tailscale): keep one row per host,
# reached the best way (LAN, then Tailscale, then anything else, loopback last)
function Merge-Games($games) {
    $rank = { param($ip) if ($ip -match '^127\.') { 3 } elseif ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { 0 } elseif ($ip -match '^100\.') { 1 } else { 2 } }
    $best = [ordered]@{}
    foreach ($g in $games) {
        $k = "$($g.host)|$($g.port)|$($g.map)"
        if (-not $best.Contains($k) -or (& $rank $g.ip) -lt (& $rank $best[$k].ip)) { $best[$k] = $g }
    }
    return @($best.Values)
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
        try { $maps.Remove($Port, "TCP") } catch {}
        try { [void]$maps.Add($Port, "TCP", $Port, $lanIp, $true, "CoD4 Coop skins") } catch {}
        $m = $maps.Add($Port, "UDP", $Port, $lanIp, $true, "CoD4 Coop")
        if ($m -and $m.ExternalIPAddress) { return $m.ExternalIPAddress }
    } catch {}
    return $null
}

function Close-RouterPort {
    if ($env:COOP_NO_UPNP) { return }   # tests
    try { $nat = New-Object -ComObject HNetCfg.NATUPnP; $maps = $nat.StaticPortMappingCollection; if ($maps) { $maps.Remove($Port, "UDP"); try { $maps.Remove($Port, "TCP") } catch {} } } catch {}
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
            } catch (Exception e) { var x = e is AggregateException && e.InnerException != null ? ((AggregateException)e).Flatten().InnerException : e; Error = x.Message; }
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
# skin pack sync: everyone sees a player's skin only if it is in their own pack, so the host's launcher
# serves its pack over TCP on the game port number, and a joining launcher downloads it if it differs.
# Pack = Mods/coop/mod.ff + images/coop_*_col.iwi + skins.txt, plus the custom emotes (tools/skin/addemote.py):
# emotes.txt + sound/music/coopemote* (their xanims and music aliases are inside mod.ff).
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function Get-PackFiles {
    $mod = Join-Path $GameDir "Mods\coop"
    $skins = Join-Path $mod "skins.txt"
    $emotes = Join-Path $mod "emotes.txt"
    $hasSkins = (Test-Path $skins) -and ((Get-Content $skins) -match '\S')
    $hasEmotes = (Test-Path $emotes) -and ((Get-Content $emotes) -match '\S')
    if (-not (Test-Path (Join-Path $mod "mod.ff")) -or -not ($hasSkins -or $hasEmotes)) { return @() }
    $files = @("mod.ff")
    if (Test-Path $skins) { $files += "skins.txt" }
    $files += @(Get-ChildItem (Join-Path $mod "images") -Filter "coop_*_col.iwi" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "images/" + $_.Name })
    if ($hasEmotes) {
        $files += "emotes.txt"
        $files += @(Get-ChildItem (Join-Path $mod "sound\music") -Filter "coopemote*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^coopemote[1-3]_[a-z0-9_]+\.(mp3|wav)$' } | Sort-Object Name | ForEach-Object { "sound/music/" + $_.Name })
    }
    return $files
}
# maps\_coop_emotes.gsc from emotes.txt ("name|node|hold ms|music alias|music file"); only the fixed animtree
# slots and music aliases of tools/skin/emotepack.py are accepted, so a pack cannot inject script code
$EmoteSlots = @("unarmed_waving", "unarmed_waving_twitch", "unarmed_waving_startidle", "unarmed_waving_endidle")
function Write-EmoteScript {
    $mod = Join-Path $GameDir "Mods\coop"
    $g = "// generated by the launcher from the host's pack: the custom emotes`n#using_animtree( `"generic_human`" );`n`nadd_all()`n{`n"
    $txt = Join-Path $mod "emotes.txt"
    if (Test-Path $txt) {
        foreach ($line in (Get-Content $txt)) {
            $f = $line -split '\|'
            if ($f.Count -lt 4) { continue }
            if ($f[0] -notmatch "^[A-Za-z0-9 _.!'-]{1,14}$" -or $EmoteSlots -notcontains $f[1] -or $f[2] -notmatch '^\d{1,5}$') { continue }
            $snd = "undefined"
            if ($f[3] -match '^coopemote[1-3]_z*_music$') { $snd = "`"$($f[3])`"" }
            $g += "`tmaps\_coop_emote::add_custom( `"$($f[0])`", $([Math]::Min(30000, [int]$f[2])), $snd, %$($f[1]) );`n"
        }
    }
    $g += "}`n"
    [void](New-Item -ItemType Directory -Force (Join-Path $mod "maps"))
    [IO.File]::WriteAllText((Join-Path $mod "maps\_coop_emotes.gsc"), $g)
}
function Get-PackHash {
    $files = @(Get-PackFiles)
    if (-not $files.Count) { return "NONE" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ms = New-Object IO.MemoryStream
    foreach ($f in $files) {
        $n = [Text.Encoding]::UTF8.GetBytes($f); $ms.Write($n, 0, $n.Length)
        $b = [IO.File]::ReadAllBytes((Join-Path $GameDir ("Mods\coop\" + $f))); $ms.Write($b, 0, $b.Length)
    }
    return ([BitConverter]::ToString($sha.ComputeHash($ms.ToArray())) -replace '-', '').Substring(0, 16)
}
function Get-PackBytes {
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($f in (Get-PackFiles)) {
        $e = $zip.CreateEntry($f, [IO.Compression.CompressionLevel]::Optimal)
        $w = $e.Open(); $b = [IO.File]::ReadAllBytes((Join-Path $GameDir ("Mods\coop\" + $f))); $w.Write($b, 0, $b.Length); $w.Close()
    }
    $zip.Dispose()
    return $ms.ToArray()
}
function Install-PackBytes([byte[]]$bytes) {
    $mod = Join-Path $GameDir "Mods\coop"
    Get-ChildItem (Join-Path $mod "images") -Filter "coop_*_col.iwi" -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem (Join-Path $mod "sound\music") -Filter "coopemote*" -ErrorAction SilentlyContinue | Remove-Item -Force
    foreach ($old in @("emotes.txt", "skins.txt")) { if (Test-Path (Join-Path $mod $old)) { Remove-Item -Force (Join-Path $mod $old) } }
    $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.ZipArchiveMode]::Read)
    foreach ($e in $zip.Entries) {
        if ($e.FullName -notmatch '^(mod\.ff|skins\.txt|emotes\.txt|images/coop_[a-z0-9_]+_col\.iwi|sound/music/coopemote[1-3]_[a-z0-9_]+\.(mp3|wav))$') { continue }   # nothing else is accepted
        $dst = Join-Path $mod ($e.FullName -replace '/', '\')
        [void](New-Item -ItemType Directory -Force (Split-Path $dst))
        $r = $e.Open(); $fs = [IO.File]::Create($dst); $r.CopyTo($fs); $fs.Close(); $r.Close()
    }
    $zip.Dispose()
    # the game reads the list of skins it may precache from this script
    $names = @()
    if (Test-Path (Join-Path $mod "skins.txt")) { $names = @(Get-Content (Join-Path $mod "skins.txt") | Where-Object { $_ -match '^coop_[a-z0-9_]+$' }) }
    $g = "// generated by the launcher from the host's skin pack`n`nlist()`n{`n`ts = [];`n"
    foreach ($n in $names) { $g += "`ts[ s.size ] = `"$n`";`n" }
    $g += "`treturn s;`n}`n"
    [IO.File]::WriteAllText((Join-Path $mod "maps\_coop_skins.gsc"), $g)
    Write-EmoteScript
}
# host side: TcpListener polled from the window timer; one short request per connection
$script:packServer = $null; $script:packCache = $null
function Start-PackServer {
    if ($script:packServer) { return }
    try { $script:packServer = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port); $script:packServer.Start() }
    catch { $script:packServer = $null }
    $script:packCache = $null
}
function Stop-PackServer { if ($script:packServer) { try { $script:packServer.Stop() } catch {} }; $script:packServer = $null }
function Step-PackServer {
    if (-not $script:packServer -or -not $script:packServer.Pending()) { return }
    $c = $script:packServer.AcceptTcpClient()
    try {
        $c.ReceiveTimeout = 3000; $c.SendTimeout = 30000
        $st = $c.GetStream()
        $line = ""
        while ($line.Length -lt 100) { $b = $st.ReadByte(); if ($b -lt 0 -or $b -eq 10) { break }; $line += [char]$b }
        $hash = Get-PackHash
        if ($line -notmatch '^PACK (\S+)') { return }
        if ($hash -eq "NONE") { $out = [Text.Encoding]::ASCII.GetBytes("NONE`n"); $st.Write($out, 0, $out.Length); return }
        if ($Matches[1] -eq $hash) { $out = [Text.Encoding]::ASCII.GetBytes("SAME`n"); $st.Write($out, 0, $out.Length); return }
        if (-not $script:packCache -or $script:packCache.hash -ne $hash) { $script:packCache = @{ hash = $hash; bytes = (Get-PackBytes) } }
        $data = $script:packCache.bytes
        $head = [Text.Encoding]::ASCII.GetBytes("DATA $($data.Length) $hash`n")
        $st.Write($head, 0, $head.Length); $st.Write($data, 0, $data.Length); $st.Flush()
    } catch {} finally { $c.Close() }
}
# client side: returns a short status text
function Sync-SkinPack([string]$ip, [int]$port, $status) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(2500)) { return "skins: the host's launcher did not answer (only skins you both have will show)" }
        $c.EndConnect($ar)
        $c.ReceiveTimeout = 15000
        $st = $c.GetStream()
        $req = [Text.Encoding]::ASCII.GetBytes("PACK $(Get-PackHash)`n"); $st.Write($req, 0, $req.Length)
        $line = ""
        while ($line.Length -lt 120) { $b = $st.ReadByte(); if ($b -lt 0 -or $b -eq 10) { break }; $line += [char]$b }
        if ($line -eq "SAME") { return "skins: you already have the host's skins" }
        if ($line -eq "NONE") { return "skins: the host has no custom skins" }
        if ($line -notmatch '^DATA (\d+) ') { return "skins: unexpected answer from the host" }
        $len = [int]$Matches[1]
        if ($len -gt 200MB) { return "skins: pack too large" }
        $buf = New-Object byte[] $len; $got = 0
        while ($got -lt $len) {
            $n = $st.Read($buf, $got, [Math]::Min(65536, $len - $got)); if ($n -le 0) { break }; $got += $n
            if ($status) { & $status ("Downloading the host's skins: {0:N1} / {1:N1} MB" -f ($got / 1MB), ($len / 1MB)) }
        }
        if ($got -lt $len) { return "skins: download interrupted" }
        Install-PackBytes $buf
        return "skins: got the host's skin pack"
    } catch { return "skins: $($_.Exception.Message)" } finally { $c.Close() }
}

# ------------------------------------------------------------------------------------------------
# self-update: the latest GitHub release is checked in the background on start; "Update" downloads its
# zip, replaces the mod files (keeping skins, settings and the skin pack) and restarts the launcher.
# ------------------------------------------------------------------------------------------------
$UpdateRepo = "simowment/cod4-coop-campaign"
$UpdaterCode = @'
using System; using System.IO; using System.Net; using System.Threading; using System.Text.RegularExpressions;
public static class CoopUpdate {
    public static volatile string Latest = null, ZipUrl = null, Error = null, Status = "";
    public static volatile bool Checked = false, Downloaded = false;
    public static volatile string ZipPath = null;
    public static void Check(string repo) {
        var t = new Thread(() => {
            try {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2
                var wc = new WebClient();
                wc.Headers.Add("User-Agent", "cod4-coop-launcher");
                string j = wc.DownloadString("https://api.github.com/repos/" + repo + "/releases/latest");
                var tag = Regex.Match(j, "\"tag_name\"\\s*:\\s*\"v?([^\"]+)\"");
                var zip = Regex.Match(j, "\"browser_download_url\"\\s*:\\s*\"([^\"]+cod4-coop-[^\"]+\\.zip)\"");
                if (tag.Success) Latest = tag.Groups[1].Value;
                if (zip.Success) ZipUrl = zip.Groups[1].Value;
            } catch (Exception e) { Error = e.Message; }
            Checked = true;
        });
        t.IsBackground = true; t.Start();
    }
    public static void Download(string url, string dest) {
        Downloaded = false; Error = null; ZipPath = null; Status = "Downloading the update...";   // a retry starts clean
        var t = new Thread(() => {
            try {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                var wc = new WebClient();
                wc.Headers.Add("User-Agent", "cod4-coop-launcher");
                wc.DownloadProgressChanged += (s, e) => { Status = string.Format("Downloading the update: {0}%", e.ProgressPercentage); };
                wc.DownloadFileTaskAsync(new Uri(url), dest).Wait();
                ZipPath = dest; Downloaded = true;
            } catch (Exception e) { Error = (e.InnerException ?? e).Message; Downloaded = true; }
        });
        t.IsBackground = true; t.Start();
    }
    // "0.2.10" > "0.2.9"
    public static bool Newer(string a, string b) {
        try { return new Version(a) > new Version(b); } catch { return false; }
    }
}
'@
function Get-InstalledVersion {
    try { return ([IO.File]::ReadAllText((Join-Path $GameDir "Mods\coop\coop_patches.json")) | ConvertFrom-Json).version } catch { return "0.0.0" }
}
function Install-UpdateZip([string]$zipPath) {
    # files a player owns (their skins, the shared skin pack, settings) are never replaced by an update
    $keep = '^(Mods/coop/(skins\.txt|emotes\.txt|mod\.ff|maps/_coop_skins\.gsc|maps/_coop_emotes\.gsc|images/coop_[^/]+|sound/music/coopemote[^/]+)|coop_launcher\.json)$'
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $rel = $e.FullName -replace '\\', '/'
            if ($rel -match '\.\.' -or $rel -match '^/') { continue }
            $dst = Join-Path $GameDir ($rel -replace '/', '\')
            if ($rel -match $keep -and (Test-Path $dst)) { continue }
            [void](New-Item -ItemType Directory -Force (Split-Path $dst))
            try { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true) }
            catch {
                # d3d9.dll is locked while a game is running: put it next to it, swapped in on the next start
                if ($rel -eq "d3d9.dll") { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, "$dst.new", $true) } else { throw }
            }
        }
    } finally { $zip.Dispose() }
}
# a d3d9.dll update that could not be written because the game was running
$pendingDll = Join-Path $GameDir "d3d9.dll.new"
if ((Test-Path $pendingDll) -and -not (Get-Process iw3sp -ErrorAction SilentlyContinue)) {
    try { Move-Item $pendingDll (Join-Path $GameDir "d3d9.dll") -Force } catch {}
}

# ------------------------------------------------------------------------------------------------
# look: dark military theme, all controls drawn by hand (C#, compiled once per launcher version and cached in
# %LOCALAPPDATA%\CoD4Coop). The header art and mission pictures are decoded from the player's OWN game files
# (main\images\*.iwi; nothing from the game is shipped) and cached as PNG in %LOCALAPPDATA%\CoD4Coop\art.
# The font comes from Mods\coop\launcher\fonts (OFL, shipped), else Bahnschrift (Windows 10+), else Arial Narrow.
# ------------------------------------------------------------------------------------------------
$ThemeCode = @'
using System; using System.IO; using System.Collections.Generic; using System.Collections.ObjectModel; using System.Collections.Specialized;
using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging; using System.Drawing.Text;
using System.Runtime.InteropServices; using System.Text.RegularExpressions; using System.Windows.Forms;

// IWI (CoD4 image, version 6): "IWi" ver fmt flags u16 w u16 h u16 depth, 4 x u32 mip offsets; the largest mip is last
public static class CoopIwi {
    public static Bitmap Load(string path) {
        byte[] b = File.ReadAllBytes(path);
        if (b.Length < 28 || b[0] != 'I' || b[1] != 'W' || b[2] != 'i') return null;
        int ver = b[3], fmt = b[4];
        int w = BitConverter.ToUInt16(b, 6), h = BitConverter.ToUInt16(b, 8);
        if (w < 1 || h < 1 || w > 4096 || h > 4096) return null;
        int hdr = ver >= 8 ? 32 : 28;
        int bw = Math.Max(1, (w + 3) / 4), bh = Math.Max(1, (h + 3) / 4);
        long size;
        switch (fmt) {
            case 1: size = (long)w * h * 4; break;          // ARGB32 (stored B G R A)
            case 2: size = (long)w * h * 3; break;          // RGB24 (B G R)
            case 3: size = (long)w * h * 2; break;          // luminance + alpha
            case 4: size = (long)w * h; break;              // 8 bit
            case 0x0B: size = (long)bw * bh * 8; break;     // DXT1
            case 0x0C: case 0x0D: size = (long)bw * bh * 16; break;   // DXT3, DXT5
            default: return null;
        }
        long off = b.Length - size;
        if (off < hdr) return null;
        int[] px = new int[w * h];
        int o = (int)off;
        if (fmt == 1) { for (int i = 0; i < w * h; i++, o += 4) px[i] = (b[o + 3] << 24) | (b[o + 2] << 16) | (b[o + 1] << 8) | b[o]; }
        else if (fmt == 2) { for (int i = 0; i < w * h; i++, o += 3) px[i] = (255 << 24) | (b[o + 2] << 16) | (b[o + 1] << 8) | b[o]; }
        else if (fmt == 3) { for (int i = 0; i < w * h; i++, o += 2) { int l = b[o]; px[i] = (b[o + 1] << 24) | (l << 16) | (l << 8) | l; } }
        else if (fmt == 4) { for (int i = 0; i < w * h; i++, o++) { int l = b[o]; px[i] = (255 << 24) | (l << 16) | (l << 8) | l; } }
        else {
            int[] c = new int[4]; int[] al = new int[8];
            for (int by = 0; by < bh; by++) for (int bx = 0; bx < bw; bx++) {
                int ao = o, co = fmt == 0x0B ? o : o + 8;
                int c0 = b[co] | (b[co + 1] << 8), c1 = b[co + 2] | (b[co + 3] << 8);
                c[0] = C565(c0); c[1] = C565(c1);
                if (fmt != 0x0B || c0 > c1) { c[2] = Mix(c[0], c[1], 2, 1, 3); c[3] = Mix(c[0], c[1], 1, 2, 3); }
                else { c[2] = Mix(c[0], c[1], 1, 1, 2); c[3] = 0; }
                uint bits = (uint)(b[co + 4] | (b[co + 5] << 8) | (b[co + 6] << 16) | (b[co + 7] << 24));
                ulong abits = 0;
                if (fmt == 0x0D) {
                    int a0 = b[ao], a1 = b[ao + 1]; al[0] = a0; al[1] = a1;
                    if (a0 > a1) { for (int k = 1; k < 7; k++) al[k + 1] = ((7 - k) * a0 + k * a1) / 7; }
                    else { for (int k = 1; k < 5; k++) al[k + 1] = ((5 - k) * a0 + k * a1) / 5; al[6] = 0; al[7] = 255; }
                    for (int k = 0; k < 6; k++) abits |= (ulong)b[ao + 2 + k] << (8 * k);
                }
                for (int py = 0; py < 4; py++) for (int qx = 0; qx < 4; qx++) {
                    int x = bx * 4 + qx, y = by * 4 + py, idx = py * 4 + qx;
                    if (x >= w || y >= h) continue;
                    int col = c[(bits >> (2 * idx)) & 3];
                    if (fmt == 0x0C) { int a4 = (b[ao + idx / 2] >> ((idx & 1) * 4)) & 15; col = (col & 0xFFFFFF) | ((a4 * 17) << 24); }
                    else if (fmt == 0x0D) col = (col & 0xFFFFFF) | (al[(int)((abits >> (3 * idx)) & 7)] << 24);
                    px[y * w + x] = col;
                }
                o += fmt == 0x0B ? 8 : 16;
            }
        }
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(px, 0, bd.Scan0, px.Length); bmp.UnlockBits(bd);
        return bmp;
    }
    static int C565(int v) { int r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31; return (255 << 24) | (((r << 3) | (r >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | ((b << 3) | (b >> 2)); }
    static int Mix(int a, int b, int wa, int wb, int d) {
        int r = (((a >> 16) & 255) * wa + ((b >> 16) & 255) * wb) / d, g = (((a >> 8) & 255) * wa + ((b >> 8) & 255) * wb) / d, bl = ((a & 255) * wa + (b & 255) * wb) / d;
        return (255 << 24) | (r << 16) | (g << 8) | bl;
    }
}

public static class CoopTheme {
    public static Color Bg = Color.FromArgb(15, 16, 12), PanelBg = Color.FromArgb(21, 23, 17), Field = Color.FromArgb(10, 11, 8);
    public static Color Line = Color.FromArgb(100, 102, 74), LineDim = Color.FromArgb(56, 59, 44), LineHi = Color.FromArgb(166, 164, 116);
    public static Color Text = Color.FromArgb(226, 222, 202), TextDim = Color.FromArgb(150, 150, 128), TextMute = Color.FromArgb(96, 98, 84);
    public static Color Gold = Color.FromArgb(238, 192, 74), Amber = Color.FromArgb(224, 188, 106);
    public static Color Green = Color.FromArgb(76, 120, 34), GreenHi = Color.FromArgb(184, 234, 94), Bad = Color.FromArgb(240, 120, 98);
    public static float Scale = 1f, FontScale = 1f, Dpi = 96f;
    public static int Px(double v) { return (int)Math.Round(v * Scale); }
    public static float Pf(double v) { return (float)(v * Scale); }

    // ---- fonts ----
    [DllImport("gdi32.dll")] static extern IntPtr AddFontMemResourceEx(IntPtr pb, uint cb, IntPtr pdv, ref uint pcFonts);
    static PrivateFontCollection pfc;
    static FontFamily headFam, bodyFam;
    static FontStyle headStyle = FontStyle.Regular, bodyStyle = FontStyle.Regular;
    static Dictionary<string, Font> fonts = new Dictionary<string, Font>();
    public static string FontName = "";
    static FontFamily Installed(string name) { try { var f = new FontFamily(name); return f.Name == name ? f : null; } catch { return null; } }
    static FontStyle FirstStyle(FontFamily f) { foreach (FontStyle s in new[] { FontStyle.Regular, FontStyle.Bold, FontStyle.Italic }) if (f.IsStyleAvailable(s)) return s; return FontStyle.Regular; }
    static bool Has(string s, string t) { return s.IndexOf(t, StringComparison.OrdinalIgnoreCase) >= 0; }
    public static void LoadFonts(string dir) {
        headFam = null; bodyFam = null; headStyle = FontStyle.Regular; bodyStyle = FontStyle.Regular;
        try {
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir)) {
                pfc = new PrivateFontCollection();
                foreach (string f in Directory.GetFiles(dir)) {
                    string ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext != ".ttf" && ext != ".otf") continue;
                    // loaded from memory (never freed): the file stays unlocked, so an update can replace it
                    byte[] d = File.ReadAllBytes(f);
                    IntPtr p = Marshal.AllocCoTaskMem(d.Length);
                    Marshal.Copy(d, 0, p, d.Length);
                    pfc.AddMemoryFont(p, d.Length);
                    uint n = 0; AddFontMemResourceEx(p, (uint)d.Length, IntPtr.Zero, ref n);   // GDI too: text boxes
                }
                foreach (FontFamily ff in pfc.Families) {
                    string nm = ff.Name;
                    if (Has(nm, "Bold") || Has(nm, "Medium") || Has(nm, "Heavy") || Has(nm, "Black")) { if (headFam == null || Has(nm, "SemiBold")) headFam = ff; }
                    else if (bodyFam == null || Has(nm, "Regular")) bodyFam = ff;
                }
                if (headFam == null && bodyFam != null) { headFam = bodyFam; if (bodyFam.IsStyleAvailable(FontStyle.Bold)) headStyle = FontStyle.Bold; }
                if (bodyFam == null) bodyFam = headFam;
                if (headFam != null) { if (headStyle != FontStyle.Bold) headStyle = FirstStyle(headFam); bodyStyle = FirstStyle(bodyFam); }
            }
        } catch { headFam = null; bodyFam = null; }
        if (headFam == null) {
            headStyle = FontStyle.Regular; bodyStyle = FontStyle.Regular;
            headFam = Installed("Bahnschrift SemiBold Condensed"); bodyFam = Installed("Bahnschrift Condensed");
            if (headFam == null || bodyFam == null) { headFam = Installed("Arial Narrow"); bodyFam = headFam; headStyle = FontStyle.Bold; }
            if (headFam == null) { headFam = Installed("Segoe UI") ?? FontFamily.GenericSansSerif; bodyFam = headFam; headStyle = FontStyle.Bold; }
        }
        FontName = headFam.Name + " / " + bodyFam.Name;
        fonts.Clear(); widths.Clear();
    }
    static Font Get(FontFamily f, float pt, FontStyle st) {
        string k = f.Name + "|" + pt + "|" + st;
        Font r;
        if (!fonts.TryGetValue(k, out r)) { r = new Font(f, pt * FontScale, st, GraphicsUnit.Point); fonts[k] = r; }
        return r;
    }
    public static Font Head(float pt) { if (headFam == null) LoadFonts(null); return Get(headFam, pt, headStyle); }
    public static Font Body(float pt) { if (bodyFam == null) LoadFonts(null); return Get(bodyFam, pt, bodyStyle); }

    // ---- text: letter-spaced, capitals centred in their line ----
    static readonly StringFormat TF = MakeTF();
    static StringFormat MakeTF() { var f = (StringFormat)StringFormat.GenericTypographic.Clone(); f.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap | StringFormatFlags.NoClip; return f; }
    static Dictionary<Font, Dictionary<char, float>> widths = new Dictionary<Font, Dictionary<char, float>>();
    static Graphics mg;
    public static Graphics MeasureG { get { if (mg == null) { var b = new Bitmap(1, 1); b.SetResolution(Dpi, Dpi); mg = Graphics.FromImage(b); mg.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; } return mg; } }
    static float CharW(Graphics g, Font f, char c) {
        Dictionary<char, float> d;
        if (!widths.TryGetValue(f, out d)) { d = new Dictionary<char, float>(); widths[f] = d; }
        float w;
        if (!d.TryGetValue(c, out w)) { w = g.MeasureString(c.ToString(), f, PointF.Empty, TF).Width; d[c] = w; }
        return w;
    }
    public static float EmPx(Graphics g, Font f) { return f.SizeInPoints * g.DpiY / 72f; }
    public static float Track(Graphics g, Font f, float em) { return EmPx(g, f) * em; }
    public static float LineH(Graphics g, Font f) { return EmPx(g, f) * 1.32f; }
    public static float TextWidth(Graphics g, string s, Font f, float track) {
        if (string.IsNullOrEmpty(s)) return 0f;
        if (track == 0f) return g.MeasureString(s, f, PointF.Empty, TF).Width;
        float w = 0f;
        foreach (char c in s) w += CharW(g, f, c) + track;
        return w - track;
    }
    public static void DrawLine(Graphics g, string s, Font f, Color col, float x, float top, float h, float track) {
        if (string.IsNullOrEmpty(s)) return;
        float em = EmPx(g, f);
        FontFamily ff = f.FontFamily;
        float asc = em * ff.GetCellAscent(f.Style) / ff.GetEmHeight(f.Style);
        float y = top + (h + em * 0.70f) / 2f - asc;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using (var b = new SolidBrush(col)) {
            if (track == 0f) { g.DrawString(s, f, b, x, y, TF); return; }
            foreach (char c in s) { if (c != ' ') g.DrawString(c.ToString(), f, b, x, y, TF); x += CharW(g, f, c) + track; }
        }
    }
    public static List<string> Wrap(Graphics g, string text, Font f, float track, float width) {
        var lines = new List<string>();
        foreach (string para in (text ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Split('\n')) {
            string cur = "";
            foreach (string w0 in para.Split(' ')) {
                string w = w0;
                string t = cur.Length == 0 ? w : cur + " " + w;
                if (TextWidth(g, t, f, track) <= width) { cur = t; continue; }
                if (cur.Length > 0) lines.Add(cur);
                while (w.Length > 1 && TextWidth(g, w, f, track) > width) {   // a word wider than the line
                    int n = w.Length - 1;
                    while (n > 1 && TextWidth(g, w.Substring(0, n), f, track) > width) n--;
                    lines.Add(w.Substring(0, n)); w = w.Substring(n);
                }
                cur = w;
            }
            lines.Add(cur);
        }
        return lines;
    }

    // ---- shapes ----
    // corners: 1 top-left, 2 top-right, 4 bottom-right, 8 bottom-left
    public static GraphicsPath Cut(RectangleF r, float c, int corners) {
        var p = new GraphicsPath();
        float tl = (corners & 1) != 0 ? c : 0, tr = (corners & 2) != 0 ? c : 0, br = (corners & 4) != 0 ? c : 0, bl = (corners & 8) != 0 ? c : 0;
        p.AddLine(r.Left + tl, r.Top, r.Right - tr, r.Top);
        p.AddLine(r.Right, r.Top + tr, r.Right, r.Bottom - br);
        p.AddLine(r.Right - br, r.Bottom, r.Left + bl, r.Bottom);
        p.AddLine(r.Left, r.Bottom - bl, r.Left, r.Top + tl);
        p.CloseFigure();
        return p;
    }
    public static RectangleF Half(Rectangle r) { return new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1f, r.Height - 1f); }
    static Bitmap noiseBmp;
    public static TextureBrush Noise() { if (noiseBmp == null) noiseBmp = MakeNoise(); return new TextureBrush(noiseBmp); }
    static Bitmap MakeNoise() {
        int n = 192;
        var bmp = new Bitmap(n, n, PixelFormat.Format32bppArgb);
        var rnd = new Random(1234);
        var px = new int[n * n];
        for (int i = 0; i < px.Length; i++) {
            int v = rnd.Next(100);
            if (v < 34) px[i] = rnd.Next(8, 26) << 24;
            else if (v < 42) px[i] = (rnd.Next(4, 12) << 24) | 0xC8C8A0;
        }
        var bd = bmp.LockBits(new Rectangle(0, 0, n, n), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(px, 0, bd.Scan0, px.Length); bmp.UnlockBits(bd);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            for (int i = 0; i < 10; i++) {
                float x = rnd.Next(n), y = rnd.Next(n), w = rnd.Next(20, 70), h = rnd.Next(10, 40);
                using (var b = new SolidBrush(i % 3 == 0 ? Color.FromArgb(7, 200, 200, 150) : Color.FromArgb(10, 0, 0, 0))) g.FillEllipse(b, x - w / 2, y - h / 2, w, h);
            }
            for (int i = 0; i < 5; i++) {
                float x = rnd.Next(n), y = rnd.Next(n);
                using (var p = new Pen(Color.FromArgb(9, 220, 220, 180), 1f)) g.DrawLine(p, x, y, x + rnd.Next(-30, 30), y + rnd.Next(-6, 6));
            }
        }
        return bmp;
    }
    public static void Vignette(Graphics g, Rectangle r, int alpha) {
        if (r.Width < 2 || r.Height < 2) return;
        using (var path = new GraphicsPath()) {
            path.AddEllipse(RectangleF.Inflate(r, r.Width * 0.25f, r.Height * 0.35f));
            using (var pb = new PathGradientBrush(path)) {
                pb.CenterColor = Color.FromArgb(0, 0, 0, 0);
                pb.SurroundColors = new[] { Color.FromArgb(alpha, 0, 0, 0) };
                pb.FocusScales = new PointF(0.55f, 0.4f);
                g.FillRectangle(pb, r);
            }
        }
    }
    public static Bitmap Backdrop(int w, int h) {
        var bmp = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            g.Clear(Bg);
            using (var nb = Noise()) g.FillRectangle(nb, 0, 0, w, h);
            Vignette(g, new Rectangle(0, 0, w, h), 170);
        }
        return bmp;
    }
    public static void FillPanel(Graphics g, Rectangle r) {
        using (var b = new SolidBrush(PanelBg)) g.FillRectangle(b, r);
        using (var nb = Noise()) g.FillRectangle(nb, r);
    }
    // framed panel with cut corners and small bright corner marks
    public static void FramePanel(Graphics g, Rectangle r, float cut, Color fill, Color line, int corners) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = Cut(Half(r), cut, corners)) {
            using (var b = new SolidBrush(fill)) g.FillPath(b, p);
            using (var pen = new Pen(Color.FromArgb(120, 0, 0, 0), 3f)) g.DrawPath(pen, p);
            using (var pen = new Pen(line, 1f)) g.DrawPath(pen, p);
        }
        float m = Pf(18);
        using (var pen = new Pen(Color.FromArgb(200, LineHi), Math.Max(1.5f, Pf(1.6)))) {
            if ((corners & 1) == 0) { g.DrawLine(pen, r.Left + 0.5f, r.Top + m, r.Left + 0.5f, r.Top + 0.5f); g.DrawLine(pen, r.Left + 0.5f, r.Top + 0.5f, r.Left + m, r.Top + 0.5f); }
            if ((corners & 4) == 0) { g.DrawLine(pen, r.Right - 0.5f, r.Bottom - m, r.Right - 0.5f, r.Bottom - 0.5f); g.DrawLine(pen, r.Right - 0.5f, r.Bottom - 0.5f, r.Right - m, r.Bottom - 0.5f); }
        }
    }
    public static void DrawField(Graphics g, Rectangle r, bool focus, bool hover) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = Cut(Half(r), Pf(5), 2 | 8)) {
            using (var b = new SolidBrush(Field)) g.FillPath(b, p);
            using (var pen = new Pen(focus ? Amber : hover ? LineHi : Line, 1f)) g.DrawPath(pen, p);
        }
        using (var pen = new Pen(Color.FromArgb(90, 0, 0, 0), 1f)) g.DrawLine(pen, r.Left + Pf(2), r.Top + 1.5f, r.Right - Pf(7), r.Top + 1.5f);
    }
    // a framed field around a text box / list / picture: drawn on the parent, around the control
    class FrameInfo { public Control C; public int L, T, R, B; }
    public static void Frame(Control c, int l, int t, int r, int b) {
        Control p = c.Parent;
        if (p == null) return;
        var fi = new FrameInfo { C = c, L = l, T = t, R = r, B = b };
        p.Paint += (s, e) => {
            if (p.Visible && !fi.C.Visible) return;      // (a window never shown, like a test snapshot, reports Visible false)
            var rc = new Rectangle(fi.C.Left - fi.L, fi.C.Top - fi.T, fi.C.Width + fi.L + fi.R, fi.C.Height + fi.T + fi.B);
            if (!e.ClipRectangle.IntersectsWith(rc)) return;
            DrawField(e.Graphics, rc, fi.C.ContainsFocus, false);
        };
        EventHandler inv = (s, e) => { var rc = new Rectangle(fi.C.Left - fi.L - 2, fi.C.Top - fi.T - 2, fi.C.Width + fi.L + fi.R + 4, fi.C.Height + fi.T + fi.B + 4); p.Invalidate(rc); };
        c.GotFocus += inv; c.LostFocus += inv; c.VisibleChanged += inv;
    }
    public static void Frame(Control c, int pad) { Frame(c, pad, pad, pad, pad); }

    // ---- glyphs ----
    static GraphicsPath Round(RectangleF r, float rad) {
        var p = new GraphicsPath(); float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure();
        return p;
    }
    public static void Glyph(Graphics g, string name, RectangleF r, Color c) {
        if (string.IsNullOrEmpty(name)) return;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = Math.Min(r.Width, r.Height), cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        using (var b = new SolidBrush(c))
        using (var p = new Pen(c, Math.Max(1.3f, s / 9f))) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            switch (name) {
                case "play": g.FillPolygon(b, new[] { new PointF(cx - s * .32f, cy - s * .42f), new PointF(cx + s * .44f, cy), new PointF(cx - s * .32f, cy + s * .42f) }); break;
                case "tri": g.FillPolygon(b, new[] { new PointF(cx - s * .18f, cy - s * .24f), new PointF(cx + s * .24f, cy), new PointF(cx - s * .18f, cy + s * .24f) }); break;
                case "star": {
                    var pts = new PointF[10];
                    for (int i = 0; i < 10; i++) { double a = -Math.PI / 2 + i * Math.PI / 5; float rr = (i % 2 == 0) ? s * .5f : s * .21f; pts[i] = new PointF(cx + (float)Math.Cos(a) * rr, cy + (float)Math.Sin(a) * rr); }
                    g.FillPolygon(b, pts); break; }
                case "crown":
                    g.FillPolygon(b, new[] { new PointF(cx - s * .45f, cy + s * .28f), new PointF(cx - s * .45f, cy - s * .25f), new PointF(cx - s * .22f, cy), new PointF(cx, cy - s * .38f),
                                             new PointF(cx + s * .22f, cy), new PointF(cx + s * .45f, cy - s * .25f), new PointF(cx + s * .45f, cy + s * .28f) });
                    g.FillRectangle(b, cx - s * .45f, cy + s * .34f, s * .9f, s * .1f); break;
                case "check": g.DrawLines(p, new[] { new PointF(cx - s * .34f, cy + s * .02f), new PointF(cx - s * .1f, cy + s * .26f), new PointF(cx + s * .36f, cy - s * .28f) }); break;
                case "checkbox":
                    using (var pp = new Pen(c, Math.Max(1.2f, s / 12f))) g.DrawRectangle(pp, cx - s * .42f, cy - s * .42f, s * .84f, s * .84f);
                    g.DrawLines(p, new[] { new PointF(cx - s * .24f, cy + s * .0f), new PointF(cx - s * .06f, cy + s * .18f), new PointF(cx + s * .26f, cy - s * .2f) }); break;
                case "info":
                    using (var pp = new Pen(c, Math.Max(1.4f, s / 13f))) g.DrawEllipse(pp, cx - s * .44f, cy - s * .44f, s * .88f, s * .88f);
                    g.FillEllipse(b, cx - s * .06f, cy - s * .27f, s * .12f, s * .12f);
                    g.FillRectangle(b, cx - s * .05f, cy - s * .08f, s * .1f, s * .34f); break;
                case "warn":
                    using (var pp = new Pen(c, Math.Max(1.4f, s / 13f))) { pp.LineJoin = LineJoin.Round; g.DrawPolygon(pp, new[] { new PointF(cx, cy - s * .42f), new PointF(cx + s * .46f, cy + s * .38f), new PointF(cx - s * .46f, cy + s * .38f) }); }
                    g.FillRectangle(b, cx - s * .045f, cy - s * .14f, s * .09f, s * .3f); g.FillEllipse(b, cx - s * .055f, cy + s * .2f, s * .11f, s * .11f); break;
                case "up":
                    g.DrawLine(p, cx, cy + s * .2f, cx, cy - s * .36f); g.DrawLines(p, new[] { new PointF(cx - s * .26f, cy - s * .12f), new PointF(cx, cy - s * .38f), new PointF(cx + s * .26f, cy - s * .12f) });
                    g.DrawLine(p, cx - s * .36f, cy + s * .4f, cx + s * .36f, cy + s * .4f); break;
                case "link": {
                    var st = g.Save(); g.TranslateTransform(cx, cy); g.RotateTransform(-45);
                    using (var pp = new Pen(c, Math.Max(1.4f, s / 10f))) {
                        using (var a = Round(new RectangleF(-s * .52f, -s * .17f, s * .54f, s * .34f), s * .17f)) g.DrawPath(pp, a);
                        using (var a = Round(new RectangleF(-s * .02f, -s * .17f, s * .54f, s * .34f), s * .17f)) g.DrawPath(pp, a);
                    }
                    g.Restore(st); break; }
                case "copy":
                    using (var pp = new Pen(c, Math.Max(1.3f, s / 11f))) {
                        g.DrawRectangle(pp, cx - s * .4f, cy - s * .4f, s * .52f, s * .58f);
                        g.DrawRectangle(pp, cx - s * .12f, cy - s * .16f, s * .52f, s * .58f);
                    } break;
                case "refresh":
                    g.DrawArc(p, cx - s * .36f, cy - s * .36f, s * .72f, s * .72f, -60, 290);
                    g.FillPolygon(b, new[] { new PointF(cx + s * .2f, cy - s * .5f), new PointF(cx + s * .44f, cy - s * .26f), new PointF(cx + s * .1f, cy - s * .18f) }); break;
                case "plus": g.DrawLine(p, cx - s * .36f, cy, cx + s * .36f, cy); g.DrawLine(p, cx, cy - s * .36f, cx, cy + s * .36f); break;
                case "join":
                    g.DrawLine(p, cx - s * .42f, cy, cx + s * .12f, cy); g.DrawLines(p, new[] { new PointF(cx - s * .08f, cy - s * .2f), new PointF(cx + s * .12f, cy), new PointF(cx - s * .08f, cy + s * .2f) });
                    g.DrawLines(p, new[] { new PointF(cx + s * .05f, cy - s * .4f), new PointF(cx + s * .4f, cy - s * .4f), new PointF(cx + s * .4f, cy + s * .4f), new PointF(cx + s * .05f, cy + s * .4f) }); break;
                case "trash":
                    g.DrawLine(p, cx - s * .38f, cy - s * .28f, cx + s * .38f, cy - s * .28f); g.DrawLine(p, cx - s * .1f, cy - s * .4f, cx + s * .1f, cy - s * .4f);
                    g.DrawLines(p, new[] { new PointF(cx - s * .28f, cy - s * .2f), new PointF(cx - s * .22f, cy + s * .42f), new PointF(cx + s * .22f, cy + s * .42f), new PointF(cx + s * .28f, cy - s * .2f) }); break;
                case "rig":
                    g.DrawEllipse(p, cx - s * .1f, cy - s * .46f, s * .2f, s * .2f);
                    g.DrawLine(p, cx, cy - s * .24f, cx, cy + s * .12f); g.DrawLine(p, cx - s * .36f, cy - s * .12f, cx + s * .36f, cy - s * .12f);
                    g.DrawLine(p, cx, cy + s * .12f, cx - s * .22f, cy + s * .46f); g.DrawLine(p, cx, cy + s * .12f, cx + s * .22f, cy + s * .46f); break;
                case "bot":
                    using (var a = Round(new RectangleF(cx - s * .36f, cy - s * .24f, s * .72f, s * .56f), s * .12f)) g.DrawPath(p, a);
                    g.FillEllipse(b, cx - s * .2f, cy - s * .04f, s * .13f, s * .13f); g.FillEllipse(b, cx + s * .07f, cy - s * .04f, s * .13f, s * .13f);
                    g.DrawLine(p, cx, cy - s * .26f, cx, cy - s * .42f); break;
                case "slash":
                    for (int i = 0; i < 2; i++) { float x0 = r.X + i * s * .42f; g.FillPolygon(b, new[] { new PointF(x0 + s * .3f, cy - s * .3f), new PointF(x0 + s * .5f, cy - s * .3f), new PointF(x0 + s * .2f, cy + s * .3f), new PointF(x0, cy + s * .3f) }); }
                    break;
                case "person":
                    g.FillEllipse(b, cx - s * .17f, cy - s * .44f, s * .34f, s * .34f);
                    using (var a = new GraphicsPath()) { a.AddArc(cx - s * .38f, cy - s * .02f, s * .76f, s * .8f, 180, 180); a.CloseFigure(); g.FillPath(b, a); }
                    break;
                case "pencil":
                    using (var pp = new Pen(c, Math.Max(1.6f, s / 5.5f))) { pp.StartCap = LineCap.Flat; pp.EndCap = LineCap.Flat; g.DrawLine(pp, cx - s * .2f, cy + s * .2f, cx + s * .32f, cy - s * .32f); }
                    g.FillPolygon(b, new[] { new PointF(cx - s * .42f, cy + s * .42f), new PointF(cx - s * .33f, cy + s * .14f), new PointF(cx - s * .14f, cy + s * .33f) }); break;
                case "minus": g.DrawLine(p, cx - s * .34f, cy, cx + s * .34f, cy); break;
                case "dot": g.FillEllipse(b, cx - s * .26f, cy - s * .26f, s * .52f, s * .52f); break;
                case "leave":
                    g.DrawLine(p, cx - s * .1f, cy, cx + s * .42f, cy); g.DrawLines(p, new[] { new PointF(cx + s * .22f, cy - s * .2f), new PointF(cx + s * .42f, cy), new PointF(cx + s * .22f, cy + s * .2f) });
                    g.DrawLines(p, new[] { new PointF(cx + s * .05f, cy - s * .4f), new PointF(cx - s * .4f, cy - s * .4f), new PointF(cx - s * .4f, cy + s * .4f), new PointF(cx + s * .05f, cy + s * .4f) }); break;
            }
        }
    }

    // ---- art from the player's own game files ----
    public static string ImagesDir = null, CacheDir = null;
    static Dictionary<string, Bitmap> art = new Dictionary<string, Bitmap>();
    public static Bitmap Art(string name, int maxSide) {
        string mk = name + "@" + maxSide;
        Bitmap have;
        if (art.TryGetValue(mk, out have)) return have;
        Bitmap res = null;
        try {
            string src = ImagesDir == null ? null : Path.Combine(ImagesDir, name + ".iwi");
            if (src != null && File.Exists(src)) {
                var fi = new FileInfo(src);
                string png = CacheDir == null ? null : Path.Combine(CacheDir, name + "_" + maxSide + "_" + fi.Length.ToString("x") + "_" + fi.LastWriteTimeUtc.Ticks.ToString("x") + ".png");
                if (png != null && File.Exists(png)) { try { using (var t = new Bitmap(png)) res = new Bitmap(t); } catch { res = null; } }
                if (res == null) {
                    Bitmap full = CoopIwi.Load(src);
                    if (full != null) {
                        res = full;
                        float k = Math.Min(1f, maxSide / (float)Math.Max(full.Width, full.Height));
                        if (k < 1f) {
                            res = new Bitmap(Math.Max(1, (int)(full.Width * k)), Math.Max(1, (int)(full.Height * k)), PixelFormat.Format32bppArgb);
                            using (var g = Graphics.FromImage(res)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.DrawImage(full, 0, 0, res.Width, res.Height); }
                            full.Dispose();
                        }
                        if (png != null) { try { Directory.CreateDirectory(CacheDir); res.Save(png, ImageFormat.Png); } catch { } }
                    }
                }
            }
        } catch { res = null; }
        art[mk] = res;
        return res;
    }
    static ImageAttributes Grade(float sat, float rMul, float gMul, float bMul, float alpha) {
        float lr = 0.299f * (1 - sat), lg = 0.587f * (1 - sat), lb = 0.114f * (1 - sat);
        var m = new ColorMatrix(new float[][] {
            new float[] { (lr + sat) * rMul, lr * gMul, lr * bMul, 0, 0 },
            new float[] { lg * rMul, (lg + sat) * gMul, lg * bMul, 0, 0 },
            new float[] { lb * rMul, lb * gMul, (lb + sat) * bMul, 0, 0 },
            new float[] { 0, 0, 0, alpha, 0 },
            new float[] { 0, 0, 0, 0, 1 } });
        var ia = new ImageAttributes(); ia.SetColorMatrix(m); ia.SetWrapMode(WrapMode.TileFlipXY);
        return ia;
    }
    // draws the part of img around (fx, fy) that fills dst, keeping its proportions
    static void Cover(Graphics g, Image img, RectangleF dst, float fx, float fy, ImageAttributes ia) {
        float k = Math.Max(dst.Width / img.Width, dst.Height / img.Height);
        float sw = dst.Width / k, sh = dst.Height / k;
        float sx = Math.Max(0, Math.Min(img.Width - sw, img.Width * fx - sw / 2)), sy = Math.Max(0, Math.Min(img.Height - sh, img.Height * fy - sh / 2));
        g.DrawImage(img, new[] { new PointF(dst.Left, dst.Top), new PointF(dst.Right, dst.Top), new PointF(dst.Left, dst.Bottom) }, new RectangleF(sx, sy, sw, sh), GraphicsUnit.Pixel, ia);
    }
    public static Bitmap Thumb(string name, int w, int h) {
        var bmp = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.SmoothingMode = SmoothingMode.AntiAlias;
            Bitmap a = name == null ? null : Art(name, Math.Max(w, h) > 200 ? 512 : 256);
            if (a != null) { using (var ia = Grade(0.55f, 1.0f, 1.0f, 0.88f, 1f)) Cover(g, a, new RectangleF(0, 0, w, h), 0.5f, 0.55f, ia); }
            else {
                using (var lg = new LinearGradientBrush(new Rectangle(0, 0, w, h + 1), Color.FromArgb(58, 60, 44), Color.FromArgb(20, 22, 16), 90f)) g.FillRectangle(lg, 0, 0, w, h);
                using (var p = new Pen(Color.FromArgb(120, LineHi), Math.Max(1f, h / 22f))) {
                    float s = h * 0.56f; g.DrawEllipse(p, w / 2f - s / 2, h / 2f - s / 2, s, s);
                    g.DrawLine(p, w / 2f - s * .75f, h / 2f, w / 2f + s * .75f, h / 2f); g.DrawLine(p, w / 2f, h / 2f - s * .75f, w / 2f, h / 2f + s * .75f);
                }
            }
            using (var lg = new LinearGradientBrush(new Rectangle(0, 0, w, h + 1), Color.FromArgb(0, 0, 0, 0), Color.FromArgb(90, 0, 0, 0), 90f)) g.FillRectangle(lg, 0, 0, w, h);
        }
        return bmp;
    }
    // light-on-black logo: black becomes transparent, cropped to what is drawn
    static Bitmap LumaKey(Bitmap src) {
        int w = src.Width, h = src.Height;
        var px = new int[w * h];
        var bd = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(bd.Scan0, px, 0, px.Length); src.UnlockBits(bd);
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int v = px[y * w + x], r = (v >> 16) & 255, gg = (v >> 8) & 255, b = v & 255, a0 = (v >> 24) & 255;
            int m = Math.Max(r, Math.Max(gg, b));
            int a = Math.Min(255, Math.Max(0, (m - 10) * 2)) * a0 / 255;
            if (a < 8) { px[y * w + x] = 0; continue; }
            r = Math.Min(255, r * 255 / Math.Max(m, 1)); gg = Math.Min(255, gg * 255 / Math.Max(m, 1)); b = Math.Min(255, b * 255 / Math.Max(m, 1));
            px[y * w + x] = (a << 24) | (r << 16) | (gg << 8) | b;
            if (a > 40) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
        }
        if (x1 < x0 || y1 < y0) return null;
        var full = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        bd = full.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(px, 0, bd.Scan0, px.Length); full.UnlockBits(bd);
        var crop = full.Clone(new Rectangle(x0, y0, x1 - x0 + 1, y1 - y0 + 1), PixelFormat.Format32bppArgb);
        full.Dispose();
        return crop;
    }
    // header banner: battlefield art from the game + the game logo + "CO-OP CAMPAIGN"
    public static string HeaderInfo = "";
    public static Bitmap Header(int w, int h, string[] artNames, string backName, string logoName, string subtitle) {
        var bmp = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var lg = new LinearGradientBrush(new Rectangle(0, 0, w, h + 1), Color.FromArgb(36, 38, 30), Bg, 90f)) g.FillRectangle(lg, 0, 0, w, h);
            Bitmap back = backName == null ? null : Art(backName, 1024);
            if (back != null) using (var ia = Grade(0.25f, 1.0f, 1.0f, 0.82f, 0.55f)) Cover(g, back, new RectangleF(0, 0, w, h), 0.5f, 0.45f, ia);
            Bitmap main = null; string used = null;
            foreach (string n in artNames) { main = Art(n, 1024); if (main != null) { used = n; break; } }
            float x0 = w * 0.26f;
            if (main != null) {
                using (var ia = Grade(0.35f, 1.0f, 0.98f, 0.80f, 1f)) Cover(g, main, new RectangleF(x0, 0, w - x0, h), 0.5f, 0.42f, ia);
                using (var lg = new LinearGradientBrush(new RectangleF(x0 - 1, 0, w * 0.34f, h), Color.FromArgb(255, Bg), Color.FromArgb(0, Bg), 0f)) g.FillRectangle(lg, x0, 0, w * 0.34f - 2, h);
                using (var b = new SolidBrush(Color.FromArgb(150, Bg))) g.FillRectangle(b, 0, 0, x0, h);
            } else if (back == null) Skyline(g, w, h);
            HeaderInfo = used ?? (back != null ? backName : "procedural");
            using (var lg = new LinearGradientBrush(new RectangleF(0, h * 0.5f - 1, w, h * 0.5f + 2), Color.FromArgb(0, Bg), Color.FromArgb(255, Bg), 90f)) g.FillRectangle(lg, 0, h * 0.5f, w, h * 0.5f + 1);
            using (var lg = new LinearGradientBrush(new RectangleF(0, -1, w, h * 0.25f + 2), Color.FromArgb(120, 0, 0, 0), Color.FromArgb(0, 0, 0, 0), 90f)) g.FillRectangle(lg, 0, 0, w, h * 0.25f);
            using (var nb = Noise()) g.FillRectangle(nb, 0, 0, w, h);
            // logo
            float lx = Pf(26), ly = h * 0.08f, lh = h * 0.56f, lw = 0;
            Bitmap logoSrc = logoName == null ? null : Art(logoName, 1024);
            Bitmap logo = logoSrc == null ? null : LumaKey(logoSrc);
            if (logo != null) {
                lw = lh * logo.Width / logo.Height;
                using (var sh = Grade(0, 0, 0, 0, 0.75f)) g.DrawImage(logo, new Rectangle((int)(lx + Pf(2)), (int)(ly + Pf(3)), (int)lw, (int)lh), 0, 0, logo.Width, logo.Height, GraphicsUnit.Pixel, sh);
                g.DrawImage(logo, new RectangleF(lx, ly, lw, lh));
                logo.Dispose();
            } else {
                Font big = Head(26f), mid = Head(13f);
                float tb = Track(g, big, 0.02f), tm = Track(g, mid, 0.16f);
                DrawLine(g, "CALL OF DUTY 4", big, Color.FromArgb(236, 232, 214), lx, ly, lh * 0.62f, tb);
                DrawLine(g, "MODERN WARFARE", mid, GreenHi, lx + Pf(2), ly + lh * 0.6f, lh * 0.4f, tm);
                lw = Math.Max(TextWidth(g, "CALL OF DUTY 4", big, tb), TextWidth(g, "MODERN WARFARE", mid, tm));
            }
            if (!string.IsNullOrEmpty(subtitle)) {
                Font sf = Head(10.5f); float tr = Track(g, sf, 0.38f);
                string t = subtitle.ToUpperInvariant();
                float tw = TextWidth(g, t, sf, tr), sy = ly + lh + Pf(2), sh2 = Pf(18), cxx = lx + lw / 2;
                DrawLine(g, t, sf, Color.FromArgb(214, 210, 190), cxx - tw / 2, sy, sh2, tr);
                using (var p = new Pen(Color.FromArgb(170, 214, 210, 190), Math.Max(1f, Pf(1)))) {
                    float my = sy + sh2 / 2, gap = Pf(10), len = Pf(26);
                    g.DrawLine(p, cxx - tw / 2 - gap - len, my, cxx - tw / 2 - gap, my);
                    g.DrawLine(p, cxx + tw / 2 + gap, my, cxx + tw / 2 + gap + len, my);
                }
            }
        }
        return bmp;
    }
    static void Skyline(Graphics g, int w, int h) {
        var rnd = new Random(42);
        using (var lg = new LinearGradientBrush(new Rectangle(0, 0, w, h + 1), Color.FromArgb(70, 66, 48), Color.FromArgb(30, 30, 24), 90f)) g.FillRectangle(lg, 0, 0, w, h);
        for (int i = 0; i < 6; i++) using (var b = new SolidBrush(Color.FromArgb(24, 10, 10, 8))) { float x = rnd.Next(w), y = rnd.Next(h / 2); g.FillEllipse(b, x - w * .15f, y - h * .3f, w * .3f, h * .6f); }
        using (var b = new SolidBrush(Color.FromArgb(230, 14, 15, 11))) {
            float x = w * 0.3f;
            while (x < w) { float bw2 = rnd.Next(Px(14), Px(46)), bh2 = h * (0.18f + (float)rnd.NextDouble() * 0.42f); g.FillRectangle(b, x, h - bh2, bw2, bh2); if (rnd.Next(4) == 0) g.FillRectangle(b, x + bw2 / 2, h - bh2 - h * 0.15f, Math.Max(1, Px(2)), h * 0.15f); x += bw2 + rnd.Next(0, Px(6)); }
            for (int i = 0; i < 2; i++) {      // helicopters
                float hx = w * (0.55f + i * 0.2f), hy = h * (0.22f + i * 0.08f), s = Pf(10 - i * 2);
                g.FillEllipse(b, hx - s, hy - s * .4f, s * 2, s * .8f); g.FillRectangle(b, hx + s * .8f, hy - s * .15f, s * 1.6f, s * .25f);
                using (var p = new Pen(b.Color, Math.Max(1f, Pf(1)))) g.DrawLine(p, hx - s * 1.6f, hy - s * .7f, hx + s * 1.6f, hy - s * .7f);
            }
        }
    }

    // ---- window helpers ----
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void DarkTitle(IntPtr h) {
        try {
            int on = 1;
            if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4);
            int cap = (Bg.B << 16) | (Bg.G << 8) | Bg.R; DwmSetWindowAttribute(h, 35, ref cap, 4);          // Windows 11 caption colour
            int brd = (LineDim.B << 16) | (LineDim.G << 8) | LineDim.R; DwmSetWindowAttribute(h, 34, ref brd, 4);
        } catch { }
    }
    // powershell.exe is DPI-unaware: without this Windows bitmap-stretches the window (blurry at 125/150%).
    // System-aware (1), not per-monitor: WinForms on .NET Framework does not rescale on a monitor change.
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool IsProcessDPIAware();
    public static bool DpiAware() {
        try { SetProcessDpiAwareness(1); } catch { }
        try { if (!IsProcessDPIAware()) SetProcessDPIAware(); return IsProcessDPIAware(); } catch { return false; }
    }
    // skin previews come on a flat blue-grey: make that background see-through (soft edge) so the field shows
    public static Bitmap KeyBackground(Image src) {
        var b = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b)) g.DrawImage(src, 0, 0, src.Width, src.Height);
        var r = new Rectangle(0, 0, b.Width, b.Height);
        var d = b.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int n = d.Stride * d.Height; var px = new byte[n];
        Marshal.Copy(d.Scan0, px, 0, n);
        int kb = px[0], kg = px[1], kr = px[2];
        for (int i = 0; i + 3 < n; i += 4) {
            int t = Math.Max(Math.Abs(px[i] - kb), Math.Max(Math.Abs(px[i + 1] - kg), Math.Abs(px[i + 2] - kr)));
            if (t < 8) px[i + 3] = 0; else if (t < 48) px[i + 3] = (byte)(px[i + 3] * (t - 8) / 40);
        }
        Marshal.Copy(px, 0, d.Scan0, n);
        b.UnlockBits(d);
        return b;
    }
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    // what the window really shows (tests; works off screen too)
    public static Bitmap Capture(Control f) {
        var b = new Bitmap(f.Width, f.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b)) { IntPtr dc = g.GetHdc(); PrintWindow(f.Handle, dc, 2); g.ReleaseHdc(dc); }
        return b;
    }
    // what is behind a control with cut corners: drawn by its parent (the themed ButtonRenderer path leaves holes when scaled)
    public static void PaintParent(Control c, Graphics g) {
        var bd = c.Parent as ICoopBackdrop;
        if (bd != null) { var st = g.Save(); g.TranslateTransform(-c.Left, -c.Top); bd.PaintBackdrop(g, c.Bounds); g.Restore(st); }
        else if (c.Parent != null) ButtonRenderer.DrawParentBackground(g, c.ClientRectangle, c);
    }
    public static void DarkScroll(Control c, string theme) {
        EventHandler set = (s, e) => { try { SetWindowTheme(c.Handle, theme, null); } catch { } };
        c.HandleCreated += set;
        if (c.IsHandleCreated) set(c, EventArgs.Empty);
    }
}

public interface ICoopBackdrop { void PaintBackdrop(Graphics g, Rectangle area); }

// the launcher window: grunge backdrop, header banner, framed main panel
public class CoopForm : Form, ICoopBackdrop {
    Bitmap cache;
    public Bitmap HeaderArt;
    public Rectangle PanelRect = Rectangle.Empty;
    public Size Canvas = Size.Empty;
    public CoopForm() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        BackColor = CoopTheme.Bg; ForeColor = CoopTheme.Text; AutoScaleMode = AutoScaleMode.None;
    }
    public void Redraw() { if (cache != null) cache.Dispose(); cache = null; Invalidate(true); }
    protected override void OnPaintBackground(PaintEventArgs e) {
        Ensure();
        e.Graphics.DrawImage(cache, AutoScrollPosition.X, AutoScrollPosition.Y, cache.Width, cache.Height);
    }
    public void PaintBackdrop(Graphics g, Rectangle r) {
        Ensure();
        g.DrawImage(cache, r, new Rectangle(r.X - AutoScrollPosition.X, r.Y - AutoScrollPosition.Y, r.Width, r.Height), GraphicsUnit.Pixel);
    }
    void Ensure() {
        int w = Math.Max(ClientSize.Width, Canvas.Width), h = Math.Max(ClientSize.Height, Canvas.Height);
        if (cache == null || cache.Width != w || cache.Height != h) {
            if (cache != null) cache.Dispose();
            cache = CoopTheme.Backdrop(w, h);
            using (var g = Graphics.FromImage(cache)) {
                if (HeaderArt != null) g.DrawImage(HeaderArt, 0, 0, HeaderArt.Width, HeaderArt.Height);
                if (!PanelRect.IsEmpty) CoopTheme.FramePanel(g, PanelRect, CoopTheme.Pf(16), Color.FromArgb(150, 21, 23, 17), CoopTheme.Line, 2 | 8);
            }
        }
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); CoopTheme.DarkTitle(Handle); }
    protected override void OnScroll(ScrollEventArgs se) { base.OnScroll(se); Invalidate(true); }
    protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); if (AutoScroll) Invalidate(true); }
}

public class MilButton : Button {
    int kind; string glyph = ""; bool hover, down;
    public int Kind { get { return kind; } set { kind = value; Invalidate(); } }       // 0 normal, 1 primary (green)
    public string Glyph { get { return glyph; } set { glyph = value ?? ""; Invalidate(); } }
    public float Track = 0.14f;
    public MilButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Head(11.5f); Cursor = Cursors.Hand; UseVisualStyleBackColor = false;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { if (!Enabled) { hover = false; down = false; } Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        CoopTheme.PaintParent(this, g);     // Button sets ControlStyles.Opaque: OnPaintBackground is never called
        g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        bool big = Height >= CoopTheme.Px(40), prim = kind == 1 && Enabled;
        float cut = CoopTheme.Pf(big ? 11 : 7), gl = prim ? CoopTheme.Pf(3) : 0;
        var r = new RectangleF(gl + 0.5f, gl + 0.5f, Width - 1 - 2 * gl, Height - 1 - 2 * gl);
        Color txt;
        using (var path = CoopTheme.Cut(r, cut, 2 | 8)) {
            if (!Enabled) {
                using (var b = new SolidBrush(Color.FromArgb(27, 29, 23))) g.FillPath(b, path);
                var st = g.Save(); g.SetClip(path);
                using (var p = new Pen(Color.FromArgb(16, 255, 255, 230), CoopTheme.Pf(3))) for (float hx = -Height; hx < Width; hx += CoopTheme.Pf(9)) g.DrawLine(p, hx, Height, hx + Height, 0);
                g.Restore(st);
                using (var p = new Pen(CoopTheme.LineDim, 1f)) g.DrawPath(p, path);
                txt = CoopTheme.TextMute;
            } else if (prim) {
                for (int i = 3; i >= 1; i--) {
                    var rr = RectangleF.Inflate(r, CoopTheme.Pf(i), CoopTheme.Pf(i));
                    using (var gp = CoopTheme.Cut(rr, cut + CoopTheme.Pf(i) * 0.4f, 2 | 8))
                    using (var p = new Pen(Color.FromArgb(hover ? 60 - i * 12 : 44 - i * 10, CoopTheme.GreenHi), CoopTheme.Pf(1.6))) g.DrawPath(p, gp);
                }
                Color top = down ? Color.FromArgb(52, 84, 24) : hover ? Color.FromArgb(92, 142, 42) : Color.FromArgb(78, 124, 36);
                Color bot = down ? Color.FromArgb(34, 56, 16) : Color.FromArgb(36, 62, 18);
                using (var b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2), top, bot, 90f)) g.FillPath(b, path);
                var st = g.Save(); g.SetClip(path);
                using (var p = new Pen(Color.FromArgb(70, 230, 255, 180), 1f)) g.DrawLine(p, r.Left + cut, r.Top + 1.5f, r.Right - cut, r.Top + 1.5f);
                using (var nb = CoopTheme.Noise()) g.FillPath(nb, path);
                g.Restore(st);
                using (var p = new Pen(CoopTheme.GreenHi, CoopTheme.Pf(1.4))) g.DrawPath(p, path);
                txt = Color.FromArgb(240, 246, 222);
            } else {
                Color top = down ? Color.FromArgb(30, 32, 25) : hover ? Color.FromArgb(58, 62, 46) : Color.FromArgb(44, 47, 36);
                Color bot = down ? Color.FromArgb(22, 24, 18) : hover ? Color.FromArgb(34, 37, 28) : Color.FromArgb(27, 29, 22);
                using (var b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2), top, bot, 90f)) g.FillPath(b, path);
                var st = g.Save(); g.SetClip(path);
                using (var p = new Pen(Color.FromArgb(28, 255, 255, 220), 1f)) g.DrawLine(p, r.Left + 1, r.Top + 1.5f, r.Right - cut, r.Top + 1.5f);
                g.Restore(st);
                using (var p = new Pen(hover ? CoopTheme.LineHi : CoopTheme.Line, 1f)) g.DrawPath(p, path);
                txt = ForeColor;
            }
            if (Focused && ShowFocusCues && Enabled) {
                var fr = RectangleF.Inflate(r, -CoopTheme.Pf(3.5), -CoopTheme.Pf(3.5));
                using (var fp = CoopTheme.Cut(fr, cut * 0.7f, 2 | 8)) using (var p = new Pen(Color.FromArgb(150, CoopTheme.Amber), 1f) { DashStyle = DashStyle.Dot }) g.DrawPath(p, fp);
            }
        }
        string t = (Text ?? "").ToUpperInvariant();
        Font f = Font;
        float tr = CoopTheme.Track(g, f, Track);
        float tw = CoopTheme.TextWidth(g, t, f, tr);
        float gs = glyph.Length > 0 && (Enabled || t.Length == 0) ?CoopTheme.EmPx(g, f) * (big ? 0.95f : 0.85f) : 0, gap = gs > 0 && t.Length > 0 ? CoopTheme.Pf(big ? 18 : 12) : 0;
        float x = (Width - tw - gs - gap) / 2f, off = down ? 1f : 0f;
        if (gs > 0) CoopTheme.Glyph(g, glyph, new RectangleF(x + off, (Height - gs) / 2f + off, gs, gs), txt);
        CoopTheme.DrawLine(g, t, f, txt, x + gs + gap + off, off, Height, tr);
    }
}

// a card on a surface: framed panel with a "// TITLE" header and an optional text on the right
public class MilCard {
    public Rectangle R;
    public string Title = "", Right = "";
    public Color RightColor = Color.Empty;
}

// a transparent area of the window that draws cards behind its controls; the result is cached
public class MilSurface : Panel, ICoopBackdrop {
    public List<MilCard> Cards = new List<MilCard>();
    Bitmap cache;
    public MilSurface() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        BackColor = CoopTheme.Bg; ForeColor = CoopTheme.Text;
    }
    public MilCard AddCard(int x, int y, int w, int h, string title) {
        var c = new MilCard { R = new Rectangle(x, y, w, h), Title = title ?? "" };
        Cards.Add(c); Redraw();
        return c;
    }
    public void Redraw() {
        if (cache != null) cache.Dispose();
        cache = null;
        foreach (Control c in Controls) { var s = c as MilSurface; if (s != null) s.Redraw(); }
        Invalidate(true);
    }
    protected override void OnLocationChanged(EventArgs e) { base.OnLocationChanged(e); Redraw(); }
    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Redraw(); }
    protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); Redraw(); }
    protected override void OnPaintBackground(PaintEventArgs e) { Ensure(); e.Graphics.DrawImage(cache, 0, 0, cache.Width, cache.Height); }
    public void PaintBackdrop(Graphics g, Rectangle r) { Ensure(); g.DrawImage(cache, r, r, GraphicsUnit.Pixel); }
    void Ensure() {
        int w = Math.Max(1, ClientSize.Width), h = Math.Max(1, ClientSize.Height);
        if (cache != null && cache.Width == w && cache.Height == h) return;
        if (cache != null) cache.Dispose();
        cache = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(cache)) {
            var bd = Parent as ICoopBackdrop;
            if (bd != null) { var st = g.Save(); g.TranslateTransform(-Left, -Top); bd.PaintBackdrop(g, Bounds); g.Restore(st); }
            else g.Clear(BackColor);
            foreach (MilCard c in Cards) DrawCard(g, c);
        }
    }
    public static void DrawCard(Graphics g, MilCard c) {
        var r = c.R;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        CoopTheme.FramePanel(g, r, CoopTheme.Pf(12), Color.FromArgb(178, 23, 25, 19), CoopTheme.Line, 2 | 8);
        // a faint lighter band behind the header
        using (var lg = new LinearGradientBrush(new RectangleF(r.X, r.Y, r.Width, CoopTheme.Pf(34)), Color.FromArgb(26, 220, 214, 170), Color.FromArgb(0, 220, 214, 170), 90f))
        using (var p = CoopTheme.Cut(new RectangleF(r.X + 1, r.Y + 1, r.Width - 2, CoopTheme.Pf(34)), CoopTheme.Pf(11), 2)) g.FillPath(lg, p);
        if (string.IsNullOrEmpty(c.Title)) return;
        float hh = CoopTheme.Pf(32), x = r.X + CoopTheme.Pf(14);
        Font hf = CoopTheme.Head(12.5f);
        float trk = CoopTheme.Track(g, hf, 0.13f), gs = hh * 0.42f;
        CoopTheme.Glyph(g, "slash", new RectangleF(x, r.Y + (hh - gs) / 2f + CoopTheme.Pf(1), gs, gs), CoopTheme.Line);
        x += gs * 1.05f + CoopTheme.Pf(10);
        CoopTheme.DrawLine(g, c.Title.ToUpperInvariant(), hf, CoopTheme.Text, x, r.Y + CoopTheme.Pf(1), hh, trk);
        if (!string.IsNullOrEmpty(c.Right)) {
            string t = c.Right.ToUpperInvariant();
            float rw = CoopTheme.TextWidth(g, t, hf, trk);
            CoopTheme.DrawLine(g, t, hf, c.RightColor != Color.Empty ? c.RightColor : CoopTheme.TextDim, r.Right - CoopTheme.Pf(16) - rw, r.Y + CoopTheme.Pf(1), hh, trk);
        }
        float ly = r.Y + hh + CoopTheme.Pf(1);
        using (var lg = new LinearGradientBrush(new RectangleF(r.X + CoopTheme.Pf(10) - 1, ly, r.Width - CoopTheme.Pf(20) + 2, 2), Color.FromArgb(170, CoopTheme.Line), Color.FromArgb(10, CoopTheme.Line), 0f))
            g.FillRectangle(lg, r.X + CoopTheme.Pf(10), ly, r.Width - CoopTheme.Pf(20), Math.Max(1, CoopTheme.Px(1)));
    }
}

// LOBBY / SETTINGS tabs with a status text on the right
public class MilTabStrip : Control {
    public string[] Tabs = new[] { "Lobby", "Settings" };
    int sel = 0, hot = -1;
    string status = ""; int statusKind = 0;
    public event EventHandler SelectedIndexChanged;
    public int SelectedIndex { get { return sel; } set { if (value != sel && value >= 0 && value < Tabs.Length) { sel = value; Invalidate(); if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty); } } }
    public string Status { get { return status; } set { if (value != status) { status = value ?? ""; Invalidate(); } } }
    public int StatusKind { get { return statusKind; } set { if (value != statusKind) { statusKind = value; Invalidate(); } } }   // 0 idle, 1 connected (green), 2 busy (amber)
    public MilTabStrip() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Head(13f);
    }
    float TabW { get { return CoopTheme.Pf(148); } }
    RectangleF TabRect(int i) { return new RectangleF(i * (TabW + CoopTheme.Pf(4)), 0, TabW, Height - CoopTheme.Pf(2)); }
    int Hit(Point p) { for (int i = 0; i < Tabs.Length; i++) if (TabRect(i).Contains(p)) return i; return -1; }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override void OnMouseMove(MouseEventArgs e) { int h = Hit(e.Location); if (h != hot) { hot = h; Invalidate(); } Cursor = h >= 0 ? Cursors.Hand : Cursors.Default; base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { int h = Hit(e.Location); if (e.Button == MouseButtons.Left && h >= 0) SelectedIndex = h; base.OnMouseDown(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        float b = Height - CoopTheme.Pf(1.5), slant = CoopTheme.Pf(16);
        // base rule across the whole width
        using (var lg = new LinearGradientBrush(new RectangleF(-1, b, Width + 2, 2), Color.FromArgb(190, CoopTheme.Line), Color.FromArgb(30, CoopTheme.Line), 0f))
            g.FillRectangle(lg, 0, b, Width, Math.Max(1, CoopTheme.Px(1)));
        for (int i = 0; i < Tabs.Length; i++) {
            RectangleF tr = TabRect(i);
            bool s = i == sel;
            float x = tr.X, w = tr.Width, y = s ? 0.5f : CoopTheme.Pf(4);
            var pts = new[] { new PointF(x + 0.5f, b), new PointF(x + 0.5f, y), new PointF(x + w - slant, y), new PointF(x + w, b) };
            if (s) {
                using (var lg = new LinearGradientBrush(new RectangleF(x, y - 1, w, b - y + 2), Color.FromArgb(96, 82, 36), Color.FromArgb(36, 36, 23), 90f)) g.FillPolygon(lg, pts);
                using (var pen = new Pen(Color.FromArgb(200, CoopTheme.Gold), 1f)) g.DrawLines(pen, pts);
                using (var pen = new Pen(CoopTheme.Gold, CoopTheme.Pf(2.5))) g.DrawLine(pen, x + 1, y + CoopTheme.Pf(1.2), x + w - slant - CoopTheme.Pf(1), y + CoopTheme.Pf(1.2));
            } else {
                Color f1 = i == hot ? Color.FromArgb(50, 53, 40) : Color.FromArgb(34, 36, 28);
                using (var lg = new LinearGradientBrush(new RectangleF(x, y - 1, w, b - y + 2), f1, Color.FromArgb(20, 22, 17), 90f)) g.FillPolygon(lg, pts);
                using (var pen = new Pen(i == hot ? CoopTheme.LineHi : CoopTheme.LineDim, 1f)) g.DrawLines(pen, pts);
            }
            string t = Tabs[i].ToUpperInvariant();
            float trk = CoopTheme.Track(g, Font, 0.14f), tw = CoopTheme.TextWidth(g, t, Font, trk);
            CoopTheme.DrawLine(g, t, Font, s ? CoopTheme.Gold : (i == hot ? CoopTheme.Text : CoopTheme.TextDim), x + (w - slant * 0.5f - tw) / 2f, y, b - y, trk);
        }
        if (status.Length > 0) {
            Font sf = CoopTheme.Head(11f);
            string t = status.ToUpperInvariant();
            float trk = CoopTheme.Track(g, sf, 0.12f), tw = CoopTheme.TextWidth(g, t, sf, trk);
            float ds = CoopTheme.Pf(14), tx = Width - CoopTheme.Pf(4) - tw, top = CoopTheme.Pf(4), h = b - top;
            Color dc = statusKind == 1 ? CoopTheme.GreenHi : statusKind == 2 ? CoopTheme.Amber : CoopTheme.TextMute;
            if (statusKind == 1) using (var gb = new SolidBrush(Color.FromArgb(50, CoopTheme.GreenHi))) g.FillEllipse(gb, tx - ds - CoopTheme.Pf(8) - ds * 0.2f, top + (h - ds) / 2f - ds * 0.2f, ds * 1.4f, ds * 1.4f);
            CoopTheme.Glyph(g, "dot", new RectangleF(tx - ds - CoopTheme.Pf(8), top + (h - ds) / 2f, ds, ds), dc);
            CoopTheme.DrawLine(g, t, sf, statusKind == 0 ? CoopTheme.TextDim : dc, tx, top, h, trk);
        }
    }
}

// the player chip in the header: person, name, pencil; Active while the profile panel is open
public class MilChip : Button {
    bool hover, active;
    public bool Active { get { return active; } set { active = value; Invalidate(); } }
    public MilChip() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(13f); Cursor = Cursors.Hand; UseVisualStyleBackColor = false;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    public override Size GetPreferredSize(Size proposed) {
        Graphics g = CoopTheme.MeasureG;
        float w = CoopTheme.Pf(12) + CoopTheme.Pf(16) + CoopTheme.Pf(10) + CoopTheme.TextWidth(g, Text ?? "", Font, 0f) + CoopTheme.Pf(14) + CoopTheme.Pf(13) + CoopTheme.Pf(14);
        return new Size((int)Math.Ceiling(Math.Min(CoopTheme.Pf(300), Math.Max(CoopTheme.Pf(120), w))), CoopTheme.Px(34));
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        CoopTheme.PaintParent(this, g);     // Button sets ControlStyles.Opaque: OnPaintBackground is never called
        g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
        using (var p = CoopTheme.Cut(r, CoopTheme.Pf(8), 2 | 8)) {
            using (var b = new SolidBrush(Color.FromArgb(active || hover ? 215 : 190, 16, 17, 13))) g.FillPath(b, p);
            using (var pen = new Pen(active ? CoopTheme.Gold : hover ? CoopTheme.LineHi : CoopTheme.Line, active ? CoopTheme.Pf(1.4) : 1f)) g.DrawPath(pen, p);
        }
        float gs = CoopTheme.Pf(16), x = CoopTheme.Pf(12);
        CoopTheme.Glyph(g, "person", new RectangleF(x, (Height - gs) / 2f, gs, gs), active ? CoopTheme.Gold : CoopTheme.TextDim);
        x += gs + CoopTheme.Pf(10);
        float ps = CoopTheme.Pf(13), px = Width - CoopTheme.Pf(14) - ps;
        var st = g.Save(); g.SetClip(new RectangleF(x, 0, Math.Max(1, px - x - CoopTheme.Pf(6)), Height), CombineMode.Intersect);
        CoopTheme.DrawLine(g, Text ?? "", Font, active ? CoopTheme.Gold : CoopTheme.Text, x, 0, Height, 0f);
        g.Restore(st);
        CoopTheme.Glyph(g, "pencil", new RectangleF(px, (Height - ps) / 2f, ps, ps), active || hover ? CoopTheme.Gold : CoopTheme.TextDim);
    }
}

// the selected mission: the game's own picture with the act, the name and a caption over it
public class MilTile : Control {
    Image thumb; string kicker = "", title = "", sub = "";
    public Image Thumb { get { return thumb; } set { thumb = value; Invalidate(); } }
    public string Kicker { get { return kicker; } set { kicker = value ?? ""; Invalidate(); } }
    public string Title { get { return title; } set { title = value ?? ""; Invalidate(); } }
    public string Sub { get { return sub; } set { sub = value ?? ""; Invalidate(); } }
    public MilTile() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
        using (var p = CoopTheme.Cut(r, CoopTheme.Pf(8), 2 | 8)) {
            using (var b = new SolidBrush(CoopTheme.Field)) g.FillPath(b, p);
            var st = g.Save(); g.SetClip(p, CombineMode.Intersect);
            if (thumb != null) g.DrawImage(thumb, new RectangleF(0, 0, Width, Height));
            using (var lg = new LinearGradientBrush(new RectangleF(-1, 0, Width + 2, Height), Color.FromArgb(235, 12, 13, 10), Color.FromArgb(0, 12, 13, 10), 0f)) {
                var cb = new ColorBlend(); cb.Positions = new[] { 0f, 0.45f, 1f };
                cb.Colors = new[] { Color.FromArgb(225, 12, 13, 10), Color.FromArgb(120, 12, 13, 10), Color.FromArgb(10, 12, 13, 10) };
                lg.InterpolationColors = cb; g.FillRectangle(lg, 0, 0, Width, Height);
            }
            using (var b = new SolidBrush(CoopTheme.Gold)) g.FillRectangle(b, 0, 0, CoopTheme.Pf(3), Height);
            g.Restore(st);
            using (var pen = new Pen(CoopTheme.LineDim, 1f)) g.DrawPath(pen, p);
        }
        float x = CoopTheme.Pf(16), w = Width - x - CoopTheme.Pf(10);
        Font kf = CoopTheme.Head(10.5f), tf = CoopTheme.Head(17f), sf = CoopTheme.Body(10.5f);
        float kh = CoopTheme.LineH(g, kf), th = CoopTheme.LineH(g, tf), sh = CoopTheme.LineH(g, sf);
        float y = (Height - kh - th - sh) / 2f;
        var cs = g.Save(); g.SetClip(new RectangleF(x, 0, Math.Max(1, w), Height), CombineMode.Intersect);
        CoopTheme.DrawLine(g, kicker.ToUpperInvariant(), kf, CoopTheme.Gold, x, y, kh, CoopTheme.Track(g, kf, 0.2f));
        string t = title.ToUpperInvariant(); Font f = tf; float trk = CoopTheme.Track(g, f, 0.06f);
        for (float size = 17f; size > 11f && CoopTheme.TextWidth(g, t, f, trk) > w; size -= 1f) { f = CoopTheme.Head(size - 1f); trk = CoopTheme.Track(g, f, 0.06f); }
        CoopTheme.DrawLine(g, t, f, Color.FromArgb(240, 236, 218), x, y + kh, th, trk);
        CoopTheme.DrawLine(g, sub, sf, CoopTheme.TextDim, x, y + kh + th, sh, 0f);
        g.Restore(cs);
    }
}

public class MilLabel : Label {
    public float Tracking = 0f;     // in em
    public bool Upper = false;
    public string Glyph = "";
    public Color GlyphColor = Color.Empty;
    public bool AutoGlyph = false;  // footer: check mark when up to date, arrow when an update is out, warning when it failed
    public bool Middle = true;      // a single line is centred vertically
    public MilLabel() {
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(11f);
    }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    string G() {
        if (!AutoGlyph) return Glyph;
        string t = Text ?? "";
        if (Regex.IsMatch(t, "fail|first", RegexOptions.IgnoreCase)) return "warn";
        if (Regex.IsMatch(t, " is out|Downloading|Installing", RegexOptions.IgnoreCase)) return "up";
        if (Regex.IsMatch(t, "up to date", RegexOptions.IgnoreCase)) return "checkbox";
        return t.Length > 0 ? "info" : "";
    }
    Color GC(string gl) {
        if (GlyphColor != Color.Empty) return GlyphColor;
        if (gl == "warn") return CoopTheme.Bad;
        if (gl == "checkbox") return CoopTheme.GreenHi;
        return CoopTheme.Gold;
    }
    public override Size GetPreferredSize(Size proposed) {
        Graphics g = CoopTheme.MeasureG;
        string t = Upper ? (Text ?? "").ToUpperInvariant() : (Text ?? "");
        float tr = CoopTheme.Track(g, Font, Tracking), lh = CoopTheme.LineH(g, Font);
        string gl = G();
        float gs = gl.Length > 0 ? lh + CoopTheme.Pf(8) : 0;
        return new Size((int)Math.Ceiling(CoopTheme.TextWidth(g, t, Font, tr) + gs + Padding.Horizontal + 2), (int)Math.Ceiling(lh + Padding.Vertical));
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        string t = Upper ? (Text ?? "").ToUpperInvariant() : (Text ?? "");
        float tr = CoopTheme.Track(g, Font, Tracking), lh = CoopTheme.LineH(g, Font);
        float x = Padding.Left;
        string gl = G();
        Color col = Enabled ? ForeColor : CoopTheme.TextMute;
        Font f = Font; Font own = null;
        float avail = Math.Max(10, Width - x - Padding.Right - (gl.Length > 0 ? lh + CoopTheme.Pf(8) : 0));
        var lines = CoopTheme.Wrap(g, t, f, tr, avail);
        // Fit: text taller than the label is drawn a little smaller, then cut with "..." (the full text is in a tooltip)
        if (Fit && lines.Count * lh > Height - Padding.Vertical) {
            for (float k = 0.94f; k >= 0.8f && lines.Count * lh > Height - Padding.Vertical; k -= 0.06f) {
                if (own != null) own.Dispose();
                own = new Font(Font.FontFamily, Font.SizeInPoints * k, Font.Style, GraphicsUnit.Point); f = own;
                lh = CoopTheme.LineH(g, f); tr = CoopTheme.Track(g, f, Tracking);
                lines = CoopTheme.Wrap(g, t, f, tr, avail);
            }
            int max = Math.Max(1, (int)((Height - Padding.Vertical) / lh));
            if (lines.Count > max) {
                lines.RemoveRange(max, lines.Count - max);
                string last = lines[max - 1];
                while (last.Length > 1 && CoopTheme.TextWidth(g, last + "...", f, tr) > avail) last = last.Substring(0, last.Length - 1);
                lines[max - 1] = last.TrimEnd() + "...";
            }
        }
        float total = lines.Count * lh;
        float y = Padding.Top;
        if (Middle && total <= Height) y = (Height - total) / 2f;
        if (gl.Length > 0) { float gs = lh * 0.82f; CoopTheme.Glyph(g, gl, new RectangleF(x, y + (lh - gs) / 2f, gs, gs), GC(gl)); x += lh + CoopTheme.Pf(8); }
        bool right = TextAlign == ContentAlignment.MiddleRight || TextAlign == ContentAlignment.TopRight;
        foreach (string ln in lines) {
            float lx = right ? Width - Padding.Right - CoopTheme.TextWidth(g, ln, f, tr) : x;
            CoopTheme.DrawLine(g, ln, f, col, lx, y, lh, tr);
            y += lh;
        }
        if (own != null) own.Dispose();
    }
    public bool Fit = false;
}

// lobby list: host row (star, gold, HOST crown), bots, friends, then "waiting for player" slots; draws its own header
public class MilLobby : Control {
    public ObservableCollection<string> Items = new ObservableCollection<string>();
    int slots = 4, idleBots = 0; string idleHost = "";
    public int Slots { get { return slots; } set { slots = value; Invalidate(); } }
    public string IdleHost { get { return idleHost; } set { idleHost = value ?? ""; Invalidate(); } }
    public int IdleBots { get { return idleBots; } set { idleBots = value; Invalidate(); } }
    public string Title = "In the lobby";
    public bool Header = true;       // false: the card around it has the title
    public MilLobby() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text;
        Items.CollectionChanged += (s, e) => Invalidate();
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rows = new List<string>(Items);
        bool idle = rows.Count == 0;
        if (idle) { rows.Add((idleHost.Length > 0 ? idleHost : "Player") + " (you, host)"); for (int i = 1; i <= idleBots; i++) rows.Add("Bot " + i); }
        int n = Math.Max(slots, rows.Count);
        var box = new Rectangle(0, 0, Width, Height);
        if (Header) {
            float hh = CoopTheme.Pf(26);
            Font hf = CoopTheme.Head(12f);
            float trk = CoopTheme.Track(g, hf, 0.12f);
            CoopTheme.Glyph(g, "slash", new RectangleF(CoopTheme.Pf(4), hh * 0.2f, hh * 0.6f, hh * 0.6f), CoopTheme.Line);
            string title = Title.ToUpperInvariant();
            float tx = CoopTheme.Pf(4) + hh * 1.25f;
            CoopTheme.DrawLine(g, title, hf, CoopTheme.Text, tx, 0, hh, trk);
            float tw = CoopTheme.TextWidth(g, title, hf, trk);
            CoopTheme.DrawLine(g, "(" + rows.Count + "/" + slots + ")", hf, CoopTheme.TextDim, tx + tw + CoopTheme.Pf(10), 0, hh, trk);
            using (var lg = new LinearGradientBrush(new RectangleF(0, 0, Width, 2), Color.FromArgb(160, CoopTheme.Line), Color.FromArgb(0, CoopTheme.Line), 0f)) g.FillRectangle(lg, 0, hh + CoopTheme.Pf(1), Width, Math.Max(1, CoopTheme.Px(1)));
            box = new Rectangle(0, (int)(hh + CoopTheme.Pf(5)), Width, Height - (int)(hh + CoopTheme.Pf(5)));
        }
        using (var p = CoopTheme.Cut(CoopTheme.Half(box), CoopTheme.Pf(6), 2 | 8)) {
            using (var b = new SolidBrush(Color.FromArgb(200, 12, 13, 10))) g.FillPath(b, p);
            using (var pen = new Pen(CoopTheme.Line, 1f)) g.DrawPath(pen, p);
        }
        float inset = CoopTheme.Pf(3), rh = (box.Height - 2 * inset) / n;
        Font nf = CoopTheme.Body(12.5f), tf = CoopTheme.Head(10.5f);
        float ttr = CoopTheme.Track(g, tf, 0.16f);
        for (int i = 0; i < n; i++) {
            var rr = new RectangleF(box.X + inset, box.Y + inset + i * rh, box.Width - 2 * inset, rh);
            if (i > 0) using (var pen = new Pen(CoopTheme.LineDim, 1f)) g.DrawLine(pen, rr.Left + CoopTheme.Pf(6), (int)rr.Top + 0.5f, rr.Right - CoopTheme.Pf(6), (int)rr.Top + 0.5f);
            float gs = Math.Min(rh * 0.62f, CoopTheme.Pf(17)), gx = rr.Left + CoopTheme.Pf(14), nx = gx + gs + CoopTheme.Pf(18);
            var gr = new RectangleF(gx, rr.Top + (rh - gs) / 2f, gs, gs);
            if (i >= rows.Count) {
                CoopTheme.Glyph(g, "tri", gr, CoopTheme.TextMute);
                CoopTheme.DrawLine(g, "WAITING FOR PLAYER...", tf, CoopTheme.TextMute, nx, rr.Top, rh, ttr);
                continue;
            }
            string s = rows[i], tag = null, gl = "tri"; Color nc = CoopTheme.Text, tc = CoopTheme.TextDim;
            if (s.EndsWith(" (you)")) { s = s.Substring(0, s.Length - 6); tag = "YOU"; tc = CoopTheme.GreenHi; gl = "person"; }
            else if (s.EndsWith(" (you, host)") || s.EndsWith(" (host)")) {
                s = s.Substring(0, s.Length - (s.EndsWith(" (host)") ? 7 : 12)); gl = "star"; nc = CoopTheme.Gold; tc = CoopTheme.Gold; tag = "HOST";
                using (var lg = new LinearGradientBrush(new RectangleF(rr.X - 1, rr.Y, rr.Width + 2, rr.Height), Color.FromArgb(idle ? 26 : 44, CoopTheme.Gold), Color.FromArgb(0, CoopTheme.Gold), 0f)) g.FillRectangle(lg, rr.X, rr.Y + 1, rr.Width, rr.Height - 1);
            } else if (i > 0 && Regex.IsMatch(s, "^Bot [0-9]+$")) { gl = "bot"; nc = CoopTheme.TextDim; tag = "AI"; tc = CoopTheme.TextMute; }
            else { tag = "JOINED"; tc = Color.FromArgb(150, CoopTheme.GreenHi); }
            CoopTheme.Glyph(g, gl, gr, gl == "star" ? CoopTheme.Gold : nc);
            CoopTheme.DrawLine(g, s, nf, nc, nx, rr.Top, rh, 0f);
            if (tag != null) {
                float tagW = CoopTheme.TextWidth(g, tag, tf, ttr), tagX = rr.Right - CoopTheme.Pf(18) - tagW;
                CoopTheme.DrawLine(g, tag, tf, tc, tagX, rr.Top, rh, ttr);
                if (tag == "HOST") CoopTheme.Glyph(g, "crown", new RectangleF(tagX - gs - CoopTheme.Pf(8), rr.Top + (rh - gs) / 2f, gs, gs), CoopTheme.Gold);
            }
        }
    }
}

public class MilCombo : ComboBox {
    public Dictionary<string, Image> Thumbs = new Dictionary<string, Image>();
    public bool ThumbsClosed = true;     // false: pictures only in the open list
    bool hover;
    public MilCombo() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DrawMode = DrawMode.OwnerDrawFixed; DropDownStyle = ComboBoxStyle.DropDownList; FlatStyle = FlatStyle.Flat;
        BackColor = CoopTheme.Field; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(12f); IntegralHeight = false; MaxDropDownItems = 14;
        CoopTheme.DarkScroll(this, "DarkMode_CFD");
    }
    // the native combo box prints itself (DrawToBitmap, screenshots): print our drawing instead
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0317 || m.Msg == 0x0318) { using (var g = Graphics.FromHdc(m.WParam)) OnPaint(new PaintEventArgs(g, ClientRectangle)); return; }
        base.WndProc(ref m);
    }
    protected override void OnSelectedIndexChanged(EventArgs e) { Invalidate(); base.OnSelectedIndexChanged(e); }
    protected override void OnDropDownClosed(EventArgs e) { Invalidate(); base.OnDropDownClosed(e); }
    protected override void OnDropDown(EventArgs e) { Invalidate(); base.OnDropDown(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    void Entry(Graphics g, int index, RectangleF r, bool closed, Color col) {
        if (index < 0 || index >= Items.Count) return;
        string t = GetItemText(Items[index]);
        float x = r.X + CoopTheme.Pf(10);
        Image th;
        if ((ThumbsClosed || !closed) && Thumbs.TryGetValue(t, out th) && th != null) {
            float h = r.Height - (closed ? 0 : CoopTheme.Pf(6)), w = h * 1.9f;
            var tr = new RectangleF(r.X + (closed ? 0 : CoopTheme.Pf(4)), r.Y + (r.Height - h) / 2f, w, h);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(th, tr);
            using (var p = new Pen(CoopTheme.LineDim, 1f)) g.DrawRectangle(p, tr.X, tr.Y, tr.Width - 1, tr.Height - 1);
            x = tr.Right + CoopTheme.Pf(14);
        }
        var st = g.Save(); g.SetClip(new RectangleF(x, r.Y, Math.Max(1, r.Right - x - CoopTheme.Pf(4)), r.Height), CombineMode.Intersect);
        CoopTheme.DrawLine(g, t.Replace(" - ", " " + (char)0x2013 + " "), Font, col, x, r.Y, r.Height, 0f);
        g.Restore(st);
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        CoopTheme.PaintParent(this, g);
        CoopTheme.DrawField(g, ClientRectangle, Focused || DroppedDown, hover && Enabled);
        float ab = CoopTheme.Pf(30), cx = Width - ab / 2f - CoopTheme.Pf(2), cy = Height / 2f, s = CoopTheme.Pf(5);
        using (var p = new Pen(Enabled ? CoopTheme.Text : CoopTheme.TextMute, CoopTheme.Pf(1.8))) { p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round; g.DrawLines(p, new[] { new PointF(cx - s, cy - s * 0.5f), new PointF(cx, cy + s * 0.5f), new PointF(cx + s, cy - s * 0.5f) }); }
        Entry(g, SelectedIndex, new RectangleF(CoopTheme.Pf(1), CoopTheme.Pf(1), Width - ab - CoopTheme.Pf(2), Height - CoopTheme.Pf(2)), true, Enabled ? ForeColor : CoopTheme.TextMute);
    }
    protected override void OnDrawItem(DrawItemEventArgs e) {
        if (e.Index < 0) return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        bool sel = (e.State & DrawItemState.Selected) != 0;
        using (var b = new SolidBrush(sel ? Color.FromArgb(58, 62, 40) : CoopTheme.Field)) g.FillRectangle(b, e.Bounds);
        if (sel) using (var b = new SolidBrush(CoopTheme.Gold)) g.FillRectangle(b, e.Bounds.X, e.Bounds.Y, CoopTheme.Px(3), e.Bounds.Height);
        Entry(g, e.Index, e.Bounds, false, sel ? CoopTheme.Gold : CoopTheme.Text);
    }
}

// numeric box (replaces NumericUpDown): Value / Minimum / Maximum / ValueChanged
public class MilSpin : Control {
    decimal val = 0, min = 0, max = 100; int hot = 0;
    public event EventHandler ValueChanged;
    public decimal Value {
        get { return val; }
        set { decimal v = Math.Max(min, Math.Min(max, value)); if (v != val) { val = v; Invalidate(); if (ValueChanged != null) ValueChanged(this, EventArgs.Empty); } }
    }
    public decimal Minimum { get { return min; } set { min = value; if (val < min) Value = min; Invalidate(); } }
    public decimal Maximum { get { return max; } set { max = value; if (val > max) Value = max; Invalidate(); } }
    public MilSpin() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(13f); TabStop = true;
    }
    public bool Stepper = false;     // [-] value [+] instead of a box with arrows
    float Bw { get { return CoopTheme.Pf(22); } }
    // which part is under x, y: 1 up / plus, 2 down / minus, 0 none
    int Part(int x, int y) {
        if (Stepper) return x >= Width - Height ? 1 : x < Height ? 2 : 0;
        return x >= Width - Bw - CoopTheme.Pf(4) ? (y < Height / 2 ? 1 : 2) : 0;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
    protected override void OnKeyDown(KeyEventArgs e) {
        if (e.KeyCode == Keys.Up) Value = val + 1; else if (e.KeyCode == Keys.Down) Value = val - 1;
        else if (e.KeyCode >= Keys.D0 && e.KeyCode <= Keys.D9) Value = e.KeyCode - Keys.D0;
        else if (e.KeyCode >= Keys.NumPad0 && e.KeyCode <= Keys.NumPad9) Value = e.KeyCode - Keys.NumPad0;
        base.OnKeyDown(e);
    }
    protected override void OnMouseDown(MouseEventArgs e) {
        Focus();
        int pt = Part(e.X, e.Y);
        if (e.Button == MouseButtons.Left && pt != 0) { if (pt == 1) Value = val + 1; else Value = val - 1; }
        base.OnMouseDown(e);
    }
    protected override void OnMouseWheel(MouseEventArgs e) { Value = val + (e.Delta > 0 ? 1 : -1); base.OnMouseWheel(e); }
    protected override void OnMouseMove(MouseEventArgs e) { int h = Enabled ? Part(e.X, e.Y) : 0; if (h != hot) { hot = h; Invalidate(); } Cursor = h != 0 ? Cursors.Hand : (Stepper ? Cursors.Default : Cursors.IBeam); base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = 0; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        Color c = Enabled ? ForeColor : CoopTheme.TextMute;
        if (Stepper) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int bh = Height;
            for (int k = 0; k < 2; k++) {
                bool plus = k == 1, can = Enabled && (plus ? val < max : val > min), h = hot == (plus ? 1 : 2) && can;
                var br = new RectangleF((plus ? Width - bh : 0) + 0.5f, 0.5f, bh - 1, bh - 1);
                using (var p = CoopTheme.Cut(br, CoopTheme.Pf(6), plus ? 2 : 8)) {
                    using (var b = new LinearGradientBrush(new RectangleF(br.X, br.Y - 1, br.Width, br.Height + 2), h ? Color.FromArgb(62, 66, 48) : Color.FromArgb(44, 47, 36), Color.FromArgb(25, 27, 21), 90f)) g.FillPath(b, p);
                    using (var pen = new Pen(h ? CoopTheme.Gold : can ? CoopTheme.Line : CoopTheme.LineDim, 1f)) g.DrawPath(pen, p);
                }
                float gs = bh * 0.42f;
                CoopTheme.Glyph(g, plus ? "plus" : "minus", new RectangleF(br.X + (br.Width - gs) / 2f, (bh - gs) / 2f, gs, gs), h ? CoopTheme.Gold : can ? CoopTheme.Text : CoopTheme.TextMute);
            }
            var fr = new Rectangle(bh + CoopTheme.Px(4), 0, Math.Max(1, Width - 2 * bh - CoopTheme.Px(8)), Height);
            using (var b = new SolidBrush(CoopTheme.Field)) g.FillRectangle(b, fr);
            using (var pen = new Pen(Focused ? CoopTheme.Amber : CoopTheme.LineDim, 1f)) g.DrawRectangle(pen, fr.X + 0.5f, 0.5f, fr.Width - 1, Height - 1);
            Font vf = CoopTheme.Head(16f); string vt = val.ToString("0");
            CoopTheme.DrawLine(g, vt, vf, Enabled ? CoopTheme.Gold : CoopTheme.TextMute, fr.X + (fr.Width - CoopTheme.TextWidth(g, vt, vf, 0f)) / 2f, 0, Height, 0f);
            return;
        }
        CoopTheme.DrawField(g, ClientRectangle, Focused, false);
        CoopTheme.DrawLine(g, val.ToString("0"), Font, c, CoopTheme.Pf(12), 0, Height, 0f);
        float bx = Width - Bw - CoopTheme.Pf(4), cx = bx + Bw / 2f, s = CoopTheme.Pf(4.5);
        using (var p = new Pen(CoopTheme.LineDim, 1f)) { g.DrawLine(p, bx, CoopTheme.Pf(5), bx, Height - CoopTheme.Pf(5)); g.DrawLine(p, bx + CoopTheme.Pf(3), Height / 2f, Width - CoopTheme.Pf(5), Height / 2f); }
        using (var b = new SolidBrush(hot == 1 ? CoopTheme.Gold : (val < max ? c : CoopTheme.TextMute))) g.FillPolygon(b, new[] { new PointF(cx - s, Height * 0.36f + s * 0.5f), new PointF(cx + s, Height * 0.36f + s * 0.5f), new PointF(cx, Height * 0.36f - s * 0.6f) });
        using (var b = new SolidBrush(hot == 2 ? CoopTheme.Gold : (val > min ? c : CoopTheme.TextMute))) g.FillPolygon(b, new[] { new PointF(cx - s, Height * 0.64f - s * 0.5f), new PointF(cx + s, Height * 0.64f - s * 0.5f), new PointF(cx, Height * 0.64f + s * 0.6f) });
    }
}

public class MilList : ListBox {
    // rows below ActionRows are clickable (one click acts): they show ActionText on the right
    public string ActionText = ""; public int ActionRows = 0;
    int hot = -1;
    public MilList() {
        DrawMode = DrawMode.OwnerDrawFixed; BorderStyle = BorderStyle.None; IntegralHeight = false;
        BackColor = CoopTheme.Field; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(12f); ItemHeight = CoopTheme.Px(26);
        CoopTheme.DarkScroll(this, "DarkMode_Explorer");
    }
    void Hot(int i) {
        if (i == hot) return;
        if (hot >= 0 && hot < Items.Count) Invalidate(GetItemRectangle(hot));
        hot = i;
        if (hot >= 0 && hot < Items.Count) Invalidate(GetItemRectangle(hot));
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        int i = IndexFromPoint(e.Location);
        if (i >= 0 && !GetItemRectangle(i).Contains(e.Location)) i = -1;
        Hot(ActionText.Length > 0 && i < ActionRows ? i : -1);
        Cursor = hot >= 0 ? Cursors.Hand : Cursors.Default;
        base.OnMouseMove(e);
    }
    protected override void OnMouseLeave(EventArgs e) { Hot(-1); base.OnMouseLeave(e); }
    protected override void OnDrawItem(DrawItemEventArgs e) {
        var g = e.Graphics;
        using (var b = new SolidBrush(CoopTheme.Field)) g.FillRectangle(b, e.Bounds);
        if (e.Index < 0 || e.Index >= Items.Count) return;
        bool sel = (e.State & DrawItemState.Selected) != 0;
        var r = e.Bounds;
        if (sel) {
            using (var lg = new LinearGradientBrush(new Rectangle(r.X - 1, r.Y, r.Width + 2, r.Height), Color.FromArgb(70, 72, 44), Color.FromArgb(30, 32, 22), 0f)) g.FillRectangle(lg, r);
            using (var b = new SolidBrush(CoopTheme.Gold)) g.FillRectangle(b, r.X, r.Y, CoopTheme.Px(3), r.Height);
        }
        using (var pen = new Pen(Color.FromArgb(40, CoopTheme.Line), 1f)) g.DrawLine(pen, r.X + CoopTheme.Px(8), r.Bottom - 1, r.Right - CoopTheme.Px(8), r.Bottom - 1);
        float gs = CoopTheme.Pf(14);
        bool act = ActionText.Length > 0 && e.Index < ActionRows, info = ActionText.Length > 0 && !act, hl = sel || e.Index == hot;
        if (e.Index == hot && !sel) using (var b = new SolidBrush(Color.FromArgb(40, 52, 32))) g.FillRectangle(b, r);
        float right = r.Right - CoopTheme.Pf(8);
        if (act) {
            Font af = CoopTheme.Head(10.5f); float trk = CoopTheme.Track(g, af, 0.16f);
            string at = ActionText.ToUpperInvariant(); float aw = CoopTheme.TextWidth(g, at, af, trk), ags = CoopTheme.Pf(11);
            right = r.Right - CoopTheme.Pf(10) - ags - CoopTheme.Pf(6) - aw;
            Color ac = hl ? CoopTheme.Gold : CoopTheme.TextDim;
            CoopTheme.DrawLine(g, at, af, ac, right, r.Y, r.Height, trk);
            CoopTheme.Glyph(g, "join", new RectangleF(right + aw + CoopTheme.Pf(6), r.Y + (r.Height - ags) / 2f, ags, ags), ac);
            right -= CoopTheme.Pf(10);
        }
        float tx = r.X + CoopTheme.Pf(30);
        if (info) tx = r.X + CoopTheme.Pf(10);
        else CoopTheme.Glyph(g, "tri", new RectangleF(r.X + CoopTheme.Pf(10), r.Y + (r.Height - gs) / 2f, gs, gs), hl ? CoopTheme.Gold : CoopTheme.TextMute);
        var st = g.Save(); g.SetClip(new RectangleF(tx, r.Y, Math.Max(1, right - tx), r.Height), CombineMode.Intersect);
        CoopTheme.DrawLine(g, GetItemText(Items[e.Index]), Font, info ? CoopTheme.TextMute : (hl ? CoopTheme.Gold : ForeColor), tx, r.Y, r.Height, 0f);
        g.Restore(st);
    }
}

public class MilCheck : CheckBox {
    public MilCheck() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; ForeColor = CoopTheme.Text; Font = CoopTheme.Body(11f); Cursor = Cursors.Hand;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { CoopTheme.PaintParent(this, e.Graphics); }
    public override Size GetPreferredSize(Size proposed) {
        Graphics g = CoopTheme.MeasureG;
        float lh = CoopTheme.LineH(g, Font);
        return new Size((int)Math.Ceiling(CoopTheme.Pf(18) + CoopTheme.Pf(8) + CoopTheme.TextWidth(g, Text, Font, 0f) + 2), (int)Math.Ceiling(Math.Max(lh, CoopTheme.Pf(18)) + CoopTheme.Pf(4)));
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        CoopTheme.PaintParent(this, g);
        float bs = CoopTheme.Pf(18), y = (Height - bs) / 2f;
        CoopTheme.DrawField(g, new Rectangle(0, (int)y, (int)bs, (int)bs), Focused, false);
        if (Checked) CoopTheme.Glyph(g, "check", new RectangleF(CoopTheme.Pf(2), y + CoopTheme.Pf(2), bs - CoopTheme.Pf(4), bs - CoopTheme.Pf(4)), Enabled ? CoopTheme.Gold : CoopTheme.TextMute);
        CoopTheme.DrawLine(g, Text, Font, Enabled ? ForeColor : CoopTheme.TextMute, bs + CoopTheme.Pf(8), 0, Height, 0f);
    }
}
'@

# ------------------------------------------------------------------------------------------------
# window
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$CoopCache = Join-Path $env:LOCALAPPDATA "CoD4Coop"
function Import-Theme {
    if ("CoopTheme" -as [type]) { return }
    $refs = @("System.Windows.Forms", "System.Drawing")
    # compiling takes a second or two, so the result is kept per launcher version
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ThemeCode))) -replace '-', '').Substring(0, 16)
    $dll = Join-Path $CoopCache "theme_$hash.dll"
    if (Test-Path $dll) { try { Add-Type -Path $dll; return } catch {} }
    try {
        [void](New-Item -ItemType Directory -Force -Path $CoopCache)
        Get-ChildItem $CoopCache -Filter "theme_*.dll" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $dll } | Remove-Item -Force -ErrorAction SilentlyContinue
        Add-Type -TypeDefinition $ThemeCode -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library
        if (-not ("CoopTheme" -as [type])) { Add-Type -Path $dll }
    } catch { if (-not ("CoopTheme" -as [type])) { Add-Type -TypeDefinition $ThemeCode -ReferencedAssemblies $refs } }
}
Import-Theme
# real pixels at 125/150% (before any window exists); point-size fonts then scale by themselves
[void][CoopTheme]::DpiAware()
# layout is written in 96-dpi pixels; S scales them (a test can force a scale with COOP_TEST_SCALE)
$dpiG = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); [CoopTheme]::Dpi = $dpiG.DpiX; $dpiG.Dispose()
[CoopTheme]::Scale = [CoopTheme]::Dpi / 96.0
if ($env:COOP_TEST_SCALE) { [CoopTheme]::Scale = [float]$env:COOP_TEST_SCALE; [CoopTheme]::FontScale = [float]$env:COOP_TEST_SCALE }
# main window layout (96-dpi px): header, (profile panel), tabs, page, bottom button, footer
$W = 720; $HeaderH = 86; $ProfileH = 84; $TabsH = 42; $PageH = 376; $PageGap = 10; $BottomH = 52; $FooterH = 30
$ColW = 338; $RightX = 350
$LayoutH = $HeaderH + 2 + $TabsH + $PageH + $PageGap + $BottomH + $FooterH
# a screen too short for the window at this DPI (1366x768 at 125%, 1080p at 150%): everything is drawn a little
# smaller instead of scrolling, measured with the profile panel folded out so that never scrolls either
$FitH = $LayoutH - 2 + $ProfileH
try {
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    if ($env:COOP_TEST_SCREEN) { $p = $env:COOP_TEST_SCREEN -split 'x'; $wa = New-Object System.Drawing.Rectangle 0, 0, ([int]$p[0]), ([int]$p[1]) }
    $tf = New-Object System.Windows.Forms.Form; $tf.FormBorderStyle = "FixedSingle"; $chrome = $tf.Height - $tf.ClientSize.Height + 4; $tf.Dispose()
    $fit = [Math]::Min(($wa.Height - $chrome) / $FitH, ($wa.Width - 24) / $W)
    if ($fit -lt [CoopTheme]::Scale -and $fit -ge 0.8) { [CoopTheme]::FontScale = [CoopTheme]::FontScale * $fit / [CoopTheme]::Scale; [CoopTheme]::Scale = $fit }
} catch {}
[CoopTheme]::ImagesDir = Join-Path $GameDir "main\images"
[CoopTheme]::CacheDir = Join-Path $CoopCache "art"
[CoopTheme]::LoadFonts((Join-Path $GameDir "Mods\coop\launcher\fonts"))
function S([double]$v) { return [CoopTheme]::Px($v) }
function New-Ctl([string]$type, [double]$x, [double]$y, [double]$w, [double]$h) {
    $c = New-Object $type
    $c.Location = New-Object System.Drawing.Point (S $x), (S $y)
    if ($w -gt 0) { $c.Size = New-Object System.Drawing.Size (S $w), (S $h) }
    return $c
}
function New-Lbl([string]$text, [double]$x, [double]$y, [double]$w, [double]$h, [switch]$Head, [double]$size = 11, [double]$track = 0) {
    $l = New-Ctl MilLabel $x $y $w $h; $l.Text = $text
    if ($Head) { $l.Font = [CoopTheme]::Head($size); $l.Upper = $true; $l.Tracking = $track; if (-not $track) { $l.Tracking = 0.1 } } else { $l.Font = [CoopTheme]::Body($size) }
    return $l
}
function New-Btn([string]$text, [double]$x, [double]$y, [double]$w, [double]$h, [string]$glyph = "", [int]$kind = 0) {
    $b = New-Ctl MilButton $x $y $w $h; $b.Text = $text; $b.Glyph = $glyph; $b.Kind = $kind
    if ($h -lt 40) { $b.Font = [CoopTheme]::Head(11) } else { $b.Font = [CoopTheme]::Head(15) }
    return $b
}
# a borderless text box inside a framed field (x, y, w, h = the field)
function New-Field([double]$x, [double]$y, [double]$w, [double]$h, [double]$size = 12.5) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.BorderStyle = "None"; $t.BackColor = [CoopTheme]::Field; $t.ForeColor = [CoopTheme]::Text; $t.Font = [CoopTheme]::Body($size)
    $pad = S 10
    $t.Location = New-Object System.Drawing.Point ((S $x) + $pad), ((S $y) + [int](((S $h) - $t.PreferredHeight) / 2))
    $t.Width = (S $w) - 2 * $pad
    $t | Add-Member -NotePropertyName FieldRect -NotePropertyValue (New-Object System.Drawing.Rectangle (S $x), (S $y), (S $w), (S $h))
    return $t
}
# frames text boxes/lists/pictures once they are on their parent
function Add-Frames($controls) {
    foreach ($c in $controls) {
        if ($c.PSObject.Properties["FieldRect"]) { $r = $c.FieldRect; [CoopTheme]::Frame($c, $c.Left - $r.Left, $c.Top - $r.Top, $r.Right - $c.Right, $r.Bottom - $c.Bottom) }
        else { [CoopTheme]::Frame($c, (S 3)) }
    }
}
# never taller/wider than the screen (a 1366x768 laptop at 125%): what does not fit scrolls instead of being cut off
function Fit-Screen($f) {
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    if ($env:COOP_TEST_SCREEN) { $p = $env:COOP_TEST_SCREEN -split 'x'; $wa = New-Object System.Drawing.Rectangle 0, 0, ([int]$p[0]), ([int]$p[1]) }
    $extraW = $f.Width - $f.ClientSize.Width; $extraH = $f.Height - $f.ClientSize.Height
    $cw = [Math]::Min($f.ClientSize.Width, $wa.Width - $extraW); $ch = [Math]::Min($f.ClientSize.Height, $wa.Height - $extraH)
    if ($cw -lt $f.ClientSize.Width -or $ch -lt $f.ClientSize.Height) {
        $f.AutoScroll = $true; $f.AutoScrollMinSize = $f.Canvas
        $f.ClientSize = New-Object System.Drawing.Size $cw, $ch
    }
}

$Missions = [ordered]@{
    # campaign order; missions chain by themselves, so starting at F.N.G. plays the whole campaign from the prologue
    "Prologue 1 - F.N.G. (killhouse)" = "killhouse"; "Prologue 2 - Crew Expendable (cargoship)" = "cargoship"; "Prologue 3 - The Coup (coup)" = "coup"
    "Act 1 - Blackout (blackout)" = "blackout"; "Act 1 - Charlie Don't Surf (armada)" = "armada"; "Act 1 - The Bog (bog_a)" = "bog_a"
    "Act 1 - Hunted (hunted)" = "hunted"; "Act 1 - Death From Above (ac130)" = "ac130"; "Act 1 - War Pig (bog_b)" = "bog_b"
    "Act 1 - Shock and Awe (airlift)" = "airlift"; "Act 1 - Aftermath (aftermath)" = "aftermath"
    "Act 2 - Safehouse (village_assault)" = "village_assault"; "Act 2 - All Ghillied Up (scoutsniper)" = "scoutsniper"
    "Act 2 - One Shot, One Kill (sniperescape)" = "sniperescape"; "Act 2 - Heat (village_defend)" = "village_defend"
    "Act 2 - The Sins of the Father (ambush)" = "ambush"
    "Act 3 - Ultimatum (icbm)" = "icbm"; "Act 3 - All In (launchfacility_a)" = "launchfacility_a"
    "Act 3 - No Fighting in the War Room (launchfacility_b)" = "launchfacility_b"; "Act 3 - Game Over (jeepride)" = "jeepride"
    "Epilogue - Mile High Club (airplane)" = "airplane"
}

$settings = @{ name = $env:USERNAME; mission = "cargoship"; squad = 2; bots = 0; skin = ""; botskin = ""; lastCode = "" }
if (Test-Path $SettingsFile) { try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } } catch {} }
# older launchers saved the skin names as whole PowerShell objects ({"value": "coop_x", "PSPath": ...})
foreach ($k in @("skin", "botskin")) { $v = $settings[$k]; if ($v -and $v -isnot [string]) { $settings[$k] = if ($v.value) { [string]$v.value } else { "" } } }
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

# layout (96-dpi px): header banner + player chip; profile panel (folds out under the header); LOBBY / SETTINGS tabs
# with the connection status; two columns of cards; the big next-step button; version / update footer
$form = New-Object CoopForm
$form.Text = "CoD4 Coop Campaign"; $form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"; $form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size (S $W), (S 610); $form.Canvas = $form.ClientSize
$form.Font = [CoopTheme]::Body(11)
[CoopTheme]::DarkScroll($form, "DarkMode_Explorer")     # if the window ever has to scroll, a dark scroll bar
# tooltips in the theme (the system ones are white boxes)
function New-Tip {
    $t = New-Object System.Windows.Forms.ToolTip; $t.OwnerDraw = $true; $t.InitialDelay = 400; $t.AutoPopDelay = 15000
    $t.Add_Popup({ param($s, $e)
        $txt = $s.GetToolTip($e.AssociatedControl)
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($txt, [CoopTheme]::Body(10.5), (New-Object System.Drawing.Size (S 340), 0), [System.Windows.Forms.TextFormatFlags]::WordBreak)
        $e.ToolTipSize = New-Object System.Drawing.Size ($sz.Width + (S 18)), ($sz.Height + (S 12))
    })
    $t.Add_Draw({ param($s, $e)
        $g = $e.Graphics; $r = $e.Bounds
        $b = New-Object System.Drawing.SolidBrush ([CoopTheme]::PanelBg); $g.FillRectangle($b, $r); $b.Dispose()
        $p = New-Object System.Drawing.Pen ([CoopTheme]::Line); $g.DrawRectangle($p, 0, 0, $r.Width - 1, $r.Height - 1); $p.Dispose()
        $tr = New-Object System.Drawing.Rectangle (S 9), (S 6), ($r.Width - (S 18)), ($r.Height - (S 12))
        [System.Windows.Forms.TextRenderer]::DrawText($g, $e.ToolTipText, [CoopTheme]::Body(10.5), $tr, [CoopTheme]::Text, [System.Windows.Forms.TextFormatFlags]::WordBreak)
    })
    return $t
}
$gameIcon = Join-Path $GameDir "cod4.ico"
if (Test-Path $gameIcon) { try { $form.Icon = New-Object System.Drawing.Icon $gameIcon } catch {} }
# banner: battlefield art + logo decoded from the player's own game files (procedural fallback inside Header)
try { $form.HeaderArt = [CoopTheme]::Header((S $W), (S $HeaderH), [string[]]@("background_american_w", "loadscreen_mp_bog", "loadscreen_mp_crash"), "bg_back", "cod4", "Co-op Campaign") } catch {}
function New-Surface([double]$x, [double]$y, [double]$w, [double]$h) { $s = New-Ctl MilSurface $x $y $w $h; return $s }
function Add-Card($surface, [double]$x, [double]$y, [double]$w, [double]$h, [string]$title) { return $surface.AddCard((S $x), (S $y), (S $w), (S $h), $title) }

# skins in the installed skin pack (tools/skin): everyone in the session needs the same pack to see them
$skinFile = Join-Path $GameDir "Mods\coop\skins.txt"
function Read-SkinNames { if (Test-Path $skinFile) { return @([IO.File]::ReadAllLines($skinFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } return @() }
$script:SkinNames = @(Read-SkinNames)
function Fill-SkinBox($b, [string]$current) {
    $b.Items.Clear()
    [void]$b.Items.Add("Soldier (default)")
    foreach ($n in $script:SkinNames) { [void]$b.Items.Add(($n -replace '^coop_', '')) }
    $b.SelectedIndex = 0
    for ($i = 0; $i -lt $script:SkinNames.Count; $i++) { if ($script:SkinNames[$i] -eq $current) { $b.SelectedIndex = $i + 1 } }
}
function New-SkinBox([string]$current, [double]$x, [double]$y, [double]$w) {
    $b = New-Ctl MilCombo $x $y $w 0; $b.ItemHeight = S 28; $b.Width = S $w; $b.DropDownHeight = S 300
    Fill-SkinBox $b $current
    return $b
}
function Get-SkinChoice($b) { if ($b.SelectedIndex -le 0) { return "" } return [string]($script:SkinNames[$b.SelectedIndex - 1]).Trim() }

# --- header: player chip (click: edit the profile)
$chip = New-Object MilChip; $chip.Text = $settings.name
function Place-Chip {
    $chipW = $chip.GetPreferredSize([System.Drawing.Size]::Empty).Width    # ($w would be $W: names ignore case)
    $chip.Size = New-Object System.Drawing.Size $chipW, (S 34)
    $chip.Location = New-Object System.Drawing.Point ((S ($W - 16)) - $chipW), ((S 18) + $form.AutoScrollPosition.Y)
}
Place-Chip

# --- profile panel: name, own skin, Done (saves)
$pnlProfile = New-Surface 16 $HeaderH ($W - 32) ($ProfileH - 6); $pnlProfile.Visible = $false
$cardProfile = Add-Card $pnlProfile 0 0 ($W - 32) ($ProfileH - 6) "Edit player profile"
$lblName = New-Lbl "Username" 14 37 84 32 -Head -size 11.5
$txtName = New-Field 98 37 210 32 13; $txtName.Text = $settings.name; $txtName.MaxLength = 24
$lblSkin = New-Lbl "Player skin" 322 37 92 32 -Head -size 11.5
$cmbSkin = New-SkinBox $settings.skin 414 38 166
$btnDone = New-Btn "Done" 592 37 82 32 "check"
$pnlProfile.Controls.AddRange(@($lblName, $txtName, $lblSkin, $cmbSkin, $btnDone))
Add-Frames @($txtName)

# --- tabs + connection status
$tabStrip = New-Ctl MilTabStrip 16 0 ($W - 32) 36

# --- lobby page
$pageLobby = New-Surface 16 0 ($W - 32) $PageH
$cardMission = Add-Card $pageLobby 0 0 $ColW 200 "Mission"
$cardAI = Add-Card $pageLobby 0 208 $ColW ($PageH - 208) "AI teammates"
$cardSquad = Add-Card $pageLobby $RightX 0 $ColW 148 "Squad"
$cardInvite = Add-Card $pageLobby $RightX 156 $ColW ($PageH - 156) "Invite / Connect"

# mission pictures: the game's own mission art (main\images\<map>.iwi), or the closest multiplayer loading screen
$MissionArt = @{ killhouse = "killhouse"; cargoship = "cargoship"; coup = "coup"; blackout = "blackout"; armada = "armada"; bog_a = "bog_a"; hunted = "hunted"
    ac130 = "ac130"; bog_b = "bog_b"; airlift = "airlift"; aftermath = "aftermath"; village_assault = "village_assault"; scoutsniper = "loadscreen_mp_overgrown"
    sniperescape = "loadscreen_mp_bloc"; village_defend = "loadscreen_mp_farm"; ambush = "ambush"; icbm = "icbm"; launchfacility_a = "loadscreen_mp_countdown"
    launchfacility_b = "loadscreen_mp_countdown"; jeepride = "loadscreen_mp_convoy"; airplane = "airplane" }
$tileMis = New-Ctl MilTile 12 42 314 104
$cmbMis = New-Ctl MilCombo 12 156 314 0; $cmbMis.ItemHeight = S 30; $cmbMis.Width = S 314; $cmbMis.DropDownHeight = S 420; $cmbMis.DropDownWidth = S 460
$cmbMis.ThumbsClosed = $false
foreach ($k in $Missions.Keys) {
    [void]$cmbMis.Items.Add($k); if ($Missions[$k] -eq $settings.mission) { $cmbMis.SelectedItem = $k }
    try { $cmbMis.Thumbs[$k] = [CoopTheme]::Thumb($MissionArt[$Missions[$k]], (S 64), (S 34)) } catch {}
}
if (-not $cmbMis.SelectedItem) { $cmbMis.SelectedIndex = 1 }
$script:tileThumbs = @{}
# "Act 1 - Blackout (blackout)" -> ACT 1 / BLACKOUT, with the mission's picture
function Update-MissionTile([string]$label) {
    if (-not $label) { $label = [string]$cmbMis.SelectedItem }
    $kick = ""; $title = $label; $map = ""
    if ($label -match '^(.+?) - (.+?)(?: \(([A-Za-z0-9_]+)\))?$') { $kick = $Matches[1]; $title = $Matches[2]; $map = $Matches[3] }
    $tileMis.Kicker = $kick; $tileMis.Title = $title
    $tileMis.Sub = $(if ($script:joining) { "Picked by $($script:joining.host)" } else { "Selected campaign level" })
    if ($map -and -not $script:tileThumbs.ContainsKey($map)) { try { $script:tileThumbs[$map] = [CoopTheme]::Thumb($MissionArt[$map], $tileMis.Width, $tileMis.Height) } catch { $script:tileThumbs[$map] = $null } }
    $tileMis.Thumb = $(if ($map) { $script:tileThumbs[$map] } else { $null })
}
$lblBots = New-Lbl "Bots" 14 248 120 36 -Head -size 12
$numBots = New-Ctl MilSpin 196 248 128 36; $numBots.Stepper = $true; $numBots.Minimum = 0; $numBots.Maximum = 3; $numBots.Value = [int]$settings.bots
$lblBotSkin = New-Lbl "Bot skin" 14 292 86 34 -Head -size 12
$cmbBotSkin = New-SkinBox $settings.botskin 106 293 220
$lblBotHint = New-Lbl "AI squadmates fight next to you and wear the bot skin. Up to 3." 14 334 312 32 -size 10.5; $lblBotHint.ForeColor = [CoopTheme]::TextDim; $lblBotHint.Middle = $false
$lstLobby = New-Ctl MilLobby ($RightX + 12) 40 ($ColW - 24) 100; $lstLobby.Header = $false; $lstLobby.IdleHost = $settings.name; $lstLobby.IdleBots = [int]$numBots.Value
$pageLobby.Controls.AddRange(@($tileMis, $cmbMis, $lblBots, $numBots, $lblBotSkin, $cmbBotSkin, $lblBotHint, $lstLobby))

# invite / connect card: one of three panels (idle: code + games on the network, hosting: join codes, joined: the host's lobby)
$ix = $RightX + 12; $iy = 156 + 38; $iw = $ColW - 24
$pnlIdle = New-Surface $ix $iy $iw 132
$lblHave = New-Lbl "Have an invite code?" 0 0 $iw 20 -size 11; $lblHave.ForeColor = [CoopTheme]::TextDim
$txtCode = New-Field 0 22 198 32 13; $txtCode.Text = $settings.lastCode
$btnJoin = New-Btn "Join lobby" 206 22 108 32 "" 0
$lblLan = New-Lbl "Games on your network" 0 62 260 24 -Head -size 10.5 -track 0.12; $lblLan.Glyph = "slash"; $lblLan.GlyphColor = [CoopTheme]::Line; $lblLan.ForeColor = [CoopTheme]::TextDim
$btnFind = New-Btn "" 288 62 26 24 "refresh"
$lstLan = New-Ctl MilList 3 91 ($iw - 6) 38; $lstLan.ItemHeight = S 19; $lstLan.Font = [CoopTheme]::Body(11); $lstLan.ActionText = "Join"
$pnlIdle.Controls.AddRange(@($lblHave, $txtCode, $btnJoin, $lblLan, $btnFind, $lstLan))
Add-Frames @($txtCode, $lstLan)
$tipMain = New-Tip
$tipMain.SetToolTip($btnFind, "Look again for games on your network (and Tailscale)")

$pnlHost = New-Surface $ix $iy $iw 170; $pnlHost.Visible = $false
$codeRows = @()
for ($i = 0; $i -lt 3; $i++) {
    $y = $i * 44
    $k = New-Lbl "" 0 $y 220 16 -Head -size 9.5 -track 0.16; $k.ForeColor = [CoopTheme]::TextDim
    $c = New-Lbl "" 0 ($y + 15) 220 26 -Head -size 16 -track 0.1; $c.ForeColor = [CoopTheme]::Gold
    $b = New-Btn "Copy" 230 ($y + 8) 84 28 "copy"; $b.Tag = $i
    $codeRows += , @{ kind = $k; code = $c; copy = $b }
    $pnlHost.Controls.AddRange(@($k, $c, $b))
}
$lblNotes = New-Lbl "" 0 92 $iw 76 -size 10; $lblNotes.ForeColor = [CoopTheme]::TextDim; $lblNotes.Middle = $false; $lblNotes.Fit = $true
$pnlHost.Controls.Add($lblNotes)

$pnlJoined = New-Surface $ix $iy $iw 132; $pnlJoined.Visible = $false
$lblJoinedKick = New-Lbl "You are in" 0 0 $iw 16 -Head -size 9.5 -track 0.16; $lblJoinedKick.ForeColor = [CoopTheme]::TextDim
$lblJoinedHost = New-Lbl "" 0 16 $iw 30 -Head -size 16 -track 0.06; $lblJoinedHost.ForeColor = [CoopTheme]::Gold
$lblJoinedMis = New-Lbl "" 0 46 $iw 22 -size 11; $lblJoinedMis.ForeColor = [CoopTheme]::Text
$btnLeave = New-Btn "Leave lobby" 0 78 150 32 "leave"
$pnlJoined.Controls.AddRange(@($lblJoinedKick, $lblJoinedHost, $lblJoinedMis, $btnLeave))

# status line of the card: join progress, the host's messages, first-start setup
$lblJoinStatus = New-Lbl "Paste the code your friend copied, or pick their game in the list." $ix ($iy + 132) $iw 44 -size 10.5
$lblJoinStatus.ForeColor = [CoopTheme]::Amber; $lblJoinStatus.Middle = $false; $lblJoinStatus.Fit = $true
# the whole message on hover, when it had to be cut
$lblJoinStatus.Add_TextChanged({ $tipMain.SetToolTip($lblJoinStatus, $lblJoinStatus.Text) })
$lblNotes.Add_TextChanged({ $tipMain.SetToolTip($lblNotes, $lblNotes.Text) })
$pageLobby.Controls.AddRange(@($pnlIdle, $pnlHost, $pnlJoined, $lblJoinStatus))

# --- settings page (skins); filled in further down
$pageSettings = New-Surface 16 0 ($W - 32) $PageH; $pageSettings.Visible = $false
$cardSkins = Add-Card $pageSettings 0 0 ($W - 32) $PageH "Your skins"

# --- bottom: the next step (Host lobby / Launch game + Close lobby / Waiting for host...), version + update
$btnHost = New-Btn "Host lobby" 16 0 ($W - 32) 46 "play" 1
$btnLaunch = New-Btn "Launch game" 16 0 452 46 "play" 1; $btnLaunch.Visible = $false
$btnUpdate = New-Btn "" ($W - 196) 0 180 26 "up" 1; $btnUpdate.Visible = $false
$lblUpdate = New-Lbl "Version $(Get-InstalledVersion)" 16 0 490 26 -Head -size 10.5 -track 0.14; $lblUpdate.AutoGlyph = $true; $lblUpdate.ForeColor = [CoopTheme]::TextDim
$form.Controls.AddRange(@($chip, $pnlProfile, $tabStrip, $pageLobby, $pageSettings, $btnHost, $btnLaunch, $btnUpdate, $lblUpdate))

# never taller than the screen: what does not fit scrolls (a 1366x768 laptop at 125%)
function Apply-Size {
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    if ($form.IsHandleCreated) { $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea }
    if ($env:COOP_TEST_SCREEN) { $p = $env:COOP_TEST_SCREEN -split 'x'; $wa = New-Object System.Drawing.Rectangle 0, 0, ([int]$p[0]), ([int]$p[1]) }
    # the border is measured with the scroll bars off (a shown scroll bar is not border), and the scroll bars
    # are added after the size is set, inside it
    $form.AutoScrollMinSize = [System.Drawing.Size]::Empty; $form.AutoScroll = $false
    $extraW = $form.Width - $form.ClientSize.Width; $extraH = $form.Height - $form.ClientSize.Height
    $cv = $form.Canvas
    $maxW = $wa.Width - $extraW; $maxH = $wa.Height - $extraH
    $sbW = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth; $sbH = [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight
    $needV = $cv.Height -gt $maxH
    $needH = ($cv.Width + $(if ($needV) { $sbW } else { 0 })) -gt $maxW
    if ($needH -and -not $needV) { $needV = ($cv.Height + $sbH) -gt $maxH }
    $cw = [Math]::Min($cv.Width + $(if ($needV) { $sbW } else { 0 }), $maxW)
    $ch = [Math]::Min($cv.Height + $(if ($needH) { $sbH } else { 0 }), $maxH)
    $form.ClientSize = New-Object System.Drawing.Size $cw, $ch
    if ($needV -or $needH) { $form.AutoScroll = $true; $form.AutoScrollMinSize = $cv }
    if ($form.Visible -and $form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
}
$script:profileOpen = $false
$script:bottomY = 0
function Do-Layout {
    # size the window first (that resets any scrolling), then place everything
    $form.Canvas = New-Object System.Drawing.Size (S $W), (S ($LayoutH + $(if ($script:profileOpen) { $ProfileH - 2 } else { 0 })))
    Apply-Size
    $sy = $form.AutoScrollPosition.Y
    $y = $HeaderH
    if ($script:profileOpen) { $pnlProfile.Location = New-Object System.Drawing.Point (S 16), ((S $y) + $sy); $pnlProfile.Visible = $true; $y += $ProfileH }
    else { $pnlProfile.Visible = $false; $y += 2 }
    $tabStrip.Location = New-Object System.Drawing.Point (S 16), ((S $y) + $sy); $y += $TabsH
    $pageLobby.Location = New-Object System.Drawing.Point (S 16), ((S $y) + $sy)
    $pageSettings.Location = $pageLobby.Location; $y += $PageH + $PageGap
    $script:bottomY = $y; $y += $BottomH
    $lblUpdate.Top = (S $y) + $sy; $btnUpdate.Top = (S $y) + $sy; $y += $FooterH
    Place-Bottom
    Place-Chip
    $form.Redraw()
}
function Place-Bottom {
    $by = (S $script:bottomY) + $form.AutoScrollPosition.Y
    if ($script:lobby) {      # (Visible reads false until the window is shown)
        $btnLaunch.Bounds = New-Object System.Drawing.Rectangle (S 16), $by, (S 452), (S 44)
        $btnHost.Bounds = New-Object System.Drawing.Rectangle (S 480), $by, (S ($W - 496)), (S 44)
    } else {
        foreach ($b in @($btnHost, $btnLaunch)) { $b.Bounds = New-Object System.Drawing.Rectangle (S 16), $by, (S ($W - 32)), (S 44) }
    }
}
function Toggle-Profile([bool]$open) {
    $script:profileOpen = $open; $chip.Active = $open
    Do-Layout
    if ($open) { [void]$txtName.Focus(); $txtName.SelectionStart = $txtName.TextLength }
}
function Save-Profile {
    $old = $settings.name
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = $env:USERNAME }
    if ($txtName.Text -ne $settings.name) { $txtName.Text = $settings.name }      # an empty name shows the Windows user name again
    $settings.skin = Get-SkinChoice $cmbSkin; Save-Settings
    $chip.Text = $settings.name; Place-Chip
    # in someone's lobby: show the new name as ours right away (the host hears it with the next heartbeat)
    if ($script:joining -and $old -ne $settings.name) {
        $nm = @($script:joining.names)
        for ($i = $nm.Count - 1; $i -ge 1; $i--) { if ($nm[$i] -eq $old) { $nm[$i] = $settings.name; break } }
        $script:joining.names = $nm
        $script:joining.lastSend = [datetime]::MinValue
    }
    if ($script:lobby) { Update-LobbyList } elseif ($script:joining) { Update-Squad }
}
$chip.Add_Click({ if ($script:profileOpen) { Save-Profile }; Toggle-Profile (-not $script:profileOpen) })
$btnDone.Add_Click({ Save-Profile; Toggle-Profile $false })
$txtName.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq "Enter") { $e.SuppressKeyPress = $true; $btnDone.PerformClick() } })
$txtName.Add_TextChanged({ $n = $txtName.Text.Trim(); if (-not $n) { $n = $env:USERNAME }; $lstLobby.IdleHost = $n; $chip.Text = $n; Place-Chip })
$tabStrip.Add_SelectedIndexChanged({ $pageLobby.Visible = $tabStrip.SelectedIndex -eq 0; $pageSettings.Visible = $tabStrip.SelectedIndex -eq 1 })
$cmbMis.Add_SelectedIndexChanged({ if (-not $script:joining) { Update-MissionTile } })
$txtCode.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq "Enter") { $e.SuppressKeyPress = $true; $btnJoin.PerformClick() } })

$script:hostingProc = $null
$script:mainCode = ""
$script:lanGames = @()
$script:setupActive = $false

$script:lobby = $null        # host lobby: socket + members (key "ip:port" -> name, endpoint, last seen)
$script:codes = @()           # @{ label; code } in order of preference
$script:joining = $null      # in someone's lobby: socket, host, mission, names
$script:setupFailed = $false
$script:ownPick = $null       # your own mission / bots while the card shows the host's (restored on leaving)
$script:hostNotes = @()
function Test-InGame { return [bool]($script:hostingProc -and -not $script:hostingProc.HasExited) }
function Get-SquadCount {
    if ($script:lobby) { return 1 + [int]$numBots.Value + $script:lobby.members.Count }
    if ($script:joining) { return [Math]::Max(1, $lstLobby.Items.Count) }
    return 1 + [int]$numBots.Value
}
# 4 players at most: while hosting, every friend in the lobby takes a bot's place
function Update-BotCap {
    $m = 3; if ($script:lobby) { $m = [Math]::Max(0, 3 - $script:lobby.members.Count) }
    if ($numBots.Maximum -ne $m) { $numBots.Maximum = $m }
}
function Set-CardRight($card, [string]$text) { if ($card.Right -ne $text) { $card.Right = $text; $pageLobby.Redraw() } }
function Update-Status {
    if ($script:setupActive) { $tabStrip.Status = "Setting up..."; $tabStrip.StatusKind = 2 }
    elseif ($script:setupFailed) { $tabStrip.Status = "Setup failed"; $tabStrip.StatusKind = 2 }
    elseif ($script:lobby) { $tabStrip.Status = "Hosting - $(Get-SquadCount)/4"; $tabStrip.StatusKind = 1 }
    elseif ($script:joining) { $tabStrip.Status = "In $($script:joining.host)'s lobby"; $tabStrip.StatusKind = 1 }
    elseif (Test-InGame) { $tabStrip.Status = "Hosting - in game"; $tabStrip.StatusKind = 1 }
    else { $tabStrip.Status = "Not connected"; $tabStrip.StatusKind = 0 }
}
# squad list: hosting = you + bots + friends; joined = the host's list (host first); idle = you + bots (drawn by the list)
function Update-Squad {
    Update-BotCap
    $lstLobby.Items.Clear()
    if ($script:lobby) {
        [void]$lstLobby.Items.Add("$($settings.name) (you, host)")
        for ($b = 1; $b -le [int]$numBots.Value; $b++) { [void]$lstLobby.Items.Add("Bot $b") }
        foreach ($m in $script:lobby.members.Values) { [void]$lstLobby.Items.Add($m.name) }
    } elseif ($script:joining) {
        $names = @($script:joining.names | Where-Object { $_ })
        if (-not $names.Count) { $names = @($script:joining.host, $settings.name) }
        $me = -1; for ($i = $names.Count - 1; $i -ge 1; $i--) { if ($names[$i] -eq $settings.name) { $me = $i; break } }
        for ($i = 0; $i -lt $names.Count; $i++) {
            if ($i -eq 0) { [void]$lstLobby.Items.Add("$($names[$i]) (host)") } elseif ($i -eq $me) { [void]$lstLobby.Items.Add("$($names[$i]) (you)") } else { [void]$lstLobby.Items.Add($names[$i]) }
        }
    }
    Set-CardRight $cardSquad "$([Math]::Min(4, (Get-SquadCount))) / 4"
    Update-Status
}
function Update-LobbyList { Update-Squad }
# what the window shows for idle / hosting a lobby / hosting a running game / in someone's lobby
$script:lastMode = "idle"
function Update-Mode {
    $hosting = [bool]$script:lobby; $joined = [bool]$script:joining
    $inGame = Test-InGame
    # hosting a running game: the codes stay up, friends can still join with them
    $hostGame = -not $hosting -and -not $joined -and $inGame -and $script:codes.Count -gt 0
    $idle = -not $hosting -and -not $joined -and -not $hostGame
    $pnlIdle.Visible = $idle
    $pnlHost.Visible = $hosting -or $hostGame
    $pnlJoined.Visible = $joined
    $lblJoinStatus.Visible = -not ($hosting -or $hostGame)
    if ($hosting) {
        $btnLaunch.Text = "Launch game"; $btnLaunch.Glyph = "play"; $btnLaunch.Kind = 1; $btnLaunch.Enabled = $true; $btnLaunch.Visible = $true
        $btnHost.Text = "Close lobby"; $btnHost.Glyph = ""; $btnHost.Kind = 0; $btnHost.Enabled = $true; $btnHost.Visible = $true
    } elseif ($joined) {
        $btnHost.Visible = $false
        $btnLaunch.Text = "Waiting for host..."; $btnLaunch.Glyph = ""; $btnLaunch.Enabled = $false; $btnLaunch.Visible = $true
    } elseif ($hostGame) {
        $btnLaunch.Visible = $false
        $btnHost.Text = "Game running"; $btnHost.Glyph = ""; $btnHost.Kind = 0; $btnHost.Enabled = $false; $btnHost.Visible = $true
    } else {
        $btnLaunch.Visible = $false
        $btnHost.Visible = $true; $btnHost.Kind = 1
        if ($script:setupFailed) { $btnHost.Text = "Retry setup"; $btnHost.Glyph = "refresh"; $btnHost.Enabled = $true }
        else { $btnHost.Text = "Host lobby"; $btnHost.Glyph = "play"; $btnHost.Enabled = -not $script:setupActive -and -not $inGame }
    }
    # no joining while the coop hooks are not installed, or while your own hosted game runs (a second game)
    $btnJoin.Enabled = -not ($script:setupActive -or $script:setupFailed -or $inGame)
    $btnFind.Enabled = -not $inGame; $lstLan.Enabled = -not $inGame
    # in someone's lobby the card shows the host's mission and bots (set in Set-JoinedInfo)
    # (and while your hosted game runs, its mission and bots are set)
    $fixed = $joined -or $hostGame
    $cmbMis.Enabled = -not $fixed; $numBots.Enabled = -not $fixed; $cmbBotSkin.Enabled = -not $fixed
    $lblBotSkin.Visible = -not $joined; $cmbBotSkin.Visible = -not $joined
    $lblBotHint.Top = S $(if ($joined) { 292 } else { 334 })
    $lblBotHint.Text = $(if ($joined) { "The host picks the mission and the bots, and their skin." } else { "AI squadmates fight next to you and wear the bot skin. Up to 3." })
    if (-not $joined) { Update-MissionTile }
    Place-Bottom
    Update-Squad
    # back to idle (left or closed a lobby, the hosted game ended): look for games on the network again
    $mode = $(if ($idle) { "idle" } else { "busy" })
    if ($idle -and $script:lastMode -ne "idle" -and $script:autoFind) { $findTimer.Stop(); $findTimer.Start() }
    $script:lastMode = $mode
}
function Show-Codes([string[]]$notes) {
    for ($i = 0; $i -lt 3; $i++) {
        $r = $codeRows[$i]; $on = $i -lt $script:codes.Count
        foreach ($c in @($r.kind, $r.code, $r.copy)) { $c.Visible = $on }
        if ($on) { $r.kind.Text = "$($script:codes[$i].label) code"; $r.code.Text = $script:codes[$i].code; $r.copy.Text = "Copy" }
    }
    $top = 44 * [Math]::Max(1, $script:codes.Count) + 2
    $lblNotes.Bounds = New-Object System.Drawing.Rectangle 0, (S $top), (S $iw), ([Math]::Max((S 20), $pnlHost.Height - (S $top)))
    $lblNotes.Text = (@($notes | Where-Object { $_ }) -join "`r`n")
}
# "Copied" for 2 seconds
$copyTimer = New-Object System.Windows.Forms.Timer; $copyTimer.Interval = 2000
$copyTimer.Add_Tick({ $copyTimer.Stop(); foreach ($r in $codeRows) { $r.copy.Text = "Copy" } })
function Copy-Code([int]$i) {
    if ($i -ge $script:codes.Count) { return }
    # another program may hold the clipboard for a moment: try again a few times
    $ok = $false
    for ($t = 0; $t -lt 4 -and -not $ok; $t++) { try { [System.Windows.Forms.Clipboard]::SetText($script:codes[$i].code); $ok = $true } catch { Start-Sleep -Milliseconds 60 } }
    for ($k = 0; $k -lt 3; $k++) { $codeRows[$k].copy.Text = $(if ($k -ne $i) { "Copy" } elseif ($ok) { "Copied" } else { "Retry" }) }
    $copyTimer.Stop(); $copyTimer.Start()
}
foreach ($r in $codeRows) { $r.copy.Add_Click({ param($s, $e) Copy-Code ([int]$s.Tag) }) }

# first start: the coop scripts are built from the player's own game files in the background
function Start-Setup {
    $script:setupActive = $true; $script:setupFailed = $false; Update-Mode
    try { Start-CoopInstall; $setupTimer.Start() }
    catch {
        $lblJoinStatus.Text = "Setup failed. Is this the CoD4 1.0 game folder (iw3sp.exe, zone\english)? $($_.Exception.Message)"
        $script:setupActive = $false; $script:setupFailed = $true; Update-Mode
    }
}

$btnHost.Add_Click({
    try {
        if ($script:lobby) { Close-Lobby; return }
        if ($script:setupFailed) { Start-Setup; return }
        if ($script:setupActive -or (Test-InGame)) { return }
        $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = $env:USERNAME }
        $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.bots = [int]$numBots.Value
        $settings.skin = Get-SkinChoice $cmbSkin; $settings.botskin = Get-SkinChoice $cmbBotSkin; Save-Settings
        $btnHost.Enabled = $false; $lblJoinStatus.Text = "Opening the game port on your router..."; $form.Refresh()
        $addr = Get-LocalAddresses
        $public = $null
        if ($addr.lan) { $public = Open-RouterPort $addr.lan }
        # Tailscale/VPN first: it works through any router; then the internet code (UPnP), then same network
        $script:codes = @()
        if ($addr.vpn) { $script:codes += @{ label = "$($addr.vpnName)"; code = (Encode-JoinCode $addr.vpn $Port) } }
        if ($public) { $script:codes += @{ label = "internet"; code = (Encode-JoinCode $public $Port) } }
        if ($addr.lan) { $script:codes += @{ label = "same network"; code = (Encode-JoinCode $addr.lan $Port) } }
        $notes = @()
        if (-not $public) { $notes += "Router did not open the port: use the $(if ($addr.vpn) { "$($addr.vpnName) code" } else { 'same network code' }), or forward UDP $Port." }
        if (-not $addr.vpn) { $notes += "No Tailscale/ZeroTier found: friends outside your network need the internet code." }
        if (-not $script:codes.Count) { $notes += "No network found on this PC." }
        $u = New-Object System.Net.Sockets.UdpClient $Port
        try { [void]$u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}
        $script:lobby = @{ u = $u; members = [ordered]@{} }
        $script:hostNotes = $notes
        Show-Codes $notes
        Start-PackServer
        $lblJoinStatus.Text = ""
        Update-Mode
    } catch {
        # the hint first: a long system message is cut at the end of the line (all of it is in the tooltip)
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        $why = $ex.Message
        if ($ex -is [System.Net.Sockets.SocketException] -and $ex.ErrorCode -eq 10048) { $why = "port $Port is already in use" }
        $script:codes = @(); Close-RouterPort
        $lblJoinStatus.Text = "Could not open the lobby. Is the game already running on this PC? ($why)"
        Update-Mode
    }
})
# goodbye (type 11): "closed" from a host to its lobby, "full" to a 5th player, "left" from a player to the host
function Send-Bye($u, $eps, [string]$why) {
    for ($r = 0; $r -lt 2; $r++) { foreach ($ep in @($eps | Where-Object { $_ })) { Send-Packet $u $ep 11 $why } }
}
function Close-Lobby {
    if ($script:lobby) {
        Send-Bye $script:lobby.u @($script:lobby.members.Values | ForEach-Object { $_.ep }) "closed"
        try { $script:lobby.u.Close() } catch {}
    }
    $script:lobby = $null; $script:codes = @()
    Stop-PackServer
    Close-RouterPort
    $lblJoinStatus.Text = "Lobby closed."
    Update-Mode
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
                    Send-Packet $L.u $pk.from 7 ("{0}|lobby|{1}|4" -f $settings.name, [Math]::Min(4, (1 + $L.members.Count + [int]$numBots.Value)))
                } elseif ($pk.type -eq 8) {
                    $nm = ($pk.text -replace '[|,~"]', '').Trim(); if (-not $nm) { $nm = "Player" }
                    $old = $null; if ($L.members.Contains($key)) { $old = $L.members[$key] }
                    if (-not $old -and 1 + $L.members.Count -ge 4) { Send-Packet $L.u $pk.from 11 "full"; continue }
                    $L.members[$key] = @{ name = $nm; ep = $pk.from; seen = $now }
                    # a newcomer (who may take a bot's place) or a new name: the list first, then the answer
                    if (-not $old -or $old.name -ne $nm) { Update-LobbyList }
                    $nb = [int]$numBots.Value
                    $names = @($settings.name) + @(if ($nb -gt 0) { 1..$nb | ForEach-Object { "Bot $_" } }) + @($L.members.Values | ForEach-Object { $_.name })
                    Send-Packet $L.u $pk.from 9 ("{0}|{1}" -f $cmbMis.SelectedItem, ($names -join ","))
                } elseif ($pk.type -eq 11) {
                    if ($L.members.Contains($key)) { $L.members.Remove($key); Update-LobbyList }
                }
            }
            $gone = @($L.members.Keys | Where-Object { ($now - $L.members[$_].seen).TotalSeconds -gt 30 })  # tolerate network hiccups
            foreach ($k in $gone) { $L.members.Remove($k) }
            if ($gone.Count) { Update-LobbyList }
        }
        if ($script:joining) { Step-JoinLobby }
        Step-PackServer
    } catch {}
})
$lobbyTimer.Start()
$numBots.Add_ValueChanged({ $lstLobby.IdleBots = [int]$numBots.Value; Update-LobbyList })
$btnLaunch.Add_Click({
    if (-not $script:lobby) { return }
    $L = $script:lobby
    $settings.mission = $Missions[$cmbMis.SelectedItem]; $settings.bots = [int]$numBots.Value
    $settings.skin = Get-SkinChoice $cmbSkin; $settings.botskin = Get-SkinChoice $cmbBotSkin; Save-Settings
    # tell every friend in the lobby to start their game, then free the port for ours
    for ($r = 0; $r -lt 3; $r++) { foreach ($m in $L.members.Values) { Send-Packet $L.u $m.ep 10 "$Port" }; Start-Sleep -Milliseconds 60 }
    $wait = 1 + $L.members.Count + $settings.bots
    try { $L.u.Close() } catch {}
    $script:lobby = $null
    $line = "Game starting for $wait players (you, $($settings.bots) bots, $($L.members.Count) friends). Friends can still join with these codes while you play."
    Show-Codes (@($line) + @($script:hostNotes))
    $lblJoinStatus.Text = $line
    $botArg = ""; if ($settings.bots -gt 0) { $botArg = "+set coop_bot $($settings.bots)" }
    $script:hostingProc = Start-Game "+set coop_host 1 +set coop_wait $wait $botArg +set coop_startmap $($settings.mission)"
    Update-Mode
})

# host still in the launcher lobby: wait there (the timer keeps checking in) until they launch; else join the game
function Join-HostOrLobby([string]$ip, [int]$port, $info) {
    $lblJoinStatus.Text = "Checking the host's skins..."; $form.Refresh()
    # remember the pick first: a downloaded pack refills the list from the saved choice
    $settings.skin = Get-SkinChoice $cmbSkin; Save-Settings
    $skinMsg = Sync-SkinPack $ip $port { param($t) $lblJoinStatus.Text = $t; $form.Refresh() }
    if ($skinMsg -match "got the host") { Refresh-Skins }
    $script:skinMsg = $skinMsg
    if ($info.map -ne "lobby") {
        $lblJoinStatus.Text = "Joining $($info.host) ($($info.map), $($info.players) players)..."; $form.Refresh()
        Join-Address $ip $port; return
    }
    if ($script:joining) { try { $script:joining.u.Close() } catch {} }
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = $env:USERNAME }; Save-Settings
    if (-not $script:ownPick) { $script:ownPick = @{ mis = $cmbMis.SelectedItem; bots = [int]$numBots.Value } }
    $script:joining = @{ u = (New-ProbeSocket); ep = (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)); ip = $ip; port = $port
                         host = $info.host; lastSend = [datetime]::MinValue; lastHeard = (Get-Date); lastCheck = (Get-Date); mission = ""; names = @() }
    $lblJoinStatus.Text = "Waiting for $($info.host) to launch the game...`r`n$skinMsg"
    Set-JoinedInfo "" @()
}
# the host's lobby as last heard: its mission and who is in it. The MISSION and AI cards show the host's pick.
function Set-JoinedInfo([string]$mission, [string[]]$names) {
    $J = $script:joining; if (-not $J) { return }
    $J.mission = $mission; $J.names = @($names)
    $lblJoinedHost.Text = "$($J.host)'s lobby"
    $lblJoinedMis.Text = $(if ($mission) { $mission -replace ' \([A-Za-z0-9_]+\)$', '' } else { "Waiting for the lobby details..." })
    if ($mission -and $Missions.Contains($mission)) { $cmbMis.SelectedItem = $mission } else { $cmbMis.SelectedIndex = -1 }
    $nb = @($names | Select-Object -Skip 1 | Where-Object { $_ -match '^Bot [0-9]+$' }).Count
    $numBots.Value = [Math]::Min(3, $nb)
    Update-Mode
    if ($mission) { Update-MissionTile $mission }
    else { $tileMis.Kicker = "Lobby"; $tileMis.Title = "Waiting for details"; $tileMis.Sub = "Asking $($J.host) for the mission..."; $tileMis.Thumb = $null }
}
# out of someone's lobby: your own mission and bots come back
function End-Joining([string]$msg, [switch]$Bye) {
    $J = $script:joining; if (-not $J) { return }
    if ($Bye) { Send-Bye $J.u @($J.ep) "left" }
    try { $J.u.Close() } catch {}
    $script:joining = $null
    if ($script:ownPick) {
        $p = $script:ownPick; $script:ownPick = $null
        if ($p.mis) { $cmbMis.SelectedItem = $p.mis }
        $numBots.Value = $p.bots
    }
    if ($msg) { $lblJoinStatus.Text = $msg }
    Update-Mode
}
function Step-JoinLobby {
    $J = $script:joining
    $now = Get-Date
    if (($now - $J.lastSend).TotalMilliseconds -gt 1000) { Send-Packet $J.u $J.ep 8 $settings.name; $J.lastSend = $now }
    foreach ($pk in (Receive-Packets $J.u)) {
        if ($pk.type -eq 9) {
            $J.lastHeard = $now
            $f = $pk.text.Split('|')
            $nm = @(([string]$f[1]).Split(',') | Where-Object { $_ })
            if ($f[0] -ne $J.mission -or ($nm -join ",") -ne ($J.names -join ",")) { Set-JoinedInfo $f[0] $nm }
            $lblJoinStatus.Text = "Waiting for $($J.host) to launch the game.`r`n$($script:skinMsg)"
        } elseif ($pk.type -eq 10) {
            End-Joining "$($J.host) launched the game: starting yours..."; $form.Refresh()
            Start-Sleep -Milliseconds 1500   # let the host's game take the port before we connect
            Join-Address $J.ip $J.port
            return
        } elseif ($pk.type -eq 11) {
            if ($pk.text -eq "full") { End-Joining "$($J.host)'s lobby is full (4 players)." } else { End-Joining "$($J.host) closed the lobby." }
            return
        } elseif ($pk.type -eq 7) {
            # answer to the check below: the host's launcher ("lobby") or its game, already running
            $J.lastHeard = $now
            $f = $pk.text.Split('|')
            if ($f.Count -ge 2 -and $f[1] -ne "lobby") {
                End-Joining "$($J.host) is already in the game: joining it..."; $form.Refresh()
                Join-Address $J.ip $J.port
                return
            }
        }
    }
    # quiet for a while (a network hiccup, or the host launched while we missed the signal): ask what the host
    # runs (the answer arrives above, nothing waits here) and either keep waiting or join the running game;
    # give up only after 3 minutes
    if (($now - $J.lastHeard).TotalSeconds -gt 6 -and ($now - $J.lastCheck).TotalSeconds -gt 2) {
        $J.lastCheck = $now
        Send-Packet $J.u $J.ep 6 ""
        if (($now - $J.lastHeard).TotalSeconds -gt 180) { End-Joining "Lost $($J.host)'s lobby for 3 minutes. Join again to retry." }
        else { $lblJoinStatus.Text = "Connection to $($J.host) is shaky, still trying..." }
    }
}
$btnLeave.Add_Click({
    if (-not $script:joining) { return }
    End-Joining "You left $($script:joining.host)'s lobby." -Bye
})

function Join-Address([string]$ip, [int]$port) {
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = $env:USERNAME }
    $settings.skin = Get-SkinChoice $cmbSkin; Save-Settings
    [void](Start-Game "+set coop_connect $($ip):$port")
    $form.Close()
}

$btnJoin.Add_Click({
    try {
        if ($script:setupActive -or $script:setupFailed -or (Test-InGame)) { return }
        $d = Decode-JoinCode $txtCode.Text
        if (-not $d) { $lblJoinStatus.Text = "That does not look like a join code (10 letters/digits, like K7F2Q-9QXAM)."; return }
        $lblJoinStatus.Text = "Looking for the host..."; $form.Refresh()
        $r = Probe-Host $d.ip $d.port
        if (-not $r) { $lblJoinStatus.Text = "No answer from that host. Is their game running, and is the code right?"; return }
        $settings.lastCode = $txtCode.Text.Trim(); Save-Settings
        Join-HostOrLobby $d.ip $d.port $r
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
})

function Show-LanGames {
    $lstLan.Items.Clear()
    $lstLan.ActionRows = $script:lanGames.Count
    if (-not $script:lanGames.Count) { [void]$lstLan.Items.Add("No games found on this network.") }
    foreach ($g in $script:lanGames) {
        $where = if ($g.map -eq "lobby") { "lobby" } else { $g.map }
        $via = if ($g.ip -match '^100\.') { "  (Tailscale)" } elseif ($g.ip -match '^127\.') { "  (this PC)" } else { "" }
        [void]$lstLan.Items.Add("$($g.host)  -  $where $($g.players)$via")
    }
    $lstLan.Invalidate()     # (the rows are owner-drawn: a reused row is not always repainted by itself)
}
function Search-LanGames {
    try {
        $lstLan.ActionRows = 0; $lstLan.Items.Clear(); [void]$lstLan.Items.Add("Searching..."); $form.Refresh()
        $script:lanGames = @(Find-LanGames)
        Show-LanGames
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
}
$btnFind.Add_Click({ Search-LanGames })
# one click on a found game joins it
function Join-LanGame([int]$i) {
    try {
        if ($script:setupActive -or $script:setupFailed -or (Test-InGame) -or $i -lt 0 -or $i -ge $script:lanGames.Count) { return }
        $g = $script:lanGames[$i]; Join-HostOrLobby $g.ip $g.port $g
    } catch { $lblJoinStatus.Text = "Something went wrong: $($_.Exception.Message)" }
}
$lstLan.Add_MouseClick({ param($s, $e) $i = $lstLan.IndexFromPoint($e.Location); if ($i -ge 0 -and $lstLan.GetItemRectangle($i).Contains($e.Location)) { Join-LanGame $i } })
$lstLan.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq "Enter") { $e.SuppressKeyPress = $true; Join-LanGame $lstLan.SelectedIndex } })

# --- skins tab: add any humanoid model (rigged or not), preview, remove. Runs the skin tools (Python) ---
$SkinTool = Join-Path $GameDir "Mods\coop\skintool\addskin.py"
$PreviewDir = Join-Path $GameDir "coop_skins\work\previews"
$lstSkins = New-Ctl MilList 17 45 194 196
$picSkin = New-Ctl System.Windows.Forms.PictureBox 229 45 442 196; $picSkin.SizeMode = "Zoom"; $picSkin.BackColor = [CoopTheme]::Field
# (the buttons line up with the list and preview frames: 14..214 and 226..674)
$btnAddSkin = New-Btn "Add character..." 14 256 200 36 "plus" 1
$btnRemoveSkin = New-Btn "Remove" 226 256 218 36 "trash"
$btnEditRig = New-Btn "Edit rig..." 456 256 218 36 "rig"
$tipSkins = New-Tip
$tipSkins.SetToolTip($btnEditRig, "Move the rig markers of the selected skin again and re-rig it. Only for models that came without a skeleton.")
$txtSkinLog = New-Ctl System.Windows.Forms.TextBox 24 312 642 50; $txtSkinLog.Multiline = $true; $txtSkinLog.ReadOnly = $true; $txtSkinLog.ScrollBars = "None"
$txtSkinLog.BorderStyle = "None"; $txtSkinLog.BackColor = [CoopTheme]::Field; $txtSkinLog.ForeColor = [CoopTheme]::Text; $txtSkinLog.Font = [CoopTheme]::Body(11)
[CoopTheme]::DarkScroll($txtSkinLog, "DarkMode_Explorer")
# a scroll bar only when the text does not fit
$txtSkinLog.Add_TextChanged({
    $fl = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    $w = $txtSkinLog.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - (S 4)
    $h = [System.Windows.Forms.TextRenderer]::MeasureText($txtSkinLog.Text, $txtSkinLog.Font, (New-Object System.Drawing.Size $w, 0), $fl).Height
    $want = $(if ($h -gt $txtSkinLog.Height) { "Vertical" } else { "None" })
    if ([string]$txtSkinLog.ScrollBars -ne $want) { $txtSkinLog.ScrollBars = $want }
})
$txtSkinLog.Text = "Any humanoid model: GLB, glTF, DAE, OBJ (FBX needs Blender). Models without a skeleton (stand in a T- or A-pose) open the rig editor: drag the markers onto the joints and click Rig it. Friends need the same skins to see them."
$pageSettings.Controls.AddRange(@($lstSkins, $picSkin, $btnAddSkin, $btnRemoveSkin, $btnEditRig, $txtSkinLog))
Add-Frames @($lstSkins, $picSkin)
[CoopTheme]::Frame($txtSkinLog, (S 10), (S 8), (S 8), (S 8))
$RigDir = Join-Path $GameDir "coop_skins\work\rigs"
$RigTmp = Join-Path $env:TEMP "coop_rig"
function Refresh-Skins {
    $script:SkinNames = @(Read-SkinNames)
    $lstSkins.Items.Clear()
    foreach ($n in $script:SkinNames) { [void]$lstSkins.Items.Add(($n -replace '^coop_', '')) }
    $cardSkins.Right = "$($script:SkinNames.Count) installed"; $pageSettings.Redraw()
    Fill-SkinBox $cmbSkin $settings.skin
    Fill-SkinBox $cmbBotSkin $settings.botskin
}
function Find-Python {
    foreach ($c in @("py", "python")) { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { return $g.Source } }
    return $null
}
$lstSkins.Add_SelectedIndexChanged({
    $i = $lstSkins.SelectedIndex
    if ($picSkin.Image) { $old = $picSkin.Image; $picSkin.Image = $null; $old.Dispose() }
    if ($i -lt 0) { return }
    $png = Join-Path $PreviewDir ($script:SkinNames[$i] + ".png")
    if (Test-Path $png) {
        $bytes = [IO.File]::ReadAllBytes($png); $raw = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
        try { $picSkin.Image = [CoopTheme]::KeyBackground($raw); $raw.Dispose() } catch { $picSkin.Image = $raw }
    }
})
$script:skinProc = $null; $script:skinOut = $null; $script:skinNext = $null
function Get-SkinToolArgLine([string]$py, [string[]]$toolArgs) {
    $pre = @(); if ((Split-Path $py -Leaf) -eq "py.exe") { $pre = @("-3") }
    return ($pre + @("`"$SkinTool`"") + ($toolArgs | ForEach-Object { "`"$_`"" })) -join " "
}
function Start-SkinTool([string[]]$toolArgs) {
    $py = Find-Python
    if (-not $py) { $txtSkinLog.Text = "Python 3 is needed for skins (python.org), with: pip install numpy pillow"; return }
    if (-not (Test-Path $SkinTool)) { $txtSkinLog.Text = "Skin tools not installed (run tools/build.py)."; return }
    $script:skinOut = [IO.Path]::GetTempFileName()
    $env:COOP_GAMEDIR = $GameDir
    $script:skinProc = Start-Process -FilePath $py -ArgumentList (Get-SkinToolArgLine $py $toolArgs) -NoNewWindow -PassThru -RedirectStandardOutput $script:skinOut -RedirectStandardError "$($script:skinOut).err"
    $btnAddSkin.Enabled = $false; $btnRemoveSkin.Enabled = $false; $btnEditRig.Enabled = $false
    $txtSkinLog.Text = "Working... (the first time also sets up the tools, about a minute)"
}
# same, but waits (used inside the rig editor; a rigprep takes a few seconds). Returns @{ ok; text }
# The window keeps processing messages meanwhile (callers disable their buttons), so it never shows "Not Responding".
function Invoke-SkinToolSync([string[]]$toolArgs, $lblStatus) {
    $py = Find-Python
    if (-not $py) { return @{ ok = $false; text = "Python 3 is needed for skins (python.org), with: pip install numpy pillow" } }
    if (-not (Test-Path $SkinTool)) { return @{ ok = $false; text = "Skin tools not installed (run tools/build.py)." } }
    $out = [IO.Path]::GetTempFileName()
    $env:COOP_GAMEDIR = $GameDir
    $p = Start-Process -FilePath $py -ArgumentList (Get-SkinToolArgLine $py $toolArgs) -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $n = 0
    while (-not $p.WaitForExit(40)) {
        [System.Windows.Forms.Application]::DoEvents()
        if ((++$n % 5) -eq 0) {
            try { $last = @([IO.File]::ReadAllText($out) -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 1; if ($last) { $lblStatus.Text = "Working... $last" } } catch {}
        }
    }
    $log = ""; $err = ""
    try { $log = [IO.File]::ReadAllText($out) } catch {}
    try { $err = [IO.File]::ReadAllText("$out.err") } catch {}
    try { Remove-Item -LiteralPath $out, "$out.err" -Force } catch {}
    if ($log -match "(?m)^OK") { return @{ ok = $true; text = "" } }
    $t = @($log -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 3
    $e = @($err -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 3
    return @{ ok = $false; text = ((@($t) + @($e)) -join "`r`n") }
}

# --- rig editor for models without a skeleton (like Mixamo): drag 8 markers onto a front view of the character.
# The json/png come from "addskin.py rigprep"; markers are pixels in that image, image RIGHT = the character's LEFT.
$RigMarkers = @(
    @{ k = "chin";        t = "Chin";    c = [System.Drawing.Color]::Gold },
    @{ k = "groin";       t = "Groin";   c = [System.Drawing.Color]::Gold },
    @{ k = "left_elbow";  t = "L elbow"; c = [System.Drawing.Color]::FromArgb(70, 190, 255) },
    @{ k = "right_elbow"; t = "R elbow"; c = [System.Drawing.Color]::FromArgb(70, 190, 255) },
    @{ k = "left_wrist";  t = "L wrist"; c = [System.Drawing.Color]::FromArgb(255, 140, 40) },
    @{ k = "right_wrist"; t = "R wrist"; c = [System.Drawing.Color]::FromArgb(255, 140, 40) },
    @{ k = "left_knee";   t = "L knee";  c = [System.Drawing.Color]::FromArgb(90, 220, 90) },
    @{ k = "right_knee";  t = "R knee";  c = [System.Drawing.Color]::FromArgb(90, 220, 90) }
)
$RigMirror = @{ left_elbow = "right_elbow"; right_elbow = "left_elbow"; left_wrist = "right_wrist"; right_wrist = "left_wrist"; left_knee = "right_knee"; right_knee = "left_knee" }
$RigBones = @(@("chin", "groin"), @("chin", "left_elbow"), @("left_elbow", "left_wrist"), @("chin", "right_elbow"), @("right_elbow", "right_wrist"), @("groin", "left_knee"), @("groin", "right_knee"))
function Read-RigJson([string]$path) { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) }
# pure ASCII (non-ASCII as \uXXXX), so Python reads it the same whatever its default code page is
$RigJsonEsc = [System.Text.RegularExpressions.MatchEvaluator] { param($mt) '\u{0:x4}' -f [int][char]$mt.Value }
function Write-RigJson([string]$path, $data) {
    $j = [regex]::Replace(($data | ConvertTo-Json -Depth 8), '[^\x00-\x7F]', $RigJsonEsc)
    [IO.File]::WriteAllText($path, $j, (New-Object System.Text.ASCIIEncoding))
}
function Copy-RigPoints($pts) { $o = @{}; foreach ($k in @($pts.Keys)) { $o[$k] = @([double]$pts[$k][0], [double]$pts[$k][1]) }; return $o }
function Rig-Load {
    $d = Read-RigJson $script:rg.json
    if ($d.rigged) { throw "This model has its own skeleton, it needs no rig." }
    $img = [string]$d.image
    if (-not $img -or -not (Test-Path -LiteralPath $img)) { $img = [IO.Path]::ChangeExtension($script:rg.json, ".png") }
    $bytes = [IO.File]::ReadAllBytes($img)          # copy through memory so the png is not locked
    $ms = New-Object IO.MemoryStream(, $bytes); $tmp = [System.Drawing.Image]::FromStream($ms)
    $bmp = New-Object System.Drawing.Bitmap $tmp; $tmp.Dispose(); $ms.Dispose()
    $old = $script:rg.pic.Image; $script:rg.pic.Image = $bmp; if ($old) { $old.Dispose() }
    $size = [double]$d.size; if (-not $size) { $size = [double]$bmp.Width }
    $script:rg.size = $size; $script:rg.scale = [double]$script:rg.pic.Width / $size
    $pts = @{}
    foreach ($m in $RigMarkers) {
        $v = $null; if ($d.markers) { $v = $d.markers.($m.k) }
        if ($v -and @($v).Count -ge 2) { $pts[$m.k] = @([double]$v[0], [double]$v[1]) } else { $pts[$m.k] = @(($size / 2), ($size / 2)) }
    }
    $script:rg.pts = $pts; $script:rg.orig = Copy-RigPoints $pts; $script:rg.data = $d
    $face = "as found"; if ($d.flip) { $face = "turned around" }
    # flip_auto = what the facing detector would pick; when flip differs, the user turned it
    $how = "guessed"; if ($d.PSObject.Properties["flip_auto"] -and ([bool]$d.flip -ne [bool]$d.flip_auto)) { $how = "set by you" }
    $script:rg.info.Text = "Facing: $face ($how). Up axis: $(([string]$d.up).ToUpper())."
    $script:rg.pic.Invalidate()
}
function Rig-Hit([double]$x, [double]$y) {
    $best = $null; $bd = [double][CoopTheme]::Pf(14); $sc = $script:rg.scale
    foreach ($m in $RigMarkers) {
        $p = $script:rg.pts[$m.k]; $d = [math]::Sqrt([math]::Pow($p[0] * $sc - $x, 2) + [math]::Pow($p[1] * $sc - $y, 2))
        if ($d -le $bd) { $bd = $d; $best = $m.k }
    }
    return $best
}
function Rig-Centre { return (($script:rg.pts["chin"][0] + $script:rg.pts["groin"][0]) / 2.0) }
function Rig-Move([string]$k, [double]$x, [double]$y) {
    # double literals everywhere: [math]::Max(0, ...) would pick the int overload and round to whole pixels
    $max = [double]$script:rg.size - 1.0
    $x = [math]::Max(0.0, [math]::Min($max, [double]$x)); $y = [math]::Max(0.0, [math]::Min($max, [double]$y))
    $script:rg.pts[$k] = @($x, $y)
    if ($script:rg.sym.Checked -and $RigMirror.ContainsKey($k)) {
        $mx = [math]::Max(0.0, [math]::Min($max, [double](2.0 * (Rig-Centre) - $x)))
        $script:rg.pts[$RigMirror[$k]] = @($mx, $y)
    }
}
function Rig-Paint($g) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $sc = $script:rg.scale; $p = $script:rg.pts
    if ($script:rg.sym.Checked) {
        $cx = [float]((Rig-Centre) * $sc)
        $dash = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 255, 255, 255)), 1
        $dash.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash; $g.DrawLine($dash, $cx, [float]0, $cx, [float]$script:rg.pic.Height); $dash.Dispose()
    }
    $shadow = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(160, 0, 0, 0)), 5
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 255, 255, 255)), 2
    foreach ($b in $RigBones) {
        $a = $p[$b[0]]; $c = $p[$b[1]]
        $g.DrawLine($shadow, [float]($a[0] * $sc), [float]($a[1] * $sc), [float]($c[0] * $sc), [float]($c[1] * $sc))
        $g.DrawLine($pen, [float]($a[0] * $sc), [float]($a[1] * $sc), [float]($c[0] * $sc), [float]($c[1] * $sc))
    }
    $shadow.Dispose(); $pen.Dispose()
    $font = [CoopTheme]::Head(10.5)     # cached by the theme: not disposed here
    $pw = [float]$script:rg.pic.Width; $ph = [float]$script:rg.pic.Height; $d10 = [CoopTheme]::Pf(10); $o12 = [CoopTheme]::Pf(12)
    $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 2
    $dots = @(); foreach ($m in $RigMarkers) { $dots += , (New-Object System.Drawing.RectangleF ([float]($p[$m.k][0] * $sc - $d10)), ([float]($p[$m.k][1] * $sc - $d10)), ([float](2 * $d10)), ([float](2 * $d10))) }
    $taken = New-Object System.Collections.ArrayList
    foreach ($m in $RigMarkers) {
        $x = [float]($p[$m.k][0] * $sc); $y = [float]($p[$m.k][1] * $sc)
        $r = [CoopTheme]::Pf(7); if ($script:rg.drag -eq $m.k -or $script:rg.hover -eq $m.k) { $r = [CoopTheme]::Pf(9) }
        $br = New-Object System.Drawing.SolidBrush $m.c
        $g.FillEllipse($br, $x - $r, $y - $r, 2 * $r, 2 * $r); $g.DrawEllipse($ring, $x - $r, $y - $r, 2 * $r, 2 * $r); $br.Dispose()
    }
    $i = 0
    foreach ($m in $RigMarkers) {
        $x = [float]($p[$m.k][0] * $sc); $y = [float]($p[$m.k][1] * $sc)
        $sz = $g.MeasureString($m.t, $font); $w = [float]$sz.Width; $h = [float]$sz.Height
        # labels sit outside the body; when that spot covers another marker or label, try above, below, then the other side
        $out = $x + $o12; $in = $x - $o12 - $w; if ($m.k -like "right_*") { $out = $x - $o12 - $w; $in = $x + $o12 }
        $cands = @(@($out, ($y - $h / 2)), @(($x - $w / 2), ($y - $o12 - $h)), @(($x - $w / 2), ($y + $o12)), @($in, ($y - $h / 2)))
        # spots outside the picture are skipped; when none is free, the first one inside (or clamped) is used
        $pick = $null
        foreach ($c in $cands) { if ($c[0] -ge 0 -and $c[1] -ge 0 -and $c[0] + $w -le $pw -and $c[1] + $h -le $ph) { $pick = $c; break } }
        if (-not $pick) { $pick = $cands[0] }
        foreach ($c in $cands) {
            if ($c[0] -lt 0 -or $c[1] -lt 0 -or $c[0] + $w -gt $pw -or $c[1] + $h -gt $ph) { continue }
            $rc = New-Object System.Drawing.RectangleF ([float]$c[0]), ([float]$c[1]), $w, $h
            $hit = $false
            for ($j = 0; $j -lt $dots.Count; $j++) { if ($j -ne $i -and $rc.IntersectsWith($dots[$j])) { $hit = $true; break } }
            if (-not $hit) { foreach ($t in $taken) { if ($rc.IntersectsWith($t)) { $hit = $true; break } } }
            if (-not $hit) { $pick = $c; break }
        }
        $tx = [float][math]::Max(0.0, [math]::Min([double]($pw - $w), [double]$pick[0])); $ty = [float][math]::Max(0.0, [math]::Min([double]($ph - $h), [double]$pick[1]))
        [void]$taken.Add((New-Object System.Drawing.RectangleF $tx, $ty, $w, $h))
        $g.DrawString($m.t, $font, [System.Drawing.Brushes]::Black, [float]($tx + 1), [float]($ty + 1))
        $g.DrawString($m.t, $font, [System.Drawing.Brushes]::White, $tx, $ty)
        $i++
    }
    $ring.Dispose()
}
# has the user moved any marker away from the guess?
function Rig-Changed {
    foreach ($m in $RigMarkers) {
        $a = $script:rg.pts[$m.k]; $b = $script:rg.orig[$m.k]
        if ([math]::Abs($a[0] - $b[0]) -gt 0.05 -or [math]::Abs($a[1] - $b[1]) -gt 0.05) { return $true }
    }
    return $false
}
# re-runs rigprep with other facing/up options. $mode "turn": markers the user moved are turned with the model
# (mirrored left/right through the model space, since a turn is 180 degrees about the up axis); "up": they cannot
# be kept, so ask first.
function Rig-Rerun([string[]]$extra, [string]$mode) {
    $r = $script:rg
    $changed = Rig-Changed
    if ($mode -eq "up" -and $changed -and -not $r.test) {
        $q = [System.Windows.Forms.MessageBox]::Show($r.form, "Swapping the up axis puts every marker back to a new guess, so the markers you moved are lost. Continue?", "Swap up axis", "YesNo", "Question")
        if ($q -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $keep = $null
    if ($mode -eq "turn" -and $changed) {
        $v = $r.data.view; $s = [double]$r.size; $keep = @{}
        foreach ($m in $RigMarkers) { $q = $r.pts[$m.k]; $keep[$m.k] = @(([double]$v.cx + ($q[0] - $s / 2) / $s * [double]$v.span), ([double]$v.cy - ($q[1] - $s / 2) / $s * [double]$v.span)) }
    }
    $buttons = @($r.turn, $r.up, $r.reset, $r.ok, $r.cancel, $r.sym)
    foreach ($b in $buttons) { $b.Enabled = $false }
    $r.pic.Enabled = $false; $r.drag = $null; $r.busy = $true
    $r.form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $r.status.ForeColor = [CoopTheme]::Text
    $r.status.Text = "Working... (a few seconds)"; $r.form.Refresh()
    try {
        $res = Invoke-SkinToolSync (@("rigprep", $r.src, $r.json) + $extra) $r.status
        if ($res.ok) {
            Rig-Load
            if ($keep) {
                $v = $r.data.view; $s = [double]$r.size; $max = $s - 1.0
                foreach ($m in $RigMarkers) {
                    $from = $m.k; if ($RigMirror.ContainsKey($from)) { $from = $RigMirror[$from] }   # its left is now on the other side
                    $X = - $keep[$from][0]; $Y = $keep[$from][1]
                    $px = $s / 2 + ($X - [double]$v.cx) / [double]$v.span * $s; $py = $s / 2 - ($Y - [double]$v.cy) / [double]$v.span * $s
                    $r.pts[$m.k] = @([math]::Max(0.0, [math]::Min($max, [double]$px)), [math]::Max(0.0, [math]::Min($max, [double]$py)))
                }
                $r.pic.Invalidate()
                $r.status.Text = "Done. Your markers were turned with the model (Reset markers gives the new guess). Check them again."
            } else { $r.status.Text = "Done. Check the markers again." }
        }
        else { $r.status.ForeColor = [CoopTheme]::Bad; $r.status.Text = "Failed: " + $res.text }
    } catch { $r.status.ForeColor = [CoopTheme]::Bad; $r.status.Text = "Failed: $($_.Exception.Message)" }
    finally { foreach ($b in $buttons) { $b.Enabled = $true }; $r.pic.Enabled = $true; $r.busy = $false; $r.form.Cursor = [System.Windows.Forms.Cursors]::Default }
}
# shows the editor on a rigprep json; on "Rig it" writes the markers back into it and returns $true
function Show-RigEditor([string]$json, [string]$src, [scriptblock]$test = $null) {
    $f = New-Object CoopForm
    $f.Text = "Rig the character"; $f.ClientSize = New-Object System.Drawing.Size (S 776), (S 544); $f.Canvas = $f.ClientSize
    $f.FormBorderStyle = "FixedDialog"; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.StartPosition = "CenterParent"
    $f.Font = [CoopTheme]::Body(10.5)
    $f.PanelRect = New-Object System.Drawing.Rectangle (S 8), (S 8), (S 760), (S 528)
    if ($test) { $f.StartPosition = "Manual"; $f.Location = New-Object System.Drawing.Point -4000, -4000; $f.ShowInTaskbar = $false }
    $pic = New-Ctl System.Windows.Forms.PictureBox 18 18 512 512; $pic.SizeMode = "StretchImage"
    $pic.BackColor = [CoopTheme]::Field
    $title = New-Lbl "Place the joints" 544 16 214 28 -Head -size 13; $title.Glyph = "rig"; $title.ForeColor = [CoopTheme]::Gold
    $help = New-Lbl "" 544 46 214 196 -size 10; $help.Middle = $false; $help.ForeColor = [CoopTheme]::TextDim
    $help.Text = "Drag each circle onto the middle of that joint. The character faces you, so its LEFT side is on the RIGHT of the picture.`r`n`r`nChin: just under the mouth.`r`nGroin: where the legs meet.`r`nElbows, wrists, knees: the centre of each joint.`r`n`r`nSeeing its back? Click Turn around. Lying on its back or front? Click Swap up axis."
    $sym = New-Ctl MilCheck 544 244 214 26; $sym.Text = "Symmetry (the other side follows)"; $sym.Checked = $true
    $info = New-Lbl "" 544 272 214 36 -size 10.5; $info.Middle = $false
    $btnTurn = New-Btn "Turn around" 544 310 214 32 "refresh"
    $btnUp = New-Btn "Swap up axis" 544 348 214 32 "up"
    $btnReset = New-Btn "Reset markers" 544 386 214 32 "trash"
    $status = New-Lbl "" 544 424 214 62 -size 10.5; $status.Middle = $false
    $btnOk = New-Btn "Rig it" 544 492 122 38 "check" 1
    $btnCancel = New-Btn "Cancel" 672 492 86 38
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.CancelButton = $btnCancel; $f.AcceptButton = $btnOk
    $f.Controls.AddRange(@($pic, $title, $help, $sym, $info, $btnTurn, $btnUp, $btnReset, $status, $btnOk, $btnCancel))
    Add-Frames @($pic)
    Fit-Screen $f
    $script:rg = @{ form = $f; pic = $pic; sym = $sym; info = $info; status = $status; turn = $btnTurn; up = $btnUp; reset = $btnReset; ok = $btnOk; cancel = $btnCancel
                    json = $json; src = $src; data = $null; pts = @{}; orig = @{}; size = 512.0; scale = 1.0; drag = $null; grab = @(0, 0); hover = $null; test = $test; busy = $false }
    $f.Add_FormClosing({ param($s, $e) if ($script:rg.busy) { $e.Cancel = $true } })   # not while rigprep runs
    $pic.Add_Paint({ param($s, $e) try { Rig-Paint $e.Graphics } catch {} })
    $pic.Add_MouseDown({ param($s, $e)
        if ($e.Button -ne "Left") { return }
        $r = $script:rg; $r.drag = Rig-Hit $e.X $e.Y
        if ($r.drag) { $q = $r.pts[$r.drag]; $r.grab = @(($q[0] * $r.scale - $e.X), ($q[1] * $r.scale - $e.Y)) }   # no jump to the cursor
        $r.pic.Invalidate()
    })
    $pic.Add_MouseMove({ param($s, $e)
        $r = $script:rg
        if ($r.drag) { Rig-Move $r.drag (($e.X + $r.grab[0]) / $r.scale) (($e.Y + $r.grab[1]) / $r.scale); $r.pic.Invalidate(); return }
        $h = Rig-Hit $e.X $e.Y
        if ($h -ne $r.hover) { $r.hover = $h; $r.pic.Invalidate() }
        if ($h) { $r.pic.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $r.pic.Cursor = [System.Windows.Forms.Cursors]::Default }
    })
    $pic.Add_MouseUp({ param($s, $e) $script:rg.drag = $null; $script:rg.pic.Invalidate() })
    $sym.Add_CheckedChanged({ $script:rg.pic.Invalidate() })
    $btnReset.Add_Click({ $script:rg.pts = Copy-RigPoints $script:rg.orig; $script:rg.status.Text = ""; $script:rg.pic.Invalidate() })
    $btnTurn.Add_Click({
        $d = $script:rg.data; $fl = "1"; if ($d.flip) { $fl = "0" }
        $up = [string]$d.up; if (-not $up) { $up = "auto" }
        Rig-Rerun @("--flip", $fl, "--up", $up) "turn"
    })
    $btnUp.Add_Click({ $up = "z"; if ([string]$script:rg.data.up -eq "z") { $up = "y" }; Rig-Rerun @("--up", $up, "--flip", "auto") "up" })
    $btnOk.Add_Click({
        try {
            $d = $script:rg.data
            if (-not $d.markers) { $d | Add-Member -NotePropertyName markers -NotePropertyValue ([pscustomobject]@{}) -Force }
            foreach ($m in $RigMarkers) {
                $p = $script:rg.pts[$m.k]
                $d.markers | Add-Member -NotePropertyName $m.k -NotePropertyValue @([math]::Round($p[0], 1), [math]::Round($p[1], 1)) -Force
            }
            Write-RigJson $script:rg.json $d
            $script:rg.form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        } catch { $script:rg.status.ForeColor = [CoopTheme]::Bad; $script:rg.status.Text = "Could not save the markers: $($_.Exception.Message)" }
    })
    $f.Add_Shown({ if ($script:rg.test) { try { & $script:rg.test $script:rg.form } catch { $script:rg.status.Text = "TEST ERROR $($_.Exception.Message)"; $script:rg.form.Close() } } })
    try { Rig-Load } catch { $f.Dispose(); throw }
    if (-not $script:rg.src) { $script:rg.src = [string]$script:rg.data.source }
    if ($form.Visible) { $res = $f.ShowDialog($form) } else { $res = $f.ShowDialog() }
    if ($pic.Image) { $pic.Image.Dispose() }
    $f.Dispose()
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}
# runs the editor from the skins tab (the tool timer pauses meanwhile); $true when the user clicked Rig it
function Open-RigEditor([string]$json, [string]$src) {
    $skinTimer.Stop()
    try { return (Show-RigEditor $json $src) }
    catch { $txtSkinLog.Text = "Could not open the rig editor: $($_.Exception.Message)"; return $false }
    finally { $skinTimer.Start() }
}
# after "rigprep" finished: rigged models are added straight away, the others go through the editor first
function Continue-SkinAdd($n, [string]$log) {
    if ($log -notmatch "(?m)^OK rigprep") { return }
    try { $d = Read-RigJson $n.json } catch { $txtSkinLog.Text = "Could not read the rig file: $($_.Exception.Message)"; return }
    if ($d.rigged) { Start-SkinTool @("add", $n.file, $n.name); return }
    if (Open-RigEditor $n.json $n.file) { Start-SkinTool @("add", $n.file, $n.name, "--rig", $n.json) }
    elseif ($txtSkinLog.Text -notmatch "^Could not") { $txtSkinLog.Text = "Cancelled: nothing was added." }
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
        $btnAddSkin.Enabled = $true; $btnRemoveSkin.Enabled = $true; $btnEditRig.Enabled = $true
        $sel = $null; if ($log -match "(?m)^OK (coop_\w+)") { $sel = $Matches[1] }
        Refresh-Skins
        if ($sel) { $k = [array]::IndexOf($script:SkinNames, $sel); if ($k -ge 0) { $lstSkins.SelectedIndex = $k } }
        $n = $script:skinNext; $script:skinNext = $null
        if ($n) { try { Continue-SkinAdd $n $log } catch { $txtSkinLog.Text = "Something went wrong: $($_.Exception.Message)" } }
    }
})
$skinTimer.Start()
$btnAddSkin.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "3D characters|*.glb;*.gltf;*.dae;*.obj;*.fbx|All files|*.*"
    if ($dlg.ShowDialog() -ne "OK") { return }
    $name = ([IO.Path]::GetFileNameWithoutExtension($dlg.FileName) -replace '[^A-Za-z0-9_]', '_').ToLower().Trim('_')
    if (-not $name) { $name = "skin" }
    try { [void](New-Item -ItemType Directory -Force -Path $RigTmp) } catch {}
    $json = Join-Path $RigTmp ("coop_" + $name + ".json")
    try { Remove-Item -LiteralPath $json, ([IO.Path]::ChangeExtension($json, ".png")) -Force -ErrorAction SilentlyContinue } catch {}
    # step 1: rigprep (is it rigged? front view + guessed markers); the timer continues with Continue-SkinAdd
    Start-SkinTool @("rigprep", $dlg.FileName, $json)
    if ($script:skinProc) { $script:skinNext = @{ file = $dlg.FileName; name = $name; json = $json } }
})
$btnRemoveSkin.Add_Click({
    $i = $lstSkins.SelectedIndex; if ($i -lt 0) { $txtSkinLog.Text = "Pick a skin in the list first."; return }
    Start-SkinTool @("remove", $script:SkinNames[$i])
})
$btnEditRig.Add_Click({
    try {
        $i = $lstSkins.SelectedIndex; if ($i -lt 0) { $txtSkinLog.Text = "Pick a skin in the list first."; return }
        $model = $script:SkinNames[$i]; $short = $model -replace '^coop_', ''
        $rj = Join-Path $RigDir ($model + ".json")
        if (-not (Test-Path -LiteralPath $rj)) {
            $txtSkinLog.Text = "'$short' has no rig to edit: it came with its own skeleton (or was added before the rig editor). To rig it by hand, Remove it and add it again."
            return
        }
        $d = Read-RigJson $rj; $src = [string]$d.source
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { $txtSkinLog.Text = "The original model file is missing:`r`n$src`r`nPut it back there, or Remove the skin and add it again."; return }
        # edit a copy, so Cancel (or a Turn around that is not kept) leaves the saved rig alone
        [void](New-Item -ItemType Directory -Force -Path $RigTmp)
        $tj = Join-Path $RigTmp ($model + ".json"); $tp = [IO.Path]::ChangeExtension($tj, ".png")
        $png = [string]$d.image; if (-not $png -or -not (Test-Path -LiteralPath $png)) { $png = [IO.Path]::ChangeExtension($rj, ".png") }
        if (Test-Path -LiteralPath $png) {
            Copy-Item -LiteralPath $png -Destination $tp -Force
            $d | Add-Member -NotePropertyName image -NotePropertyValue $tp -Force
        } else {
            # the front view is gone: make it again with the saved facing and up axis, then put the saved markers back
            $up = [string]$d.up; if ($up -notin @("y", "z")) { $up = "auto" }
            $fl = "auto"; if ($d.PSObject.Properties["flip"]) { if ($d.flip) { $fl = "1" } else { $fl = "0" } }
            $btnAddSkin.Enabled = $false; $btnRemoveSkin.Enabled = $false; $btnEditRig.Enabled = $false
            $txtSkinLog.Text = "The rig picture is missing, making it again..."
            try { $res = Invoke-SkinToolSync @("rigprep", $src, $tj, "--flip", $fl, "--up", $up) $txtSkinLog }
            finally { $btnAddSkin.Enabled = $true; $btnRemoveSkin.Enabled = $true; $btnEditRig.Enabled = $true }
            if (-not $res.ok) { $txtSkinLog.Text = "Could not make the rig picture again:`r`n$($res.text)"; return }
            $n = Read-RigJson $tj
            if ($n.rigged) { $txtSkinLog.Text = "'$short' now loads with its own skeleton, so it needs no rig."; return }
            if ($d.markers) { $n | Add-Member -NotePropertyName markers -NotePropertyValue $d.markers -Force }
            $d = $n
        }
        Write-RigJson $tj $d
        if (Open-RigEditor $tj $src) { Start-SkinTool @("add", $src, $short, "--rig", $tj) }
        elseif ($txtSkinLog.Text -notmatch "^Could not") { $txtSkinLog.Text = "Cancelled: '$short' was not changed." }
    } catch { $txtSkinLog.Text = "Something went wrong: $($_.Exception.Message)" }
})
Refresh-Skins

# keep the router port open while hosting; close it when the game exits or the launcher closes
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ if ($script:hostingProc -and $script:hostingProc.HasExited) { Stop-PackServer; Close-RouterPort; $script:hostingProc = $null; $script:codes = @(); $lblJoinStatus.Text = "The game closed. Hosting stopped."; Update-Mode } })
$timer.Start()
$form.Add_FormClosing({
    # say goodbye, so the lobby (or its players) need not wait for the time-out
    if ($script:lobby) { Send-Bye $script:lobby.u @($script:lobby.members.Values | ForEach-Object { $_.ep }) "closed"; try { $script:lobby.u.Close() } catch {}; Close-RouterPort }
    elseif ($script:hostingProc) { Close-RouterPort }
    if ($script:joining) { Send-Bye $script:joining.u @($script:joining.ep) "left"; try { $script:joining.u.Close() } catch {} }
})

# first-start setup runs in the background; the window stays responsive and shows the progress
$setupTimer = New-Object System.Windows.Forms.Timer; $setupTimer.Interval = 250
$setupTimer.Add_Tick({
    if (-not [CoopFF]::Done) { $lblJoinStatus.Text = "First start: setting up the coop scripts from your own game files...`r`n" + [CoopFF]::Status; return }
    $setupTimer.Stop()
    # failed: hosting and joining stay off (the coop hooks are missing); the big button retries
    if ([CoopFF]::Error) { $lblJoinStatus.Text = "Setup failed. Is this the CoD4 1.0 game folder (iw3sp.exe, zone\english)? $([CoopFF]::Error)"; $script:setupFailed = $true }
    else { $lblJoinStatus.Text = "Ready. Pick a mission and host a lobby, or join a friend."; $script:setupFailed = $false }
    $script:setupActive = $false; Update-Mode
})
$script:updateState = "idle"
$updateTimer = New-Object System.Windows.Forms.Timer; $updateTimer.Interval = 300
$updateTimer.Add_Tick({
    try {
        if ($script:updateState -eq "checking" -and [CoopUpdate]::Checked) {
            $mine = Get-InstalledVersion
            if ([CoopUpdate]::Latest -and [CoopUpdate]::ZipUrl -and [CoopUpdate]::Newer([CoopUpdate]::Latest, $mine)) {
                $lblUpdate.Text = "Version $([CoopUpdate]::Latest) is out (you have $mine)."
                $btnUpdate.Text = "Update to $([CoopUpdate]::Latest)"; $btnUpdate.Visible = $true
                $script:updateState = "available"
            } else {
                $lblUpdate.Text = "Version $mine" + $(if ([CoopUpdate]::Error) { " (update check failed)" } else { " (up to date)" })
                $script:updateState = "done"; $updateTimer.Stop()
            }
        } elseif ($script:updateState -eq "downloading") {
            $lblUpdate.Text = [CoopUpdate]::Status
            if ([CoopUpdate]::Downloaded) {
                if ([CoopUpdate]::Error) { $lblUpdate.Text = "Update failed: $([CoopUpdate]::Error)"; $btnUpdate.Enabled = $true; $script:updateState = "available"; return }
                $lblUpdate.Text = "Installing the update..."; $form.Refresh()
                Install-UpdateZip ([CoopUpdate]::ZipPath)
                $updateTimer.Stop()
                # restart the (updated) launcher; first start re-applies the hooks if they changed
                Start-Process -FilePath (Join-Path $GameDir "CoD4 Coop.bat") -WorkingDirectory $GameDir
                $form.Close()
            }
        }
    } catch { $lblUpdate.Text = "Update failed: $($_.Exception.Message)"; $script:updateState = "done" }
})
$btnUpdate.Add_Click({
    if (($script:hostingProc -and -not $script:hostingProc.HasExited) -or $script:lobby -or (Get-Process iw3sp -ErrorAction SilentlyContinue)) { $lblUpdate.Text = "Close the lobby/game first, then update."; return }
    $btnUpdate.Enabled = $false; $script:updateState = "downloading"
    [CoopUpdate]::Download([CoopUpdate]::ZipUrl, (Join-Path $env:TEMP "cod4-coop-update.zip"))
})
$form.Add_Shown({
    if (-not $env:COOP_NO_UPDATE) {
        try {
            if (-not ("CoopUpdate" -as [type])) { Add-Type -TypeDefinition $UpdaterCode -ReferencedAssemblies System.Core }
            [CoopUpdate]::Check($UpdateRepo); $script:updateState = "checking"; $updateTimer.Start()
        } catch {}
    }
})
$form.Add_Shown({
    if (-not (Test-CoopInstalled)) { Start-Setup }
})
# look for games on the network once the window is up (a search blocks for about a second)
$findTimer = New-Object System.Windows.Forms.Timer; $findTimer.Interval = 700
# (also when the window is back to idle; called directly: a click on a hidden button does nothing)
$findTimer.Add_Tick({ $findTimer.Stop(); if ($form.Visible -and $pnlIdle.Visible -and -not (Test-InGame)) { Search-LanGames } })
$script:autoFind = -not $env:COOP_LAUNCHER_SNAPSHOT -and -not $env:COOP_TEST_LOBBY
if ($script:autoFind) { $form.Add_Shown({ $findTimer.Start() }) }

$txtName.Text = $settings.name
Do-Layout
Update-Mode

# test hook: rig editor headless (COOP_TEST_RIGEDITOR=<rigprep json>, COOP_TEST_SHOT=<png>). Drags the L wrist
# marker with symmetry on, saves a screenshot, clicks "Rig it" (markers written back into the json), log in <json>.log
if ($env:COOP_TEST_RIGEDITOR) {
    $tj = $env:COOP_TEST_RIGEDITOR; $tlog = "$tj.log"; Set-Content -Path $tlog -Value "START"
    $fmt = { ($RigMarkers | ForEach-Object { $p = $script:rg.pts[$_.k]; "{0}={1},{2}" -f $_.k, [math]::Round($p[0], 1), [math]::Round($p[1], 1) }) -join " " }
    $test = {
        param($f)
        $pic = $script:rg.pic; $sc = $script:rg.scale
        Add-Content -Path $tlog -Value ("BEFORE " + (& $fmt))
        $p = $script:rg.pts["left_wrist"]; $x = [int]($p[0] * $sc); $y = [int]($p[1] * $sc)
        $call = { param($n, $ex, $ey)
            $ea = [System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::Left, 1, [int]$ex, [int]$ey, 0)
            [void]$pic.GetType().GetMethod($n, [Reflection.BindingFlags]"NonPublic,Instance").Invoke($pic, [object[]]@($ea.PSObject.BaseObject)) }
        & $call "OnMouseDown" ($x + 4) ($y + 3)          # grab a little off-centre (hit radius)
        & $call "OnMouseMove" ($x + 20) ($y + 12)
        & $call "OnMouseMove" ($x + 36) ($y + 24)
        Add-Content -Path $tlog -Value ("DRAG " + $script:rg.drag)
        & $call "OnMouseUp" ($x + 36) ($y + 24)
        Add-Content -Path $tlog -Value ("AFTER " + (& $fmt))
        $c = Rig-Centre; $l = $script:rg.pts["left_wrist"]; $r = $script:rg.pts["right_wrist"]
        Add-Content -Path $tlog -Value ("MIRROR centre={0} left={1} right={2} ok={3}" -f [math]::Round($c, 1), [math]::Round($l[0], 1), [math]::Round($r[0], 1), ([math]::Abs(($l[0] + $r[0]) / 2 - $c) -lt 0.01 -and $l[1] -eq $r[1]))
        if ($env:COOP_TEST_RIGACTION) {      # optional: also press "turn" or "up" (re-runs rigprep through python)
            $b = $script:rg.turn; if ($env:COOP_TEST_RIGACTION -eq "up") { $b = $script:rg.up }
            [void]$b.GetType().GetMethod("OnClick", [Reflection.BindingFlags]"NonPublic,Instance").Invoke($b, @([EventArgs]::Empty))
            Add-Content -Path $tlog -Value ("ACTION " + $env:COOP_TEST_RIGACTION + ": " + ($script:rg.status.Text -replace "`r?`n", " / ") + " | " + $script:rg.info.Text)
            Add-Content -Path $tlog -Value ("LOADED " + (& $fmt))
        }
        if ($env:COOP_TEST_SHOT) {
            $f.Refresh()
            $bmp = New-Object System.Drawing.Bitmap $f.Width, $f.Height
            $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $f.Width, $f.Height)); $bmp.Save($env:COOP_TEST_SHOT); $bmp.Dispose()
        }
        [void]$script:rg.ok.GetType().GetMethod("OnClick", [Reflection.BindingFlags]"NonPublic,Instance").Invoke($script:rg.ok, @([EventArgs]::Empty))
    }
    try { $ok = Show-RigEditor $tj "" $test; Add-Content -Path $tlog -Value "RESULT $ok"; if (-not $ok) { Add-Content -Path $tlog -Value ("STATUS " + $script:rg.status.Text) } }
    catch { Add-Content -Path $tlog -Value "ERROR $($_.Exception.Message)" }
    exit
}

# test hooks: drive the lobby headless (COOP_TEST_LOBBY=host|join:<code>, results to COOP_NO_GAME file)
if ($env:COOP_TEST_LOBBY) {
    $click = { param($b) $b.GetType().GetMethod("OnClick", [Reflection.BindingFlags]"NonPublic,Instance").Invoke($b, @([EventArgs]::Empty)) }
    $log = { param($t) Add-Content -Path $env:COOP_NO_GAME -Value $t }
    if ($env:COOP_TEST_LOBBY -eq "host") {
        & $click $btnHost
        & $log ("CODES " + ((@($script:codes | ForEach-Object { "$($_.label): $($_.code)" }) + @($lblNotes.Text -split "`r`n" | Where-Object { $_ })) -join " / "))
        $end = (Get-Date).AddSeconds(40); $launched = $false
        while ((Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40
            if (-not $launched -and $script:lobby -and $script:lobby.members.Count -ge 1) {
                & $log ("LOBBY " + (@($lstLobby.Items) -join ", ")); Start-Sleep -Milliseconds 2500
                for ($k = 0; $k -lt 20; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
                & $click $btnLaunch; $launched = $true; & $log ("HOST " + ($lblJoinStatus.Text -replace "`r`n", " / ")); break
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
    if ($parts.Count -gt 1) { $tabStrip.SelectedIndex = [int]$parts[1] }
    if ($lstSkins.Items.Count) { $lstSkins.SelectedIndex = 0 }
    # COOP_TEST_STATE (comma list): lobby (opens it on COOP_TEST_PORT, 1 bot + a fake friend), joined (in a fake host's lobby),
    # profile (the profile panel open), update, uptodate, setup, joinlist, missionlist
    $states = @(([string]$env:COOP_TEST_STATE) -split ',' | Where-Object { $_ })
    $click = { param($b) [void]$b.GetType().GetMethod("OnClick", [Reflection.BindingFlags]"NonPublic,Instance").Invoke($b, @([EventArgs]::Empty)) }
    if ($states -contains "lobby") {
        $numBots.Value = 1; & $click $btnHost
        if ($script:lobby) { $script:lobby.members["192.0.2.7:28970"] = @{ name = "Soap-MacTavish"; ep = $null; seen = (Get-Date) }; Update-LobbyList }
    }
    if ($states -contains "joined") {     # nothing answers on loopback: only the look of the state
        $script:skinMsg = "skins: you already have the host's skins"
        $script:joining = @{ u = (New-ProbeSocket); ep = (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port)); ip = "127.0.0.1"; port = $Port
                             host = "Ghost-Actual"; lastSend = [datetime]::MaxValue; lastHeard = [datetime]::MaxValue; lastCheck = [datetime]::MaxValue; mission = ""; names = @() }
        Set-JoinedInfo "Prologue 2 - Crew Expendable (cargoship)" @("Ghost-Actual", "Bot 1", $settings.name)
        $lblJoinStatus.Text = "Waiting for Ghost-Actual to launch the game.`r`n$($script:skinMsg)"
    }
    if ($states -contains "profile") { Toggle-Profile $true }
    if ($states -contains "update") { $lblUpdate.Text = "Version 9.9.9 is out (you have $(Get-InstalledVersion))."; $btnUpdate.Text = "Update to 9.9.9"; $btnUpdate.Visible = $true }
    if ($states -contains "uptodate") { $lblUpdate.Text = "Version $(Get-InstalledVersion) (up to date)" }
    if ($states -contains "setup") {
        $script:setupActive = $true; Update-Mode
        $lblJoinStatus.Text = "First start: setting up the coop scripts from your own game files...`r`nreading your game files: 3 of 11"
    }
    if ($states -contains "joinlist") {
        $script:lanGames = @([pscustomobject]@{ ip = "192.168.1.20"; port = $Port; host = "Ghost-Actual"; map = "lobby"; players = "2/4" },
                             [pscustomobject]@{ ip = "100.101.1.2"; port = $Port; host = "Price"; map = "cargoship"; players = "3/4" })
        Show-LanGames; $lstLan.SelectedIndex = 0
    }
    if ($states -contains "missionlist") {     # the open drop-down list, drawn item by item
        $ih = $cmbMis.ItemHeight; $dw = $cmbMis.DropDownWidth; $lb = New-Object System.Drawing.Bitmap $dw, ($ih * $cmbMis.Items.Count)
        $lg = [System.Drawing.Graphics]::FromImage($lb)
        $od = $cmbMis.GetType().GetMethod("OnDrawItem", [Reflection.BindingFlags]"NonPublic,Instance")
        for ($i = 0; $i -lt $cmbMis.Items.Count; $i++) {
            $st = [System.Windows.Forms.DrawItemState]::None; if ($i -eq 3) { $st = [System.Windows.Forms.DrawItemState]::Selected }
            $ea = New-Object System.Windows.Forms.DrawItemEventArgs $lg, $cmbMis.Font, (New-Object System.Drawing.Rectangle 0, ($i * $ih), $dw, $ih), $i, $st
            [void]$od.Invoke($cmbMis, [object[]]@($ea.PSObject.BaseObject))
        }
        $lb.Save($parts[0] + ".list.png"); $lg.Dispose(); $lb.Dispose()
    }
    Do-Layout
    if ($env:COOP_TEST_LIVE) {
        # shown (invisibly) and captured as painted (DrawToBitmap skips native parts such as combo boxes)
        $form.Opacity = 0.01; $form.ShowInTaskbar = $false     # on screen but invisible: off-screen windows lose their content
        $shotTimer = New-Object System.Windows.Forms.Timer; $shotTimer.Interval = 900
        $shotTimer.Add_Tick({
            $shotTimer.Stop(); $form.Refresh()
            for ($k = 0; $k -lt 15; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
            $b = [CoopTheme]::Capture($form); $b.Save($parts[0]); $b.Dispose(); $form.Close()
        })
        $form.Add_Shown({ $shotTimer.Start() })
        [void]$form.ShowDialog(); exit
    }
    $mk = [System.Windows.Forms.Control].GetMethod("CreateHandle", [Reflection.BindingFlags]"NonPublic,Instance")
    function Make-Handles($c) { if (-not $c.IsHandleCreated) { [void]$mk.Invoke($c, $null) }; foreach ($x in $c.Controls) { Make-Handles $x } }
    Make-Handles $form
    $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    $bmp.Save($parts[0]); exit
}
Do-Layout
[void]$form.ShowDialog()
