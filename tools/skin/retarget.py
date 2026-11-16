"""Dance/emote animations from other games and tools -> a CoD4 xanim on the player skeleton.

Readers (all give a Clip: bone names, parents, world rotation matrices and positions per frame plus the
rest pose, in the file's own axes and units):
  .ueanim (+ .uemodel skeleton)   UEFormat (the Unreal exporter format), zstd payload
  .glb / .gltf                     first animation, sampled at 30 fps (Mixamo exports, Blender exports...)
  .fbx                             through Blender (converted to GLB first, like the skin tools)
  .bvh                             motion capture

Retarget: the bones are matched with rebind.py's classifier (pelvis, spine chain, neck, head, clavicle /
upper arm / forearm / hand, thigh / calf / foot / toe, fingers), the source's facing, up and handedness
are read from its rest pose (hips -> left, pelvis -> head = up, ankle -> toe = forward), and each CoD bone
takes its source bone's rotation relative to the rest pose, turned so the bone points where the source
bone points (A-pose / T-pose differences and other proportions do not matter). The pelvis height and sway
are scaled to the CoD soldier; travel (root motion) is dropped so the emote plays on the spot, and for a
looping emote the net travel and turn over one cycle are spread out so the loop seam does not snap.
"""
import math
import os
import re
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


# --------------------------------------------------------------------------------------------------
# math
# --------------------------------------------------------------------------------------------------

def q2m(q):
    """quats [..., 4] xyzw -> matrices [..., 3, 3]"""
    q = np.asarray(q, float)
    q = q / np.linalg.norm(q, axis=-1, keepdims=True)
    x, y, z, w = np.moveaxis(q, -1, 0)
    return np.stack([
        np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], -1),
        np.stack([2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], -1),
        np.stack([2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)], -1)], -2)


def m2q(m):
    """one proper rotation matrix -> quat xyzw"""
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = math.sqrt(t + 1) * 2
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, s / 4]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [s / 4, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / s, s / 4, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = math.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, s / 4, (m[1, 0] - m[0, 1]) / s]
    q = np.array(q)
    return q / np.linalg.norm(q)


def rot_between(a, b):
    """smallest rotation turning direction a onto direction b"""
    a = a / (np.linalg.norm(a) + 1e-12)
    b = b / (np.linalg.norm(b) + 1e-12)
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


def slerp(a, b, t):
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + t * (b - a)
        return r / np.linalg.norm(r)
    th = math.acos(d)
    return (math.sin((1 - t) * th) * a + math.sin(t * th) * b) / math.sin(th)


def sample_keys(times, vals, at, quat):
    """sparse keys (sorted times) -> values at the times 'at' (linear / slerp, ends held)"""
    times = np.asarray(times, float)
    vals = np.asarray(vals, float)
    out = np.empty((len(at), vals.shape[1]))
    for k, t in enumerate(at):
        j = int(np.searchsorted(times, t, side='right')) - 1
        if j < 0:
            out[k] = vals[0]
        elif j >= len(times) - 1:
            out[k] = vals[-1]
        else:
            u = (t - times[j]) / (times[j + 1] - times[j]) if times[j + 1] > times[j] else 0
            out[k] = slerp(vals[j], vals[j + 1], u) if quat else vals[j] + (vals[j + 1] - vals[j]) * u
    return out


class Clip:
    """names[B], parents[B] (-1 root, parents before children), rest_rot[B,3,3], rest_pos[B,3],
    rot[F,B,3,3], pos[F,B,3] (world), fps"""

    def __init__(self, names, parents, rest_rot, rest_pos, rot, pos, fps, name=''):
        self.names, self.parents = list(names), list(parents)
        self.rest_rot, self.rest_pos = np.asarray(rest_rot, float), np.asarray(rest_pos, float)
        self.rot, self.pos = np.asarray(rot, float), np.asarray(pos, float)
        self.fps = float(fps)
        self.name = name


