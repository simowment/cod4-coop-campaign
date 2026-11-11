"""Rebind a rigged humanoid character (glTF/GLB or Collada DAE) onto the CoD4 soldier skeleton and stage it
for the skin pack (tools/skin/pack.py).

  python tools/skin/rebind.py <character.glb|.gltf|.dae> <skin_name> [--keep-weapons] [--preview out.png]

CoD4 animations set bone transforms in the CoD skeleton's own bone frames, so a character's rig cannot be
used by renaming bones. Instead:
 1. read the character into one format (bones with bind matrices, skinned meshes, textures);
 2. find each bone's role (pelvis, spine chain, clavicle/upper arm/forearm/hand, thigh/calf/foot/toe,
    fingers) from name tokens and the hierarchy, so Mixamo, VRM, Unreal, League, Nintendo... rigs all map;
 3. bring it into CoD space (Y up, inches, facing +X, left at -Z; facing found from where its left-side
    bones are) and scale it to soldier head height;
 4. pose it into the CoD rest pose limb by limb and move every vertex onto the mapped CoD bone (unmapped
    bones - cloth, hair, props, attach points - hand their weights to the nearest mapped ancestor);
 5. write a GLB on the real CoD skeleton (from a stock body dumped by OAT), one CoD material + texture per
    character texture, the xmodel json and a manifest for pack.py.
"""
import argparse
import io
import json
import os
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gltfio import Gltf  # noqa: E402

DEFAULT_COD = r'C:\Users\got\cod4-decomp\oat_dump\killhouse\model_export\body_complete_sp_sas_ct_charles_lod0.gltf'
OAT_IMAGECONV = r'C:\Users\got\tools\oat\ImageConverter.exe'
TEMPLATE_MATERIAL = r'C:\Users\got\cod4-decomp\oat_dump\killhouse_mat\materials\mc\mtl_spotlightvechicle_off.json'


class Char:
    def __init__(self):
        self.bones = []        # names
        self.parent = {}       # name -> parent name or None
        self.bind = {}         # name -> 4x4 world bind matrix
        self.prims = []        # pos (n,3), uv (n,2), jn (n lists of bone names), w (n,k), tris (m,3), image (PIL or None)
        self.up_is_z = False


def load_gltf(path):
    g = Gltf(path)
    c = Char()
    images = {}

    def image_of(mat_index):
        if mat_index is None:
            return None
        t = g.j['materials'][mat_index].get('pbrMetallicRoughness', {}).get('baseColorTexture')
        if t is None:
            return None
        src = g.j['textures'][t['index']]['source']
        if src not in images:
            im = g.j['images'][src]
            if 'bufferView' in im:
                raw, _ = g.bufferview(im['bufferView'])
                images[src] = Image.open(io.BytesIO(raw))
            else:
                images[src] = Image.open(os.path.join(g.dir, im['uri']))
        return images[src]

    skinned = [i for i, n in enumerate(g.nodes) if 'mesh' in n and 'skin' in n]
    if not skinned:
        sys.exit('no skinned mesh in %s (the model needs a rig: see Mesh2Motion for unrigged models)' % path)
    for ni in skinned:
        skin = g.j['skins'][g.nodes[ni]['skin']]
        names = [g.nodes[j].get('name') or 'bone%d' % j for j in skin['joints']]
        ibm = g.accessor(skin['inverseBindMatrices']).reshape(-1, 4, 4).transpose(0, 2, 1)
        jset = set(skin['joints'])
        for k, j in enumerate(skin['joints']):
            nm = names[k]
            if nm in c.bind:
                continue
            p = g.parent.get(j)
            while p is not None and p not in jset:
                p = g.parent.get(p)
            c.bones.append(nm)
            c.bind[nm] = np.linalg.inv(ibm[k])
            c.parent[nm] = (g.nodes[p].get('name') or 'bone%d' % p) if p is not None else None
        for pr in g.j['meshes'][g.nodes[ni]['mesh']]['primitives']:
            at = pr['attributes']
            if 'JOINTS_0' not in at:
                continue
            pos = g.accessor(at['POSITION']).astype(float)
            pos = (g.world(ni) @ np.c_[pos, np.ones(len(pos))].T).T[:, :3]
            n = len(pos)
            uv = g.accessor(at['TEXCOORD_0']).astype(float) if 'TEXCOORD_0' in at else np.zeros((n, 2))
            J = g.accessor(at['JOINTS_0']).astype(int)
            W = g.accessor(at['WEIGHTS_0']).astype(float)
            tris = g.accessor(pr['indices']).reshape(-1, 3).astype(int) if 'indices' in pr else np.arange(n).reshape(-1, 3)
            c.prims.append({'pos': pos, 'uv': uv, 'jn': [[names[x] for x in row] for row in J], 'w': W, 'tris': tris,
                            'image': image_of(pr.get('material'))})
    return c


