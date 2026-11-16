"""Custom emotes for the emote wheel (local files, built into the same pack as the skins).

  python addemote.py add <anim file> <name> [--music <wav/mp3/ogg...>] [--once] [--hold <seconds>]
                         [--skeleton <.uemodel>] [--no-fingers]
  python addemote.py remove <name>
  python addemote.py list

anim file: .ueanim (UEFormat; the .uemodel skeleton next to it is used, or --skeleton), GLB / glTF
           (Mixamo and Blender exports), FBX (needs Blender) or BVH.
add:       retargets it onto the CoD4 soldier skeleton, writes the xanim, converts the song (ffmpeg if found,
           else a .wav / .mp3 is used as is), rebuilds the pack (skins + emotes) and installs it.
           Dances loop until the song ends (no song: 3 loops, or --hold); --once plays it a single time.
           A preview of the retargeted pose is written to coop_skins/work/previews/emote_<name>.png.
           Up to 4 custom emotes (3 of them with a song); they take the wheel's last slices (8, 7, 6, 5).
remove:    drops it from the pack and reinstalls.
Progress goes to stdout line by line; the last line is "OK ..." or "ERROR ...".
"""
import json
import os
import re
import shutil
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import emotepack  # noqa: E402
import skinenv  # noqa: E402

EMDIR = os.path.join(skinenv.WORK, 'emotes')


def ident(name):
    return re.sub(r'[^a-z0-9_]', '_', name.lower()).strip('_') or 'emote'


def display(name):
    d = re.sub(r"[^A-Za-z0-9 _.!'-]", '', name).strip()[:14]
    return d or 'Emote'


def ffmpeg():
    exe = shutil.which('ffmpeg')
    return exe


def audio_seconds(path):
    """length of a song (ffprobe/ffmpeg if present, else wav header)"""
    ff = ffmpeg()
    if ff:
        r = subprocess.run([ff, '-hide_banner', '-i', path], capture_output=True, text=True, errors='replace')
        m = re.search(r'Duration: (\d+):(\d+):(\d+(?:\.\d+)?)', r.stderr)
        if m:
            return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    if path.lower().endswith('.wav'):
        import wave
        with wave.open(path) as w:
            return w.getnframes() / float(w.getframerate())
    return None


