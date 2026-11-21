"""Automatic rig for an unrigged humanoid mesh standing in a T- or A-pose, Mixamo style.

Like Mixamo's auto-rigger the skeleton is built from 8 markers placed on a front view of the character
(chin, groin, wrists, elbows, knees). The markers are guessed from the silhouette (rigprep writes them
with a front-view PNG so the user can drag them in the launcher's rig editor); with or without the
user's corrections the SAME builder turns markers into joints:
  * spine/neck along groin -> chin, head from the chin to the top of the mesh
  * shoulders from the torso edge and the upper-arm axis, kept inside the body
  * elbows / wrists / knees exactly at the markers, hand tip = farthest mesh point past the wrist,
    ankle / foot / toe found from the mesh below each knee
  * the depth (Z) of every joint from the mesh itself: a ray along Z through the marker, middle of the
    limb's thickness (the solid interval nearest to the parent joint when the ray also crosses the torso;
    entries and exits are paired by the surface winding, so a single-sided coat or skirt around a leg is
    not taken for the leg)
The guesses work for T- and A-poses; arms hanging close to the body (more than ~60 deg below horizontal)
or very unusual shapes need the markers checked in the editor - that is what it is for.
The body ("core") is the main part plus the parts touching it; props floating beside it, and a long prop
gripped in a hand (sticking out of the body's box), are left out of every measurement and of the view.
Weights: distance to each bone segment, gated by body region (arms beyond the shoulder plane, legs
below the hips on their own side), then Laplacian smoothing over the welded mesh (so UV seams and
primitive borders never split). Separate small parts (eyes, buttons, belt rings on their clasps) take
the weights of what they touch, solved over the chain of touching parts so linked pieces move together;
props away from the body move with the nearest bone.

Space used everywhere here ("turned" space): Y up, the character faces +Z, its LEFT is +X. The input
can be Y-up or Z-up and face either way: up axis and facing are detected (or forced by the user).
The bones get Mixamo names, which rebind.py understands, and rebind takes it onto the CoD4 skeleton.
"""
import json
import os

import numpy as np
from PIL import Image, ImageDraw

Z_UP = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)   # Z-up (front -Y) -> Y-up (front +Z)
TURN = np.diag([-1.0, 1.0, -1.0])                              # 180 deg about Y


def rot_y(deg):
    """rotation about Y (up) by deg, counter-clockwise seen from above"""
    r = np.radians(deg)
    c, s_ = np.cos(r), np.sin(r)
    return np.array([[c, 0, s_], [0, 1, 0], [-s_, 0, c]], float)


def clean_yaw(yaw):
    """0 / 90 / 180 / 270 (the rig editor's rotate buttons; anything else is snapped to 90)"""
    try:
        return int(round(float(yaw or 0) / 90.0)) % 4 * 90
    except (TypeError, ValueError):
        return 0
MARKERS = ('chin', 'groin', 'left_wrist', 'right_wrist', 'left_elbow', 'right_elbow', 'left_knee', 'right_knee')
SIDES = (('Left', 1), ('Right', -1))

PARENT = {'Hips': None, 'Spine': 'Hips', 'Chest': 'Spine', 'Neck': 'Chest', 'Head': 'Neck'}
for _s, _ in SIDES:
    PARENT.update({_s + 'Shoulder': 'Chest', _s + 'Arm': _s + 'Shoulder', _s + 'ForeArm': _s + 'Arm',
                   _s + 'Hand': _s + 'ForeArm', _s + 'UpLeg': 'Hips', _s + 'Leg': _s + 'UpLeg',
                   _s + 'Foot': _s + 'Leg', _s + 'ToeBase': _s + 'Foot'})
CHILD = {'Hips': 'Spine', 'Spine': 'Chest', 'Chest': 'Neck', 'Neck': 'Head', 'Head': 'HeadTop'}
for _s, _ in SIDES:
    CHILD.update({_s + 'Shoulder': _s + 'Arm', _s + 'Arm': _s + 'ForeArm', _s + 'ForeArm': _s + 'Hand',
                  _s + 'Hand': _s + 'HandTip', _s + 'UpLeg': _s + 'Leg', _s + 'Leg': _s + 'Foot',
                  _s + 'Foot': _s + 'ToeBase', _s + 'ToeBase': _s + 'ToeTip'})
BONES = list(PARENT)


def say(msg):
    print(msg, flush=True)


# ----------------------------------------------------------------------------------------------- mesh
def _gather(ch):
    Vs, Ts, off = [], [], 0
    for pr in ch.prims:
        Vs.append(np.asarray(pr['pos'], float))
        Ts.append(np.asarray(pr['tris'], int).reshape(-1, 3) + off)
        off += len(pr['pos'])
    return np.vstack(Vs), np.vstack(Ts)


def _weld(V, tol):
    """vertex -> welded node id (same position = same node, across primitives and UV seams)"""
    _, inv = np.unique(np.round(V / tol).astype(np.int64), axis=0, return_inverse=True)
    return inv.ravel()


def _edges(T):
    E = np.vstack([T[:, [0, 1]], T[:, [1, 2]], T[:, [2, 0]]])
    E = np.sort(E, 1)
    E = E[E[:, 0] != E[:, 1]]
    return np.unique(E, axis=0)


def _components(n, E):
    lab = np.arange(n)
    if not len(E):
        return lab
    # per node: the minimum over its edges, by one sort + reduceat (np.minimum.at is slow on big meshes)
    a, b = np.r_[E[:, 0], E[:, 1]], np.r_[E[:, 1], E[:, 0]]
    o = np.argsort(a, kind='stable')
    a, b = a[o], b[o]
    starts = np.r_[0, np.nonzero(np.diff(a))[0] + 1]
    owners = a[starts]
    while True:
        new = lab.copy()
        new[owners] = np.minimum(new[owners], np.minimum.reduceat(lab[b], starts))
        while True:
            nn = new[new]
            if np.array_equal(nn, new):
                break
            new = nn
        if np.array_equal(new, lab):
            return lab
        lab = new


def _code(k):
    """one int64 per integer grid cell (exact for +-2^20 cells per axis, plenty at ~1% of the height)"""
    k = np.clip(k + (1 << 20), 0, (1 << 21) - 1).astype(np.int64)
    return (k[:, 0] << 42) | (k[:, 1] << 21) | k[:, 2]


_OFFS = np.array([[a, b, c] for a in (-1, 0, 1) for b in (-1, 0, 1) for c in (-1, 0, 1)])


