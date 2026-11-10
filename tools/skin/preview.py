"""Flat-shaded orthographic preview of skinned glTF meshes in their bind pose (front + side), side by side.
  python tools/skin/preview.py out.png a.gltf [b.gltf ...]"""
import sys
import os

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gltfio import Gltf  # noqa: E402


def mesh(path):
    g = Gltf(path)
    Vs, Ts = [], []
    base = 0
    for i, nd in enumerate(g.nodes):
        if 'mesh' not in nd:
            continue
        for p in g.j['meshes'][nd['mesh']]['primitives']:
            v = g.accessor(p['attributes']['POSITION']).astype(float)
            t = g.accessor(p['indices']).reshape(-1, 3).astype(int)
            Vs.append(v)
            Ts.append(t + base)
            base += len(v)
    return np.vstack(Vs), np.vstack(Ts)


def render(V, T, axes, size=400):
    img = Image.new('RGB', (size, size), (40, 40, 48))
    d = ImageDraw.Draw(img)
    a, b, depth = axes
    lo, hi = V.min(0), V.max(0)
    span = max(hi[a] - lo[a], hi[b] - lo[b]) * 1.1
    cx, cy = (hi[a] + lo[a]) / 2, (hi[b] + lo[b]) / 2

    def P(p):
        return (size / 2 + (p[a] - cx) / span * size, size / 2 - (p[b] - cy) / span * size)
    zs = V[T].mean(1)[:, depth]
    n = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    for k in np.argsort(zs):
        shade = int(80 + 170 * abs(n[k][depth]))
        d.polygon([P(V[i]) for i in T[k]], fill=(shade, shade, shade))
    return img


out = sys.argv[1]
tiles = []
for path in sys.argv[2:]:
    V, T = mesh(path)
    tiles.append(render(V, T, (2, 1, 0)))  # front: looking down -X (CoD forward is +X)
    tiles.append(render(V, T, (0, 1, 2)))  # side
W = Image.new('RGB', (400 * len(tiles), 400))
for i, t in enumerate(tiles):
    W.paste(t, (400 * i, 0))
W.save(out)
print('saved', out)