def load_dae(path):
    root = ET.parse(path).getroot()
    nsuri = root.tag[1:].split('}')[0] if root.tag.startswith('{') else ''

    def q(tag):
        return '{%s}%s' % (nsuri, tag) if nsuri else tag

    def floats(el):
        return np.array([float(x) for x in el.text.split()]) if el is not None and el.text else np.zeros(0)
    ids = {el.get('id'): el for el in root.iter() if el.get('id')}

    def ref(url):
        return ids.get(url.lstrip('#'))
    c = Char()
    up = root.find('.//' + q('up_axis'))
    c.up_is_z = up is not None and up.text.strip() == 'Z_UP'
    base = os.path.dirname(path)
    img_file = {im.get('id'): im.find(q('init_from')).text.strip() for im in root.iter(q('image')) if im.find(q('init_from')) is not None}
    eff_img = {}
    for ef in root.iter(q('effect')):
        surf = {}
        for np_ in ef.iter(q('newparam')):
            s = np_.find(q('surface'))
            if s is not None and s.find(q('init_from')) is not None:
                surf[np_.get('sid')] = s.find(q('init_from')).text.strip()
            s2 = np_.find(q('sampler2D'))
            if s2 is not None and s2.find(q('source')) is not None:
                surf[np_.get('sid')] = surf.get(s2.find(q('source')).text.strip())
        tex = ef.find('.//' + q('diffuse') + '/' + q('texture'))
        if tex is not None:
            key = tex.get('texture')
            im = surf.get(key) or key
            eff_img[ef.get('id')] = img_file.get(im, im)
    mat_img = {}
    for m in root.iter(q('material')):
        ie = m.find(q('instance_effect'))
        if ie is not None:
            mat_img[m.get('id')] = eff_img.get(ie.get('url').lstrip('#'))

    def node_mat(nd):
        M = np.eye(4)
        for ch in nd:
            t = ch.tag.split('}')[-1]
            if t == 'matrix':
                M = M @ floats(ch).reshape(4, 4)
            elif t == 'translate':
                T = np.eye(4)
                T[:3, 3] = floats(ch)
                M = M @ T
            elif t == 'rotate':
                x, y, z, ang = floats(ch)
                ang = np.radians(ang)
                ax = np.array([x, y, z]) / np.linalg.norm([x, y, z])
                K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
                R = np.eye(4)
                R[:3, :3] = np.eye(3) + np.sin(ang) * K + (1 - np.cos(ang)) * K @ K
                M = M @ R
            elif t == 'scale':
                S = np.eye(4)
                S[0, 0], S[1, 1], S[2, 2] = floats(ch)
                M = M @ S
        return M
    world = {}
    key_name = {}

    def walk(nd, parentM, parent_joint):
        M = parentM @ node_mat(nd)
        pj = parent_joint
        if nd.get('type') == 'JOINT':
            nm = nd.get('name') or nd.get('id')
            world[nm] = M
            c.parent[nm] = parent_joint
            c.bones.append(nm)
            for key in (nd.get('sid'), nd.get('id'), nd.get('name')):
                if key:
                    key_name[key] = nm
            pj = nm
        for ch in nd.findall(q('node')):
            walk(ch, M, pj)
    for vs in root.iter(q('visual_scene')):
        for nd in vs.findall(q('node')):
            walk(nd, np.eye(4), None)
    for nm in c.bones:
        c.bind[nm] = world[nm]
    for ic in root.iter(q('instance_controller')):
        skin = ref(ic.get('url')).find(q('skin'))
        bsm_el = skin.find(q('bind_shape_matrix'))
        bsm = floats(bsm_el).reshape(4, 4) if bsm_el is not None else np.eye(4)
        jsrc = ibm_src = None
        for inp in skin.find(q('joints')).findall(q('input')):
            if inp.get('semantic') == 'JOINT':
                jsrc = ref(inp.get('source'))
            elif inp.get('semantic') == 'INV_BIND_MATRIX':
                ibm_src = ref(inp.get('source'))
        arr = jsrc.find(q('Name_array'))
        if arr is None:
            arr = jsrc.find(q('IDREF_array'))
        jnames = [key_name.get(n, n) for n in arr.text.split()]
        ibms = floats(ibm_src.find(q('float_array'))).reshape(-1, 4, 4)
        for k, nm in enumerate(jnames):
            if nm in c.bind:
                c.bind[nm] = np.linalg.inv(ibms[k])  # the skin's bind pose wins over the scene pose
        vw = skin.find(q('vertex_weights'))
        wsrc = None
        joff = woff = 0
        ninp = 0
        for inp in vw.findall(q('input')):
            ninp = max(ninp, int(inp.get('offset')) + 1)
            if inp.get('semantic') == 'WEIGHT':
                wsrc = floats(ref(inp.get('source')).find(q('float_array')))
                woff = int(inp.get('offset'))
            elif inp.get('semantic') == 'JOINT':
                joff = int(inp.get('offset'))
        vcount = [int(x) for x in vw.find(q('vcount')).text.split()]
        v = [int(x) for x in vw.find(q('v')).text.split()]
        infl = []
        o = 0
        for cnt in vcount:
            lst = []
            for k in range(cnt):
                lst.append((jnames[v[o + joff]], wsrc[v[o + woff]]))
                o += ninp
            infl.append(lst)
        mesh = ref(skin.get('source')).find(q('mesh'))
        possrc = next(ref(i.get('source')) for i in mesh.find(q('vertices')).findall(q('input')) if i.get('semantic') == 'POSITION')
        P = floats(possrc.find(q('float_array'))).reshape(-1, 3)
        P = (bsm @ np.c_[P, np.ones(len(P))].T).T[:, :3]
        mat_bind = {im.get('symbol'): im.get('target').lstrip('#') for im in ic.iter(q('instance_material'))}
        for tri in list(mesh.findall(q('triangles'))) + list(mesh.findall(q('polylist'))):
            inputs = tri.findall(q('input'))
            nst = max(int(i.get('offset')) for i in inputs) + 1
            voff = next(int(i.get('offset')) for i in inputs if i.get('semantic') == 'VERTEX')
            tin = next((i for i in inputs if i.get('semantic') == 'TEXCOORD' and i.get('set', '0') == '0'), None)
            T = floats(ref(tin.get('source')).find(q('float_array'))).reshape(-1, 2) if tin is not None else None
            toff = int(tin.get('offset')) if tin is not None else voff
            idx = np.array([int(x) for x in tri.find(q('p')).text.split()]).reshape(-1, nst)
            if tri.tag.endswith('polylist'):
                if any(int(x) != 3 for x in tri.find(q('vcount')).text.split()):
                    sys.exit('polylist with non-triangle faces: triangulate the model first')
            pairs = np.c_[idx[:, voff], idx[:, toff]]
            uniq, first, inv = np.unique(pairs, axis=0, return_index=True, return_inverse=True)
            sets = []
            for i in sorted((i for i in inputs if i.get('semantic') == 'TEXCOORD'), key=lambda i: int(i.get('set', '0'))):
                Ts = floats(ref(i.get('source')).find(q('float_array'))).reshape(-1, 2)
                sets.append(Ts[idx[first, int(i.get('offset'))]])
            vi, ti = uniq[:, 0], uniq[:, 1]
            pos = P[vi]
            uv = (T[ti] * np.array([1, -1]) + np.array([0, 1])) if T is not None else np.zeros((len(vi), 2))  # DAE v up -> glTF v down
            jn = []
            W = np.zeros((len(vi), 4))
            for k, src in enumerate(vi):
                lst = sorted(infl[src], key=lambda t: -t[1])[:4]
                jn.append([n for n, _ in lst] + [lst[0][0]] * (4 - len(lst)))
                for m, (_, w) in enumerate(lst):
                    W[k, m] = w
            matid = mat_bind.get(tri.get('material'), tri.get('material'))
            imfile = mat_img.get(matid)
            image = Image.open(os.path.join(base, imfile)) if imfile and os.path.isfile(os.path.join(base, imfile)) else None
            c.prims.append({'pos': pos, 'uv': uv, 'jn': jn, 'w': W, 'tris': np.asarray(inv).reshape(-1, 3), 'image': image,
                            'mat': matid, 'uvsets': sets, 'dir': base})
    if not c.prims:
        sys.exit('no skinned mesh in %s (the model needs a rig: see Mesh2Motion for unrigged models)' % path)
    return c