def fk(parents, lrot, lpos):
    """local [..., B, 3, 3] / [..., B, 3] -> world"""
    grot = np.empty_like(lrot)
    gpos = np.empty_like(lpos)
    for i, p in enumerate(parents):
        if p < 0:
            grot[..., i, :, :] = lrot[..., i, :, :]
            gpos[..., i, :] = lpos[..., i, :]
        else:
            grot[..., i, :, :] = grot[..., p, :, :] @ lrot[..., i, :, :]
            gpos[..., i, :] = gpos[..., p, :] + np.einsum('...ij,...j->...i', grot[..., p, :, :], lpos[..., i, :])
    return grot, gpos


def order_parents_first(names, parents):
    """-> permutation so that every parent comes before its children"""
    done, order = set(), []
    kids = {}
    for i, p in enumerate(parents):
        kids.setdefault(p, []).append(i)
    stack = list(reversed(kids.get(-1, [])))
    while stack:
        i = stack.pop()
        order.append(i)
        stack.extend(reversed(kids.get(i, [])))
    return order


# --------------------------------------------------------------------------------------------------
# readers
# --------------------------------------------------------------------------------------------------

class _R:
    def __init__(self, b, o=0):
        self.b, self.o = b, o

    def i(self):
        v = struct.unpack_from('<i', self.b, self.o)[0]
        self.o += 4
        return v

    def f(self, n):
        v = struct.unpack_from('<%df' % n, self.b, self.o)
        self.o += 4 * n
        return v

    def u8(self):
        v = self.b[self.o]
        self.o += 1
        return v

    def fs(self):
        n = self.i()
        v = self.b[self.o:self.o + n].decode('latin1').rstrip('\0')
        self.o += n
        return v


def _ue_payload(path):
    b = open(path, 'rb').read()
    if b[:8] != b'UEFORMAT':
        sys.exit('%s is not a UEFormat file' % os.path.basename(path))
    r = _R(b, 8)
    ident = r.fs()
    r.u8()          # version
    name = r.fs()
    r.fs()          # object path
    if r.u8():
        ctype = r.fs()
        usize = r.i()
        csize = r.i()
        blob = b[r.o:r.o + csize]
        if ctype.upper() == 'ZSTD':
            try:
                import zstandard
            except ImportError:
                sys.exit('reading .ueanim needs the zstandard module: pip install zstandard')
            d = zstandard.ZstdDecompressor().decompress(blob, max_output_size=usize)
        elif ctype.upper() == 'GZIP':
            import gzip
            d = gzip.decompress(blob)
        else:
            sys.exit('unknown UEFormat compression ' + ctype)
    else:
        d = b[r.o:]
    return ident, name, d


def _ue_sections(d, o):
    r = _R(d, o)
    out = []
    for _ in range(r.i()):
        nm = r.fs()
        sz = r.i()
        out.append((nm, r.o, sz))
        r.o += sz
    return out


def read_uemodel(path):
    ident, _, d = _ue_payload(path)
    secs = _ue_sections(d, 0)
    sk = [s for s in secs if s[0] == 'SKELETON']
    if not sk:
        sys.exit('%s has no skeleton' % os.path.basename(path))
    for nm, o, sz in _ue_sections(d, sk[0][1]):
        if nm == 'BONES':
            r = _R(d, o)
            bones = []
            for _ in range(r.i()):
                bn = r.fs()
                par = r.i()
                pos = r.f(3)
                rot = r.f(4)
                r.f(3)
                bones.append((bn, par, pos, rot))
            return bones
    sys.exit('%s has no bones' % os.path.basename(path))