def convert_music(src, m, out_dir=None):
    """-> (file name in out_dir (default emotes/sound), seconds). mp3 at 44.1 kHz stereo (the game's own
    music format)."""
    out_dir = out_dir or os.path.join(EMDIR, 'sound')
    os.makedirs(out_dir, exist_ok=True)
    ff = ffmpeg()
    ext = os.path.splitext(src)[1].lower()
    if ff:
        name = emotepack.music_file(m, '.mp3')
        dst = os.path.join(out_dir, name)
        r = subprocess.run([ff, '-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-t', str(emotepack.MAX_MS / 1000.0),
                            '-vn', '-ac', '2', '-ar', '44100', '-b:a', '160k', dst], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(dst):
            raise SystemExit('ffmpeg could not convert the song: ' + r.stderr[-300:])
    elif ext in ('.mp3', '.wav'):
        name = emotepack.music_file(m, ext)
        dst = os.path.join(out_dir, name)
        shutil.copyfile(src, dst)
    else:
        raise SystemExit('the song must be .mp3 or .wav (or install ffmpeg to convert other formats)')
    return name, audio_seconds(dst)


def load_all():
    out = {}
    if os.path.isdir(EMDIR):
        for f in os.listdir(EMDIR):
            if f.endswith('.json'):
                try:
                    out[f[:-5]] = json.load(open(os.path.join(EMDIR, f), encoding='utf-8'))
                except ValueError:
                    pass
    return out


def drop(eid, keep_files=False):
    e = load_all().get(eid)
    if not e:
        return None
    for p in [os.path.join(EMDIR, eid + '.json'), os.path.join(skinenv.WORK, 'previews', 'emote_%s.png' % eid)] + \
            ([] if keep_files else [os.path.join(skinenv.WORK, 'xanim', e.get('node', '?'))]) + \
            ([os.path.join(EMDIR, 'sound', e['music_file'])] if e.get('music_file') else []):
        if os.path.isfile(p):
            os.remove(p)
    return e


def add(a):
    import retarget
    import xanim
    skinenv.ensure_all()
    eid = ident(a.name)
    have = load_all()
    old = have.pop(eid, None)
    used = {e['node'] for e in have.values()}
    if old and old.get('node') in emotepack.SLOTS:
        node = old['node']
    else:
        free = [s for s in emotepack.SLOTS if s not in used]
        if not free:
            raise SystemExit('all %d custom emote slots are taken (%s): remove one first'
                             % (len(emotepack.SLOTS), ', '.join(sorted(e['name'] for e in have.values()))))
        node = free[0]
    skinenv.say('reading %s ...' % os.path.basename(a.file))
    clip = retarget.load_clip(a.file, a.skeleton)
    cod = retarget.CodSkel(skinenv.COD_BODY)
    skinenv.say('retargeting onto the CoD4 skeleton ...')
    loop = not a.once
    spec, poses = retarget.retarget(clip, cod, loop=loop, fingers=not a.no_fingers, log=skinenv.say)
    num, fps, _, tracks = spec
    data = xanim.build(*spec)
    anim_s = (num if loop else max(1, num - 1)) / float(fps)
    msl, mfile, msec = None, None, None
    if a.music:
        taken = {e.get('music_slot') for e in have.values()}
        if old and old.get('music_slot') is not None:
            msl = old['music_slot']
        else:
            free = [k for k in range(len(emotepack.TEMPLATES)) if k not in taken]
            if not free:
                raise SystemExit('only %d custom emotes can have a song: remove one with music first' % len(emotepack.TEMPLATES))
            msl = free[0]
        # convert first (into a temp folder): if that fails, a re-added emote keeps its old files
        skinenv.say('converting the song %s ...' % os.path.basename(a.music))
        tmp = os.path.join(EMDIR, 'sound', '_new')
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        try:
            mfile, msec = convert_music(a.music, msl, tmp)
            if old:
                drop(eid)       # its old song file
            os.replace(os.path.join(tmp, mfile), os.path.join(EMDIR, 'sound', mfile))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    elif old:
        drop(eid, keep_files=True)
    if a.hold:
        hold = a.hold
    elif loop and msec:
        hold = msec
    elif loop:
        hold = anim_s * 3
    else:
        hold = anim_s
    hold_ms = int(min(emotepack.MAX_MS, max(hold, 0.5 if not loop else anim_s) * 1000))
    os.makedirs(os.path.join(skinenv.WORK, 'xanim'), exist_ok=True)
    with open(os.path.join(skinenv.WORK, 'xanim', node), 'wb') as f:
        f.write(data)
    os.makedirs(os.path.join(skinenv.WORK, 'previews'), exist_ok=True)
    prev = retarget.preview(cod, poses, os.path.join(skinenv.WORK, 'previews', 'emote_%s.png' % eid),
                            '%s  (%d frames, %s fps%s)' % (display(a.name), num, fps, ', loop' if loop else ''))
    e = {'id': eid, 'name': display(a.name), 'node': node, 'loop': loop, 'frames': num, 'fps': fps,
         'anim_s': round(anim_s, 3), 'hold_ms': hold_ms, 'music_slot': msl,
         'music': emotepack.music_alias(msl) if msl is not None else None, 'music_file': mfile,
         'source': os.path.abspath(a.file), 'song': os.path.abspath(a.music) if a.music else None}
    os.makedirs(EMDIR, exist_ok=True)
    with open(os.path.join(EMDIR, eid + '.json'), 'w', encoding='utf-8') as f:
        json.dump(e, f, indent=1)
    skinenv.say('%s: %d bones, %.2f s%s, plays %.1f s%s' % (e['name'], len(tracks), anim_s, ' loop' if loop else '',
                                                           hold_ms / 1000.0, ', song %.1f s' % msec if msec else ''))
    skinenv.say('building the pack ...')
    import addskin
    addskin.repack()
    print('OK emote %s slot %s preview=%s' % (e['name'], node, prev), flush=True)


SRC_DIR = os.path.join(skinenv.GAME, 'coop_skins', 'emotes')   # one folder per emote with its source files


def from_folder(a):
    """'add swipeit' (or a folder path): take the files from coop_skins/emotes/<name>/ - the animation
    (.ueanim, preferring the male *CMM* one; else .glb/.gltf/.fbx/.bvh), its .uemodel skeleton and a song."""
    d = a.file if os.path.isdir(a.file) else os.path.join(SRC_DIR, a.file)
    if os.path.isfile(a.file) or not os.path.isdir(d):
        return
    files = sorted(os.listdir(d))
    pick = lambda exts: [os.path.join(d, f) for f in files if f.lower().endswith(exts)]
    anims = pick(('.ueanim',))
    anims = sorted(anims, key=lambda f: 'cmm' not in os.path.basename(f).lower()) or pick(('.glb', '.gltf', '.fbx', '.bvh'))
    if not anims:
        raise SystemExit('no animation file in ' + d)
    a.file = anims[0]
    if not a.skeleton and pick(('.uemodel',)):
        a.skeleton = pick(('.uemodel',))[0]
    if not a.music and pick(('.wav', '.mp3', '.ogg', '.flac')):
        a.music = pick(('.wav', '.mp3', '.ogg', '.flac'))[0]
    if not a.name:
        a.name = os.path.basename(os.path.normpath(d))
    skinenv.say('using %s%s%s' % (os.path.basename(a.file), ' + ' + os.path.basename(a.skeleton) if a.skeleton else '',
                                  ' + ' + os.path.basename(a.music) if a.music else ''))


def main():
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, ValueError):
            pass
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    cmd = args[0]
    try:
        if cmd == 'list':
            for e in emotepack.staged(skinenv.WORK):
                print('%s\t%s\t%.1fs%s' % (e['id'], e['name'], e['hold_ms'] / 1000.0, '\tmusic' if e.get('music') else ''))
            return
        if cmd == 'add':
            import argparse
            ap = argparse.ArgumentParser(prog='addemote.py add')
            ap.add_argument('file', help='anim file, or the name of a folder in coop_skins/emotes/')
            ap.add_argument('name', nargs='?')
            ap.add_argument('--music')
            ap.add_argument('--skeleton')
            ap.add_argument('--once', action='store_true', help='play it once (default: loop)')
            ap.add_argument('--loop', action='store_true', help='loop it (the default)')
            ap.add_argument('--hold', type=float, help='seconds the emote lasts (max 30)')
            ap.add_argument('--no-fingers', action='store_true')
            a = ap.parse_args(args[1:])
            from_folder(a)
            if not a.name:
                raise SystemExit('add <anim file> <name>, or add <folder in coop_skins/emotes>')
            if not os.path.isfile(a.file):
                raise SystemExit('no such file: ' + a.file)
            if a.music and not os.path.isfile(a.music):
                raise SystemExit('no such file: ' + a.music)
            add(a)
            return
        if cmd == 'remove':
            if len(args) < 2:
                raise SystemExit('remove <name>')
            e = drop(ident(args[1]))
            if not e:
                raise SystemExit('no custom emote named %s' % args[1])
            import addskin
            addskin.repack()
            print('OK removed emote %s' % e['name'], flush=True)
            return
        print('ERROR unknown command ' + cmd)
    except SystemExit as e:
        print('ERROR %s' % e, flush=True)
        sys.exit(1)
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        print('ERROR %s' % e, flush=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