def bake_layers(ch, cfg):
    """Some game rips use layered materials (e.g. 3DS eyes: an eyelid/blink atlas picked by a texture
    matrix, plus pupils on other UV sets). CoD4 gets one texture per material, so bake them:
      {"materials": {"<material id>": {"atlas": [columns, rows, frame],
                                       "multiply": [["pupil.png", uvset], ...], "size": 256}}}
    The atlas frame becomes the base (the mesh's UV set 0 is already in single-frame space), and each
    multiply layer is sampled through its own UV set (outside 0..1 counts as white, i.e. no change)."""
    for pr in ch.prims:
        spec = cfg.get('materials', {}).get(pr.get('mat'))
        if not spec:
            continue
        size = spec.get('size', 256)
        base = pr['image'].convert('RGBA')
        if 'atlas' in spec:
            cols, rows, fr = spec['atlas']
            fw, fh = base.width // cols, base.height // rows
            x, y = (fr % cols) * fw, (fr // cols) * fh
            base = base.crop((x, y, x + fw, y + fh))
        uv0 = pr['uvsets'][0]
        # layers tied to one side of the body ("+x"/"-x", e.g. one pupil per eye) need their own copy of
        # the texture: the baked texture gets one column per side and those triangles' UVs move into it
        sides = sorted({l[2] for l in spec.get('multiply', []) if len(l) > 2})
        cols_out = max(1, len(sides))
        cx = pr['pos'][pr['tris']].mean(1)[:, 0]
        tri_col = np.zeros(len(pr['tris']), int)
        for k, sd in enumerate(sides):
            tri_col[(cx > 0) if sd == '+x' else (cx <= 0)] = k
        one = np.asarray(base.resize((size, size), Image.LANCZOS)).astype(float) / 255
        out = np.concatenate([one] * cols_out, axis=1)
        for layer_spec in spec.get('multiply', []):
            img_name, uvset = layer_spec[0], layer_spec[1]
            col = sides.index(layer_spec[2]) if len(layer_spec) > 2 else None
            layer = np.asarray(Image.open(os.path.join(pr['dir'], img_name)).convert('RGBA')).astype(float) / 255
            lh, lw = layer.shape[:2]
            uvl = pr['uvsets'][uvset]
            mult = np.ones((size, size * cols_out, 3))
            for ti, t in enumerate(pr['tris']):
                if col is not None and tri_col[ti] != col:
                    continue
                xo = (tri_col[ti] if col is not None else 0) * size
                # texel space of the baked texture: u right, v down (DAE v up)
                P = np.array([[uv0[i][0] % 1.0 * size, (1 - uv0[i][1] % 1.0) * size] for i in t])
                L = uvl[t]
                x0, y0 = np.floor(P.min(0)).astype(int)
                x1, y1 = np.ceil(P.max(0)).astype(int)
                M = np.array([[P[0][0] - P[2][0], P[1][0] - P[2][0]], [P[0][1] - P[2][1], P[1][1] - P[2][1]]])
                if abs(np.linalg.det(M)) < 1e-9:
                    continue
                Mi = np.linalg.inv(M)
                for yy in range(max(y0, 0), min(y1 + 1, size)):
                    for xx in range(max(x0, 0), min(x1 + 1, size)):
                        if col is None:
                            xo = 0
                        l1, l2 = Mi @ (np.array([xx + 0.5, yy + 0.5]) - P[2])
                        l3 = 1 - l1 - l2
                        if min(l1, l2, l3) < -0.02:
                            continue
                        u, v = l1 * L[0] + l2 * L[1] + l3 * L[2]
                        if 0 <= u <= 1 and 0 <= v <= 1:
                            px = layer[min(int((1 - v) * lh), lh - 1), min(int(u * lw), lw - 1)]
                            a_ = px[3]
                            mult[yy, xx + xo] *= px[:3] * a_ + (1 - a_)
            out[..., :3] *= mult
        pr['image'] = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), 'RGBA')
        # the baked texture is the single frame: map UV set 0 straight onto it
        uvo = np.c_[uv0[:, 0] % 1.0, 1 - uv0[:, 1] % 1.0]
        if cols_out > 1:
            # split shared vertices so each side's triangles point into their own column
            newpos, newuv, newjn, neww, newtris = [], [], [], [], []
            for ti, t in enumerate(pr['tris']):
                row = []
                for i in t:
                    newpos.append(pr['pos'][i])
                    newuv.append([(uvo[i][0] + tri_col[ti]) / cols_out, uvo[i][1]])
                    newjn.append(pr['jn'][i])
                    neww.append(pr['w'][i])
                    row.append(len(newpos) - 1)
                newtris.append(row)
            pr['pos'], pr['jn'], pr['w'] = np.array(newpos), newjn, np.array(neww)
            pr['tris'] = np.array(newtris)
            uvo = np.array(newuv)
        pr['uv'] = uvo
        print('baked layered material', pr['mat'])