def read_ueanim(path, skel_path):
    bones = read_uemodel(skel_path)
    _, name, d = _ue_payload(path)
    meta, tracks = {}, {}
    for nm, o, sz in _ue_sections(d, 0):
        r = _R(d, o)
        if nm == 'METADATA':
            meta['frames'] = r.i()
            meta['fps'] = r.f(1)[0]
        elif nm == 'TRACKS':
            for _ in range(r.i()):
                bn = r.fs()
                pk = [(r.i(), r.f(3)) for _ in range(r.i())]
                rk = [(r.i(), r.f(4)) for _ in range(r.i())]
                for _ in range(r.i()):
                    r.i()
                    r.f(3)
                tracks[bn.lower()] = (pk, rk)
    n = meta['frames']
    names = [b[0] for b in bones]
    parents = [b[1] for b in bones]
    B = len(bones)
    at = np.arange(n)
    lq = np.zeros((n, B, 4))
    lp = np.zeros((n, B, 3))
    rest_q = np.array([b[3] for b in bones], float)
    rest_p = np.array([b[2] for b in bones], float)
    for i, b in enumerate(bones):
        pk, rk = tracks.get(b[0].lower(), ([], []))
        lp[:, i] = sample_keys([k[0] for k in pk], [k[1] for k in pk], at, False) if pk else rest_p[i]
        if rk:
            v = np.array([k[1] for k in rk], float)
            v /= np.linalg.norm(v, axis=1, keepdims=True)
            for k in range(1, len(v)):
                if np.dot(v[k], v[k - 1]) < 0:
                    v[k] = -v[k]
            lq[:, i] = sample_keys([k[0] for k in rk], v, at, True)
        else:
            lq[:, i] = rest_q[i]
    grot, gpos = fk(parents, q2m(lq), lp)
    rrot, rpos = fk(parents, q2m(rest_q), rest_p)
    # the stored rate is frames / length; the keys are spaced length / (frames - 1)
    fps = meta['fps'] * (n - 1) / n if n > 1 else meta['fps']
    if abs(fps - round(fps)) < 0.05:
        fps = round(fps)
    return Clip(names, parents, rrot, rpos, grot, gpos, fps, name)


def read_gltf(path, fps=30):
    from gltfio import Gltf, quat_to_mat
    g = Gltf(path)
    anims = g.j.get('animations') or []
    if not anims:
        sys.exit('%s has no animation' % os.path.basename(path))
    an = anims[0]
    chans = {}
    tmax = 0
    for ch in an['channels']:
        tgt = ch['target']
        if 'node' not in tgt or tgt['path'] not in ('translation', 'rotation', 'scale'):
            continue
        smp = an['samplers'][ch['sampler']]
        t = g.accessor(smp['input']).astype(float).reshape(-1)
        v = g.accessor(smp['output']).astype(float)
        if smp.get('interpolation') == 'CUBICSPLINE':
            v = v.reshape(len(t), 3, -1)[:, 1]
        v = v.reshape(len(t), -1)
        chans[(tgt['node'], tgt['path'])] = (t, v, smp.get('interpolation', 'LINEAR'))
        tmax = max(tmax, float(t[-1]))
    n = max(2, int(round(tmax * fps)) + 1)
    at = np.arange(n) / fps
    # every node (bones and their non-bone parents such as the Armature / scale nodes)
    N = len(g.nodes)
    parents = [g.parent.get(i, -1) for i in range(N)]
    order = order_parents_first(list(range(N)), parents)
    inv = {o: k for k, o in enumerate(order)}
    names = [g.nodes[i].get('name') or 'node%d' % i for i in order]
    par = [inv[parents[i]] if parents[i] >= 0 else -1 for i in order]
    lrot = np.zeros((n, N, 3, 3))
    lpos = np.zeros((n, N, 3))
    rrot = np.zeros((N, 3, 3))
    rpos = np.zeros((N, 3))
    for k, i in enumerate(order):
        nd = g.nodes[i]
        if 'matrix' in nd:
            M = np.array(nd['matrix'], float).reshape(4, 4).T
            T, R, S = M[:3, 3], M[:3, :3], np.linalg.norm(M[:3, :3], axis=0)
            R = R / S
            rq = m2q(R)
        else:
            T = np.array(nd.get('translation', [0, 0, 0]), float)
            rq = np.array(nd.get('rotation', [0, 0, 0, 1]), float)
            S = np.array(nd.get('scale', [1, 1, 1]), float)
        rrot[k] = quat_to_mat(rq) * S
        rpos[k] = T
        tr = chans.get((i, 'translation'))
        ro = chans.get((i, 'rotation'))
        sc = chans.get((i, 'scale'))
        P = sample_keys(tr[0], tr[1], at, False) if tr else np.tile(T, (n, 1))
        if ro:
            v = ro[1] / np.linalg.norm(ro[1], axis=1, keepdims=True)
            for j in range(1, len(v)):
                if np.dot(v[j], v[j - 1]) < 0:
                    v[j] = -v[j]
            Q = sample_keys(ro[0], v, at, True)
        else:
            Q = np.tile(rq, (n, 1))
        Sc = sample_keys(sc[0], sc[1], at, False) if sc else np.tile(S, (n, 1))
        lrot[:, k] = q2m(Q) * Sc[:, None, :]
        lpos[:, k] = P
    grot, gpos = fk(par, lrot, lpos)
    rg, rp = fk(par, rrot, rpos)
    # scale (an Armature node at 0.01...) stays in the positions; rotations are made orthonormal
    grot = grot / np.linalg.norm(grot, axis=-2, keepdims=True)
    rg = rg / np.linalg.norm(rg, axis=-2, keepdims=True)
    return Clip(names, par, rg, rp, grot, gpos, fps, an.get('name', ''))


