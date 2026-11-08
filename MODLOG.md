# MODLOG — CoD4 SP Coop Campaign

## Install facts (verified 2026-11-07)
- Game: `C:\Users\got\Downloads\Call.of.Duty.4.Modern.Warfare\Call of Duty 4-Modern Warfare` (repack layout: CorePack.exe, loose main/ assets, no .iwd).
- `iw3sp.exe` only: 3,017,216 bytes, SHA256 `d07c39ee5865972a319a4a174be6134c59911f34fa9ebbafb815674af7d3e116`, PE TimeDateStamp 2007-10-04, version string `1.0`, image base 0x400000, no ASLR. No `iw3mp.exe`, no MP zones.
- Imports: DDRAW, GDI32, KERNEL32, SHELL32, USER32, WINMM, binkw32, d3d9 (only Direct3DCreate9), d3dx9_34, mscoree, mss32. **No winsock**, no Netchan: SV/CL are loopback only.
- **Game does not start on this PC**: exit 0xC0000135 = missing `d3dx9_34.dll` (DirectX 9.0c June 2007 runtime). SysWOW64 has d3dx9_24..32, 39, 43 only. User must install the DirectX End-User Runtime.
- Zones: `zone/english/*.ff`, `IWffu100` + version 5, then one zlib stream. Load order: code_post_gfx, ui, common, mod (`<base>\<fs_game>\mod.ff`), then the level. "Override asset ... with zone ..." means later zones win.
- `fs_game` must be "" or under `mods/`.

## Engine internals (iw3sp 1.0, by disassembly)
- Builtin table entries `{char* name; void(*fn)(); int dev}`, 12 bytes. Functions and methods are both dumped to `C:\Users\got\cod4-decomp\builtins_all.txt` (708 names) by `tools/methods.py`.
- openfile/closefile/fprintln/fprintfields/freadln/fgetarg are at VA 0x6de7b4..0x6de7f0, step 12, all fn=0x4da560 (`C3` = ret), dev=1. They are compiled out in retail, so **we repurpose them as the native bridge**.
- VM: top `*(VarValue**)0x1287250` (8-byte {u, type}); param i = top - i; arg count `*(int*)0x128725c`; push counter `*(int*)0x1287258`; stack end `0x1287244`. Types: 2 string (u = SL id), 3 istring, 4 vector, 5 float, 6 int.
- SL string = `*(char**)0xfdbdcc + id*12 + 4`.
- Scr_ClearOutParams 0x551d90 (cdecl; frees the args, so read params first). Scr_AddInt 0x5587c0 (cdecl int). Scr_AddString 0x558950 (esi = char*). The float push is inlined (copied from getdvarfloat 0x4c82c4). Scr_GetType 0x558650 (eax). Scr_GetInt 0x557d30 (eax). Scr_GetFloat 0x557fe0 (eax, st0). Scr_Error 0x558ca0 (ecx).
- Cbuf_AddText 0x52ff90 (eax = text, ecx = localClientNum). Dvar_SetIntByName 0x589090 (eax = value, push name). Dvar_FindVar 0x587560 (cdecl). The cl_paused dvar_t* is stored at 0x7fdddc.
- **No `islinked`, `angleclamp180` or `getstruct` builtins** (the last two are script functions). `vectorScale` is in common_scripts/utility.

## Route (decided)
- Dual simulation. Each player runs their own iw3sp level. The `d3d9.dll` proxy (forwards Direct3DCreate9 to SysWOW64) runs UDP and the GSC bridge. The Present hook ticks the network every rendered frame and forces cl_paused=1 during the level-start barrier and cl_paused=0 during coop.
- Script injection: **loose GSC under Mods/coop** (to be verified in game; fallback is mod.ff via OpenAssetTools or our own linker). Stock scripts are patched by anchored one-line hooks (`tools/patches.py`) from the user's own fastfiles at build time.
- Ship nothing derived from game files; `tools/build.py` regenerates the patched stock scripts on the user's machine.

## Derived data (NOT in repo, never ship)
- Extracted rawfiles: `C:\Users\got\cod4-decomp\raw` (617 gsc). Tools: `C:\Users\got\cod4-decomp\tools\{ffdump,dis,xref,methods,exegrep}.py`.
- Research reports: `C:\Users\got\cod4-decomp\rep_*.md`.

## Verified
- Net harness (`native/test/harness.c`), loopback: join, ~MAP, client follows (Cbuf "map bog_a"), ~RDY, barrier release, reliable events, interpolated poses, ping.
- Under 30% random loss, 100+ events arrived in order with no gaps.
- gsclint reports 0 false positives on _load/_utility/bog_a/_drone/blackout/_spawner.

## Not yet verified (needs the game running)
T1 loose GSC override wins; T2 bridge builtins callable with dev flag cleared in developer 0; Present hook installs; cl_paused barrier holds/releases; two instances on one PC; puppet anim on a fakeai script_model; downed threshold vs engine deathInvulnerableTime; dodamage while invulnerable; hud settext with plain strings.

## Gotchas
1. The Bash tool here collapses `\\` in quoted strings and in heredocs. Write Python with the Write tool and use `\x5c` in CLI regex.
2. Python heredocs through Bash turn `\n` inside string literals into real newlines. Use the Edit tool for C string escapes.
3. mingw64 here is x86_64-only. A 32-bit DLL needs `-m32 -ffreestanding` + `dlltool -m i386 --as-flags=--32 -k` import libs + `ld -m i386pe`; no CRT, so rt.c provides memcpy etc.
4. Windows Sleep(5) is about 15 ms, which inflates harness ping. The game ticks at frame rate.

