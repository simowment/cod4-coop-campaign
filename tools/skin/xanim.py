"""CoD4 (IW3) raw compiled xanim, version 17 -- the file the Linker reads from xanim/<name>
and the Unlinker dumps. Layout (little endian), confirmed against OAT CompiledXAnimLoader.cpp:

  u16 version (17)  u16 numFrames  u16 boneCount  u8 flags (1=looped, 2=delta)  u8 assetType  u16 fps
  numLoopFrames = numFrames + 1 if looped else numFrames ;  byteIdx = (numLoopFrames-1) < 256
  [delta]   quat2 track (yaw only) + trans track          (same encoding as below, half quat)
  flipBits[ceil(bones/8)]  halfBits[ceil(bones/8)]        (bit i = bone i)
  boneCount x cstring bone names
  per bone:  quat track, trans track
  u8 numNotes, numNotes x (cstring name, u16 frame)      ("end" is implicit)

  quat track:  u16 n ; n==0 -> none (half bones only) ; n==1 -> one key ;
               else [indices if n < numLoopFrames: u8 or u16 each] + n keys
               key = full: i16 x,y,z (w = +sqrt(32767^2 - x2-y2-z2)) ; half: i16 z (w likewise) (rotation about Z)
               flip bit negates the whole first key (lets w be negative)
  trans track: u16 n ; 0 none ; 1 -> f32 x,y,z ;
               else [indices] + u8 small + f32 mins[3] + f32 size[3] + n x (u8[3] if small else u16[3])
               value = mins + q * size / (255 or 65535)   (size is stored raw; OAT multiplies by 1/255, 1/65535)
"""
import math
import struct


class Reader:
    def __init__(self, b):
        self.b, self.p = b, 0

    def u8(self):
        v = self.b[self.p]; self.p += 1; return v

    def u16(self):
        v = struct.unpack_from('<H', self.b, self.p)[0]; self.p += 2; return v

    def i16s(self, n):
        v = list(struct.unpack_from('<%dh' % n, self.b, self.p)); self.p += 2 * n; return v

    def f32s(self, n):
        v = list(struct.unpack_from('<%df' % n, self.b, self.p)); self.p += 4 * n; return v

    def raw(self, n):
        v = self.b[self.p:self.p + n]; self.p += n; return bytes(v)

    def cstr(self):
        e = self.b.index(0, self.p); s = self.b[self.p:e].decode('latin1'); self.p = e + 1; return s


def _read_idx(r, n, nloop, byteidx):
    if n >= nloop:
        return None                      # implicit 0..n-1
    if byteidx:
        return [r.u8() for _ in range(n)]
    return list(struct.unpack_from('<%dH' % n, r.raw(2 * n)))


def _write_idx(out, idx, byteidx):
    if idx is None:
        return
    out += bytes(idx) if byteidx else struct.pack('<%dH' % len(idx), *idx)


def _read_quat(r, nloop, byteidx, half):
    n = r.u16()
    t = {'n': n, 'idx': None, 'keys': []}
    if n == 0:
        return t
    c = 1 if half else 3
    if n > 1:
        t['idx'] = _read_idx(r, n, nloop, byteidx)
    t['keys'] = [r.i16s(c) for _ in range(n)]
    return t


def _read_trans(r, nloop, byteidx):
    n = r.u16()
    t = {'n': n, 'idx': None}
    if n == 0:
        return t
    if n == 1:
        t['const'] = r.f32s(3)
        return t
    t['idx'] = _read_idx(r, n, nloop, byteidx)
    t['small'] = r.u8()
    t['mins'] = r.f32s(3)
    t['size'] = r.f32s(3)
    t['frames'] = [list(r.raw(3)) for _ in range(n)] if t['small'] else [list(struct.unpack('<3H', r.raw(6))) for _ in range(n)]
    return t


def _write_trans(out, t, byteidx):
    out += struct.pack('<H', t['n'])
    if t['n'] == 0:
        return
    if t['n'] == 1:
        out += struct.pack('<3f', *t['const'])
        return
    _write_idx(out, t['idx'], byteidx)
    out += struct.pack('<B3f3f', t['small'], *t['mins'], *t['size'])
    for f in t['frames']:
        out += bytes(f) if t['small'] else struct.pack('<3H', *f)


