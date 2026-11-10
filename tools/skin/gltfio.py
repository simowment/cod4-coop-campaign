"""Minimal glTF/GLB reader helpers (numpy only): nodes, hierarchy, global transforms, accessors."""
import base64
import json
import os
import struct

import numpy as np

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


class Gltf:
    def __init__(self, path):
        self.path = path
        self.dir = os.path.dirname(path)
        data = open(path, 'rb').read()
        self.bin = None
        if data[:4] == b'glTF':
            off = 12
            while off < len(data):
                clen, ctype = struct.unpack('<II', data[off:off + 8])
                chunk = data[off + 8:off + 8 + clen]
                if ctype == 0x4E4F534A:
                    self.j = json.loads(chunk)
                elif ctype == 0x004E4942:
                    self.bin = chunk
                off += 8 + clen
        else:
            self.j = json.loads(data)
        self.nodes = self.j['nodes']
        self.parent = {}
        for i, nd in enumerate(self.nodes):
            for c in nd.get('children', []):
                self.parent[c] = i
        self.name_to_node = {nd.get('name'): i for i, nd in enumerate(self.nodes)}
        self._g = {}

    def buffer(self, i):
        b = self.j['buffers'][i]
        if 'uri' not in b:
            return self.bin
        uri = b['uri']
        if uri.startswith('data:'):
            return base64.b64decode(uri.split(',', 1)[1])
        return open(os.path.join(self.dir, uri), 'rb').read()

    def bufferview(self, i):
        bv = self.j['bufferViews'][i]
        buf = self.buffer(bv['buffer'])
        o = bv.get('byteOffset', 0)
        return buf[o:o + bv['byteLength']], bv.get('byteStride')

    def accessor(self, i):
        a = self.j['accessors'][i]
        dt = COMP[a['componentType']]
        n = NCOMP[a['type']]
        raw, stride = self.bufferview(a['bufferView'])
        off = a.get('byteOffset', 0)
        isz = np.dtype(dt).itemsize
        if stride and stride != n * isz:
            out = np.empty((a['count'], n), dt)
            for k in range(a['count']):
                out[k] = np.frombuffer(raw, dt, n, off + k * stride)
        else:
            out = np.frombuffer(raw, dt, a['count'] * n, off).reshape(a['count'], n)
        if a.get('normalized') and dt != np.float32:
            out = out.astype(np.float32) / np.iinfo(dt).max
        return out

    def local(self, i):
        nd = self.nodes[i]
        M = np.eye(4)
        if 'matrix' in nd:
            return np.array(nd['matrix'], float).reshape(4, 4).T
        M[:3, :3] = quat_to_mat(nd.get('rotation', [0, 0, 0, 1])) * np.array(nd.get('scale', [1, 1, 1]))
        M[:3, 3] = nd.get('translation', [0, 0, 0])
        return M

    def world(self, i):
        if i not in self._g:
            L = self.local(i)
            self._g[i] = self.world(self.parent[i]) @ L if i in self.parent else L
        return self._g[i]


def quat_to_mat(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