def _contact_pairs(NV, comp, used, cell):
    """(a, b) component pairs (a < b) with nodes closer than about one cell (separate parts that touch)"""
    key = np.floor(NV[used] / cell).astype(np.int64)
    cmp_ = comp[used].astype(np.int64)
    kc = _code(key)
    o = np.lexsort((cmp_, kc))                              # (cell, comp) table, sorted by cell
    kc, cmp_, key = kc[o], cmp_[o], key[o]
    keep = np.r_[True, (np.diff(kc) != 0) | (np.diff(cmp_) != 0)]
    kc, cmp_, key = kc[keep], cmp_[keep], key[keep]
    big = int(cmp_.max()) + 1 if len(cmp_) else 1
    pairs = []
    for off in _OFFS:
        nb = _code(key + off)
        lo = np.searchsorted(kc, nb, 'left')
        hi = np.searchsorted(kc, nb, 'right')
        has = hi > lo
        if not has.any():
            continue
        rep = hi[has] - lo[has]
        src = np.repeat(cmp_[has], rep)
        idx = np.repeat(lo[has], rep) + (np.arange(rep.sum()) - np.repeat(np.cumsum(rep) - rep, rep))
        dst = cmp_[idx]
        ok = src != dst
        pairs.append(np.unique(np.minimum(src[ok], dst[ok]) * big + np.maximum(src[ok], dst[ok])))
    pairs = [p for p in pairs if len(p)]
    if not pairs:
        return np.zeros((0, 2), np.int64)
    u = np.unique(np.concatenate(pairs))
    return np.c_[u // big, u % big]


def _groups(ids, pairs):
    """connected groups of the components ids through the contact pairs (only pairs inside ids)"""
    ids = list(ids)
    pos = {c: k for k, c in enumerate(ids)}
    lab = np.arange(len(ids))
    E = np.array([(pos[a], pos[b]) for a, b in pairs if a in pos and b in pos], int).reshape(-1, 2)
    lab = _components(len(ids), E)
    out = {}
    for c, l in zip(ids, lab):
        out.setdefault(int(l), []).append(c)
    return list(out.values())


def _samples(V, T, n=40000, seed=0):
    """points spread over the surface (low-poly meshes have too few vertices to measure with)"""
    A = V[T]
    area = np.linalg.norm(np.cross(A[:, 1] - A[:, 0], A[:, 2] - A[:, 0]), axis=1) / 2
    if area.sum() <= 0:
        return V
    rng = np.random.default_rng(seed)
    k = rng.choice(len(T), size=n, p=area / area.sum())
    r1, r2 = rng.random(n), rng.random(n)
    sq = np.sqrt(r1)
    P = A[k, 0] * (1 - sq)[:, None] + A[k, 1] * (sq * (1 - r2))[:, None] + A[k, 2] * (sq * r2)[:, None]
    return np.vstack([P, V[np.unique(T)]])


class Mesh:
    """the whole model in turned space + welded connectivity, components and the 'core' (body without
    loose props far from it, nor a weapon gripped in a hand)"""

    def __init__(self, ch, turn):
        V0, self.T = _gather(ch)
        self.V = V0 @ turn.T
        self.turn = turn
        used = np.zeros(len(self.V), bool)
        used[self.T.ravel()] = True
        lo, hi = self.V[used].min(0), self.V[used].max(0)
        diag = float(np.linalg.norm(hi - lo)) or 1.0
        self.node = _weld(self.V, diag * 2e-5)
        self.nn = int(self.node.max()) + 1
        self.E = _edges(self.node[self.T])
        self.comp = _components(self.nn, self.E)            # per node
        NV = np.zeros((self.nn, 3))
        NV[self.node] = self.V
        self.NV = NV
        self.used = np.zeros(self.nn, bool)                 # nodes some triangle uses (stray vertices are not)
        self.used[self.node[self.T.ravel()]] = True
        cid, cnt = np.unique(self.comp[self.used], return_counts=True)
        # the main part: the tallest of the big parts (a single-sided skirt can have more vertices than a
        # low-poly body)
        lo_c = np.full((len(cid), 3), np.inf)
        hi_c = np.full((len(cid), 3), -np.inf)
        ci = np.searchsorted(cid, self.comp[self.used])
        np.minimum.at(lo_c, ci, NV[self.used])
        np.maximum.at(hi_c, ci, NV[self.used])
        self._cbox = dict(zip(cid.tolist(), zip(lo_c, hi_c)))
        bigs = cnt >= 0.2 * cnt.max()
        big = cid[bigs][np.argmax((hi_c - lo_c)[bigs, 1])]
        mlo, mhi = self._cbox[big]
        mh = max(float(mhi[1] - mlo[1]), 1e-9)
        mcx = float(np.median(NV[(self.comp == big) & self.used, 0]))
        # parts that touch each other (rings hanging from clasps on a belt, the pieces of an axe)
        self.cell = mh * 0.008
        self.pairs = _contact_pairs(NV, self.comp, self.used, self.cell)
        self._key = np.floor(NV / self.cell).astype(np.int64)
        self._kc = _code(self._key)

        def touching(cs):
            return self.touching(np.isin(self.comp, list(cs)) & self.used)

        def held_prop(g, at):
            """a long group sticking out of the main part's box that touches the body (nodes at) far out to
            the side (a sword held up), or that reaches below the feet without hanging from its top end like
            a leg would (an axe held low, touching the hand or the shin)"""
            glo = np.min([self._cbox[c][0] for c in g], 0)
            ghi = np.max([self._cbox[c][1] for c in g], 0)
            if (ghi - glo).max() < 0.2 * mh:
                return False
            ct = at & np.isin(self.comp, g)
            if not ct.any():
                return False
            out = max(float((mlo - glo)[:2].max()), float((ghi - mhi)[:2].max()))
            below = float(mlo[1] - glo[1])
            lateral = abs(float(NV[ct, 0].mean()) - mcx) > 0.2 * mh
            hang = (float(NV[ct, 1].mean()) - glo[1]) / max(float(ghi[1] - glo[1]), 1e-12)
            return (out > 0.03 * mh and lateral) or (below > 0.03 * mh and hang < 0.75)
        # core = main part + parts touching it + groups of parts touching those (rings on clasps on a belt)
        # + other big parts (Draven's floating axes are not body) ... but not a prop gripped in a hand
        core_c = {big} | set(cid[cnt >= 0.3 * cnt.max()].tolist())
        self.props_held = 0
        at = touching({big})
        lvl1 = set(np.unique(self.comp[at]).tolist())
        for c in lvl1:
            if held_prop([c], at):
                self.props_held += 1
            else:
                core_c.add(c)
        rest = [c for c in cid.tolist() if c not in core_c and c not in lvl1]
        at = touching(core_c)
        for g in _groups(rest, self.pairs):
            if not (at & np.isin(self.comp, g)).any():
                continue                                # floating: a prop beside the body
            if held_prop(g, at):
                self.props_held += 1
            else:
                core_c |= set(g)
        self.main = big
        self.core_node = np.isin(self.comp, list(core_c)) & self.used
        self.core_tri = self.core_node[self.node[self.T[:, 0]]]
        CV = NV[self.core_node]
        self.y0 = float(CV[:, 1].min())     # floor and top from the body only (no stray vertex / shadow disc)
        self.top = float(CV[:, 1].max())
        self.H = (self.top - self.y0) or 1.0
        self.S = _samples(self.V, self.T[self.core_tri], 60000)
        self._set_tris(self.V[self.T[self.core_tri]])

    def touching(self, on):
        """nodes (not in the mask on) next to the nodes on: where separate parts touch them (rest pose,
        computed in the mesh as built; a turned copy keeps the same answer)"""
        occ = np.unique(np.concatenate([_code(self._key[on] + o) for o in _OFFS]))
        return np.isin(self._kc, occ) & self.used & ~on

    def _set_tris(self, tri):
        """core triangles + a coarse grid per axis to find the ones a ray along that axis can hit"""
        self._tri = tri
        n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        ctr = tri.reshape(-1, 3).mean(0)
        vol = float(np.einsum('ij,ij->i', tri[:, 0] - ctr, np.cross(tri[:, 1] - ctr, tri[:, 2] - ctr)).sum())
        self._n = n * (1.0 if vol >= 0 else -1.0)           # outward normals (as far as the winding says)
        self._lo, self._hi = tri.min(1), tri.max(1)
        self._grid = {}
        G = int(np.clip(np.sqrt(len(tri) / 3.0), 8, 160))
        for ax in range(3):
            i, j = [k for k in range(3) if k != ax]
            o = np.array([self._lo[:, i].min(), self._lo[:, j].min()])
            sz = np.maximum(np.array([self._hi[:, i].max(), self._hi[:, j].max()]) - o, 1e-12) / G
            a0 = np.clip(((np.c_[self._lo[:, i], self._lo[:, j]] - o) / sz).astype(int), 0, G - 1)
            a1 = np.clip(((np.c_[self._hi[:, i], self._hi[:, j]] - o) / sz).astype(int), 0, G - 1)
            span = a1 - a0 + 1
            bigt = (span[:, 0] > 8) | (span[:, 1] > 8)
            cells, tids = [], []
            for di in range(int(min(span[:, 0].max(), 8))):
                for dj in range(int(min(span[:, 1].max(), 8))):
                    s = ~bigt & (span[:, 0] > di) & (span[:, 1] > dj)
                    cells.append((a0[s, 0] + di) * G + a0[s, 1] + dj)
                    tids.append(np.nonzero(s)[0])
            cells = np.concatenate(cells) if cells else np.zeros(0, int)
            tids = np.concatenate(tids) if tids else np.zeros(0, int)
            order = np.argsort(cells, kind='stable')
            self._grid[ax] = (i, j, o, sz, G, cells[order], tids[order], np.nonzero(bigt)[0])

    def turned(self, R):
        """the same mesh rotated by R about the origin (Y stays up): no rebuild of the connectivity"""
        import copy
        m = copy.copy(self)
        m.V = self.V @ R.T
        m.NV = self.NV @ R.T
        m.S = self.S @ R.T
        m.turn = R @ self.turn
        m._set_tris(self._tri @ R.T)
        return m

    def hits(self, p, ax):
        """[(coord along ax, +1 entering / -1 leaving)] where the line through p along axis ax crosses the
        core surface, sorted"""
        i, j, o, sz, G, cells, tids, bigt = self._grid[ax]
        ci = int(np.clip((p[i] - o[0]) / sz[0], 0, G - 1))
        cj = int(np.clip((p[j] - o[1]) / sz[1], 0, G - 1))
        c = ci * G + cj
        a, b = np.searchsorted(cells, c), np.searchsorted(cells, c, 'right')
        cand = np.concatenate([tids[a:b], bigt])
        if not len(cand):
            return []
        lo, hi = self._lo[cand], self._hi[cand]
        cand = cand[(lo[:, i] <= p[i]) & (hi[:, i] >= p[i]) & (lo[:, j] <= p[j]) & (hi[:, j] >= p[j])]
        if not len(cand):
            return []
        t = self._tri[cand]
        A, B, C = t[:, 0], t[:, 1], t[:, 2]
        q = np.array([p[i], p[j]])
        v0 = np.c_[B[:, i] - A[:, i], B[:, j] - A[:, j]]
        v1 = np.c_[C[:, i] - A[:, i], C[:, j] - A[:, j]]
        v2 = q - np.c_[A[:, i], A[:, j]]
        d00, d01, d11 = (v0 * v0).sum(1), (v0 * v1).sum(1), (v1 * v1).sum(1)
        d20, d21 = (v2 * v0).sum(1), (v2 * v1).sum(1)
        den = d00 * d11 - d01 * d01
        ok = np.abs(den) > 1e-12 * d00 * d11            # relative: works in millimetres and in kilometres
        den = np.where(ok, den, 1)
        v = (d11 * d20 - d01 * d21) / den
        w = (d00 * d21 - d01 * d20) / den
        u = 1 - v - w
        hit = ok & (u >= -1e-7) & (v >= -1e-7) & (w >= -1e-7)
        if not hit.any():
            return []
        z = (u * A[:, ax] + v * B[:, ax] + w * C[:, ax])[hit]
        s = np.where(self._n[cand[hit], ax] < 0, 1, -1)
        o_ = np.argsort(z)
        out = []
        for zz, ss in zip(z[o_], s[o_]):
            if out and out[-1][1] == ss and zz - out[-1][0] <= self.H * 1e-4:
                continue                                # a ray through a shared edge hits twice
            out.append((float(zz), int(ss)))
        return out

    def inside(self, p):
        """is p inside the body: rays in the 6 axis directions must (nearly) all leave a surface more often
        than they enter one (a single-sided coat or skirt is open at its hem, so the ray down escapes)"""
        votes = 0
        for ax in range(3):
            hs = self.hits(p, ax)
            fwd = sum(-s for z, s in hs if z > p[ax])
            bwd = sum(s for z, s in hs if z < p[ax])
            votes += (fwd > 0) + (bwd > 0)
        return votes >= 5

    # --- rays along Z through (x, y): solid intervals of the core mesh
    def intervals(self, x, y):
        """(z_in, z_out) pieces of solid along Z: each entry paired with the nearest exit after it, and a
        piece that only encloses others (a single-sided coat around a leg) dropped for the inner ones"""
        hs = self.hits((x, y, 0.0), 2)
        if not hs:
            return []
        if len(hs) == 1:
            return [(hs[0][0], hs[0][0])]
        ivs, stack = [], []
        for z, s in hs:
            if s > 0:
                stack.append(z)
            elif stack:
                ivs.append((stack.pop(), z))
        if not ivs:                                     # winding makes no sense: pair them in order
            z = [h[0] for h in hs]
            return [(z[i], z[i + 1]) for i in range(0, len(z) - 1, 2)]
        ivs.sort()
        # an armour plate sunk into the thigh is nested too, but it is thin next to the body around it
        return [a for a in ivs if not any(b != a and a[0] <= b[0] and b[1] <= a[1] and b[1] - b[0] >= 0.25 * (a[1] - a[0])
                                          for b in ivs)]

    def depth(self, x, y, ref=None, r=None):
        """Z in the middle of the limb/torso under (x, y): the interval nearest to ref (the parent joint's
        depth), else the thickest; rays around the point if the exact one misses"""
        r = r or self.H * 0.015
        ivs = self.intervals(x, y)
        if not ivs:
            for rad in (r * 0.5, r, r * 2, r * 4):
                for a in np.linspace(0, 2 * np.pi, 8, endpoint=False):
                    ivs += self.intervals(x + rad * np.cos(a), y + rad * np.sin(a))
                if ivs:
                    break
        if not ivs:
            return float(np.median(self.S[:, 2])) if ref is None else ref
        mids = np.array([(a + b) / 2 for a, b in ivs])
        if ref is None:
            th = np.array([b - a for a, b in ivs])
            return float(mids[np.argmax(th)])
        return float(mids[np.argmin(np.abs(mids - ref))])


class Silhouette:
    """front-view occupancy grid of the core mesh (row 0 = top)"""

    def __init__(self, m, res=400):
        self.cell = m.H / res
        tri = m._tri
        self.xmin = float(tri[:, :, 0].min()) - 2 * self.cell
        self.ytop = m.top + 2 * self.cell
        w = int((tri[:, :, 0].max() - self.xmin) / self.cell) + 3
        h = int((self.ytop - m.y0) / self.cell) + 3
        img = Image.new('L', (w, h), 0)
        d = ImageDraw.Draw(img)
        px = (tri[:, :, 0] - self.xmin) / self.cell
        py = (self.ytop - tri[:, :, 1]) / self.cell
        for k in range(len(tri)):
            d.polygon([(px[k, 0], py[k, 0]), (px[k, 1], py[k, 1]), (px[k, 2], py[k, 2])], fill=255)
        self.M = np.array(img) > 0
        self.h, self.w = self.M.shape

    def row(self, y):
        return int(np.clip((self.ytop - y) / self.cell, 0, self.h - 1))

    def col(self, x):
        return int(np.clip((x - self.xmin) / self.cell, 0, self.w - 1))

    def y(self, r):
        return self.ytop - (r + 0.5) * self.cell

    def x(self, c):
        return self.xmin + (c + 0.5) * self.cell

    def run(self, r, c):
        """(left, right) columns of the filled run through column c of row r, or None"""
        line = self.M[r]
        if not line[c]:
            return None
        L = c
        while L > 0 and line[L - 1]:
            L -= 1
        R = c
        while R + 1 < self.w and line[R + 1]:
            R += 1
        return L, R

    def vrun(self, c, r):
        """(top, bottom) rows of the filled run through row r of column c, or None"""
        line = self.M[:, c]
        if not line[r]:
            return None
        a = r
        while a > 0 and line[a - 1]:
            a -= 1
        b = r
        while b + 1 < self.h and line[b + 1]:
            b += 1
        return a, b


# ----------------------------------------------------------------------------------------- orientation
def detect_up(ch):
    """the up axis is the longer of Y and Z (a body is never deeper than it is tall; X is left/right)"""
    V, _ = _gather(ch)
    ext = np.ptp(V, 0)
    return 'z' if ext[2] > ext[1] else 'y'


def facing_score(m):
    """> 0 when the character faces +Z: the feet stick out in front of the shins far more than the heels
    behind them (normalised by the height). Head shapes were tried too but are unreliable (skull, hair,
    caps stick out at the back as much as noses and brims at the front)."""
    S, y0, H = m.S, m.y0, m.H
    Y = (S[:, 1] - y0) / H
    xc = float(np.median(S[Y < 0.3, 0])) if (Y < 0.3).sum() > 10 else float(np.median(S[:, 0]))
    feet = 0.0
    n = 0
    for sgn in (1, -1):
        side = (S[:, 0] - xc) * sgn > 0
        low = side & (Y < 0.035)
        shin = side & (Y > 0.10) & (Y < 0.22)
        if low.sum() < 10 or shin.sum() < 10:
            continue
        zl, zs = S[low, 2], S[shin, 2]
        lo_mid = (np.percentile(zl, 98) + np.percentile(zl, 2)) / 2
        # the shin's middle by rays through the solid leg: a single-sided coat / robe hanging around the
        # shins is not leg (its samples would move the middle)
        mids = []
        for f in (0.12, 0.16, 0.20):
            y = y0 + f * H
            sp = _leg_span(m, xc, y, sgn)
            if sp:
                x = (sp[0] + sp[1]) / 2
                ivs = [iv for iv in m.intervals(x, y) if iv[1] - iv[0] > 0.02 * H and m.inside((x, y, (iv[0] + iv[1]) / 2))]
                if ivs:
                    a, b = max(ivs, key=lambda iv: iv[1] - iv[0])
                    mids.append((a + b) / 2)
        if mids:
            sh_mid = float(np.median(mids))
        else:
            sh_mid = (np.percentile(zs, 98) + np.percentile(zs, 2)) / 2
        feet += (lo_mid - sh_mid) / H
        n += 1
    feet = feet / n if n else 0.0
    return feet


def orientation(ch, up='auto', flip='auto', yaw=0):
    """-> (mesh in turned space, up 'y'|'z', flip bool, flip_auto bool, score). flip_auto = the facing the
    detector picks (the launcher shows "set by you" when flip differs from it)"""
    up = (up or 'auto').lower()
    if up not in ('y', 'z'):
        up = detect_up(ch)
    base = Z_UP if up == 'z' else np.eye(3)
    m = Mesh(ch, base)
    feet = facing_score(m)
    auto = feet < -0.004        # no clear feet: keep the glTF convention (facing +Z)
    if flip in (True, 1, '1', 'true', 'yes'):
        f = True
    elif flip in (False, 0, '0', 'false', 'no'):
        f = False
    else:
        f = auto
    if f:
        m = m.turned(TURN)      # same mesh, turned 180 deg about Y (no second build)
    yaw = clean_yaw(yaw)
    if yaw:
        m = m.turned(rot_y(yaw))  # the user's quarter turns (a model facing sideways)
    return m, up, f, auto, feet


# ----------------------------------------------------------------------------------------- auto markers
def _solid(m, x, y, th):
    """does a ray along Z at (x, y) cross solid body thicker than th (a cloth panel is thinner, and a
    single-sided coat / skirt only encloses air: its middle is not inside)"""
    return any(b - a > th and m.inside((x, y, (a + b) / 2)) for a, b in m.intervals(x, y))


def _crotch(m, x0):
    """top of the gap between the legs on the centre line, by rays along Z: a loincloth / tabard / coat
    panel in front of the crotch is thin, so it does not close the gap"""
    H, y0 = m.H, m.y0
    th = 0.03 * H
    nb = 100
    gap = np.zeros(nb, bool)
    for b in range(int(nb * 0.75)):
        y = y0 + (b + 0.5) / nb * H
        gap[b] = not _solid(m, x0, y, th)
    best, cur = None, []
    for b in range(int(nb * 0.75) + 1):
        if b < int(nb * 0.75) and gap[b]:
            cur.append(b)
        else:
            if cur and cur[0] <= nb * 0.25 and (best is None or len(cur) > len(best)):
                best = cur
            cur = []
    if best and len(best) >= 8:
        return y0 + (best[-1] + 1) / nb * H
    return None


def _leg_span(m, x0, y, sgn):
    """(inner, outer) x of the solid leg on one side at height y (rays, so cloth panels do not count)"""
    H = m.H
    th = 0.03 * H
    inner = None
    for k in range(0, 80):
        x = x0 + sgn * k * 0.004 * H
        s = _solid(m, x, y, th)
        if inner is None and s:
            inner = x
        elif inner is not None and not s:
            return inner, x
    return None


def _leg_gap(m, x0, y):
    """x of the inner edges of the two legs at height y (rays), or None"""
    H = m.H
    th = 0.03 * H
    edges = []
    for sgn in (1, -1):
        e = None
        for k in range(1, 60):
            x = x0 + sgn * k * 0.004 * H
            if _solid(m, x, y, th):
                e = x
                break
        edges.append(e)
    return None if None in edges else edges


def _leg_slice(m, sgn, x0, ylo, yhi, xc=None, xw=None):
    S = m.S
    sel = ((S[:, 0] - x0) * sgn > 0) & (S[:, 1] >= ylo) & (S[:, 1] < yhi)
    if xc is not None:
        sel &= np.abs(S[:, 0] - xc) < xw
    return S[sel]


def _ankle(m, sgn, x0, ytop, xc=None, xw=None):
    """height of the ankle below ytop (the knee or crotch): top of the band near the floor where the foot
    makes the leg much deeper (front-back) than the shin"""
    H, y0 = m.H, m.y0
    nb = 40
    ext = np.full(nb, np.nan)
    for b in range(nb):
        lo = y0 + (ytop - y0) * b / nb
        P = _leg_slice(m, sgn, x0, lo, lo + (ytop - y0) / nb, xc, xw)
        if len(P) > 8:
            ext[b] = np.percentile(P[:, 2], 98) - np.percentile(P[:, 2], 2)
    shin = np.nanmedian(ext[int(nb * 0.3):int(nb * 0.7)]) if np.isfinite(ext[int(nb * 0.3):int(nb * 0.7)]).any() else np.nan
    top_b = None
    if np.isfinite(shin):
        for b in range(nb // 2):
            if np.isfinite(ext[b]) and ext[b] > shin * 1.35:
                top_b = b
            elif top_b is not None or b > 2:
                break
    if top_b is None:
        return y0 + 0.05 * H
    y = y0 + (ytop - y0) * (top_b + 1) / nb
    return float(np.clip(y, y0 + 0.025 * H, y0 + 0.16 * H))


def _knee(m, sgn, x0, ank, crotch):
    """knee height from the leg's own shape: the narrow part between a wide thigh above and a wider calf /
    boot top below (front width + depth). None when the leg is a plain tube (no signal)"""
    S = m.S
    nb = 40
    L = crotch - ank
    if L <= 0:
        return None
    sz = np.full(nb, np.nan)
    for b in range(nb):
        P = _leg_slice(m, sgn, x0, ank + L * b / nb, ank + L * (b + 1) / nb)
        if len(P) > 8:
            sz[b] = (np.percentile(P[:, 0], 98) - np.percentile(P[:, 0], 2)) + (np.percentile(P[:, 2], 98) - np.percentile(P[:, 2], 2))
    sm = np.array([np.nanmean(sz[max(0, b - 1):b + 2]) if np.isfinite(sz[max(0, b - 1):b + 2]).any() else np.nan for b in range(nb)])
    lo, hi = int(nb * 0.35), int(nb * 0.8)
    if not np.isfinite(sm[lo:hi]).any():
        return None
    k = lo + int(np.nanargmin(sm[lo:hi]))
    mn = sm[k]
    above = sm[k + 1:int(nb * 0.95)]
    below = sm[int(nb * 0.15):k]
    if not (np.isfinite(above).any() and np.isfinite(below).any()):
        return None
    if np.nanmax(above) < 1.25 * mn or np.nanmax(below) < 1.12 * mn:
        return None
    a = b = k
    while a - 1 >= lo and np.isfinite(sm[a - 1]) and sm[a - 1] <= 1.15 * mn:
        a -= 1
    while b + 1 < hi and np.isfinite(sm[b + 1]) and sm[b + 1] <= 1.15 * mn:
        b += 1
    t = float(np.clip(((a + b) / 2 + 0.5) / nb, 0.4, 0.75))
    return ank + L * t


def auto_markers(m, sil=None, verbose=True):
    """guess the 8 markers (turned space X, Y) from the silhouette and the surface samples"""
    sil = sil or Silhouette(m)
    S, H, y0 = m.S, m.H, m.y0
    x0 = float(np.median(S[:, 0]))
    j0 = sil.col(x0)
    crotch = _crotch(m, x0)
    if crotch is not None:
        # centre = between the two legs just below the crotch
        g = _leg_gap(m, x0, crotch - 0.04 * H)
        if g:
            x0 = (g[0] + g[1]) / 2
    else:
        crotch = y0 + 0.45 * H
    j0 = sil.col(x0)
    # torso edges: from the row where the run through the centre reaches furthest out (the arms), going
    # down, the armpit is where the edge falls back onto the torso
    rows = list(range(sil.row(crotch + 0.03 * H), sil.row(y0 + 0.97 * H), -1))[::-1]   # top -> down
    armpit = {}
    e_t = {}
    for sgn in (1, -1):
        es = []
        for r in rows:
            rr = sil.run(r, j0)
            es.append(np.nan if rr is None else ((sil.x(rr[1]) - x0) if sgn > 0 else (x0 - sil.x(rr[0]))))
        es = np.array(es)
        if np.isfinite(es).any():
            k = int(np.nanargmax(es))
            for i in range(k + 1, len(rows)):
                if np.isfinite(es[i]) and np.isfinite(es[i - 1]) and es[i - 1] - es[i] > 0.03 * H and es[i] < 0.6 * es[k]:
                    armpit[sgn] = sil.y(rows[i - 1])
                    below = es[i:i + max(2, int(0.06 * H / sil.cell))]
                    e_t[sgn] = float(np.nanmedian(below)) if np.isfinite(below).any() else float(es[i])
                    break
        if sgn not in armpit:
            armpit[sgn] = crotch + 0.55 * (m.top - crotch)
            e_t[sgn] = float(np.nanmedian(es)) if np.isfinite(es).any() else 0.1 * H
    apit = float(np.mean(list(armpit.values())))
    # chin: going down from the top of the head, the head first gets wider; the chin is where it then
    # either narrows into the neck (at the narrowest point) or bursts out into shoulders / collar
    chin = None
    wmax, narrow = 0.0, None
    y = m.top - 0.005 * H
    while y > apit:
        ws = []
        for yy in (y - 0.004 * H, y, y + 0.004 * H):
            rr = sil.run(sil.row(yy), j0)
            ws.append((rr[1] - rr[0] + 1) * sil.cell if rr else 0.0)
        w = float(np.median(ws))
        started = wmax >= 0.04 * H and y < m.top - 0.05 * H
        if narrow is not None:
            if w < narrow[1]:
                narrow = (y, w)
            elif w > narrow[1] * 1.3 or w > wmax:
                chin = narrow[0]
                break
        elif started and w > 1.6 * wmax:
            chin = y + 0.01 * H
            break
        elif started and w < 0.8 * wmax:
            narrow = (y, w)
        wmax = max(wmax, w) if narrow is None else wmax
        y -= 0.005 * H
    if chin is None:
        chin = narrow[0] if narrow else apit + 0.45 * (m.top - apit)
    mk = {'chin': (x0, chin), 'groin': (x0, crotch)}
    # arms: tip = the most lateral core point above the crotch; profile along shoulder -> tip
    for side, sgn in SIDES:
        s = side.lower()
        xe = x0 + sgn * e_t[sgn]
        ce = sil.col(xe + sgn * sil.cell)
        ra = sil.row(armpit[sgn] + sil.cell)
        vr = sil.vrun(ce, ra) or sil.vrun(ce, min(sil.h - 1, ra + 2))
        ys = (armpit[sgn] + min(sil.y(vr[0]), armpit[sgn] + 0.12 * H)) / 2 if vr else armpit[sgn] + 0.03 * H
        S0 = np.array([xe, ys])
        cand = S[((S[:, 0] - xe) * sgn > 0) & (S[:, 1] > crotch)]
        if len(cand) < 20:
            tip = S0 + np.array([sgn * 0.3 * H, 0])
        else:
            tip = cand[np.argmax(cand[:, 0] * sgn), :2]
        d = tip - S0
        L = float(np.linalg.norm(d)) or 1.0
        d /= L
        nrm = np.array([-d[1], d[0]])
        P = cand if len(cand) else S[:1]
        t = ((P[:, :2] - S0) @ d) / L
        u = (P[:, :2] - S0) @ nrm
        near = (t > -0.05) & (t < 1.02) & (np.abs(u) < 0.4 * L)
        P, t, u = P[near], t[near], u[near]
        nb = 40
        size = np.full(nb, np.nan)
        cen = np.zeros(nb)
        for b in range(nb):
            sel = (t >= b / nb) & (t < (b + 1) / nb)
            if sel.sum() > 6:
                uu = u[sel]
                zz = P[sel, 2]
                size[b] = max(np.ptp(uu), np.percentile(zz, 98) - np.percentile(zz, 2))
                cen[b] = (uu.max() + uu.min()) / 2
        # wrist: going out along the arm, the first place where the limb gets clearly thicker than the
        # thinnest part so far (hand / glove / cuff); a normal-proportion guess if there is none
        tw = 0.72
        lo = np.inf
        for b in range(int(nb * 0.2), int(nb * 0.92)):
            if not np.isfinite(size[b]):
                continue
            lo = min(lo, size[b])
            ahead = size[b + 1:b + 4]
            ahead = ahead[np.isfinite(ahead)]
            if b >= int(nb * 0.3) and len(ahead) >= 2 and np.median(ahead) > lo * 1.25 and np.min(ahead) > lo * 1.1:
                tw = (b + 1) / nb
                break
        te = tw * 0.53

        def at(tt):
            b = int(np.clip(tt * nb, 0, nb - 1))
            return S0 + d * tt * L + nrm * (cen[b] if np.isfinite(size[b]) else 0)
        mk[s + '_wrist'] = tuple(at(tw))
        mk[s + '_elbow'] = tuple(at(te))
        # legs
        ank = _ankle(m, sgn, x0, crotch)
        ky = _knee(m, sgn, x0, ank, crotch)
        if ky is None:
            ky = ank + 0.53 * (crotch - ank)        # a plain tube of a leg: the usual proportion
        P = _leg_slice(m, sgn, x0, ky - 0.02 * H, ky + 0.02 * H)
        kx = (P[:, 0].max() + P[:, 0].min()) / 2 if len(P) > 5 else x0 + sgn * 0.08 * H
        mk[s + '_knee'] = (float(kx), float(ky))
        if verbose:
            say('autorig: %s armpit %.2f, torso half-width %.1f%%, arm tip %.1f%% out' %
                (s, (armpit[sgn] - y0) / H, 100 * e_t[sgn] / H, 100 * abs(tip[0] - x0) / H))
    if verbose:
        say('autorig: groin %.2f, chin %.2f of the height' % ((crotch - y0) / H, (chin - y0) / H))
    return {k: (float(v[0]), float(v[1])) for k, v in mk.items()}


# ------------------------------------------------------------------------------------ skeleton builder
def build_skeleton(m, mk, sil=None):
    """markers (turned-space X, Y) -> joint positions J (turned space)"""
    sil = sil or Silhouette(m)
    mk = fix_sides(mk)
    H, y0 = m.H, m.y0
    S = m.S
    chin = np.array(mk['chin'], float)
    groin = np.array(mk['groin'], float)
    x0 = float(groin[0])
    up = chin - groin
    tl = float(np.linalg.norm(up)) or H * 0.4
    J = {}

    def spine_at(f, ref):
        p = groin + up * f
        return np.array([p[0], p[1], m.depth(p[0], p[1], ref)])
    J['Hips'] = spine_at(0.22, None)
    J['Spine'] = spine_at(0.40, J['Hips'][2])
    J['Chest'] = spine_at(0.62, J['Spine'][2])
    # head depth from the head itself (above the chin, clear of collars), the neck between chest and head
    hz = m.depth(chin[0], chin[1] + 0.2 * max(m.top - chin[1], 0.05 * H), J['Chest'][2])
    J['Neck'] = spine_at(0.84, J['Chest'][2])
    J['Neck'][2] = (J['Chest'][2] + hz) / 2
    J['Head'] = np.array([chin[0], chin[1], hz])
    J['HeadTop'] = np.array([chin[0], max(m.top, chin[1] + 0.05 * H), hz])
    # torso half-width under the armpits, from the silhouette (the run through the centre line)
    j0 = sil.col(x0)
    for side, sgn in SIDES:
        s = side.lower()
        el = np.array(mk[s + '_elbow'], float)
        wr = np.array(mk[s + '_wrist'], float)
        # torso edge: widest run through the centre between the Spine and Chest heights, never past
        # 85% of the way to the elbow
        es = []
        for r in range(sil.row(J['Spine'][1]), sil.row(J['Chest'][1]) - 1, -1):
            rr = sil.run(r, j0)
            if rr:
                es.append((sil.x(rr[1]) - x0) if sgn > 0 else (x0 - sil.x(rr[0])))
        et = float(np.median(es)) if es else 0.12 * H
        lim = abs(el[0] - x0) * 0.85
        if et > lim or et < 0.03 * H:
            et = min(max(et, 0.03 * H), lim) if lim > 0.03 * H else lim
        xs = x0 + sgn * et
        # shoulder height: the usual height under the chin, corrected a little by the upper-arm axis seen
        # in the silhouette (the arm's centre in a few columns towards the elbow, a line through them up to
        # the shoulder column). The elbow marker only says where to look, so moving it barely moves the
        # shoulder
        ydef = chin[1] - 0.2 * tl
        ys = ydef
        if abs(el[0] - xs) > 0.04 * H:
            pts = []
            for f in (0.5, 0.6, 0.7, 0.8, 0.9):
                xm = xs + (el[0] - xs) * f
                yg = ydef + (el[1] - ydef) * f
                c = sil.col(xm)
                rows = np.nonzero(sil.M[:, c])[0]
                if len(rows):
                    r0 = rows[np.argmin(np.abs(rows - sil.row(yg)))]
                    a, b = sil.vrun(c, r0)
                    if (b - a) * sil.cell < 0.3 * H:        # not merged with the torso
                        pts.append((xm, (sil.y(a) + sil.y(b)) / 2))
            if len(pts) >= 3:
                P = np.array(pts)
                k, q = np.polyfit(P[:, 0], P[:, 1], 1)
                ys = k * xs + q
        ys = float(np.clip(ys, ydef - 0.05 * tl, ydef + 0.05 * tl))
        ys = float(np.clip(ys, chin[1] - 0.45 * tl, chin[1] - 0.06 * tl))
        # keep it inside the body: below the top of the silhouette at that column
        c = sil.col(xs)
        rows = np.nonzero(sil.M[:, c])[0]
        if len(rows):
            r0 = rows[np.argmin(np.abs(rows - sil.row(ys)))]
            a, b = sil.vrun(c, r0)
            ya, yb = sil.y(a), sil.y(b)
            mg = min(0.25 * (ya - yb), 0.03 * H)
            ys = float(np.clip(ys, yb + mg, ya - mg))
        chest_z = J['Chest'][2]
        az = m.depth(xs, ys, chest_z)
        J[side + 'Arm'] = np.array([xs, ys, az])
        J[side + 'Shoulder'] = np.array([x0 + sgn * 0.22 * et, ys + 0.01 * H, (chest_z + az) / 2])
        ez = m.depth(el[0], el[1], az)
        J[side + 'ForeArm'] = np.array([el[0], el[1], ez])
        wz = m.depth(wr[0], wr[1], ez)
        J[side + 'Hand'] = np.array([wr[0], wr[1], wz])
        # hand tip: farthest core point past the wrist, not too far off the forearm line
        dirv = J[side + 'Hand'] - J[side + 'ForeArm']
        dl = float(np.linalg.norm(dirv)) or 1.0
        dirv /= dl
        rel = S - J[side + 'Hand']
        along = rel @ dirv
        lat = np.linalg.norm(rel - along[:, None] * dirv, axis=1)
        ok = (along > 0) & (lat < max(0.6 * dl, 0.12 * H)) & ((S[:, 0] - x0) * sgn > et * 0.5)
        if ok.sum() > 3:
            far = along[ok].max()
            tipp = S[ok][along[ok] > far * 0.85].mean(0)
            J[side + 'HandTip'] = J[side + 'Hand'] + dirv * far + (tipp - (J[side + 'Hand'] + dirv * (tipp - J[side + 'Hand']) @ dirv)) * 0.5
        else:
            J[side + 'HandTip'] = J[side + 'Hand'] + dirv * 0.08 * H
        # legs
        kn = np.array(mk[s + '_knee'], float)
        kz = None
        uy = groin[1] + 0.75 * (J['Hips'][1] - groin[1])
        # thigh centre just below the groin: the first filled run out from the centre line on that side
        ux = (x0 + kn[0]) / 2
        sp = _leg_span(m, x0, groin[1] - 0.04 * H, sgn)
        if sp:
            ux = (sp[0] + sp[1]) / 2
        ux = x0 + sgn * float(np.clip(abs(ux - x0), 0.25 * abs(kn[0] - x0), 1.5 * abs(kn[0] - x0) + 0.01 * H))
        uz = m.depth(ux, uy, J['Hips'][2])
        J[side + 'UpLeg'] = np.array([ux, uy, uz])
        kz = m.depth(kn[0], kn[1], uz)
        J[side + 'Leg'] = np.array([kn[0], kn[1], kz])
        xw = max(0.12 * H, abs(kn[0] - x0))
        ay = _ankle(m, sgn, x0, kn[1], kn[0], xw)
        P = _leg_slice(m, sgn, x0, ay - 0.015 * H, ay + 0.015 * H, kn[0], xw)
        ax = (P[:, 0].max() + P[:, 0].min()) / 2 if len(P) > 5 else kn[0]
        az_ = m.depth(ax, ay, kz)
        J[side + 'Foot'] = np.array([ax, ay, az_])
        P = _leg_slice(m, sgn, x0, y0 - 1, ay, kn[0], xw)
        if len(P) > 5:
            toe = P[np.argmax(P[:, 2])]
            toe = np.array([toe[0], y0 + 0.25 * (ay - y0), toe[2]])
        else:
            toe = J[side + 'Foot'] + np.array([0, -(ay - y0) * 0.7, 0.08 * H])
        J[side + 'ToeTip'] = toe
        J[side + 'ToeBase'] = np.array([ax + 0.6 * (toe[0] - ax), y0 + 0.35 * (ay - y0), az_ + 0.62 * (toe[2] - az_)])
    return J


# ---------------------------------------------------------------------------------------------- weights
def _seg_dist(P, a, b):
    ab = b - a
    t = np.clip(((P - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)


def _ramp(s, a, b):
    """0 below a, 1 above b, smooth in between"""
    t = np.clip((s - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def gates(P, J, H, head_hw):
    """bone -> soft mask 0..1 of the points that may follow it (region by region, soft at the borders so
    the weights never jump between neighbouring vertices)"""
    x0 = J['Hips'][0]
    X, Y = P[:, 0], P[:, 1]
    ax = np.abs(X - x0)
    g = {}
    torso_x = max(abs(J['LeftArm'][0] - x0), abs(J['RightArm'][0] - x0)) + 0.03 * H
    torso = _ramp(torso_x - ax, 0, 0.05 * H)
    # the head (from the chin up, as wide as the head) belongs to the head only, even when it is wider
    # than the shoulders
    head = _ramp(Y, J['Head'][1] - 0.04 * H, J['Head'][1] + 0.01 * H) * _ramp(head_hw * 1.15 + 0.02 * H - ax, 0, 0.04 * H)
    g['Head'] = head
    g['Neck'] = torso * _ramp(Y, J['Chest'][1], J['Chest'][1] + 0.03 * H)
    g['Chest'] = torso * _ramp(Y, J['Spine'][1] - 0.06 * H, J['Spine'][1] - 0.02 * H)
    g['Spine'] = torso * _ramp(Y, J['Hips'][1] - 0.06 * H, J['Hips'][1] - 0.02 * H) * _ramp(J['Neck'][1] + 0.06 * H - Y, 0, 0.04 * H)
    g['Hips'] = torso * _ramp(J['Chest'][1] - Y, 0, 0.04 * H)
    for side, sgn in SIDES:
        d = (X - x0) * sgn
        aw = abs(J[side + 'Arm'][0] - x0)
        # beyond the plane at the shoulder; the soft band reaches into the torso only around the shoulder
        # itself, under the armpit the torso side stays with the spine
        inner = 0.01 * H + 0.05 * H * _ramp(Y, J[side + 'Arm'][1] - 0.08 * H, J[side + 'Arm'][1])
        arm = _ramp((X - J[side + 'Arm'][0]) * sgn + inner, 0, inner) * (1 - head)
        g[side + 'Arm'] = arm
        g[side + 'ForeArm'] = arm
        g[side + 'Hand'] = arm
        g[side + 'Shoulder'] = _ramp(d, 0.05 * aw, 0.3 * aw) * _ramp(Y, J['Spine'][1], J['Chest'][1]) * (1 - head)
        leg = _ramp(d, -0.015 * H, 0.0) * _ramp(J['Hips'][1] + 0.04 * H - Y, 0, 0.05 * H)
        g[side + 'UpLeg'] = leg
        mid = (J[side + 'UpLeg'][1] + J[side + 'Leg'][1]) / 2
        g[side + 'Leg'] = leg * _ramp(mid - Y, 0, 0.04 * H)
        mid = (J[side + 'Leg'][1] + J[side + 'Foot'][1]) / 2
        g[side + 'Foot'] = g[side + 'Leg'] * _ramp(mid - Y, 0, 0.03 * H)
        g[side + 'ToeBase'] = g[side + 'Foot']
    return g


def skin_weights(m, J, iters=None):
    """(nodes x bones) weights on the welded mesh"""
    P = m.NV
    H = m.H
    nb = len(BONES)
    S = m.S
    x0 = J['Hips'][0]
    up = S[:, 1] > J['Head'][1] + 0.3 * (J['HeadTop'][1] - J['Head'][1])
    head_hw = float(np.percentile(np.abs(S[up, 0] - x0), 98)) if up.sum() > 10 else 0.1 * H
    G = gates(P, J, H, head_hw)
    D = np.full((m.nn, nb), np.inf)
    soft = np.zeros((m.nn, nb))
    for k, b in enumerate(BONES):
        soft[:, k] = G[b]
        sel = G[b] > 0
        D[sel, k] = _seg_dist(P[sel], J[b], J[CHILD[b]])
    gate = soft > 0
    # a point both an arm and a leg may take (a hand hanging by the thigh) goes to the nearer limb only
    for side, _ in SIDES:
        ia = [BONES.index(side + b) for b in ('Arm', 'ForeArm', 'Hand')]
        il = [BONES.index(side + b) for b in ('UpLeg', 'Leg', 'Foot', 'ToeBase')]
        both = gate[:, ia].any(1) & gate[:, il].any(1)
        if both.any():
            da, dl = D[both][:, ia].min(1), D[both][:, il].min(1)
            rows = np.nonzero(both)[0]
            for cols, lose in ((ia, da > dl), (il, dl >= da)):
                r = rows[lose]
                gate[np.ix_(r, cols)] = False
                soft[np.ix_(r, cols)] = 0
                D[np.ix_(r, cols)] = np.inf
    none = ~gate.any(1)
    hi = BONES.index('Hips')
    gate[none, hi] = True
    soft[none, hi] = 1
    D[none, hi] = 1.0
    W = soft / np.maximum(D, H * 0.004) ** 4
    W /= W.sum(1, keepdims=True)
    # Laplacian smoothing over the welded connectivity, radius ~ 2.5% of the height
    E = m.E
    if len(E):
        el = np.linalg.norm(P[E[:, 0]] - P[E[:, 1]], axis=1)
        e = float(np.median(el)) or H * 0.01
        if iters is None:
            iters = int(np.clip((0.025 * H / e) ** 2, 2, 40))
        deg = np.bincount(E.ravel(), minlength=m.nn).astype(float)
        has = deg > 0
        # neighbour sums by sorted edge lists + reduceat (np.add.at is very slow on big meshes)
        src = np.r_[E[:, 1], E[:, 0]]
        dst = np.r_[E[:, 0], E[:, 1]]
        o = np.argsort(dst, kind='stable')
        src, dst = src[o], dst[o]
        starts = np.r_[0, np.nonzero(np.diff(dst))[0] + 1]
        owners = dst[starts]
        for _ in range(iters):
            acc = np.zeros_like(W)
            acc[owners] = np.add.reduceat(W[src], starts, axis=0)
            avg = np.where(has[:, None], acc / np.maximum(deg, 1)[:, None], W)
            W = (0.5 * W + 0.5 * avg) * gate
            W /= np.maximum(W.sum(1, keepdims=True), 1e-30)
    W *= soft
    s = W.sum(1, keepdims=True)
    bad = s[:, 0] <= 1e-12
    W[~bad] /= s[~bad]
    if bad.any():
        W[bad] = soft[bad] / np.maximum(soft[bad].sum(1, keepdims=True), 1e-30)
    # loose parts move rigidly with one bone: small ones on the body (eyes, buttons, hats) with the bone
    # that owns most of them, props away from the body (a held axe floating by the hand) with the bone
    # nearest to them
    # Pieces that touch each other move as one (rings hanging from clasps on a belt): a group of small
    # pieces takes the weights of the body where it touches it, so it stays on the belt / sleeve it hangs
    # from instead of each piece snapping to a different bone
    cid, inv, cnt = np.unique(m.comp, return_inverse=True, return_counts=True)
    members = {int(c): np.nonzero(inv == k)[0] for k, c in enumerate(cid)}
    core_c = {int(c) for c in cid if m.core_node[members[int(c)][0]]}

    def small(idx):
        return len(idx) < 0.25 * m.nn and (np.linalg.norm(np.ptp(P[idx], 0)) if len(idx) > 1 else 0) < 0.22 * H

    loose = [c for c in members if c not in core_c or small(members[c])]
    rigid = 0

    def nearest_bone(idx):
        Q = P[idx]
        return int(np.argmin([_seg_dist(Q, J[bn], J[CHILD[bn]]).min() for bn in BONES]))
    for g in _groups(loose, m.pairs):
        idx = np.concatenate([members[c] for c in g])
        if not any(c in core_c for c in g):         # a prop beside the body: with the nearest bone
            b = nearest_bone(idx)
            W[idx] = 0
            W[idx, b] = 1
            rigid += len(g)
            continue
        # each piece: the weights where it touches the body, and the weights of the pieces it touches
        # (by how much they touch: a ring touching its clasp a lot and the thigh at one point hangs
        # from the clasp), solved together; a group touching no body at all moves with its main bone
        body = m.core_node & ~np.isin(m.comp, g)
        k = len(g)
        bw = np.zeros((k, nb))
        bn = np.zeros(k)
        C = np.zeros((k, k))
        pos = {c: i for i, c in enumerate(g)}
        for i, c in enumerate(g):
            on = np.zeros(m.nn, bool)
            on[members[c]] = True
            at = m.touching(on)
            ab = at & body
            bw[i] = W[ab].sum(0)
            bn[i] = ab.sum()
            if k > 1:
                for c2, n2 in zip(*np.unique(m.comp[at & ~body & ~on], return_counts=True)):
                    if int(c2) in pos:
                        C[i, pos[int(c2)]] += n2
        if bn.sum() == 0:
            w = np.tile(np.eye(nb)[int(np.argmax(W[idx].sum(0)))], (k, 1))
        else:
            C = (C + C.T) / 2
            w = np.array([W[members[c]].mean(0) for c in g])
            den = bn + C.sum(1)
            for _ in range(200):
                w_new = np.where(den[:, None] > 0, (bw + C @ w) / np.maximum(den, 1e-12)[:, None], w)
                if np.abs(w_new - w).max() < 1e-6:
                    w = w_new
                    break
                w = w_new
            w /= np.maximum(w.sum(1, keepdims=True), 1e-12)
        for i, c in enumerate(g):
            W[members[c]] = w[i]
        rigid += k
    return W, rigid


# ------------------------------------------------------------------------------------------------ render
def view_of(m):
    """frame the body (core), not props floating around it: the markers are only placed on the body"""
    P = m.NV[m.core_node] if hasattr(m, 'core_node') and m.core_node.any() else m.V
    lo = P[:, :2].min(0)
    hi = P[:, :2].max(0)
    span = float(max(hi[0] - lo[0], hi[1] - lo[1]) * 1.08) or 1.0
    return {'cx': float((hi[0] + lo[0]) / 2), 'cy': float((hi[1] + lo[1]) / 2), 'span': span}


def to_px(view, size, x, y):
    return (size / 2 + (x - view['cx']) / view['span'] * size, size / 2 - (y - view['cy']) / view['span'] * size)


def from_px(view, size, px, py):
    return (view['cx'] + (px - size / 2) / size * view['span'], view['cy'] - (py - size / 2) / size * view['span'])


def tri_colors(ch, m):
    """flat colour per triangle from its texture (or grey)"""
    cols = []
    cache = {}
    for pr in ch.prims:
        T = np.asarray(pr['tris'], int).reshape(-1, 3)
        im = pr.get('image')
        if im is None or pr.get('uv') is None:
            cols.append(np.full((len(T), 3), 170.0))
            continue
        if id(im) not in cache:
            a = im.convert('RGB')
            a.thumbnail((256, 256))
            cache[id(im)] = np.asarray(a, float)
        A = cache[id(im)]
        uv = np.asarray(pr['uv'], float)[T].mean(1) % 1.0
        px = np.clip((uv[:, 0] * A.shape[1]).astype(int), 0, A.shape[1] - 1)
        py = np.clip((uv[:, 1] * A.shape[0]).astype(int), 0, A.shape[0] - 1)
        cols.append(A[py, px])
    return np.vstack(cols)


def render(V, T, view, size=512, colors=None, depth_axis=2, xaxis=0, flipx=False, bg=(38, 40, 48), ss=2):
    """flat-shaded orthographic view: the viewer looks along -depth_axis (front: from +Z)"""
    S = size * ss
    img = Image.new('RGB', (S, S), bg)
    d = ImageDraw.Draw(img)
    A = V[T]
    n = np.cross(A[:, 1] - A[:, 0], A[:, 2] - A[:, 0])
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    light = np.array([0.35, 0.5, 0.0])
    light[depth_axis] = 0.8
    light /= np.linalg.norm(light)
    shade = 0.35 + 0.65 * np.abs(n @ light)
    if colors is None:
        colors = np.full((len(T), 3), 190.0)
    col = np.clip(colors * shade[:, None], 0, 255).astype(int)
    xs = A[:, :, xaxis] * (-1 if flipx else 1)
    cx = view['cx'] * (-1 if flipx else 1)
    px = S / 2 + (xs - cx) / view['span'] * S
    py = S / 2 - (A[:, :, 1] - view['cy']) / view['span'] * S
    for k in np.argsort(A[:, :, depth_axis].mean(1)):
        d.polygon([(px[k, 0], py[k, 0]), (px[k, 1], py[k, 1]), (px[k, 2], py[k, 2])], fill=tuple(col[k]))
    return img.resize((size, size), Image.LANCZOS) if ss > 1 else img


# --------------------------------------------------------------------------------------------- the rig
def load_rig(path):
    """a rig json as the launcher writes it (UTF-8, with or without a BOM; never the ANSI code page)"""
    with open(path, encoding='utf-8-sig') as f:
        return json.load(f)


def markers_from_json(d):
    """rig json (pixel markers) -> turned-space markers"""
    size = float(d.get('size', 512))
    v = d['view']
    return {k: from_px(v, size, *d['markers'][k]) for k in MARKERS if k in d.get('markers', {})}


def fix_sides(mk):
    """the character's LEFT is +X (the image RIGHT): a left/right pair placed the other way round is
    swapped back (otherwise the skeleton crosses over and the skin can come out turned around)"""
    mk = dict(mk)
    swapped = []
    for part in ('wrist', 'elbow', 'knee'):
        lk, rk = 'left_' + part, 'right_' + part
        if lk in mk and rk in mk and mk[lk][0] < mk[rk][0]:
            mk[lk], mk[rk] = mk[rk], mk[lk]
            swapped.append(part)
    if swapped:
        say('autorig: WARNING the left/right %s markers were the wrong way round (the character\'s left is on '
            'the image right): swapped them' % '/'.join(swapped))
    return mk


def prepare(ch, up='auto', flip='auto', yaw=0):
    m, up_, f, auto, sc = orientation(ch, up, flip, yaw)
    say('autorig: %s up, %s (feet score %+.3f%s)' %
        (up_.upper(), 'turned 180' if f else 'facing front', sc, ', auto' if f == auto else ', forced'))
    if m.props_held:
        say('autorig: %d held prop(s) left out of the body measurements' % m.props_held)
    if clean_yaw(yaw):
        say('autorig: turned a further %d deg' % clean_yaw(yaw))
    return m, {'up': up_, 'flip': bool(f), 'flip_auto': bool(auto), 'yaw': clean_yaw(yaw), 'scores': sc}


def autorig(ch, flip='auto', up='auto', markers=None, yaw=0):
    """Fill ch.bones / ch.parent / ch.bind and every prim's jn / w for an unrigged Char (everything is left
    in turned space, Y up). markers: turned-space {name: (X, Y)} (rig editor), else guessed.
    -> info dict (up, flip, flip_auto, markers, view, J, mesh)"""
    m, info = prepare(ch, up, flip, yaw)
    sil = Silhouette(m)
    auto = auto_markers(m, sil)
    mk = dict(auto)
    if markers:
        mk.update({k: (float(v[0]), float(v[1])) for k, v in markers.items() if k in MARKERS})
        say('autorig: using %d markers from the rig editor' % sum(k in MARKERS for k in markers))
        mk = fix_sides(mk)          # (so the saved rig has them the right way round too)
    J = build_skeleton(m, mk, sil)
    W, rigid = skin_weights(m, J)
    # write back: everything in turned space
    off = 0
    for pr in ch.prims:
        n = len(pr['pos'])
        pr['pos'] = m.V[off:off + n].copy()
        Wn = W[m.node[off:off + n]]
        order = np.argsort(-Wn, axis=1)[:, :4]
        w4 = np.take_along_axis(Wn, order, 1)
        w4[w4 < 0.01] = 0
        w4 /= np.maximum(w4.sum(1, keepdims=True), 1e-12)
        pr['jn'] = [[BONES[k] for k in row] for row in order]
        pr['w'] = w4
        off += n
    ch.bones = list(BONES)
    ch.parent = dict(PARENT)
    ch.bind = {}
    for b in BONES:
        M = np.eye(4)
        M[:3, 3] = J[b]
        ch.bind[b] = M
    ch.up_is_z = False
    ch.rigged = False
    say('autorig: %d bones, %d separate small parts follow what they touch' % (len(BONES), rigid))
    info.update({'markers': mk, 'auto_markers': auto, 'J': J, 'mesh': m, 'view': view_of(m)})
    return info


def write_rig(ch, info, json_path, source, size=512):
    """front-view png + rig json (the rigprep / rigs/ format) for a prepared model"""
    m = info['mesh']
    view = info.get('view') or view_of(m)
    png = os.path.splitext(json_path)[0] + '.png'
    render(m.V, m.T, view, size, tri_colors(ch, m)).save(png)
    d = {'rigged': False, 'source': os.path.abspath(source), 'up': info['up'], 'flip': info['flip'],
         'flip_auto': info['flip_auto'], 'yaw': info.get('yaw', 0), 'image': os.path.abspath(png), 'size': size, 'view': view,
         'markers': {k: [round(c, 2) for c in to_px(view, size, *info['markers'][k])] for k in MARKERS}}
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(d, f, indent=2)       # ASCII only (\u escapes): the launcher reads it whatever the code page
    return d


def rigprep(ch, source, json_path, up='auto', flip='auto', size=512, yaw=0):
    """rig json + front view for the launcher's rig editor (auto markers)"""
    m, info = prepare(ch, up, flip, yaw)
    info['markers'] = auto_markers(m)
    info['mesh'] = m
    info['view'] = view_of(m)
    return write_rig(ch, info, json_path, source, size)
