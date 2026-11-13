# CoD4 Coop Campaign

Play the **Call of Duty 4: Modern Warfare** single-player campaign with 2–4 friends over LAN or the internet.
Host a mission, share a join code, play through the campaign together. Mission transitions, cutscenes,
checkpoints and failures stay in sync.

> **Status: alpha, playable.** Tested in game with two instances. The core loop works: joining,
> synchronized mission starts, squadmates, progression sync, down/revive, checkpoints, mission
> fail and mission transitions. Automated scene tests ran the key scripted sequence of all 20 other
> missions with no coop-caused errors (details below). A full campaign playthrough by humans has not
> been done yet.

## Quick start

1. Download `cod4-coop-<version>.zip` from the [latest release](../../releases/latest) and **unzip it into your game folder** (the one
   with `iw3sp.exe`). Double-click **`CoD4 Coop.bat`**. On first start it adds the coop hooks to the game's scripts, reading
   them from your own game files. That takes a few seconds, once.
2. **Host:** double-click `CoD4 Coop.bat`, enter your name, then **Host a game**. Pick a mission and how
   many players to wait for, and click **Start hosting**. Copy the **join code** (e.g. `2H092-T0W9A`) and send
   it to your friends.
3. **Friends:** double-click `CoD4 Coop.bat`, then **Join a friend**, paste the code and click **Join**.
   On the same network you don't need a code: the host shows up under *Games on your network*.
4. Each friend's game loads the host's mission by itself. The mission waits on *"Waiting for your squad to
   load..."* until everyone is in, and then everyone starts on the same frame.

### Playing with bots

Set **Bots** (0–3) on the host tab to add AI squadmates. They join the lobby right away and count toward
*Wait for*, so **Wait for 2 + Bots 1** starts at once, and friends can still join the free slots.

A bot runs inside the host's game and looks like any other squadmate: animated soldier, name tag, squad
HUD. It follows you along the path you walked, matches your stance, shoots enemies it can see (real
bullets, short bursts), and revives you about 3 seconds after you go down. During rides and rigs it rides
along out of sight. Friends who join see your bots too. A bot never goes down, never triggers story
events and never holds up a sync point; it doesn't use grenades or launchers.

### Character skins

Pick a **Skin** next to your name (and a skin for your bots on the host tab). Your game announces it, and
everyone who has that skin in their skin pack sees you wearing it. Anyone without it sees the normal soldier.
Everyone should install the same skin pack.

**Adding skins from the launcher:** open the **Skins** tab, click **Add character…** and pick a GLB, glTF, DAE,
OBJ or FBX file (FBX needs Blender). Models without a skeleton are **rigged automatically**: they should stand
in a T- or A-pose, and you tick "faces away" if the result comes out backwards. The tab shows a preview, and
**Remove** drops a skin. It needs Python 3 with `numpy` and `pillow`. On first use it downloads
OpenAssetTools and reads the soldier skeleton from your own game files. Everything lives in `coop_skins/`
next to the game.

From the command line (same tool):

```bash
python tools/skin/addskin.py add path/to/character.glb mychar
python tools/skin/addskin.py remove mychar
```

`rebind.py` finds each bone's role (pelvis, spine, arms, legs and fingers) from its name and the hierarchy, so
Mixamo, VRM/VRChat, Unreal, League and Nintendo-style rigs map without setup. It works out which way the model
faces, poses it onto CoD4's soldier skeleton, remaps the skin weights and merges cloth, hair and attach
bones into their parents. It drops weapon props, and gives every texture its own material. `--preview`
renders the result next to a stock soldier. `pack.py` links every staged skin into the skin pack (`mod.ff`),
and `build.py` installs it.