def tokens(name):
    n = name.split(':')[-1].split('|')[-1]
    n = re.sub(r'([a-z])([A-Z])', r'\1 \2', n)
    n = re.sub(r'([A-Za-z])([0-9])', r'\1 \2', n)
    n = re.sub(r'([0-9])([A-Za-z])', r'\1 \2', n)
    return [t for t in re.split(r'[^a-z0-9]+', n.lower()) if t]


SIDE_L = ('l', 'left', 'lf')
SIDE_R = ('r', 'right', 'rt')
FINGER = {'thumb': 'thumb', 'index': 'index', 'middle': 'mid', 'mid': 'mid', 'md': 'mid', 'ring': 'ring', 'pinky': 'pinky', 'little': 'pinky'}
LIMB = {  # joined role tokens (side removed) -> role
    'clavicle': 'clavicle', 'shoulder': 'clavicle', 'collar': 'clavicle',
    'upperarm': 'upperarm', 'uparm': 'upperarm', 'arm': 'upperarm', 'armupper': 'upperarm',
    'forearm': 'forearm', 'lowerarm': 'forearm', 'elbow': 'forearm', 'armlower': 'forearm',
    'hand': 'hand', 'wrist': 'hand',
    'thigh': 'thigh', 'upleg': 'thigh', 'upperleg': 'thigh', 'hip': 'thigh', 'legupper': 'thigh',
    'calf': 'calf', 'leg': 'calf', 'lowerleg': 'calf', 'knee': 'calf', 'shin': 'calf', 'leglower': 'calf',
    'foot': 'foot', 'ankle': 'foot',
    'toe': 'toe', 'toes': 'toe', 'toebase': 'toe', 'ball': 'toe',
}
SKIP = ('weapon', 'attach', 'roll', 'twist', 'end', 'nub', 'helper', 'ik', 'pole', 'target', 'ctrl', 'loc', 'parenting')
NOISE = ('j', 'def', 'mixamorig', 'bip', 'bip01', 'b', 'bone', 'jnt', 'c', 'org', 'mch')


