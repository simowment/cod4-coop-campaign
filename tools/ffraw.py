"""Read rawfiles (GSC etc.) out of the user's own CoD4 PC fastfiles (IWffu100 v5, zlib).

Nothing extracted here is shipped; build.py uses it to patch stock scripts on the user's machine.
"""
import os
import re
import zlib

_PAT = re.compile(
    rb'\xff\xff\xff\xff(.{4})\xff\xff\xff\xff'
    rb'([a-zA-Z0-9_/\\.\-]{3,120}\.(?:gsc|csv|cfg|txt|menu|str|vision|atr|gdt|shock|arena|sun))\x00',
    re.S)

_cache = {}


def inflate(path):
    d = open(path, 'rb').read()
    if d[:8] != b'IWffu100':
        raise ValueError('not an IW3 fastfile: %s' % path)
    return zlib.decompress(d[12:])


def rawfiles(ff_path):
    """Return {name: bytes} for every rawfile in the zone (later duplicates win)."""
    if ff_path in _cache:
        return _cache[ff_path]
    z = inflate(ff_path)
    out = {}
    for m in _PAT.finditer(z):
        ln = int.from_bytes(m.group(1), 'little')
        if 0 < ln < 8_000_000:
            out[m.group(2).decode().replace('\\', '/')] = z[m.end():m.end() + ln]
    _cache[ff_path] = out
    return out


def find(game_dir, name, zones=('common',)):
    for zn in zones:
        p = os.path.join(game_dir, 'zone', 'english', zn + '.ff')
        rf = rawfiles(p)
        if name in rf:
            return rf[name]
    raise KeyError('%s not found in %s' % (name, zones))
