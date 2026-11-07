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