def classify(name):
    """-> (side or None, role or None, finger segment number or None)"""
    t = tokens(name)
    if any(s in t for s in SKIP) or any(x.startswith('buff') for x in t):
        return None, None, None
    side = None
    rest = []
    for x in t:
        if side is None and x in SIDE_L:
            side = 'L'
        elif side is None and x in SIDE_R:
            side = 'R'
        elif x in NOISE:
            continue
        else:
            rest.append(x)
    nums = [int(x) for x in rest if x.isdigit()]
    words = [x for x in rest if not x.isdigit()]
    for w in words:
        if w in FINGER:
            return side, 'finger_' + FINGER[w], (nums[0] if nums else 1)
    key = ''.join(words)
    if side and key in LIMB:
        return side, LIMB[key], None
    if not side:
        if key in ('hips', 'pelvis', 'hip'):
            return None, 'pelvis', None
        if key == 'head':
            return None, 'head', None
        if key.startswith('neck'):
            return None, 'neck', None
        if key.startswith('spine') or key in ('chest', 'upperchest', 'torso', 'waist', 'abdomen'):
            return None, 'spine', None
        if key in ('root', 'ndchapos', 'armature', 'cog', 'center'):
            return None, 'root', None
    return side, None, None


def build_map(ch, cpos):
    """character bone -> (CoD bone, aim character bone or None, aim CoD bone or None)"""
    roles = {}
    for b in ch.bones:
        side, role, num = classify(b)
        if role:
            roles.setdefault((side, role), []).append((num or 0, b))

    def one(side, role):
        v = roles.get((side, role))
        return sorted(v)[0][1] if v else None
    pelvis = one(None, 'pelvis')
    head = one(None, 'head')
    root = one(None, 'root')
    if not pelvis or not head:
        sys.exit('could not find the pelvis/hips and head bones among: %s' % ', '.join(ch.bones[:60]))
    m = {}
    if root and root != pelvis:
        m[root] = ('j_mainroot', None, None)
    m[pelvis] = ('j_mainroot', None, None)
    # spine chain = bones between the pelvis (or root) and the head, from the hierarchy
    chain = []
    p = ch.parent.get(head)
    while p is not None and p not in (pelvis, root):
        chain.append(p)
        p = ch.parent.get(p)
    chain.reverse()
    cod_spine = ['j_spinelower', 'j_spineupper', 'j_spine4', 'j_neck']

    def spine_target(i):
        return cod_spine[0] if len(chain) == 1 else cod_spine[round(i * (len(cod_spine) - 1) / (len(chain) - 1))]
    for i, b in enumerate(chain):
        if i + 1 < len(chain):
            m[b] = (spine_target(i), chain[i + 1], spine_target(i + 1))
        else:
            m[b] = (spine_target(i), head, 'j_head')
    m[head] = ('j_head', None, None)
    for side, s in (('L', 'le'), ('R', 'ri')):
        arms = [('clavicle', 'j_clavicle_%s' % s), ('upperarm', 'j_shoulder_%s' % s), ('forearm', 'j_elbow_%s' % s), ('hand', 'j_wrist_%s' % s)]
        legs = [('thigh', 'j_hip_%s' % s), ('calf', 'j_knee_%s' % s), ('foot', 'j_ankle_%s' % s), ('toe', 'j_ball_%s' % s)]
        for seq in (arms, legs):
            present = [(one(side, r), cb) for r, cb in seq if one(side, r)]
            for i, (b, cb) in enumerate(present):
                m[b] = (cb, present[i + 1][0], present[i + 1][1]) if i + 1 < len(present) else (cb, None, None)
        hand = one(side, 'hand')
        for f in ('thumb', 'index', 'mid', 'ring', 'pinky'):
            segs = [b for _, b in sorted(roles.get((side, 'finger_' + f), []))][:3]
            for i, b in enumerate(segs):
                cb = 'j_%s_%s_%d' % (f, s, i + 1)
                m[b] = (cb, segs[i + 1], 'j_%s_%s_%d' % (f, s, i + 2)) if i + 1 < len(segs) else (cb, None, None)
            if hand and f == 'mid' and segs:
                m[hand] = (m[hand][0], segs[0], 'j_mid_%s_1' % s)
    return {b: v for b, v in m.items() if v[0] in cpos}