## In-game verification (2026-11-07, two instances on one PC via a virtual monitor)
Setup: Virtual Display Driver 25.7.23 (monitor at x=1920), `tools/bg.ps1` (allowdupe, coop_background, coop_tag, per-instance mods/coop + mods/coopb), screenshots taken by the proxy inside Present.
- Join, host map follow, start barrier, both levels running (heartbeat level time advancing on both).
- Puppets: correct position and facing, name tag, full-body drone anims re-anchored on the network pose.
- Flags 16/16, trigger hit replicated (T|387), AI ids deterministic (17/17 axis had ids on both), host kills 17 sent / 17 received.
- Downed on lethal damage -> D|1 -> host HUD/puppet show downed; bleed-out respawn next to buddy.
- Checkpoint: host save -> S -> client commits (140 ms).
- Mission fail: X -> client fails -> both reload, stale events drained.
- Mission end: E -> both load the next mission (hunted) together, barrier released.

## Engine facts learned in game
- The game presents from its render backend thread; game-state work must run on the main loop (hook: call at 0x5956e4 -> Com_Frame 0x5356a0).
- WinMain refuses a second instance unless the command line starts with "allowdupe".
- An unfocused window gets cl_paused=1 every frame (5 sites, patched only in test mode).
- `+map X` on the command line can stall before the first server frame when unfocused; `coop_startmap` loads it from the menu instead.
- Compiling all 21 level modules overflowed the script variable pool on bog_a; each level now references only its own module.
- Fake-AI script models only animate via animscripted with full-body anims, drawn at the anchor (re-anchor per pose).
- `loc_warnings` and `fs_game` are internal or write-protected for scripts; set loc_warnings on the command line or through Cbuf.
- getentnum/getentbynum are dev builtins with full retail implementations; the method table is in .rdata (VirtualProtect).

## In-game verification, round 2
- Start points follow the host (~MAP|map|start -> "set start X; map Y"); cargoship `end` start matched on both.
- Cargoship ending: host flag end_start_player_anim -> client pulled to the jump spot, both play their own rescue scene. No coop-caused script errors (the remaining `self.position` error at cargoship_code.gsc:555 happens identically without a second player, from the dev start point).
- Down/revive round trip: D|1 -> downed HUD with countdown -> V|1 from the squadmate -> up at 50% health, D|0.

## Bugs found by playing (fixed)
1. Remote flags applied immediately raced the receiver's own setup (cargoship heroes_ready -> runtime error, which is fatal in retail). Remote flags now wait 4 s, are skipped if the world set them itself, and are never applied in the first 15 s of a level.
2. `delete()` fires "death": the host's kill sync killed story AI on the client. Only real deaths of axis AI are synced now.
3. get_up() notified the event its caller (bleed_out) ended on, which killed the get-up halfway.
4. `anim` is a reserved global; prone_crawl root motion dragged the puppet away; VIP models were used as the squadmate.

## Test environment
- The virtual monitor was removed again with `tools/vdd_uninstall.ps1` (2026-11-07). `tools/bg.ps1` places
  test instances at x=1920, so reinstall it first with `tools/vdd_install.ps1 <driver folder>`.

## Bots (2026-11-08)
- Host-side AI squadmates: `coop_bot N` on the host. The proxy gives each bot a connected slot with no link
  (`botMask`): it counts as ready for the barrier and as a player for `coop_wait`, HELLO skips its slot, and
  its pose/events are relayed to real clients. GSC drives it with `openfile("coop","as",slot)` + fprintfields/fprintln.
- Brain: `mod/maps/_coop_bot.gsc` (follow the host's breadcrumb trail, match stance, shoot visible axis within
  2200 units in 3-round bursts via the normal puppet shot replay, revive after 3 s, hide during rides).
- Verified in game (bog_a, one instance): join + HUD + puppet with M4, revive (V|0 3 s after D|1), follow at
  ~100 units, bot kills (target down after 3 shots; several more K events).
- Test-only artifact: in background mode the input-less host never lands after a teleport, so ride detection
  hides the bot. `+set coop_test_nolink 1` and test cmd `nearaxis` exist for this.

## Puppet animation fix + fast visual test (2026-11-08)
- `drone_stand_idle` / `drone_stand_run` are NOT xanims in this game ("Could not load xanim"): every standing
  puppet pose was a junk fallback. Now: casual_stand_idle, exposed_aim_5, walk_lowready_*, run_lowready_*,
  sprint1_loop, exposed_crouch_aim_5, prone_aim_5 (all full-body, in common.ff).
- Locomotion anims carry root motion; re-anchoring animscripted mid-cycle drew the body ahead of the real
  position (surge + snap = sliding, or off-screen). Anchor is now pulled back by getmovedelta(anim, 0, t).
- Bot ground trace hit the bot's own body (floating): traces ignore the puppet.
- Fast test loop: test mode rewrites the hard-coded "%s\main\video\%s.%s" to "%s\mods\ctv\%s.%s" with a
  468-byte stub (credits_load.bik) -> gameplay 3 s after load instead of 35-45 s. GSC can request a named
  screenshot at an exact moment: openfile("coop","shot",name). `bash tools/botdemo_test.sh <out> killhouse start`
  runs the whole bot animation check (16 phases x 2 frames + contact sheet) in ~66 s, on port 28971 and
  fs_game mods/cooptest so it never touches a running player game.