def parse(b):
    r = Reader(b)
    a = {}
    a['version'] = r.u16()
    assert a['version'] == 17, a['version']
    a['numFrames'] = r.u16()
    nb = r.u16()
    a['flags'] = r.u8()
    a['type'] = r.u8()
    a['fps'] = r.u16()
    nloop = a['numFrames'] + 1 if a['flags'] & 1 else a['numFrames']
    byteidx = (nloop - 1) < 256
    a['delta'] = None
    if a['flags'] & 2:
        a['delta'] = {'quat': _read_quat(r, nloop, byteidx, True), 'trans': _read_trans(r, nloop, byteidx)}
    m = (nb + 7) // 8
    flip = r.raw(m) if nb else b''
    halfb = r.raw(m) if nb else b''
    names = [r.cstr() for _ in range(nb)]
    a['bones'] = []
    for i, nm in enumerate(names):
        half = bool(halfb[i >> 3] & (1 << (i & 7)))
        bone = {'name': nm, 'flip': bool(flip[i >> 3] & (1 << (i & 7))), 'half': half}
        bone['quat'] = _read_quat(r, nloop, byteidx, half)
        bone['trans'] = _read_trans(r, nloop, byteidx)
        a['bones'].append(bone)
    nn = r.u8()
    a['notes'] = [(r.cstr(), r.u16()) for _ in range(nn)]
    assert r.p == len(b), (r.p, len(b))
    return a


def write(a):
    nloop = a['numFrames'] + 1 if a['flags'] & 1 else a['numFrames']
    byteidx = (nloop - 1) < 256
    out = bytearray()
    nb = len(a['bones'])
    out += struct.pack('<HHHBBH', 17, a['numFrames'], nb, a['flags'], a['type'], a['fps'])

    def q(t, half):
        out.extend(struct.pack('<H', t['n']))
        if t['n'] == 0:
            return
        if t['n'] > 1:
            _write_idx(out, t['idx'], byteidx)
        for k in t['keys']:
            out.extend(struct.pack('<%dh' % len(k), *k))

    if a['flags'] & 2:
        q(a['delta']['quat'], True)
        _write_trans(out, a['delta']['trans'], byteidx)
    if nb:
        m = (nb + 7) // 8
        flip = bytearray(m); halfb = bytearray(m)
        for i, bn in enumerate(a['bones']):
            if bn['flip']: flip[i >> 3] |= 1 << (i & 7)
            if bn['half']: halfb[i >> 3] |= 1 << (i & 7)
        out += flip + halfb
        for bn in a['bones']:
            out += bn['name'].encode('latin1') + b'\0'
        for bn in a['bones']:
            q(bn['quat'], bn['half'])
            _write_trans(out, bn['trans'], byteidx)
    out += struct.pack('<B', len(a['notes']))
    for nm, fr in a['notes']:
        out += nm.encode('latin1') + b'\0' + struct.pack('<H', fr)
    return bytes(out)


# ---------- helpers to decode / encode keys as real quaternions ----------
Q = 32767.0


def key_to_quat(key, half, negate=False):
    """-> (x, y, z, w) float."""
    if half:
        z = key[0]; w = math.sqrt(max(0, 0x3FFF0001 - z * z)); x = y = 0
    else:
        x, y, z = key; w = math.sqrt(max(0, 0x3FFF0001 - x * x - y * y - z * z))
    s = -1 if negate else 1
    return (s * x / Q, s * y / Q, s * z / Q, s * w / Q)