def read_bvh(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    tok = txt.split()
    i = 0
    names, parents, offsets, chans = [], [], [], []
    stack = []
    while i < len(tok) and tok[i] != 'MOTION':
        t = tok[i]
        if t in ('ROOT', 'JOINT'):
            names.append(tok[i + 1])
            parents.append(stack[-1] if stack else -1)
            offsets.append(None)
            chans.append([])
            i += 2
        elif t == 'End':
            names.append(names[stack[-1]] + '_end')
            parents.append(stack[-1])
            offsets.append(None)
            chans.append([])
            i += 2
        elif t == '{':
            stack.append(len(names) - 1)
            i += 1
        elif t == '}':
            stack.pop()
            i += 1
        elif t == 'OFFSET':
            offsets[stack[-1]] = [float(x) for x in tok[i + 1:i + 4]]
            i += 4
        elif t == 'CHANNELS':
            k = int(tok[i + 1])
            chans[stack[-1]] = tok[i + 2:i + 2 + k]
            i += 2 + k
        else:
            i += 1
    i += 1
    nf = int(tok[i + 1])                      # Frames: n
    ft = float(tok[i + 4])                    # Frame Time: t
    vals = np.array([float(x) for x in tok[i + 5:]], float)
    width = sum(len(c) for c in chans)
    vals = vals[:nf * width].reshape(nf, width)
    B = len(names)
    lrot = np.tile(np.eye(3), (nf, B, 1, 1))
    lpos = np.tile(np.array([o or [0, 0, 0] for o in offsets], float), (nf, 1, 1))
    col = 0
    axes = {'X': 0, 'Y': 1, 'Z': 2}
    for b in range(B):
        R = np.tile(np.eye(3), (nf, 1, 1))
        for c in chans[b]:
            v = vals[:, col]
            col += 1
            ax = c[0].upper()
            if c.lower().endswith('position'):
                lpos[:, b, axes[ax]] = v + (offsets[b][axes[ax]] if parents[b] >= 0 else 0)
            else:
                a = np.radians(v)
                ca, sa = np.cos(a), np.sin(a)
                M = np.tile(np.eye(3), (nf, 1, 1))
                p, q = [(1, 2), (2, 0), (0, 1)][axes[ax]]
                M[:, p, p] = ca
                M[:, p, q] = -sa
                M[:, q, p] = sa
                M[:, q, q] = ca
                R = R @ M
        lrot[:, b] = R
    grot, gpos = fk(parents, lrot, lpos)
    rr, rp = fk(parents, np.tile(np.eye(3), (B, 1, 1)), np.array([o or [0, 0, 0] for o in offsets], float))
    fps = 1.0 / ft if ft > 0 else 30
    if abs(fps - round(fps)) < 0.05:
        fps = round(fps)
    return Clip(names, parents, rr, rp, grot, gpos, fps, os.path.splitext(os.path.basename(path))[0])


def load_clip(path, skeleton=None):
    ext = os.path.splitext(path)[1].lower()
    if ext == '.ueanim':
        if not skeleton:
            d = os.path.dirname(os.path.abspath(path))
            cands = sorted(f for f in os.listdir(d) if f.lower().endswith('.uemodel'))
            if not cands:
                sys.exit('no .uemodel skeleton next to %s: pass --skeleton' % os.path.basename(path))
            skeleton = os.path.join(d, cands[0])
        return read_ueanim(path, skeleton)
    if ext in ('.glb', '.gltf'):
        return read_gltf(path)
    if ext == '.fbx':
        import rebind
        return read_gltf(rebind.fbx_to_glb(path))
    if ext == '.bvh':
        return read_bvh(path)
    sys.exit('unsupported animation format %s (use .ueanim, GLB / glTF, FBX or BVH)' % ext)


# --------------------------------------------------------------------------------------------------
# the CoD4 soldier skeleton (the same one the skins are bound to)
# --------------------------------------------------------------------------------------------------

class CodSkel:
    def __init__(self, path):
        from gltfio import Gltf
        g = Gltf(path)
        root = g.name_to_node['tag_origin']
        self.names, self.parents, self.lpos, self.lrot = [], [], [], []
        idx = {}

        def walk(i, p):
            idx[i] = len(self.names)
            nd = g.nodes[i]
            self.names.append(nd['name'])
            self.parents.append(p)
            if i == root:                 # OAT turns the model Y-up here: the game's tag_origin is identity
                self.lrot.append(np.eye(3))
                self.lpos.append(np.zeros(3))
            else:
                L = g.local(i)
                self.lrot.append(L[:3, :3] / np.linalg.norm(L[:3, :3], axis=0))
                self.lpos.append(L[:3, 3].copy())
            me = idx[i]
            for c in nd.get('children', []):
                if 'mesh' not in g.nodes[c]:
                    walk(c, me)
        walk(root, -1)
        self.lpos = np.array(self.lpos)
        self.lrot = np.array(self.lrot)
        self.wrot, self.wpos = fk(self.parents, self.lrot, self.lpos)
        self.index = {n: i for i, n in enumerate(self.names)}


# --------------------------------------------------------------------------------------------------
# retarget
# --------------------------------------------------------------------------------------------------

class _Char:
    def __init__(self, bones, parent):
        self.bones, self.parent = bones, parent


def _basis(pelvis, head, hip_l, hip_r, toe=None, ankle=None):
    """rows = forward, left, up of a character in its own rest pose (may be a mirror for a left-handed file)"""
    up = head - pelvis
    up /= np.linalg.norm(up)
    left = hip_l - hip_r
    left -= up * np.dot(left, up)
    left /= np.linalg.norm(left)
    fwd = np.cross(left, up)
    if toe is not None and ankle is not None and np.dot(toe - ankle, fwd) < 0:
        fwd = -fwd                       # the toes point the other way: left-handed axes (Unreal)
    return np.array([fwd, left, up])


def retarget(clip, cod, loop=True, fingers=True, log=print):
    """-> (num_frames, fps, looped, tracks) for xanim.build, and the CoD world poses (for a preview)"""
    import rebind
    names = clip.names
    lower = [n.lower() for n in names]
    # metacarpals would take the first finger segment; IK / twist / helpers are skipped by classify
    # and face bones (under the head) can look like fingers (l_brow_mid...): only the body is matched
    head_i = [i for i, n in enumerate(names) if rebind.classify(n)[1] == 'head']
    under_head = set()
    for i in range(len(names)):
        p = clip.parents[i]
        while p >= 0:
            if p in head_i:
                under_head.add(i)
                break
            p = clip.parents[p]
    keep = [i for i, n in enumerate(lower) if 'metacarpal' not in n and i not in under_head]
    keepset = set(keep)

    def kept_parent(i):
        p = clip.parents[i]
        while p >= 0 and p not in keepset:
            p = clip.parents[p]
        return p
    bones = [names[i] for i in keep]
    parent = {names[i]: (names[kept_parent(i)] if kept_parent(i) >= 0 else None) for i in keep}
    cpos = {n: cod.wpos[k] for k, n in enumerate(cod.names)}
    m = rebind.build_map(_Char(bones, parent), cpos)
    sidx = {n: i for i, n in enumerate(names)}
    roles = {b: rebind.classify(b) for b in bones}
    pelvis = next((b for b in bones if roles[b][1] == 'pelvis'), None)
    head = next((b for b in bones if roles[b][1] == 'head'), None)

    def role(side, r):
        c = [b for b in bones if roles[b][0] == side and roles[b][1] == r]
        return c[0] if c else None
    thl, thr = role('L', 'thigh'), role('R', 'thigh')
    if not (pelvis and head and thl and thr):
        sys.exit('could not find the pelvis, head and both thighs among: %s' % ', '.join(names[:80]))
    # group: CoD bone -> source bones mapped to it, in chain order (spine bones share CoD bones)
    groups = {}
    for b in bones:
        if b in m:
            cb, aim_s, aim_c = m[b]
            if cb == 'j_mainroot' and b != pelvis:
                continue
            if not fingers and cb.startswith(('j_thumb', 'j_index', 'j_mid_', 'j_ring', 'j_pinky')):
                continue
            groups.setdefault(cb, []).append(b)
    for cb, g in groups.items():
        g.sort(key=lambda b: _depth(b, parent))
    log('bone map: ' + ', '.join('%s<-%s' % (cb, '+'.join(g)) for cb, g in sorted(groups.items())))
    # axes: source -> CoD model space (both from their rest poses)
    tl, tr = role('L', 'toe') or role('L', 'foot'), role('R', 'toe') or role('R', 'foot')
    al, ar = role('L', 'foot') or role('L', 'calf'), role('R', 'foot') or role('R', 'calf')
    rp = clip.rest_pos
    toe = ankle = None
    if tl and al and tl != al:
        toe = (rp[sidx[tl]] + rp[sidx[tr]]) / 2
        ankle = (rp[sidx[al]] + rp[sidx[ar]]) / 2
    Bs = _basis(rp[sidx[pelvis]], rp[sidx[head]], rp[sidx[thl]], rp[sidx[thr]], toe, ankle)
    ci = cod.index
    Bc = _basis(cod.wpos[ci['j_mainroot']], cod.wpos[ci['j_head']], cod.wpos[ci['j_hip_le']], cod.wpos[ci['j_hip_ri']],
                (cod.wpos[ci['j_ball_le']] + cod.wpos[ci['j_ball_ri']]) / 2,
                (cod.wpos[ci['j_ankle_le']] + cod.wpos[ci['j_ankle_ri']]) / 2)
    T = Bc.T @ Bs                       # source world -> CoD model space (a reflection for Unreal files)
    if np.linalg.det(T) < 0:
        log('source axes are left-handed: mirrored into the CoD axes')
    rot = np.einsum('ij,fbjk,lk->fbil', T, clip.rot, T)
    pos = np.einsum('ij,fbj->fbi', T, clip.pos)
    rrot = np.einsum('ij,bjk,lk->bil', T, clip.rest_rot, T)
    rpos = np.einsum('ij,bj->bi', T, clip.rest_pos)
    F = rot.shape[0]
    # pelvis height above the feet, for scale
    up = np.array([0, 0, 1.0])
    sp = sidx[pelvis]
    feet_s = [sidx[x] for x in (al, ar) if x]
    src_h = float(np.dot(rpos[sp] - rpos[feet_s].mean(0), up))
    cod_h = float(np.dot(cod.wpos[ci['j_mainroot']] - (cod.wpos[ci['j_ankle_le']] + cod.wpos[ci['j_ankle_ri']]) / 2, up))
    scale = cod_h / src_h if src_h > 1e-6 else 1.0
    log('scale %.4f (pelvis %.1f -> %.1f in CoD units), %d frames at %s fps' % (scale, src_h, cod_h, F, clip.fps))
    # pelvis offset from its rest spot; travel removed (first frame on the spot; for a one-shot the net
    # drift is spread out here, for a loop below, once the frame that closes the loop is known)
    off = (pos[:, sp] - rpos[sp]) * scale
    h = off[:, :2]
    h = h - h[0]
    if not loop:
        h = h - (h[-1] - h[0])[None, :] * (np.arange(F) / max(1, F - 1))[:, None]
    off = np.c_[h, off[:, 2]]
    # pose every CoD bone, parents first
    NB = len(cod.names)
    W = np.zeros((F, NB, 3, 3))
    P = np.zeros((F, NB, 3))
    for k, cb in enumerate(cod.names):
        p = cod.parents[k]
        if p < 0:
            W[:, k] = cod.lrot[k]
            P[:, k] = cod.lpos[k]
            continue
        P[:, k] = P[:, p] + np.einsum('fij,j->fi', W[:, p], cod.lpos[k])
        g = groups.get(cb)
        if not g:
            W[:, k] = W[:, p] @ cod.lrot[k]
            continue
        first, last = sidx[g[0]], sidx[g[-1]]
        delta = rot[:, last] @ rrot[last].T[None]                  # source rotation from its rest pose
        aim_s, aim_c = m[g[-1]][1], m[g[-1]][2]
        Wr = cod.wrot[k]
        if aim_s and aim_c in ci and aim_s in sidx:
            v_rest = cod.wpos[ci[aim_c]] - cod.wpos[k]
            v_local = Wr.T @ v_rest
            A = rot_between(v_rest, rpos[sidx[aim_s]] - rpos[first])
            base = delta @ (A @ Wr)[None]
            for f in range(F):
                cur = base[f] @ v_local
                want = pos[f, sidx[aim_s]] - pos[f, first]
                W[f, k] = rot_between(cur, want) @ base[f]
        else:
            W[:, k] = delta @ Wr[None]
        if cb == 'j_mainroot':
            P[:, k] = cod.wpos[k] + off
    # the xanim: local rotations of every posed bone (and the ones between them); pelvis translation
    # stored relative to the model's own (the game adds the base offset)
    posed = set(groups)
    out_bones = []
    for k, cb in enumerate(cod.names):
        if cb == 'tag_origin':
            continue
        if cb in posed or any(_is_ancestor(cod, k, ci[x]) for x in posed):
            out_bones.append(k)
    # loop: the last frame is the first again; keys = frames 0..N-1 then frame 0
    frames = list(range(F))
    kr = ci['j_mainroot']
    turn = None                          # per frame: a yaw about the vertical that undoes heading drift
    if loop:
        d = _pose_diff(W[0], W[-1])
        log('first / last frame difference %.4f' % d)
        if F > 2 and d < 0.05:
            frames = frames[:-1]
        num = len(frames)
        frames = frames + [0]
        # the loop closes by jumping back to frame 0, so whatever the dance travels or turns over one cycle
        # would snap back at every seam: spread that drift out over the cycle. The closing frame is frame
        # num (the dropped near-duplicate F-1, or one step past the last frame, extrapolated).
        if F > 1:
            yaws = np.unwrap([_yaw(W[f, kr], cod.wrot[kr]) for f in range(F)])
            if num < F:
                h_end = P[num, kr, :2]
                y_end = yaws[num]
            else:
                h_end = P[0, kr, :2] + (P[F - 1, kr, :2] - P[0, kr, :2]) * F / (F - 1)
                y_end = yaws[0] + (yaws[F - 1] - yaws[0]) * F / (F - 1)
            t = (np.arange(F) / float(num))[:, None]
            dh = h_end - P[0, kr, :2]
            P[:, kr, :2] -= dh[None, :] * t
            # whole turns per cycle loop seamlessly: only the rest is drift
            dy = (y_end - yaws[0] + math.pi) % (2 * math.pi) - math.pi
            if abs(dy) > math.radians(2):
                turn = [_rz(-dy * f / float(num)) for f in range(F)]
            log('loop drift removed: %.1f units, %.1f degrees' % (float(np.hypot(*dh)), math.degrees(dy)))
    else:
        num = F
    tracks = []
    for k in out_bones:
        p = cod.parents[k]
        if k == kr and turn is not None:
            # turning the pelvis turns everything under it (their rotations are stored relative to it)
            quats = [m2q(W[f, p].T @ turn[f] @ W[f, k]) for f in frames]
        else:
            quats = [m2q(W[f, p].T @ W[f, k]) for f in frames]
        trans = None
        if cod.names[k] == 'j_mainroot':
            trans = [tuple(P[f, k] - cod.lpos[k]) for f in frames]
        tracks.append((cod.names[k], quats, trans))
    return (num, clip.fps, loop, tracks), (W, P)


def _depth(b, parent):
    d = 0
    while parent.get(b):
        b = parent[b]
        d += 1
    return d


def _is_ancestor(cod, a, k):
    """is bone a an ancestor of bone k"""
    p = cod.parents[k]
    while p >= 0:
        if p == a:
            return True
        p = cod.parents[p]
    return False


def _yaw(Wk, Wrest):
    """heading (radians) of a bone's turn from its rest pose: where it carries the model's forward axis"""
    v = Wk @ Wrest.T @ np.array([1.0, 0, 0])
    return math.atan2(v[1], v[0])


def _rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def _pose_diff(Wa, Wb):
    return float(np.max(np.abs(Wa - Wb)))


def preview(cod, poses, path, title=''):
    """stick figure of the CoD skeleton at 6 moments, front and side"""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        return None
    W, P = poses
    F = P.shape[0]
    pick = sorted(set(int(round(x)) for x in np.linspace(0, F - 1, 6)))
    skip = re.compile(r'^(tag_|j_(coat|knee_bulge|kneebuldge|shorts|brow|cheek|eye|lip|levator|mouth|jaw|helmet|gasmask|'
                      r'nvg|chin|collar|shoulderraise|elbow_bulge|head_end|gun)|joint)')
    fig, axes = plt.subplots(2, len(pick), figsize=(2.2 * len(pick), 5.2))
    for col, f in enumerate(pick):
        for row, (a, b, lab) in enumerate(((1, 2, 'front'), (0, 2, 'side'))):
            ax = axes[row][col]
            for k, nm in enumerate(cod.names):
                p = cod.parents[k]
                if p <= 0 or skip.match(nm) or skip.match(cod.names[p]):
                    continue
                c = 'tab:blue' if nm.endswith('_le') or '_le_' in nm else ('tab:red' if nm.endswith('_ri') or '_ri_' in nm else 'k')
                ax.plot([P[f, p, a], P[f, k, a]], [P[f, p, b], P[f, k, b]], c, lw=1.4)
            ax.set_xlim(-35, 35)
            ax.set_ylim(-5, 70)
            ax.set_aspect('equal')
            ax.set_xticks([])
            ax.set_yticks([])
            if row == 0:
                ax.set_title('frame %d' % f, fontsize=8)
            if col == 0:
                ax.set_ylabel(lab, fontsize=8)
    fig.suptitle(title, fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=80)
    plt.close(fig)
    return path
