"""Collect the named test screenshots (coop_shot_<tag>_<name>.bmp) into a labelled contact sheet.
   python contact_sheet.py <game dir> <tag> <out dir>"""
import glob, os, re, sys
from PIL import Image, ImageDraw
game, tag, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
files = sorted(glob.glob(os.path.join(game, 'coop_shot_%s_*.bmp' % tag)), key=os.path.getmtime)
W, H = 320, 300
cols = 4
rows = (len(files) + cols - 1) // cols
sheet = Image.new('RGB', (W * cols, H * max(rows, 1)))
for i, f in enumerate(files):
    name = re.sub(r'^coop_shot_%s_' % tag, '', os.path.basename(f))[:-4]
    im = Image.open(f).convert('RGB')
    w, h = im.size
    im.save(os.path.join(out, name + '.png'))
    crop = im.crop((w // 8, h // 8, w * 7 // 8, h * 7 // 8)).resize((W, H))  # the bot walks up to ~25 deg off centre
    ImageDraw.Draw(crop).text((4, 4), name, fill=(255, 40, 40))
    sheet.paste(crop, ((i % cols) * W, (i // cols) * H))
    os.remove(f)
sheet.save(os.path.join(out, 'sheet.png'))
print('sheet: %d frames -> %s' % (len(files), os.path.join(out, 'sheet.png')))
