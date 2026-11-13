"""Build the player release zip: unzip into the game folder (next to iw3sp.exe) and run CoD4 Coop.bat.

  python tools/release.py            -> build/release/cod4-coop-<version>.zip

Contains only this project's files: d3d9.dll, the launcher, Mods/coop (coop scripts, the stock-script hook
list, skin tools). The launcher applies the hooks to the player's own fastfiles on first start.
"""
import os
import re
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    ver = re.search(r'c\.version = "([^"]+)"', open(os.path.join(ROOT, 'mod', 'maps', '_coop.gsc')).read()).group(1)
    stage = os.path.join(ROOT, 'build', 'release', 'stage')
    shutil.rmtree(stage, ignore_errors=True)
    subprocess.run([sys.executable, os.path.join(HERE, 'build.py'), '--stage', stage], check=True)
    if not os.path.isfile(os.path.join(stage, 'd3d9.dll')):
        sys.exit('native/build/d3d9.dll missing: run native/build.sh first')
    for junk in ('maps/_coop_skins.gsc.generated',):
        p = os.path.join(stage, 'Mods', 'coop', junk)
        if os.path.exists(p):
            os.remove(p)
    out = os.path.join(ROOT, 'build', 'release', 'cod4-coop-%s.zip' % ver)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for dp, _, fs in os.walk(stage):
            for f in fs:
                full = os.path.join(dp, f)
                z.write(full, os.path.relpath(full, stage))
    print('release:', out, os.path.getsize(out) // 1024, 'KB')


if __name__ == '__main__':
    main()
