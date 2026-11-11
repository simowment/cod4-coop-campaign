"""Where the skin tools find things, and first-run setup.

Everything lives in <game>/coop_skins/:
  oat/    OpenAssetTools (downloaded from its GitHub release if missing)
  cache/  the CoD4 soldier skeleton + material template, dumped from the user's own killhouse.ff
  work/   staged skins (one xmodel / material / textures per skin) and the linked skin pack
The game folder is COOP_GAMEDIR, else the folder above this script that has iw3sp.exe, else the repo's
sibling "Call of Duty 4-Modern Warfare".
"""
import glob
import io
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def game_dir():
    g = os.environ.get('COOP_GAMEDIR')
    if g and os.path.isfile(os.path.join(g, 'iw3sp.exe')):
        return os.path.abspath(g)
    d = HERE
    for _ in range(5):
        if os.path.isfile(os.path.join(d, 'iw3sp.exe')):
            return d
        d = os.path.dirname(d)
    sib = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), 'Call of Duty 4-Modern Warfare')
    if os.path.isfile(os.path.join(sib, 'iw3sp.exe')):
        return sib
    sys.exit('cannot find the game folder (iw3sp.exe): set COOP_GAMEDIR')


GAME = game_dir()
ROOT = os.path.join(GAME, 'coop_skins')
OAT = os.path.join(ROOT, 'oat')
CACHE = os.path.join(ROOT, 'cache')
WORK = os.path.join(ROOT, 'work')
ZONES = os.path.join(GAME, 'zone', 'english')
LINKER = os.path.join(OAT, 'Linker.exe')
UNLINKER = os.path.join(OAT, 'Unlinker.exe')
IMAGECONV = os.path.join(OAT, 'ImageConverter.exe')
COD_BODY = os.path.join(CACHE, 'body', 'model_export', 'body_complete_sp_sas_ct_charles_lod0.gltf')
TEMPLATE_MATERIAL = os.path.join(CACHE, 'mat', 'materials', 'mc', 'mtl_spotlightvechicle_off.json')
OAT_RELEASE = 'https://api.github.com/repos/Laupetin/OpenAssetTools/releases/latest'


def say(msg):
    print(msg, flush=True)


def ensure_oat():
    if os.path.isfile(LINKER):
        return
    os.makedirs(OAT, exist_ok=True)
    local = r'C:\Users\got\tools\oat'
    if os.path.isfile(os.path.join(local, 'Linker.exe')):
        shutil.copytree(local, OAT, dirs_exist_ok=True)
        return
    say('downloading OpenAssetTools (one time, ~4 MB)...')
    import json
    rel = json.load(urllib.request.urlopen(urllib.request.Request(OAT_RELEASE, headers={'User-Agent': 'cod4-coop-skins'})))
    url = next(a['browser_download_url'] for a in rel['assets'] if a['name'] == 'oat-windows.zip')
    data = urllib.request.urlopen(url).read()
    zipfile.ZipFile(io.BytesIO(data)).extractall(OAT)


def ensure_cache():
    if os.path.isfile(COD_BODY) and os.path.isfile(TEMPLATE_MATERIAL):
        return
    ensure_oat()
    say('reading the CoD4 soldier skeleton from your killhouse.ff (one time)...')
    kh = os.path.join(ZONES, 'killhouse.ff')
    subprocess.run([UNLINKER, '--model-format', 'GLTF', '--include-assets', 'xmodel', '-o', os.path.join(CACHE, 'body'), kh],
                   check=True, capture_output=True)
    subprocess.run([UNLINKER, '--include-assets', 'material', '-o', os.path.join(CACHE, 'mat'), kh],
                   check=True, capture_output=True)
    # keep only what is needed
    for f in glob.glob(os.path.join(CACHE, 'body', 'model_export', '*')):
        if 'body_complete_sp_sas_ct_charles_lod0' not in f:
            os.remove(f)
    if not os.path.isfile(COD_BODY):
        sys.exit('could not dump the soldier skeleton from killhouse.ff')


def ensure_all():
    ensure_oat()
    ensure_cache()
    os.makedirs(WORK, exist_ok=True)