def bone_quats(bone, nloop):
    """Per-frame quats (sample-and-hold expanded via linear interpolation of indices) for a bone."""
    t = bone['quat']
    if t['n'] == 0:
        return [(0, 0, 0, 1)] * nloop
    keys = []
    prev = None
    for i, k in enumerate(t['keys']):
        qq = key_to_quat(k, bone['half'], bone['flip'] and i == 0)
        if prev is not None and sum(p * c for p, c in zip(prev, qq)) < 0:
            qq = tuple(-c for c in qq)
        keys.append(qq); prev = qq
    if t['n'] == 1:
        return [keys[0]] * nloop
    idx = t['idx'] if t['idx'] is not None else list(range(t['n']))
    out = []
    j = 0
    for f in range(nloop):
        while j + 1 < len(idx) and idx[j + 1] <= f:
            j += 1
        if j + 1 < len(idx) and idx[j] < f:
            u = (f - idx[j]) / (idx[j + 1] - idx[j])
            a, b = keys[j], keys[j + 1]
            qq = tuple(a[c] * (1 - u) + b[c] * u for c in range(4))
            l = math.sqrt(sum(c * c for c in qq)); qq = tuple(c / l for c in qq)
        else:
            qq = keys[j]
        out.append(qq)
    return out


def encode_full_track(quats):
    """quats: list of (x,y,z,w) per loop frame -> full-quat track dict + flip flag. Stores every frame."""
    qs = []
    prev = None
    for qq in quats:
        l = math.sqrt(sum(c * c for c in qq)); qq = [c / l for c in qq]
        if prev is not None and sum(p * c for p, c in zip(prev, qq)) < 0:
            qq = [-c for c in qq]
        qs.append(qq); prev = qq
    # game reconstructs w >= 0 for every key and re-flips by dot with the previous key, so a key with w<0
    # is stored negated (same rotation). Only the first key's sign is carried by the flip bit.
    flip = qs[0][3] < 0
    keys = []
    for qq in qs:
        if qq[3] < 0:
            qq = [-c for c in qq]
        keys.append([max(-32767, min(32767, int(round(c * Q)))) for c in qq[:3]])
    if all(k == keys[0] for k in keys):
        return {'n': 1, 'idx': None, 'keys': [keys[0]]}, flip
    return {'n': len(keys), 'idx': None, 'keys': keys}, flip


def encode_trans_track(vecs):
    """vecs: list of (x,y,z) per loop frame -> trans track dict (u16 quantised, or one constant)."""
    if all(max(abs(v[c] - vecs[0][c]) for c in range(3)) < 1e-4 for v in vecs):
        return {'n': 1, 'idx': None, 'const': [float(c) for c in vecs[0]]}
    mins = [min(v[c] for v in vecs) for c in range(3)]
    size = [max(v[c] for v in vecs) - mins[c] for c in range(3)]
    frames = [[int(round((v[c] - mins[c]) / size[c] * 65535)) if size[c] > 0 else 0 for c in range(3)] for v in vecs]
    return {'n': len(vecs), 'idx': None, 'small': 0, 'mins': mins, 'size': size, 'frames': frames}


def build(num_frames, fps, looped, tracks):
    """tracks: [(bone name, [quat xyzw per loop frame], [trans xyz per loop frame] or None)]
    (loop frames = num_frames + 1 when looped: the last one is the first again) -> raw xanim bytes."""
    nloop = num_frames + 1 if looped else num_frames
    bones = []
    for name, quats, trans in tracks:
        assert len(quats) == nloop, (name, len(quats), nloop)
        q, flip = encode_full_track(quats)
        t = encode_trans_track(trans) if trans is not None else {'n': 0, 'idx': None}
        bones.append({'name': name, 'flip': flip, 'half': False, 'quat': q, 'trans': t})
    # the game reads the rotation data by part type (OAT keeps the file order): no rotation, half, full,
    # half one key, full one key -- the bones must come in that order
    def part(bn):
        n = bn['quat']['n']
        if n == 0:
            return 0
        if n > 1:
            return 1 if bn['half'] else 2
        return 3 if bn['half'] else 4
    bones.sort(key=part)
    a = {'numFrames': num_frames, 'flags': 1 if looped else 0, 'type': 2, 'fps': int(round(fps)),
         'delta': None, 'bones': bones, 'notes': []}
    b = write(a)
    assert write(parse(b)) == b
    return b
