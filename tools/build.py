"""Build the coop mod into <game>/Mods/coop from the user's own install.

  python tools/build.py [--game "<install dir>"]

1. Stock scripts listed in patches.PATCHES are read from the user's fastfiles,
   patched at anchored points, and written as loose files (fs_game loose files
   override fastfile rawfiles in iw3sp).
2. Our own scripts in mod/ are copied verbatim.
3. The native proxy (native/build/d3d9.dll) is copied next to iw3sp.exe if built.
"""
import argparse
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ffraw  # noqa: E402
import patches  # noqa: E402

DEFAULT_GAME = os.path.join(os.path.dirname(ROOT), 'Call of Duty 4-Modern Warfare')


def apply_edits(name, text, edits):
    for anchor, mode, payload in edits:
        hits = list(re.finditer(anchor, text, re.M))
        if len(hits) != 1:
            raise SystemExit('patch anchor for %s matched %d times: %r' % (name, len(hits), anchor))
        m = hits[0]
        if mode == 'after':
            text = text[:m.end()] + payload + text[m.end():]
        elif mode == 'before':
            text = text[:m.start()] + payload + text[m.start():]
        elif mode == 'replace':
            text = text[:m.start()] + payload + text[m.end():]
        else:
            raise SystemExit('bad mode ' + mode)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', default=DEFAULT_GAME)
    ap.add_argument('--mod', default='coop')
    a = ap.parse_args()
    exe = os.path.join(a.game, 'iw3sp.exe')
    if not os.path.isfile(exe):
        raise SystemExit('iw3sp.exe not found in ' + a.game)
    out = os.path.join(a.game, 'Mods', a.mod)
    os.makedirs(out, exist_ok=True)

    n = 0
    for p in patches.PATCHES:
        src = ffraw.find(a.game, p['file'], p.get('zones', ('common',))).decode('latin-1')
        src = apply_edits(p['file'], src, p['edits'])
        dst = os.path.join(out, p['file'])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'w', encoding='latin-1', newline='') as f:
            f.write(src)
        n += 1
    print('patched stock scripts:', n)

    mod_src = os.path.join(ROOT, 'mod')
    c = 0
    for dp, _, fs in os.walk(mod_src):
        for fn in fs:
            s = os.path.join(dp, fn)
            d = os.path.join(out, os.path.relpath(s, mod_src))
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copyfile(s, d)
            c += 1
    print('copied mod files:', c)

    dll = os.path.join(ROOT, 'native', 'build', 'd3d9.dll')
    if os.path.isfile(dll):
        shutil.copyfile(dll, os.path.join(a.game, 'd3d9.dll'))
        print('installed d3d9.dll proxy')
    print('done ->', out)


if __name__ == '__main__':
    main()
