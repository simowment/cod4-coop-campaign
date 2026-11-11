"""Link every skin staged by rebind.py into one skin pack (mod.ff) with the OAT Linker.

  python tools/skin/pack.py

Writes build/skins/zone_out/mod.ff and build/skins/skins.txt (one model name per line). tools/build.py
installs both (plus the loose .iwi textures) and generates maps/_coop_skins.gsc from the list, so the game
knows which skins it can precache. Everyone in a session needs the same pack to see each other's skins.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import skinenv  # noqa: E402
SKINS = skinenv.WORK
LINKER = skinenv.LINKER
COMMON = os.path.join(skinenv.ZONES, 'common.ff')


def main():
    skinenv.ensure_all()
    xdir = os.path.join(SKINS, 'xmodel')
    models = sorted(f[:-5] for f in os.listdir(xdir) if f.endswith('.json')) if os.path.isdir(xdir) else []
    if not models:
        sys.exit('no skins staged: run tools/skin/rebind.py first')
    import json
    lines = ['>game,IW3', '', 'techniqueset,,mc_l_sm_r0c0', 'image,,$identitynormalmap']
    for m in models:
        manifest = os.path.join(xdir, m + '.skin')
        if not os.path.isfile(manifest):
            sys.exit('%s was staged by an older rebind.py: run rebind.py again for it' % m)
        lines += json.load(open(manifest))['assets']
    os.makedirs(os.path.join(SKINS, 'zone_source'), exist_ok=True)
    open(os.path.join(SKINS, 'zone_source', 'mod.zone'), 'w').write('\n'.join(lines) + '\n')
    r = subprocess.run([LINKER, '-b', '.', '--add-asset-search-path', '.', '--source-search-path', './zone_source',
                        '--load', COMMON, '--output-folder', './zone_out', 'mod'], cwd=SKINS, capture_output=True, text=True)
    print(r.stdout[-600:])
    if r.returncode != 0:
        sys.exit('linker failed')
    open(os.path.join(SKINS, 'skins.txt'), 'w').write('\n'.join(models) + '\n')
    print('skin pack:', ', '.join(models))


if __name__ == '__main__':
    main()