def rot_between(a, b):
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if c < -0.9999:
        axis = np.cross(a, [1, 0, 0])
        if np.linalg.norm(axis) < 1e-6:
            axis = np.cross(a, [0, 1, 0])
        axis /= np.linalg.norm(axis)
        return 2 * np.outer(axis, axis) - np.eye(3)
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx / (1 + c)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('character')
    ap.add_argument('name')
    ap.add_argument('--cod', default=DEFAULT_COD)
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.dirname(HERE)), 'build', 'skins'))
    ap.add_argument('--keep-weapons', action='store_true')
    ap.add_argument('--preview', help='also render a front/side preview png next to the stock soldier')
    ap.add_argument('--layers', help='json describing layered materials to bake (see tools/skin/presets)')
    a = ap.parse_args()
    name = re.sub(r'[^a-z0-9_]', '_', a.name.lower())
    out = os.path.abspath(a.out)
    ext = os.path.splitext(a.character)[1].lower()
    if ext in ('.glb', '.gltf'):
        ch = load_gltf(a.character)
    elif ext == '.dae':
        ch = load_dae(a.character)
    elif ext == '.fbx':
        sys.exit('FBX: export it as GLB (Blender or Mesh2Motion), or use the .dae if the rip has one')
    else:
        sys.exit('unsupported format ' + ext)

    if a.layers:
        bake_layers(ch, json.load(open(a.layers)))

    cod = Gltf(a.cod)
    cskin = cod.j['skins'][0]
    cjoints = cskin['joints']
    cidx = {cod.nodes[n]['name']: k for k, n in enumerate(cjoints)}
    cpos = {cod.nodes[n]['name']: cod.world(n)[:3, 3] for n in cjoints}

    bmap = build_map(ch, cpos)
    unmapped = [b for b in ch.bones if b not in bmap]
    print('mapped %d bones: %s' % (len(bmap), ', '.join('%s>%s' % (b, v[0]) for b, v in bmap.items())))
    if unmapped:
        print('merged into parents: %s' % ', '.join(unmapped))

    # 1. character -> CoD space: facing from the skeleton itself
    Z2Y = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float) if ch.up_is_z else np.eye(3)
    B = {b: Z2Y @ ch.bind[b][:3, 3] for b in ch.bones}
    pel = next(b for b, v in bmap.items() if classify(b)[1] == 'pelvis')
    head = next(b for b, v in bmap.items() if v[0] == 'j_head')
    up = B[head] - B[pel]
    up /= np.linalg.norm(up)
    lefts = [B[b] for b, v in bmap.items() if '_le' in v[0]]
    rights = [B[b] for b, v in bmap.items() if '_ri' in v[0]]
    left = np.mean(lefts, 0) - np.mean(rights, 0)
    left -= up * np.dot(left, up)
    left /= np.linalg.norm(left)
    fwd = np.cross(left, up)
    char_basis = np.c_[fwd, up, left]
    cod_basis = np.c_[[1, 0, 0], [0, 1, 0], [0, 0, -1]]
    R0 = cod_basis @ char_basis.T @ Z2Y
    all_pos = np.vstack([p['pos'] for p in ch.prims])
    ground = (R0 @ all_pos.T)[1].min()
    top = (R0 @ all_pos.T)[1].max()
    # soldier head height, but never taller than a soldier overall (big-headed characters would be giants)
    scale = min(cpos['j_head'][1] / ((R0 @ ch.bind[head][:3, 3])[1] - ground), 74.0 / (top - ground))
    off = np.array([0, -ground * scale, 0])
    P = {b: R0 @ ch.bind[b][:3, 3] * scale + off for b in ch.bones}

    order, seen = [], set()

    def visit(b):
        if b in seen:
            return
        if ch.parent.get(b):
            visit(ch.parent[b])
        seen.add(b)
        order.append(b)
    for b in ch.bones:
        visit(b)

    # 2. pose into the CoD rest pose
    A, PP = {}, {}
    for b in order:
        p = ch.parent.get(b)
        Ap = A[p] if p else np.eye(3)
        PP[b] = PP[p] + Ap @ (P[b] - P[p]) if p else P[b]
        An = Ap
        if b in bmap and bmap[b][1] in P and bmap[b][2] in cpos:
            cb, da, ca = bmap[b]
            cur = Ap @ (P[da] - P[b])
            tgt = cpos[ca] - cpos[cb]
            if np.linalg.norm(cur) > 1e-6 and np.linalg.norm(tgt) > 1e-6:
                An = rot_between(cur, tgt) @ Ap
        A[b] = An
    anc = {}
    for b in order:
        anc[b] = b if b in bmap else (anc[ch.parent[b]] if ch.parent.get(b) else pel)

    # 3. vertices, per primitive
    out_prims = []
    for pr in ch.prims:
        V = (R0 @ pr['pos'].T).T * scale + off
        n = len(V)
        outV = np.zeros((n, 3))
        outJ = np.zeros((n, 4), int)
        outW = np.zeros((n, 4))
        drop = np.zeros(n, bool)
        for v in range(n):
            acc = {}
            tot = 0.0
            heavy, hw = None, 0
            for k in range(len(pr['jn'][v])):
                w = pr['w'][v, k]
                d = pr['jn'][v][k]
                if w <= 0 or d not in P:
                    continue
                if w > hw:
                    hw, heavy = w, d
                a_ = anc[d]
                cb = bmap[a_][0]
                posed = PP[d] + A[d] @ (V[v] - P[d])
                outV[v] += w * (cpos[cb] + (posed - PP[a_]))
                acc[cb] = acc.get(cb, 0) + w
                tot += w
            if tot > 0:
                outV[v] /= tot
            else:
                outV[v] = cpos['j_mainroot'] + (V[v] - P[pel])
                acc = {'j_mainroot': 1}
            if heavy and 'weapon' in heavy.lower() and not a.keep_weapons:
                drop[v] = True
            top = sorted(acc.items(), key=lambda t: -t[1])[:4]
            s = sum(t[1] for t in top) or 1
            for k, (cb, w) in enumerate(top):
                outJ[v, k] = cidx[cb]
                outW[v, k] = w / s
        tris = pr['tris'][~drop[pr['tris']].any(1)]
        N = np.zeros((n, 3))
        fn = np.cross(outV[tris[:, 1]] - outV[tris[:, 0]], outV[tris[:, 2]] - outV[tris[:, 0]])
        for k in range(3):
            np.add.at(N, tris[:, k], fn)
        N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
        if len(tris):
            out_prims.append({'V': outV, 'N': N, 'uv': pr['uv'], 'J': outJ, 'W': outW, 'tris': tris, 'image': pr['image']})
    print('top %.1f (soldier ~73), %d meshes, %d triangles' % (max(p['V'][:, 1].max() for p in out_prims), len(out_prims),
                                                             sum(len(p['tris']) for p in out_prims)))

    # 4. write sources: one material + texture per distinct image
    for d in ('model_export', 'xmodel', 'materials/mc', 'images'):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    model = 'coop_%s' % name
    img_ids = {}
    assets = []
    tmpl = json.load(open(TEMPLATE_MATERIAL))
    for p in out_prims:
        im = p['image']
        key = id(im) if im is not None else 'none'
        if key not in img_ids:
            k = len(img_ids)
            image = 'coop_%s_%d_col' % (name, k)
            material = 'mc/mtl_coop_%s_%d' % (name, k)
            img_ids[key] = material
            src = (im if im is not None else Image.new('RGB', (4, 4), (160, 160, 160))).convert('RGBA')
            w2 = 1 << max(2, (src.width - 1).bit_length())
            h2 = 1 << max(2, (src.height - 1).bit_length())
            if (w2, h2) != src.size:
                src = src.resize((w2, h2), Image.LANCZOS)
            dds = os.path.join(out, 'images', image + '.dds')
            src.save(dds)
            subprocess.run([OAT_IMAGECONV, '--iw3', dds], check=True, capture_output=True)
            mat = json.loads(json.dumps(tmpl))
            for t in mat['textures']:
                if t['semantic'] == 'colorMap':
                    t['image'] = image
            mat['surfaceTypeBits'] = 64
            json.dump(mat, open(os.path.join(out, 'materials', material + '.json'), 'w'), indent=2)
            assets += ['image,' + image, 'material,' + material]
        p['material'] = img_ids[key]

    g = json.loads(json.dumps(cod.j))
    blob = bytearray()
    views, accs = [], []

    def add(arr, ctype, typ, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        while len(blob) % 4:
            blob.append(0)
        o = len(blob)
        blob.extend(arr.tobytes())
        v = {'buffer': 0, 'byteOffset': o, 'byteLength': arr.nbytes}
        if target:
            v['target'] = target
        views.append(v)
        acc = {'bufferView': len(views) - 1, 'componentType': ctype, 'count': len(arr), 'type': typ}
        if minmax:
            acc['min'] = arr.min(0).tolist()
            acc['max'] = arr.max(0).tolist()
        accs.append(acc)
        return len(accs) - 1
    mats = sorted(set(p['material'] for p in out_prims))
    prims_json = []
    for p in out_prims:
        nv = len(p['V'])
        prims_json.append({'attributes': {
            'POSITION': add(p['V'].astype(np.float32), 5126, 'VEC3', 34962, True),
            'NORMAL': add(p['N'].astype(np.float32), 5126, 'VEC3', 34962),
            'TEXCOORD_0': add(p['uv'].astype(np.float32), 5126, 'VEC2', 34962),
            'COLOR_0': add(np.ones((nv, 4), np.float32), 5126, 'VEC4', 34962),
            'JOINTS_0': add(p['J'].astype(np.uint16), 5123, 'VEC4', 34962),
            'WEIGHTS_0': add(p['W'].astype(np.float32), 5126, 'VEC4', 34962)},
            'indices': add(p['tris'].reshape(-1).astype(np.uint32), 5125, 'SCALAR', 34963),
            'material': mats.index(p['material'])})
    g['skins'][0]['inverseBindMatrices'] = add(cod.accessor(cskin['inverseBindMatrices']).astype(np.float32), 5126, 'MAT4')
    while len(blob) % 4:
        blob.append(0)
    g['buffers'] = [{'byteLength': len(blob)}]  # GLB: the OAT Linker does not read external .bin buffers
    g['bufferViews'] = views
    g['accessors'] = accs
    g['materials'] = [{'name': m} for m in mats]
    g['meshes'] = [{'primitives': prims_json}]
    first = True
    for nd in g['nodes']:
        if 'mesh' in nd:
            if first:
                nd['mesh'] = 0
                nd['skin'] = 0
                first = False
            else:
                del nd['mesh']
                nd.pop('skin', None)
    for k in ('images', 'textures', 'samplers'):
        g.pop(k, None)
    js = json.dumps(g).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    glb = os.path.join(out, 'model_export', model + '.glb')
    with open(glb, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        f.write(struct.pack('<II', len(js), 0x4E4F534A) + js)
        f.write(struct.pack('<II', len(blob), 0x004E4942) + bytes(blob))
    json.dump({'$schema': 'http://openassettools.dev/schema/xmodel.v1.json', '_game': 'iw3', '_type': 'xmodel', '_version': 2,
               'flags': 0, 'lods': [{'distance': 1000000.0, 'file': 'model_export/%s.glb' % model}], 'type': 'animated'},
              open(os.path.join(out, 'xmodel', model + '.json'), 'w'), indent=2)
    json.dump({'model': model, 'assets': assets + ['xmodel,' + model]}, open(os.path.join(out, 'xmodel', model + '.skin'), 'w'))
    if a.preview:
        subprocess.run([sys.executable, os.path.join(HERE, 'preview.py'), a.preview, glb, a.cod], check=True)
    print('staged', model, 'in', out)


if __name__ == '__main__':
    main()
