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
        try { $maps.Remove($Port, "TCP") } catch {}
        try { [void]$maps.Add($Port, "TCP", $Port, $lanIp, $true, "CoD4 Coop skins") } catch {}
        $m = $maps.Add($Port, "UDP", $Port, $lanIp, $true, "CoD4 Coop")
        if ($m -and $m.ExternalIPAddress) { return $m.ExternalIPAddress }
    } catch {}
    return $null
}

function Close-RouterPort {
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
# skin pack sync: everyone sees a player's skin only if it is in their own pack, so the host's launcher
# serves its pack over TCP on the game port number, and a joining launcher downloads it if it differs.
# Pack = Mods/coop/mod.ff + images/coop_*_col.iwi + skins.txt.
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function Get-PackFiles {
    $mod = Join-Path $GameDir "Mods\coop"
    $skins = Join-Path $mod "skins.txt"
    if (-not (Test-Path (Join-Path $mod "mod.ff")) -or -not (Test-Path $skins) -or -not ((Get-Content $skins) -match '\S')) { return @() }
    $files = @("mod.ff", "skins.txt")
    $files += @(Get-ChildItem (Join-Path $mod "images") -Filter "coop_*_col.iwi" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "images/" + $_.Name })
    return $files
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
    $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.ZipArchiveMode]::Read)
    foreach ($e in $zip.Entries) {
        if ($e.FullName -notmatch '^(mod\.ff|skins\.txt|images/coop_[a-z0-9_]+_col\.iwi)$') { continue }   # nothing else is accepted
        $dst = Join-Path $mod ($e.FullName -replace '/', '\')
        [void](New-Item -ItemType Directory -Force (Split-Path $dst))
        $r = $e.Open(); $fs = [IO.File]::Create($dst); $r.CopyTo($fs); $fs.Close(); $r.Close()
    }
    $zip.Dispose()
    # the game reads the list of skins it may precache from this script
    $names = @(Get-Content (Join-Path $mod "skins.txt") | Where-Object { $_ -match '^coop_[a-z0-9_]+$' })
    $g = "// generated by the launcher from the host's skin pack`n`nlist()`n{`n`ts = [];`n"
    foreach ($n in $names) { $g += "`ts[ s.size ] = `"$n`";`n" }
    $g += "`treturn s;`n}`n"
    [IO.File]::WriteAllText((Join-Path $mod "maps\_coop_skins.gsc"), $g)
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
    $keep = '^(Mods/coop/(skins\.txt|mod\.ff|maps/_coop_skins\.gsc|images/coop_[^/]+)|coop_launcher\.json)$'
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
# window
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

$form = New-Object System.Windows.Forms.Form
$form.Text = "CoD4 Coop Campaign"; $form.Size = New-Object System.Drawing.Size(520, 484); $form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$font = New-Object System.Drawing.Font("Segoe UI", 10); $form.Font = $font

$lblName = New-Object System.Windows.Forms.Label; $lblName.Text = "Your name"; $lblName.Location = "16,16"; $lblName.AutoSize = $true
$txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = "110,13"; $txtName.Width = 170; $txtName.Text = $settings.name; $txtName.MaxLength = 24
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
function New-SkinBox([string]$current, [string]$loc, [int]$w) {
    $b = New-Object System.Windows.Forms.ComboBox; $b.DropDownStyle = "DropDownList"; $b.Location = $loc; $b.Width = $w
    Fill-SkinBox $b $current
    return $b
}
function Get-SkinChoice($b) { if ($b.SelectedIndex -le 0) { return "" } return [string]($script:SkinNames[$b.SelectedIndex - 1]).Trim() }
$lblSkin = New-Object System.Windows.Forms.Label; $lblSkin.Text = "Skin"; $lblSkin.Location = "292,16"; $lblSkin.AutoSize = $true
$cmbSkin = New-SkinBox $settings.skin "330,13" 160
$form.Controls.AddRange(@($lblName, $txtName, $lblSkin, $cmbSkin))

$btnUpdate = New-Object System.Windows.Forms.Button; $btnUpdate.Location = "330,410"; $btnUpdate.Size = "166,26"; $btnUpdate.Visible = $false
$lblUpdate = New-Object System.Windows.Forms.Label; $lblUpdate.Location = "14,414"; $lblUpdate.Size = "310,20"; $lblUpdate.Text = ""
$form.Controls.AddRange(@($btnUpdate, $lblUpdate))
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
        Start-PackServer
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
    Stop-PackServer
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
            $gone = @($L.members.Keys | Where-Object { ($now - $L.members[$_].seen).TotalSeconds -gt 30 })  # tolerate network hiccups
            foreach ($k in $gone) { $L.members.Remove($k) }
            if ($gone.Count) { Update-LobbyList }
        }
        if ($script:joining) { Step-JoinLobby }
        Step-PackServer
    } catch {}
})
$lobbyTimer.Start()
$numBots.Add_ValueChanged({ if ($script:lobby) { Update-LobbyList } })
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
    $lblJoinStatus.Text = "Checking the host's skins..."; $form.Refresh()
    $skinMsg = Sync-SkinPack $ip $port { param($t) $lblJoinStatus.Text = $t; $form.Refresh() }
    if ($skinMsg -match "got the host") { Refresh-Skins }
    $script:skinMsg = $skinMsg
    if ($info.map -ne "lobby") {
        $lblJoinStatus.Text = "Joining $($info.host) ($($info.map), $($info.players) players)..."; $form.Refresh()
        Join-Address $ip $port; return
    }
    if ($script:joining) { try { $script:joining.u.Close() } catch {} }
    $settings.name = $txtName.Text.Trim(); if (-not $settings.name) { $settings.name = "Player" }; Save-Settings
    $script:joining = @{ u = (New-ProbeSocket); ep = (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)); ip = $ip; port = $port
                         host = $info.host; lastSend = [datetime]::MinValue; lastHeard = (Get-Date); lastCheck = (Get-Date) }
    $lblJoinStatus.Text = "In $($info.host)'s lobby. Waiting for them to launch the game...`r`n$skinMsg"
}
function Step-JoinLobby {
    $J = $script:joining
    $now = Get-Date
    if (($now - $J.lastSend).TotalMilliseconds -gt 1000) { Send-Packet $J.u $J.ep 8 $settings.name; $J.lastSend = $now }
    foreach ($pk in (Receive-Packets $J.u)) {
        if ($pk.type -eq 9) {
            $J.lastHeard = $now
            $f = $pk.text.Split('|')
            $lblJoinStatus.Text = "In $($J.host)'s lobby ($($f[0])): $($f[1] -replace ',', ', ').`r`nWaiting for $($J.host) to launch the game. $($script:skinMsg)"
        } elseif ($pk.type -eq 10) {
            try { $J.u.Close() } catch {}
            $script:joining = $null
            $lblJoinStatus.Text = "$($J.host) launched the game: starting yours..."; $form.Refresh()
            Start-Sleep -Milliseconds 1500   # let the host's game take the port before we connect
            Join-Address $J.ip $J.port
            return
        }
    }
    # quiet for a while (a network hiccup, or the host launched while we missed the signal): look again and
    # either keep waiting in the lobby or join the running game; give up only after 3 minutes
    if (($now - $J.lastHeard).TotalSeconds -gt 6 -and ($now - $J.lastCheck).TotalSeconds -gt 4) {
        $J.lastCheck = $now
        $r = Probe-Host $J.ip $J.port
        if ($r -and $r.map -ne "lobby") {
            try { $J.u.Close() } catch {}
            $script:joining = $null
            $lblJoinStatus.Text = "$($J.host) is already in the game: joining it..."; $form.Refresh()
            Join-Address $J.ip $J.port
            return
        }
        if ($r) { $J.lastHeard = $now }
        elseif (($now - $J.lastHeard).TotalSeconds -gt 180) {
            try { $J.u.Close() } catch {}
            $script:joining = $null
            $lblJoinStatus.Text = "Lost $($J.host)'s lobby for 3 minutes. Click Join to try again."
        } else { $lblJoinStatus.Text = "Connection to $($J.host) is shaky, still trying..." }
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
$btnEditRig = New-Object System.Windows.Forms.Button; $btnEditRig.Text = "Edit rig..."; $btnEditRig.Location = "12,284"; $btnEditRig.Size = "150,28"
$tipSkins = New-Object System.Windows.Forms.ToolTip
$tipSkins.SetToolTip($btnEditRig, "Move the rig markers of the selected skin again and re-rig it. Only for models that came without a skeleton.")
$txtSkinLog = New-Object System.Windows.Forms.TextBox; $txtSkinLog.Multiline = $true; $txtSkinLog.ReadOnly = $true; $txtSkinLog.ScrollBars = "Vertical"; $txtSkinLog.Location = "172,218"; $txtSkinLog.Size = "290,94"; $txtSkinLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$txtSkinLog.Text = "Any humanoid model: GLB, glTF, DAE, OBJ (FBX needs Blender). Models without a skeleton (stand in a T- or A-pose) open the rig editor: drag the markers onto the joints and click Rig it. Friends need the same skins to see them."
$tabSkins.Controls.AddRange(@($lstSkins, $picSkin, $btnAddSkin, $btnRemoveSkin, $btnEditRig, $txtSkinLog))
$RigDir = Join-Path $GameDir "coop_skins\work\rigs"
$RigTmp = Join-Path $env:TEMP "coop_rig"
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
    $script:rg.size = $size; $script:rg.scale = 512.0 / $size
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
    $best = $null; $bd = 14.0; $sc = $script:rg.scale
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
        $dash.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash; $g.DrawLine($dash, $cx, [float]0, $cx, [float]512); $dash.Dispose()
    }
    $shadow = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(160, 0, 0, 0)), 5
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 255, 255, 255)), 2
    foreach ($b in $RigBones) {
        $a = $p[$b[0]]; $c = $p[$b[1]]
        $g.DrawLine($shadow, [float]($a[0] * $sc), [float]($a[1] * $sc), [float]($c[0] * $sc), [float]($c[1] * $sc))
        $g.DrawLine($pen, [float]($a[0] * $sc), [float]($a[1] * $sc), [float]($c[0] * $sc), [float]($c[1] * $sc))
    }
    $shadow.Dispose(); $pen.Dispose()
    $font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 2
    $dots = @(); foreach ($m in $RigMarkers) { $dots += , (New-Object System.Drawing.RectangleF ([float]($p[$m.k][0] * $sc - 10)), ([float]($p[$m.k][1] * $sc - 10)), ([float]20), ([float]20)) }
    $taken = New-Object System.Collections.ArrayList
    foreach ($m in $RigMarkers) {
        $x = [float]($p[$m.k][0] * $sc); $y = [float]($p[$m.k][1] * $sc)
        $r = [float]7; if ($script:rg.drag -eq $m.k -or $script:rg.hover -eq $m.k) { $r = [float]9 }
        $br = New-Object System.Drawing.SolidBrush $m.c
        $g.FillEllipse($br, $x - $r, $y - $r, 2 * $r, 2 * $r); $g.DrawEllipse($ring, $x - $r, $y - $r, 2 * $r, 2 * $r); $br.Dispose()
    }
    $i = 0
    foreach ($m in $RigMarkers) {
        $x = [float]($p[$m.k][0] * $sc); $y = [float]($p[$m.k][1] * $sc)
        $sz = $g.MeasureString($m.t, $font); $w = [float]$sz.Width; $h = [float]$sz.Height
        # labels sit outside the body; when that spot covers another marker or label, try above, below, then the other side
        $out = $x + 12; $in = $x - 12 - $w; if ($m.k -like "right_*") { $out = $x - 12 - $w; $in = $x + 12 }
        $cands = @(@($out, ($y - $h / 2)), @(($x - $w / 2), ($y - 12 - $h)), @(($x - $w / 2), ($y + 12)), @($in, ($y - $h / 2)))
        $pick = $cands[0]
        foreach ($c in $cands) {
            $rc = New-Object System.Drawing.RectangleF ([float]$c[0]), ([float]$c[1]), $w, $h
            $hit = $false
            for ($j = 0; $j -lt $dots.Count; $j++) { if ($j -ne $i -and $rc.IntersectsWith($dots[$j])) { $hit = $true; break } }
            if (-not $hit) { foreach ($t in $taken) { if ($rc.IntersectsWith($t)) { $hit = $true; break } } }
            if (-not $hit) { $pick = $c; break }
        }
        $tx = [float]$pick[0]; $ty = [float]$pick[1]
        [void]$taken.Add((New-Object System.Drawing.RectangleF $tx, $ty, $w, $h))
        $g.DrawString($m.t, $font, [System.Drawing.Brushes]::Black, [float]($tx + 1), [float]($ty + 1))
        $g.DrawString($m.t, $font, [System.Drawing.Brushes]::White, $tx, $ty)
        $i++
    }
    $ring.Dispose(); $font.Dispose()
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
    $r.form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $r.status.ForeColor = [System.Drawing.SystemColors]::ControlText
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
        else { $r.status.ForeColor = [System.Drawing.Color]::DarkRed; $r.status.Text = "Failed: " + $res.text }
    } catch { $r.status.ForeColor = [System.Drawing.Color]::DarkRed; $r.status.Text = "Failed: $($_.Exception.Message)" }
    finally { foreach ($b in $buttons) { $b.Enabled = $true }; $r.pic.Enabled = $true; $r.busy = $false; $r.form.Cursor = [System.Windows.Forms.Cursors]::Default }
}
# shows the editor on a rigprep json; on "Rig it" writes the markers back into it and returns $true
function Show-RigEditor([string]$json, [string]$src, [scriptblock]$test = $null) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Rig the character"; $f.ClientSize = New-Object System.Drawing.Size 760, 528
    $f.FormBorderStyle = "FixedDialog"; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.StartPosition = "CenterParent"
    $f.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    if ($test) { $f.StartPosition = "Manual"; $f.Location = New-Object System.Drawing.Point -4000, -4000; $f.ShowInTaskbar = $false }
    $pic = New-Object System.Windows.Forms.PictureBox; $pic.Location = "8,8"; $pic.Size = "512,512"; $pic.SizeMode = "StretchImage"
    $pic.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48)
    $help = New-Object System.Windows.Forms.Label; $help.Location = "532,8"; $help.Size = "220,222"
    $help.Text = "Drag each circle onto the middle of that joint. The character faces you, so its LEFT side is on the RIGHT of the picture.`r`n`r`nChin: just under the mouth.`r`nGroin: where the legs meet.`r`nElbows, wrists, knees: the centre of each joint.`r`n`r`nSeeing its back? Click Turn around. Lying on its back or front? Click Swap up axis."
    $sym = New-Object System.Windows.Forms.CheckBox; $sym.Text = "Symmetry (the other side follows)"; $sym.Location = "532,232"; $sym.AutoSize = $true; $sym.Checked = $true
    $info = New-Object System.Windows.Forms.Label; $info.Location = "532,258"; $info.Size = "220,36"
    $btnTurn = New-Object System.Windows.Forms.Button; $btnTurn.Text = "Turn around"; $btnTurn.Location = "532,296"; $btnTurn.Size = "220,30"
    $btnUp = New-Object System.Windows.Forms.Button; $btnUp.Text = "Swap up axis"; $btnUp.Location = "532,330"; $btnUp.Size = "220,30"
    $btnReset = New-Object System.Windows.Forms.Button; $btnReset.Text = "Reset markers"; $btnReset.Location = "532,364"; $btnReset.Size = "220,30"
    $status = New-Object System.Windows.Forms.Label; $status.Location = "532,400"; $status.Size = "220,78"
    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = "Rig it"; $btnOk.Location = "532,484"; $btnOk.Size = "124,36"
    $btnOk.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Location = "662,484"; $btnCancel.Size = "90,36"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.CancelButton = $btnCancel; $f.AcceptButton = $btnOk
    $f.Controls.AddRange(@($pic, $help, $sym, $info, $btnTurn, $btnUp, $btnReset, $status, $btnOk, $btnCancel))
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
        } catch { $script:rg.status.ForeColor = [System.Drawing.Color]::DarkRed; $script:rg.status.Text = "Could not save the markers: $($_.Exception.Message)" }
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

$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabJoin -and $lstLan.Items.Count -eq 0) { $btnFind.PerformClick() } })

# keep the router port open while hosting; close it when the game exits or the launcher closes
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ if ($script:hostingProc -and $script:hostingProc.HasExited) { Stop-PackServer; Close-RouterPort; $script:hostingProc = $null; $btnHost.Enabled = $true; $txtCodes.Text = "The game closed. Hosting stopped." } })
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
    if (-not (Test-CoopInstalled)) {
        $btnHost.Enabled = $false; $btnJoin.Enabled = $false; $btnJoinLan.Enabled = $false
        try { Start-CoopInstall; $setupTimer.Start() }
        catch { $txtCodes.Text = "Setup failed: $($_.Exception.Message)"; $btnHost.Enabled = $true; $btnJoin.Enabled = $true; $btnJoinLan.Enabled = $true }
    }
})

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
