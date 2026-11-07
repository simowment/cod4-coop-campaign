# MODLOG — CoD4 SP Coop Campaign

## Install facts (verified 2026-11-07)
- Game: `C:\Users\got\Downloads\Call.of.Duty.4.Modern.Warfare\Call of Duty 4-Modern Warfare`
- `iw3sp.exe` only (3,017,216 bytes, version string `1.0`). No `iw3mp.exe`, no MP zones. No `.iwd` — images/sound/video are loose under `main/`.
- Zones: `zone/english/*.ff`, header `IWffu100` + version 5, rest is one zlib stream.
- Zone load order (exe strings @0x28d4fb): `code_post_gfx, ui, common, mod`, then the level zone. Mod zone path `%s\%s\%s.ff` = `<base>\<fs_game>\mod.ff`. Exe has "Override asset '%s' from zone '%s' with zone '%s'" → later zones override earlier.
- `fs_game` must be "" or a subdir of `mods/`.
- GSC builtins present in exe: openfile, closefile, freadln, fgetarg, fprintln, fprintfields, getdvar/getdvarint/getdvarfloat, setdvar, setsaveddvar, magicbullet, playerlinkto/playerlinktodelta/playerlinktoabsolute.
- Profiles: `players/profiles` (empty at start).

## Derived data (NOT in repo, never ship)
- Extracted rawfiles: `C:\Users\got\cod4-decomp\raw` (617 gsc). Tool: `C:\Users\got\cod4-decomp\tools\ffdump.py`.
- Decompressed zones: `C:\Users\got\cod4-decomp\raw\_zones\*.zone`.

## Gotchas
1. Bash tool in this environment collapses `\\` in quoted strings — write Python with the Write tool, use `\x5c` in CLI regex.

## Route
(pending research workflow wf_28cc30e5-9b9)
