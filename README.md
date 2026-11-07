# CoD4 Coop Campaign

Play the Call of Duty 4: Modern Warfare single-player campaign with 2–4 players over LAN or the internet.

> Status: **pre-release / untested in game.** The network layer passes its offline tests (loopback,
> 30% packet loss). The in-game slice has not been run yet; see "Verification" below.

## How it works

CoD4's single-player executable (`iw3sp.exe`) has no network code at all. The multiplayer engine has
no AI, which is why nobody has shipped a campaign coop for this game. This mod takes another route:

- **Dual simulation.** Every player runs the real campaign in their own `iw3sp.exe`. Cinematics,
  rigs, vehicle rides, the AC-130 and turrets therefore run natively for each player. The mod keeps
  the worlds in step:
  - **Progression flags** are merged. A flag set by any player is set for everyone, and only the host
    can clear one.
  - **Trigger hits.** When you walk into a trigger, it fires on your squadmates' copies too.
  - **AI deaths.** The host reports every death and clients report their own kills. AI are matched
    by spawner and spawn order.
  - **Checkpoints** come from the host only, so everyone holds the same save.
  - **Mission fail.** If one player fails, the squad fails, and everyone reloads the shared checkpoint.
  - **Level end.** The host finishes the level. A client who reaches the end first waits for the host.
  - **Level start barrier.** A mission does not start until the whole squad has loaded it, then
    everyone starts on the same frame.
- **Squadmates are visible.** Each remote player is drawn as an animated soldier: stance,
  run/walk/sprint/crawl, aiming, and their weapon. Their gunfire is replayed, so you see tracers and
  impacts and hear the shots. Enemies near a squadmate shoot at them.
- **Downed and revive.** Lethal damage puts you down: you go prone, enemies ignore you, and you can
  still use your weapon. A squadmate holds [Use] next to you to revive you. If you bleed out while
  someone is still up, you regroup next to them. The squad only fails when everyone is down.
- **Per-level handling** lives in `mod/maps/_coop_lvl_<level>.gsc`. It covers player-local state,
  pulling a straggler into a scene a squadmate started, hiding squadmates during rigs, and
  kill/out-of-bounds volumes that should only affect you.
- **Native proxy (`d3d9.dll`).** The game loads it as its Direct3D 9 DLL. It forwards to the real
  `d3d9.dll`, runs a UDP session (host relays, reliable ordered events plus 20 Hz poses), and wires
  six script functions that are compiled out in retail (`openfile`, `fprintln`, `freadln`,
  `fprintfields`, `fgetarg`, `closefile`) to that session. It touches nothing else and does nothing
  on an unknown game build.

## Requirements

- CoD4 single player, **`iw3sp.exe` 1.0**: 3,017,216 bytes, SHA256 `d07c39ee…e116`. Any other build
  makes the proxy turn itself off (pure passthrough). Builds 1.5 and later and Steam need their own
  address table, which is not done yet.
- The **DirectX 9.0c End-User Runtime** (it provides `d3dx9_34.dll`, which CoD4 needs). Get it from
  Microsoft.
- Python 3 to run the build script. It reads your own game files and writes the mod into your game
  folder; no game files ship with this mod.
- A network path between players on **UDP 28970**: LAN, a VPN such as Tailscale, ZeroTier or Radmin,
  or a port forward on the host.

## Install

```bash
python tools/build.py --game "C:/path/to/Call of Duty 4-Modern Warfare"
```

This writes `Mods/coop/`, `d3d9.dll`, `Coop - Host.bat` and `Coop - Join.bat` into the game folder.
To build the native proxy yourself, run `bash native/build.sh`. It needs mingw `gcc`/`ld`/`dlltool`
and builds a freestanding PE32 with no CRT.

To uninstall, delete `d3d9.dll`, `Mods/coop` and the two `.bat` files.

## Play

1. Host: run `Coop - Host.bat` and enter your name, the mission (e.g. `cargoship`) and the squad size.
   The mission holds on "Waiting for your squad to load…".
2. Friends: run `Coop - Join.bat` and enter the host's IP. Their game loads the host's mission by
   itself, and everyone starts together.
3. Later missions follow the host automatically. A friend who joins mid-mission is caught up on
   progression and moved to the host.

Manual launch options: `+set fs_game mods/coop` plus either `+set coop_host 1` (optionally
`+set coop_wait N`, `+set coop_port P`, `+set coop_maxplayers N`) or `+set coop_connect ip[:port]`,
and `+set coop_name "Name"`. Without `coop_host` or `coop_connect` the mod stays out of the way and
the campaign plays solo.

## Known limits

- Each player's AI is simulated locally. Scripted waves line up, but positions drift, and an enemy
  can survive on one screen for a moment after it died on another.
- Remote shots are cosmetic plus approximate damage. Kills are what count.
- Squadmates use a friendly soldier model borrowed from the level, since SP has no player body.
- During scripted rigs (rappels, vehicles, the AC-130) squadmates are hidden, because both players
  occupy the same seat in their own world.

## Verification

- `native/test/harness.c` runs the session code offline. Host and client run over loopback with the
  join, the map handshake, the barrier, reliable events and poses. Under 30% simulated packet loss
  all events arrived in order with no gaps.
- `python tools/gsclint.py` statically checks every mod script. It verifies function references
  against the stock scripts and the engine builtin table and reports 0 false positives on the stock
  files.
- **In game: not yet run.** On the development machine the game could not start because the DirectX
  9 runtime is missing.

## Credits

Built with AI assistance (Claude Code). The research drew on public work by the CoD4 modding
community. The addresses for this exe were derived independently by disassembly. Publicly documented
1.5 addresses from JerryALT's iw3sp_mod and kejjjjj's iw3sptool were used as reference only.
