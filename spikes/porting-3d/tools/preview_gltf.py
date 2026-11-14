#!/usr/bin/env python3
"""把导出的 glTF 渲成一张 PNG，方便不装 Blender 也能肉眼验收。

做法很朴素：按材质贴图给顶点取色 + 兰伯特光照，正交投影后做点云泼溅
（每点画一个小圆盘，带深度缓冲）。够看出"模型在不在、贴图有没有、
颜色对不对"，不追求画质。

    preview_gltf.py <model.gltf> <out.png> [--size 900]
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image


def load_gltf(path: Path):
    data = json.loads(path.read_text())
    base = path.parent
    buffers = []
    for buf in data["buffers"]:
        blob = (base / buf["uri"]).read_bytes()
        buffers.append(blob)

    def accessor(index: int):
        acc = data["accessors"][index]
        view = data["bufferViews"][acc["bufferView"]]
        blob = buffers[view.get("buffer", 0)]
        offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        kind = {5126: "f", 5123: "H", 5125: "I", 5121: "B"}[acc["componentType"]]
        count = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[acc["type"]]
        size = struct.calcsize(kind * count)
        raw = blob[offset: offset + size * acc["count"]]
        return np.frombuffer(raw, dtype=np.dtype(kind)).reshape(acc["count"], count)

    return data, base, accessor


def texture_image(base: Path, data, material) -> Image.Image | None:
    pbr = material.get("pbrMetallicRoughness", {})
    ref = pbr.get("baseColorTexture")
    if not ref:
        return None
    index = data["textures"][ref["index"]]["source"]
    uri = data["images"][index].get("uri")
    if not uri:
        return None
    try:
        return Image.open(base / uri).convert("RGB")
    except OSError:
        return None


def sample(image: Image.Image | None, u: float, v: float):
    if image is None:
        return np.array([200, 200, 200], dtype=np.float64)
    w, h = image.size
    x = min(max(int(u * w), 0), w - 1)
    y = min(max(int((1.0 - v) * h), 0), h - 1)
    return np.asarray(image.getpixel((x, y)), dtype=np.float64)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model")
    parser.add_argument("out")
    parser.add_argument("--size", type=int, default=900)
    parser.add_argument("--yaw", type=float, default=0.0, help="绕 Y 轴旋转角度")
    args = parser.parse_args()

    data, base, accessor = load_gltf(Path(args.model))
    colors, points = [], []
    yaw = np.deg2rad(args.yaw)
    rot = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
    for mesh in data["meshes"]:
        for prim in mesh["primitives"]:
            attrs = prim["attributes"]
            pos = accessor(attrs["POSITION"]).astype(np.float64)
            uv = accessor(attrs["TEXCOORD_0"]).astype(np.float64) if "TEXCOORD_0" in attrs else None
            if "indices" in prim:
                idx = accessor(prim["indices"]).reshape(-1)
                pos_v = pos[idx]
                uv_v = uv[idx] if uv is not None else None
            else:
                pos_v, uv_v = pos, uv
            mat = data["materials"][prim.get("material", 0)] if data.get("materials") else {}
            tex = texture_image(base, data, mat)
            if uv_v is not None:
                cols = np.array([sample(tex, u, v) for u, v in uv_v[::7]])
                pts = pos_v[::7]
            else:
                cols = np.tile(sample(tex, 0.5, 0.5), (len(pos_v[::7]), 1))
                pts = pos_v[::7]
            colors.append(cols)
            points.append(pts)
    if not points:
        print("没有可渲染的顶点")
        return 1
    pts = np.concatenate(points) @ rot.T
    cols = np.concatenate(colors)

    size = args.size
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    center = (lo + hi) / 2
    scale = (hi - lo)[:2].max() * 1.15 or 1.0
    xy = (pts[:, [0, 1]] - center[[0, 1]]) / scale
    sx = (xy[:, 0] * size * 0.9 + size / 2).astype(int)
    sy = (size / 2 - xy[:, 1] * size * 0.9).astype(int)
    depth = pts[:, 2]

    pad = 2
    canvas = np.full((size, size, 3), 24, dtype=np.float64)
    zbuf = np.full((size, size), -1e9)
    normal_light = 0.55 + 0.45 * np.clip((depth - depth.min()) / max(np.ptp(depth), 1e-6), 0, 1)
    for dy in range(-pad, pad + 1):
        for dx in range(-pad, pad + 1):
            x = np.clip(sx + dx, 0, size - 1)
            y = np.clip(sy + dy, 0, size - 1)
            mask = depth > zbuf[y, x]
            canvas[y[mask], x[mask]] = cols[mask] * normal_light[mask, None]
            zbuf[y[mask], x[mask]] = depth[mask]
    image = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8))
    image.save(args.out)
    print(f"{args.out}  ({len(pts)} 顶点泼溅)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
