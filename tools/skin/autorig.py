"""Automatic rig for an unrigged humanoid mesh standing in a T- or A-pose.

Places a simple humanoid skeleton from the shape of the mesh (height bands, arm span, leg split, slice
centroids) and computes skin weights from the distance to each bone segment, gated by body region so the
arms never pull the torso and the legs never pull each other. The bones get Mixamo-style names, which
rebind.py already understands, so the result goes through the normal rebind onto the CoD4 skeleton.

Assumes Y up (Z-up meshes are detected and turned) and the glTF convention of facing +Z with the
character's left at +X; --flip turns a model that faces the other way.
"""
import numpy as np


def _centroid_near(V, point, radius, mask=None):
    d = np.linalg.norm(V - point, axis=1)
    sel = d < radius
    if mask is not None:
        sel &= mask
    if sel.sum() < 3:
        return point
    return V[sel].mean(0)


def _seg_dist(P, a, b):
    ab = b - a
    t = np.clip(((P - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)


def autorig(ch, flip=False):
    """Fill ch.bones / ch.parent / ch.bind and every prim's jn / w for an unrigged Char."""
    V = np.vstack([p['pos'] for p in ch.prims])
    ext = V.max(0) - V.min(0)
    turn = np.eye(3)
    if ext[2] > ext[1] * 1.3 and ext[2] > ext[0] * 0.8:   # Z up -> Y up
        turn = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
    if flip:
        turn = np.array([[-1, 0, 0], [0, 1, 0], [0, 0, -1]], float) @ turn
    V = V @ turn.T
    y0 = V[:, 1].min()
    H = V[:, 1].max() - y0
    Y = (V[:, 1] - y0) / H
    # --- landmarks measured from the body, so cartoon proportions work too ---
    # measure on points spread over the surface (low-poly meshes have too few vertices to see gaps)
    rng = np.random.default_rng(0)
    pts = []
    for pr in ch.prims:
        P = pr['pos'] @ turn.T
        T = P[pr['tris']]
        area = np.linalg.norm(np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]), axis=1) / 2
        if area.sum() <= 0:
            continue
        k = rng.choice(len(T), size=max(2000, int(40000 * area.sum() / max(area.sum(), 1e-9))), p=area / area.sum())
        r1, r2 = rng.random(len(k)), rng.random(len(k))
        sq = np.sqrt(r1)
        pts.append(T[k, 0] * (1 - sq)[:, None] + T[k, 1] * (sq * (1 - r2))[:, None] + T[k, 2] * (sq * r2)[:, None])
    S_ = np.vstack(pts + [V])
    SY = (S_[:, 1] - y0) / H
    bins = 60
    xc = float(np.median(S_[:, 0]))
    zc = float(np.median(S_[:, 2]))

    def band(lo, hi):
        return (Y >= lo) & (Y < hi)
    width = np.zeros(bins)
    centre_gap = np.zeros(bins, bool)
    for b in range(bins):
        m = (SY >= b / bins) & (SY < (b + 1) / bins)
        if m.sum() < 5:
            continue
        width[b] = np.percentile(np.abs(S_[m, 0] - xc), 98)
        centre_gap[b] = not (np.abs(S_[m, 0] - xc) < H * 0.012).any()
    # arms (T- or A-pose): the widest part of the body; shoulder = top of that wide run
    bmax = int(np.argmax(width[bins // 5:])) + bins // 5
    thr = width[bmax] * 0.55
    top_b = bmax
    while top_b + 1 < bins and width[top_b + 1] > thr:
        top_b += 1
    shoulder = (top_b + 1) / bins
    # crotch: the legs are apart below it (gap on the centre line), else half the shoulder height
    crotch = shoulder * 0.5
    gaps = [b for b in range(1, int(shoulder * bins * 0.8)) if centre_gap[b]]
    if gaps:
        b = gaps[0]
        while b + 1 < bins and centre_gap[b + 1]:
            b += 1
        crotch = (b + 1) / bins
    above = [b for b in range(top_b + 1, bins - 1) if width[b] > 0]
    neck = ((min(above[:max(1, len(above) // 2)], key=lambda b: width[b]) + 0.5) / bins) if above else shoulder + 0.03
    tw = float(np.median(width[int(crotch * bins) + 1:max(int(crotch * bins) + 2, int(shoulder * bins) - 2)]))
    tw = min(max(tw, H * 0.05), width[bmax] * 0.45)
    torso = band(crotch + 0.02, shoulder) & (np.abs(V[:, 0] - xc) < tw * 1.2)
    x0 = float(np.median(V[torso, 0])) if torso.sum() > 3 else xc
    z0 = float(np.median(V[torso, 2])) if torso.sum() > 3 else zc
    dx = V[:, 0] - x0
    w = tw
    hip_y = crotch + (shoulder - crotch) * 0.12
    print('autorig: crotch %.2f shoulder %.2f neck %.2f of the height, torso half-width %.1f%%' % (crotch, shoulder, neck, 100 * w / H))

    def at(x, yf, z=None):
        return np.array([x, y0 + yf * H, z0 if z is None else z])
    J = {}
    J['Hips'] = at(x0, hip_y)
    J['Spine'] = at(x0, hip_y + (shoulder - hip_y) * 0.35)
    J['Chest'] = at(x0, hip_y + (shoulder - hip_y) * 0.70)
    J['Neck'] = at(x0, neck)
    J['Head'] = at(x0, neck + (1 - neck) * 0.15)
    top = at(x0, 1.0)
    slab = H * 0.05
    for side, sgn in (('Left', 1), ('Right', -1)):
        on_side = dx * sgn > w * 0.9
        S = at(x0 + sgn * w * 0.95, shoulder - 0.02)
        cand = on_side & (Y > crotch * 0.8)
        if cand.sum() > 3:
            T = V[cand][np.argmax(np.linalg.norm(V[cand] - S, axis=1))]
        else:
            T = at(x0 + sgn * H * 0.45, shoulder)
        arm_dir = T - S
        J[side + 'Shoulder'] = at(x0 + sgn * w * 0.35, shoulder - 0.02)
        J[side + 'Arm'] = _centroid_near(V, S, slab * 1.5, on_side)
        J[side + 'ForeArm'] = _centroid_near(V, S + arm_dir * 0.48, slab, on_side)
        J[side + 'Hand'] = _centroid_near(V, S + arm_dir * 0.80, slab, on_side)
        J[side + 'HandTip'] = T
        leg = (dx * sgn > 0) & (Y < crotch + 0.02)
        hipj = at(x0 + sgn * w * 0.45, hip_y)
        low = leg & (Y < 0.08)
        ank = V[low].mean(0) if low.sum() > 3 else at(x0 + sgn * w * 0.5, 0.04)
        ank[1] = y0 + 0.05 * H
        J[side + 'UpLeg'] = hipj
        J[side + 'Leg'] = _centroid_near(V, (hipj + ank) / 2, slab, leg)
        J[side + 'Foot'] = ank
        feet = leg & (Y < 0.06)
        toe = V[feet][np.argmax(V[feet][:, 2])] if feet.sum() > 3 else ank + np.array([0, 0, H * 0.08])
        toe = np.array([toe[0], y0 + 0.02 * H, toe[2]])
        J[side + 'ToeBase'] = ank + (toe - ank) * 0.6
        J[side + 'ToeTip'] = toe
    parent = {'Hips': None, 'Spine': 'Hips', 'Chest': 'Spine', 'Neck': 'Chest', 'Head': 'Neck'}
    for side in ('Left', 'Right'):
        parent.update({side + 'Shoulder': 'Chest', side + 'Arm': side + 'Shoulder', side + 'ForeArm': side + 'Arm',
                       side + 'Hand': side + 'ForeArm', side + 'UpLeg': 'Hips', side + 'Leg': side + 'UpLeg',
                       side + 'Foot': side + 'Leg', side + 'ToeBase': side + 'Foot'})
    child = {'Hips': 'Spine', 'Spine': 'Chest', 'Chest': 'Neck', 'Neck': 'Head'}
    for side in ('Left', 'Right'):
        child.update({side + 'Shoulder': side + 'Arm', side + 'Arm': side + 'ForeArm', side + 'ForeArm': side + 'Hand',
                      side + 'UpLeg': side + 'Leg', side + 'Leg': side + 'Foot', side + 'Foot': side + 'ToeBase'})
    seg_end = {b: J[c] for b, c in child.items()}
    seg_end['Head'] = top
    for side in ('Left', 'Right'):
        seg_end[side + 'Hand'] = J[side + 'HandTip']
        seg_end[side + 'ToeBase'] = J[side + 'ToeTip']
    bones = list(parent)

    # region gate per bone: which vertices may follow it
    def gate(b, P):
        Yp = (P[:, 1] - y0) / H
        d = P[:, 0] - x0
        for side, sgn in (('Left', 1), ('Right', -1)):
            if b.startswith(side):
                if any(k in b for k in ('Arm', 'Hand')):
                    return (d * sgn > w * 0.8) & (Yp > crotch * 0.8)
                if 'Shoulder' in b:
                    return (d * sgn > w * 0.2) & (Yp > hip_y + (shoulder - hip_y) * 0.5)
                return (d * sgn > -w * 0.05) & (Yp < hip_y + 0.04)
        if b in ('Hips',):
            return Yp < hip_y + (shoulder - hip_y) * 0.4
        return Yp > crotch
    inv_turn = turn.T
    for pr in ch.prims:
        P = pr['pos'] @ turn.T
        n = len(P)
        D = np.full((n, len(bones)), np.inf)
        for k, b in enumerate(bones):
            g = gate(b, P)
            D[g, k] = _seg_dist(P[g], J[b], seg_end[b])
        D[np.isinf(D).all(1), bones.index('Hips')] = 1.0   # anything ungated follows the hips
        order = np.argsort(D, axis=1)[:, :3]
        jn, W = [], np.zeros((n, 4))
        for i in range(n):
            ds = D[i, order[i]]
            ok = np.isfinite(ds)
            ws = np.where(ok, 1.0 / (np.maximum(ds, H * 0.005) ** 4), 0)
            ws /= ws.sum()
            jn.append([bones[k] for k in order[i]] + [bones[order[i][0]]])
            W[i, :3] = ws
        pr['jn'] = jn
        pr['w'] = W
    ch.bones = bones
    ch.parent = parent
    for b in bones:
        M = np.eye(4)
        M[:3, 3] = inv_turn @ J[b]   # back into the mesh's own space; rebind turns everything itself
        ch.bind[b] = M
    ch.up_is_z = False
    if not np.allclose(turn, np.eye(3)):
        # keep mesh and skeleton in the same (turned) space for rebind
        for pr in ch.prims:
            pr['pos'] = pr['pos'] @ turn.T
        for b in bones:
            ch.bind[b][:3, 3] = J[b]
    return J