Limits:
- The auto-rig handles a humanoid in a T- or A-pose. It finds the shoulders, crotch and neck from the body
  shape, so cartoon proportions work. For odd poses, rigging in
  [Mesh2Motion](https://github.com/Mesh2Motion/mesh2motion-desktop) first gives better weights.
- FBX must be exported to GLB first, or use the DAE if the model comes with one.
- Body parts are placed on the soldier's joints, so very stylized proportions get stretched limbs or a head
  that rises above the soldier.
- Only the first texture layer of each material is used, unless a `--layers` preset says how to bake the layers.
  Some game rips need one, for example animated eye atlases drawn over pupil layers on extra UV sets
  (layer modes `multiply` or `under`, optional `scale`, one copy per body side with `+x`/`-x`). Example:
  `tools/skin/presets/mario_party_star_rush_luigi.json`.

### How the connection works

- The game uses **UDP port 28970** on the host.
- When you host, the launcher asks your router to open that port (UPnP). It reads your public address
  from the router, so no third-party service is contacted. The port is closed again when you stop
  hosting.
- If your router doesn't support UPnP (or you are behind carrier-grade NAT), use a VPN such as
  **Tailscale**, ZeroTier or Radmin. The launcher detects it and shows a VPN join code. A manual port
  forward of UDP 28970 also works.
- Join codes just encode `IP:port`. Typing a plain IP in the code box works too.

## Playing the campaign

- **Pick a mission** in the launcher, or use the game's own **New Game / Mission Select** menus as host.
  Whatever mission the host loads, every client follows, at the same start point and on the host's
  difficulty.
- **Mission to mission** works like solo. When the host completes a mission, every player gets the normal
  mission-success flow and the next mission's loading briefing, and the next mission starts for everyone
  together. A player who reaches the end first waits for the host. Missions unlock in each player's own
  profile.
- **Squadmates** appear as animated soldiers with name tags. Their gunfire is replayed, and the squad
  HUD (top left) shows names and health.
- **Down, not dead.** Lethal damage puts you down: prone, invulnerable, enemies ignore you. A squadmate
  holds **[Use]** next to you to revive you. If you bleed out (45 s) while someone is still up, you
  regroup next to them. The mission fails only when everyone is down.
- **Shared progress.** Story progress and the triggers you walk into apply in your squadmates' games
  too, enemy kills count for everyone, checkpoints come from the host, and if one player fails, the
  squad reloads the checkpoint together.
- **Cutscenes and scripted sequences** play natively for every player on their own screen (rigs,
  vehicles, the AC-130, turrets). When one player starts a scene, it starts for everyone, and a player
  who is far away is moved into it. Personal moments, such as the Killhouse course, the Coup drive and
  your own rescue animations, stay personal.

## How it works

CoD4's single-player executable has no network code, and the multiplayer engine has no AI, so neither
one can run the campaign for several players. This mod uses **dual simulation** instead: every player
runs the real campaign in their own `iw3sp.exe`, and the mod keeps the copies in step.

- **Native proxy (`d3d9.dll`).** The game loads it as its Direct3D 9 DLL, and it forwards to the real
  one. It runs a small UDP protocol: the host relays, reliable ordered events, and 20 Hz pose
  snapshots. It wires six script functions that are compiled out in retail (`openfile`, `fprintln`,
  `freadln`, `fprintfields`, `fgetarg`, `closefile`) to the session. It runs on the game's main loop,
  and it does nothing on an unknown game build.
- **Coop scripts** (`mod/maps/_coop*.gsc`):
  - replication: flags (delayed and deduplicated), trigger hits, enemy deaths, checkpoints, fail, level
    end;
  - remote-player puppets;
  - down/revive and the squad HUD.
- **One module per mission** (`mod/maps/_coop_lvl_<mission>.gsc`, 21 in all). Each was written from the
  mission's scripts and decides which moments are personal, which are shared, who gets pulled into a
  scene, and when squadmates are hidden.
- **Stock script hooks.** They are one-line insertions, applied at build time to scripts read from
  *your own* game files (`tools/patches.py`). No game files are distributed.

## Requirements

- CoD4 single player, **`iw3sp.exe` 1.0**: 3,017,216 bytes, SHA256 `d07c39ee…e116`. On any other build the
  proxy stays inactive and the game runs normally. Build 1.5+/Steam needs its own address table, which
  is not done yet.
- **DirectX 9.0c End-User Runtime** (`d3dx9_34.dll`), from Microsoft.
- **Windows PowerShell** (built in) runs the launcher. Nothing else is needed to play.
- **Python 3** with `numpy` and `pillow`, only for adding character skins (Skins tab).

## Install

1. Get `cod4-coop-<version>.zip` from the [latest release](../../releases/latest).
2. Unzip it into the game folder, next to `iw3sp.exe`. It contains `CoD4 Coop.bat`, `d3d9.dll` and `Mods/coop/`.
3. Run `CoD4 Coop.bat`. The first start patches the stock scripts from your own fastfiles into `Mods/coop/`.
   A new release re-applies the patch automatically.

To uninstall, delete `d3d9.dll`, `CoD4 Coop.bat`, `Mods/coop` and `coop_skins` (if you added skins).

### Building from source (developers)

```bash
bash native/build.sh                                      # d3d9.dll (mingw gcc/ld/dlltool, freestanding PE32, no CRT)
python tools/build.py --game "C:/path/to/Call of Duty 4-Modern Warfare"   # install straight into a game folder
python tools/release.py                                   # build/release/cod4-coop-<version>.zip
```

The release zip holds only this project's files. The stock-script hooks ship as data (`coop_patches.json`)
and are applied on each player's machine; `tools/build.py` and the launcher produce byte-identical scripts.

## Testing

| What | Result |
|---|---|
| Net protocol, offline (`native/test/harness.c`, host + client) | join, map handshake, barrier, ordered reliable events under 30% packet loss |
| Script lint (`tools/gsclint.py`) | 0 problems. Checks references against the stock scripts and the engine builtin table, reserved names, unsafe flag access, and level-specific references |
| In game, two instances on one PC (`tools/bg.ps1`, virtual monitor) | join, mission follow, start barrier, puppets, flags, triggers, kill sync (17/17), down/bleed-out/revive, checkpoint, mission fail, mission transition (bog_a → hunted) |
| Scene tests (`tools/scene_test.py`, `tests/scene_plans.json`) | 16/20 pass. The other 4 have no coop-caused errors: aftermath ended and airplane's timer failed both players, which is stock behaviour; blackout pulled the client into the scene as designed but the plan checked the wrong flag; airlift showed no script errors but did not finish cleanly and is still unexplained. Cargoship's ending was verified by hand |

## Known limits

- AI is simulated in each game separately. Scripted waves line up, but positions drift, and an enemy
  can survive a moment longer on one screen.
- Remote gunfire is cosmetic plus approximate damage; the kills that count are synced by ID.
- During vehicle rides and rigs, squadmates are hidden (you share one seat). Showing them in another seat
  is planned.
- Flags from other players arrive after a short safety delay (~4 s). Scenes started by triggers sync on
  the same frame.
- Only `iw3sp.exe` 1.0 is supported.

## Credits

Built with AI assistance (Claude Code), including reverse engineering of the 1.0 executable, the
network layer, the scripts and the in-game test automation. Addresses for this build were found by
disassembly. JerryALT's iw3sp_mod and kejjjjj's iw3sptool (patch 1.5) were used as reference only. Call
of Duty 4 is a trademark of Activision; this project contains no game files.
