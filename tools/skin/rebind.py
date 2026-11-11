"""Rebind a rigged humanoid character (glTF/GLB) onto the CoD4 soldier skeleton and stage it for
OpenAssetTools.

  python tools/skin/rebind.py <character.glb> <skin_name> [--keep-weapons]

CoD4 animations set bone transforms in the CoD skeleton's own bone frames, so a character's rig cannot
be used by just renaming bones. Instead:
 1. bring the character into CoD space (Y up, inches, facing +X) and scale it to soldier height;
 2. pose it into the CoD rest pose bone by bone (each mapped limb is aimed along the CoD limb);
 3. move every skinned vertex onto the CoD bone its character bone maps to (unmapped bones such as
    cloth, hair or props hand their weights to the nearest mapped ancestor);
 4. write a glTF that uses the real CoD skeleton (copied from a stock body dumped by OAT), plus the
    xmodel / material / image sources and a zone file for the OAT Linker.
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gltfio import Gltf, quat_to_mat  # noqa: E402

DEFAULT_COD = r'C:\Users\got\cod4-decomp\oat_dump\killhouse\model_export\body_complete_sp_sas_ct_charles_lod0.gltf'
OAT_IMAGECONV = r'C:\Users\got\tools\oat\ImageConverter.exe'
TEMPLATE_MATERIAL = r'C:\Users\got\cod4-decomp\oat_dump\killhouse_mat\materials\mc\mtl_spotlightvechicle_off.json'

# character bone name patterns -> CoD bone, with an aim child pair (character child, CoD child)
FINGERS = (('Thumb', 'thumb'), ('Index', 'index'), ('Middle', 'mid'), ('Ring', 'ring'), ('Pinky', 'pinky'))


def bone_map():
    m = [('Root', 'j_mainroot', None, None), ('Pelvis', 'j_mainroot', None, None),
         ('Spine0', 'j_spinelower', 'Spine', 'j_spineupper'),
         ('Spine', 'j_spineupper', 'Chest', 'j_spine4'),
         ('Chest', 'j_spine4', 'Neck', 'j_neck'),
         ('Neck', 'j_neck', 'Head', 'j_head'),
         ('Head', 'j_head', None, None)]
    for s, c in (('L', 'le'), ('R', 'ri')):
        m += [('%s_Shoulder' % s, 'j_clavicle_%s' % c, '%s_UpArm' % s, 'j_shoulder_%s' % c),
              ('%s_UpArm' % s, 'j_shoulder_%s' % c, '%s_ForeArm' % s, 'j_elbow_%s' % c),
              ('%s_ForeArm' % s, 'j_elbow_%s' % c, '%s_Hand' % s, 'j_wrist_%s' % c),
              ('%s_Hand' % s, 'j_wrist_%s' % c, '%s_Middle_1' % s, 'j_mid_%s_1' % c),
              ('%s_Hip' % s, 'j_hip_%s' % c, '%s_Knee' % s, 'j_knee_%s' % c),
              ('%s_Knee' % s, 'j_knee_%s' % c, '%s_Foot' % s, 'j_ankle_%s' % c),
              ('%s_Foot' % s, 'j_ankle_%s' % c, '%s_Toe' % s, 'j_ball_%s' % c),
              ('%s_Toe' % s, 'j_ball_%s' % c, None, None)]
        for F, f in FINGERS:
            m += [('%s_%s_1' % (s, F), 'j_%s_%s_1' % (f, c), '%s_%s_2' % (s, F), 'j_%s_%s_2' % (f, c)),
                  ('%s_%s_2' % (s, F), 'j_%s_%s_2' % (f, c), None, None)]
    return m


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
    ap.add_argument('--out', default=os.path.join(os.path.dirname(HERE), '..', 'build', 'skins'))
    ap.add_argument('--keep-weapons', action='store_true')
    a = ap.parse_args()
    name = a.name
    out = os.path.abspath(a.out)

    cod = Gltf(a.cod)
    ch = Gltf(a.character)
    cskin = cod.j['skins'][0]
    cjoints = cskin['joints']
    cidx = {cod.nodes[n]['name']: k for k, n in enumerate(cjoints)}
    cpos = {cod.nodes[n]['name']: cod.world(n)[:3, 3] for n in cjoints}

    skin = ch.j['skins'][0]
    jn = skin['joints']
    names = [ch.nodes[n].get('name') for n in jn]
    ibm = ch.accessor(skin['inverseBindMatrices']).reshape(-1, 4, 4).transpose(0, 2, 1)
    bind = np.linalg.inv(ibm)

    # 1. character -> CoD space: CoD is Y up, inches, facing +X with its left at -Z. The character is
    #    assumed Y up facing +Z with its left at +X (glTF convention): turn 90 deg about Y, scale to height.
    R0 = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], float)
    head = names.index('Head')
    scale = cpos['j_head'][1] / bind[head][1, 3]
    P = {nm: R0 @ (bind[k][:3, 3] * scale) for k, nm in enumerate(names)}

    # character joint hierarchy restricted to skin joints
    jset = set(jn)
    par = {}
    for k, n in enumerate(jn):
        p = ch.parent.get(n)
        while p is not None and p not in jset:
            p = ch.parent.get(p)
        par[names[k]] = names[jn.index(p)] if p is not None else None
    order = []
    seen = set()

    def visit(nm):
        if nm in seen:
            return
        if par[nm] is not None:
            visit(par[nm])
        seen.add(nm)
        order.append(nm)
    for nm in names:
        visit(nm)

    bmap = {d: (c, da, ca) for d, c, da, ca in bone_map() if d in P and c in cpos}
    missing = [d for d, c, _, _ in bone_map() if d not in P]
    if missing:
        print('note: character has no', ', '.join(missing))

    # 2. pose into the CoD rest pose: A[nm] = world rotation applied to the bone and its subtree
    A = {}
    PP = {}
    for nm in order:
        p = par[nm]
        Ap = A[p] if p else np.eye(3)
        PP[nm] = PP[p] + Ap @ (P[nm] - P[p]) if p else P[nm]
        An = Ap
        if nm in bmap and bmap[nm][1] in P and bmap[nm][2] in cpos:
            c, da, ca = bmap[nm]
            cur = Ap @ (P[da] - P[nm])
            tgt = cpos[ca] - cpos[c]
            if np.linalg.norm(cur) > 1e-6 and np.linalg.norm(tgt) > 1e-6:
                An = rot_between(cur, tgt) @ Ap
        A[nm] = An

    # nearest mapped ancestor of every character bone
    anc = {}
    for nm in order:
        anc[nm] = nm if nm in bmap else (anc[par[nm]] if par[nm] else None)

    # 3. vertices
    mesh_node = next(i for i, n in enumerate(ch.nodes) if 'mesh' in n)
    prim = ch.j['meshes'][ch.nodes[mesh_node]['mesh']]['primitives'][0]
    pos = ch.accessor(prim['attributes']['POSITION']).astype(float)
    uv = ch.accessor(prim['attributes']['TEXCOORD_0']).astype(float)
    J = ch.accessor(prim['attributes']['JOINTS_0']).astype(int)
    W = ch.accessor(prim['attributes']['WEIGHTS_0']).astype(float)
    idx = ch.accessor(prim['indices']).reshape(-1).astype(int)
    pos = (ch.world(mesh_node) @ np.c_[pos, np.ones(len(pos))].T).T[:, :3]
    V = (R0 @ (pos * scale).T).T

    nv = len(V)
    outV = np.zeros((nv, 3))
    outJ = np.zeros((nv, 4), int)
    outW = np.zeros((nv, 4))
    drop = np.zeros(nv, bool)
    for v in range(nv):
        acc = {}
        tot = 0.0
        heavy = None
        hw = 0
        for k in range(4):
            w = W[v, k]
            if w <= 0:
                continue
            d = names[J[v, k]]
            if w > hw:
                hw, heavy = w, d
            a_ = anc[d] or 'Root'
            c = bmap[a_][0] if a_ in bmap else 'j_mainroot'
            posed = PP[d] + A[d] @ (V[v] - P[d])
            outV[v] += w * (cpos[c] + (posed - PP[a_]))
            acc[c] = acc.get(c, 0) + w
            tot += w
        if tot > 0:
            outV[v] /= tot
        if heavy and 'Weapon' in heavy and not a.keep_weapons:
            drop[v] = True
        top = sorted(acc.items(), key=lambda t: -t[1])[:4]
        s = sum(t[1] for t in top) or 1
        for k, (c, w) in enumerate(top):
            outJ[v, k] = cidx[c]
            outW[v, k] = w / s

    tris = idx.reshape(-1, 3)
    tris = tris[~drop[tris].any(1)]
    # normals
    N = np.zeros((nv, 3))
    fn = np.cross(outV[tris[:, 1]] - outV[tris[:, 0]], outV[tris[:, 2]] - outV[tris[:, 0]])
    for k in range(3):
        np.add.at(N, tris[:, k], fn)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    print('vertices %d, triangles %d (%d dropped as weapon), height %.1f' % (nv, len(tris), len(idx) // 3 - len(tris), outV[:, 1].max()))

    # 4. write sources
    for d in ('model_export', 'xmodel', 'materials/mc', 'images', 'zone_source'):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    material = 'mc/mtl_coop_%s' % name
    image = 'coop_%s_col' % name
    model = 'coop_%s' % name

    g = json.loads(json.dumps(cod.j))  # skeleton, skin and scene from the stock body
    blob = bytearray()
    views, accs = [], []

    def add(arr, ctype, typ, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        while len(blob) % 4:
            blob.append(0)
        off = len(blob)
        blob.extend(arr.tobytes())
        v = {'buffer': 0, 'byteOffset': off, 'byteLength': arr.nbytes}
        if target:
            v['target'] = target
        views.append(v)
        acc = {'bufferView': len(views) - 1, 'componentType': ctype, 'count': len(arr), 'type': typ}
        if minmax:
            acc['min'] = arr.min(0).tolist()
            acc['max'] = arr.max(0).tolist()
        accs.append(acc)
        return len(accs) - 1

    cibm = cod.accessor(cskin['inverseBindMatrices']).astype(np.float32)
    a_pos = add(outV.astype(np.float32), 5126, 'VEC3', 34962, True)
    a_nrm = add(N.astype(np.float32), 5126, 'VEC3', 34962)
    a_uv = add(uv.astype(np.float32), 5126, 'VEC2', 34962)
    a_col = add(np.ones((nv, 4), np.float32), 5126, 'VEC4', 34962)
    a_j = add(outJ.astype(np.uint16), 5123, 'VEC4', 34962)
    a_w = add(outW.astype(np.float32), 5126, 'VEC4', 34962)
    a_i = add(tris.reshape(-1).astype(np.uint32), 5125, 'SCALAR', 34963)
    a_ibm = add(cibm, 5126, 'MAT4')
    while len(blob) % 4:
        blob.append(0)
    g['buffers'] = [{'byteLength': len(blob)}]  # GLB: the OAT Linker does not read external .bin buffers
    g['bufferViews'] = views
    g['accessors'] = accs
    g['skins'][0]['inverseBindMatrices'] = a_ibm
    g['materials'] = [{'name': material}]
    g['meshes'] = [{'primitives': [{'attributes': {'POSITION': a_pos, 'NORMAL': a_nrm, 'TEXCOORD_0': a_uv, 'COLOR_0': a_col,
                                                   'JOINTS_0': a_j, 'WEIGHTS_0': a_w}, 'indices': a_i, 'material': 0}]}]
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
    with open(os.path.join(out, 'model_export', model + '.glb'), 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        f.write(struct.pack('<II', len(js), 0x4E4F534A) + js)
        f.write(struct.pack('<II', len(blob), 0x004E4942) + bytes(blob))
    json.dump({'$schema': 'http://openassettools.dev/schema/xmodel.v1.json', '_game': 'iw3', '_type': 'xmodel', '_version': 2,
               'flags': 0, 'lods': [{'distance': 1000000.0, 'file': 'model_export/%s.glb' % model}], 'type': 'animated'},
              open(os.path.join(out, 'xmodel', model + '.json'), 'w'), indent=2)
    mat = json.load(open(TEMPLATE_MATERIAL))
    for t in mat['textures']:
        if t['semantic'] == 'colorMap':
            t['image'] = image
    mat['surfaceTypeBits'] = 64  # same surface as the stock bodies
    json.dump(mat, open(os.path.join(out, 'materials', material + '.json'), 'w'), indent=2)

    # texture -> uncompressed DDS
    from PIL import Image
    import io
    tex = ch.j['images'][0]
    if 'bufferView' in tex:
        raw, _ = ch.bufferview(tex['bufferView'])
        img = Image.open(io.BytesIO(raw))
    else:
        img = Image.open(os.path.join(ch.dir, tex['uri']))
    img = img.convert('RGBA')
    img.save(os.path.join(out, 'images', image + '.dds'))
    # the OAT Linker reads IW3 images as .iwi: convert with its ImageConverter
    import subprocess
    subprocess.run([OAT_IMAGECONV, '--iw3', os.path.join(out, 'images', image + '.dds')], check=True, capture_output=True)
    print('texture', img.size)
    print('staged', model, 'in', out)


if __name__ == '__main__':
    main()
