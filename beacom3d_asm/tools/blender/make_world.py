# make_world.py -- the building's surfaces, painted at real scale as height
# fields and baked into albedo + normal/gloss maps (assets/<name>_albedo.png,
# assets/<name>_normal.png). Every map tiles seamlessly left to right (noise
# is made periodic with an FFT) because the game maps one texture across each
# 2 m grid face: walls are 2 m x 3.2 m (v = 0 at the top), floors and
# ceilings 2 m x 2 m.
#
# Runs on the Python that ships with Blender (it has numpy):
#   "C:/Program Files/Blender Foundation/Blender 5.0/5.0/python/bin/python.exe" tools/blender/make_world.py
import os, sys, zlib, struct
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
os.makedirs(OUT, exist_ok=True)

# ---- plumbing --------------------------------------------------------------------------

def write_png(path, arr):
    """arr: HxWx3 or HxWx4 floats in 0..1 (sRGB for colour)"""
    a = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    h, w, c = a.shape
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if c == 4 else 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", path, len(png) // 1024, "KB")

def noise(h, w, scale_px, seed, beta=2.0, aniso=(1.0, 1.0)):
    """periodic fractal noise, mean 0 / std 1; scale_px ~ size of the largest
    features in pixels; beta the spectral slope (higher = smoother)"""
    rng = np.random.default_rng(seed)
    F = np.fft.fft2(rng.standard_normal((h, w)))
    fy = np.fft.fftfreq(h)[:, None] * aniso[1]
    fx = np.fft.fftfreq(w)[None, :] * aniso[0]
    f = np.sqrt(fx * fx + fy * fy)
    f0 = 1.0 / scale_px
    amp = 1.0 / np.power(np.maximum(f, f0), beta / 2.0 + 0.5)
    amp[0, 0] = 0.0
    n = np.real(np.fft.ifft2(F * amp))
    return (n - n.mean()) / (n.std() + 1e-12)

def blur(a, sigma_px):
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2 * (np.pi * sigma_px) ** 2 * (fx * fx + fy * fy))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))

def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

def rgb(r, g, b):
    return np.array([r, g, b], np.float64) / 255.0

def normal_map(height_m, px_m, gloss, strength=1.0):
    """tangent-space normal from a height field (x = columns, y = rows, both
    in the direction the texture coordinates grow); gloss in alpha"""
    gx = (np.roll(height_m, -1, 1) - np.roll(height_m, 1, 1)) / (2 * px_m)
    gy = (np.roll(height_m, -1, 0) - np.roll(height_m, 1, 0)) / (2 * px_m)
    n = np.stack([-gx * strength, -gy * strength, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return np.concatenate([n * 0.5 + 0.5, gloss[..., None]], -1)

def cavity(height_m, px_m, radius_m, depth_m):
    """ambient occlusion from the height field: dark where below the local average"""
    d = blur(height_m, radius_m / px_m) - height_m
    return np.clip(1.0 - d / depth_m, 0.35, 1.0)

def save(name, albedo, height, px, gloss, strength=1.0, ao=None):
    if ao is not None:
        albedo = albedo * ao[..., None]
    write_png(os.path.join(OUT, name + "_albedo.png"), albedo)
    write_png(os.path.join(OUT, name + "_normal.png"), normal_map(height, px, gloss, strength))

# ---- painted cinderblock: the hallways ------------------------------------------------------

def wall_block(W=1024):
    H = int(round(W * 3.2 / 2.0))
    px = 2.0 / W
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) * px     # metres; y down from the top
    course = np.floor(y / 0.2)
    yy = y - course * 0.2
    off = (course % 2) * 0.2
    xs = x + off
    xx = np.mod(xs, 0.4)
    bid = (course * 7 + np.floor(xs / 0.4) % 5).astype(int)
    dj = np.minimum(np.minimum(xx, 0.4 - xx), np.minimum(yy, 0.2 - yy))   # to the nearest joint
    jw = 0.0050
    e = dj - jw
    rng = np.random.default_rng(11)
    tilt_x = rng.normal(0, 0.0015, 200)[bid % 200]
    tilt_y = rng.normal(0, 0.0015, 200)[(bid * 3) % 200]
    tone = rng.normal(0, 1, 200)[(bid * 5) % 200]
    # height: flat block faces with rounded arrises, tooled concave joints
    n_fine = noise(H, W, 6, 1, beta=0.6)
    n_mid = noise(H, W, 40, 2, beta=1.4)
    pits = smoothstep(1.55, 2.3, -n_fine) * 0.0009 + smoothstep(2.4, 3.2, -noise(H, W, 14, 3, 1.0)) * 0.0016
    block_h = (tilt_x * (xx - 0.2) + tilt_y * (yy - 0.1)) * 0.5 - pits + n_mid * 0.00012
    block_h -= 0.0028 * np.clip(1 - e / 0.0045, 0, 1) ** 2
    # chips knocked out of the arrises here and there
    chip = smoothstep(1.3, 2.0, noise(H, W, 18, 4, 1.6)) * (e < 0.012) * (e > 0)
    block_h -= chip * 0.0022 * np.clip(1 - e / 0.012, 0, 1)
    mortar_h = -0.0036 - 0.0009 * (1 - (dj / jw) ** 2) + n_fine * 0.00018
    h = np.where(e > 0, block_h, mortar_h)
    # the rubber cove base along the floor
    base_top = 3.2 - 0.100
    is_base = y > base_top
    h = np.where(is_base, 0.004 + 0.0012 * smoothstep(base_top + 0.012, base_top, y), h)
    # paint: beige semi-gloss over everything, a red course at chest height
    beige = rgb(188, 176, 146)
    col = beige + (rgb(196, 186, 158) - beige) * (0.5 + 0.5 * np.tanh(tone * 0.6))[..., None] * 0.6
    col = col + (n_mid[..., None] * 0.012)
    mortar = rgb(170, 160, 134)
    col = np.where((e > 0)[..., None], col, mortar + n_fine[..., None] * 0.02)
    red = (course == 8)
    col = np.where(red[..., None], rgb(118, 40, 38) * np.where((e > 0), 1.0, 0.85)[..., None], col)
    col = col * (1.0 - pits[..., None] * 120.0)          # the pits hold dirt
    # grime: shoe scuffs and dirt above the base, hand smudges, water streaks
    low = smoothstep(2.75, 3.1, y)
    scuff = smoothstep(0.8, 2.2, noise(H, W, 60, 5, 1.2, aniso=(1.0, 0.12))) * smoothstep(2.9, 3.08, y)
    col = col * (1 - 0.18 * low[..., None]) * (1 - 0.35 * scuff[..., None])
    hands = smoothstep(0.6, 1.8, noise(H, W, 120, 6, 1.8)) * np.exp(-((y - 2.0) / 0.22) ** 2)
    col = col * (1 - 0.10 * hands[..., None])
    streak = smoothstep(1.2, 2.4, noise(H, W, 300, 7, 2.0, aniso=(0.04, 1.0))) * smoothstep(0.0, 0.8, y) * (1 - low)
    col = col * (1 - 0.13 * streak[..., None]) + rgb(40, 32, 18) * 0.13 * streak[..., None]
    col = np.where(is_base[..., None], rgb(26, 26, 26) + n_fine[..., None] * 0.006, col)
    gloss = np.where(e > 0, 0.55 - pits * 250, 0.30) - 0.25 * scuff - 0.1 * streak
    gloss = np.where(is_base, 0.40, gloss)
    ao = cavity(h, px, 0.01, 0.006)
    save("wall_block", col, h, px, np.clip(gloss, 0.05, 1), 1.0, ao)

# ---- vinyl composition tile floors ----------------------------------------------------------------

def floor_vct(name, ca, cb, n_tiles=6, W=1024, seed=20):
    px = 2.0 / W
    y, x = np.mgrid[0:W, 0:W].astype(np.float64) * px
    t = 2.0 / n_tiles
    tx, ty = np.floor(x / t), np.floor(y / t)
    lx, ly = x - tx * t, y - ty * t
    de = np.minimum(np.minimum(lx, t - lx), np.minimum(ly, t - ly))
    tid = (tx + ty * n_tiles).astype(int)
    rng = np.random.default_rng(seed)
    # quarter-turned marbling: the chip pattern runs one way on alternate tiles
    m1 = noise(W, W, 50, seed + 1, 1.6, aniso=(1.0, 0.25))
    m2 = noise(W, W, 50, seed + 2, 1.6, aniso=(0.25, 1.0))
    marb = np.where(((tx + ty) % 2) == 0, m1, m2)
    chips = noise(W, W, 3, seed + 3, 0.3)
    checker = ((tx + ty) % 2 == 0)[..., None]
    base = np.where(checker, rgb(*ca), rgb(*cb))
    tint = rng.normal(0, 0.012, 64)[tid % 64][..., None]
    col = base * (1 + 0.07 * np.tanh(marb)[..., None]) + tint
    col = col + (smoothstep(1.6, 2.4, chips) * 0.10 - smoothstep(1.6, 2.4, -chips) * 0.08)[..., None]
    # traffic: worn and dirty down the middle, dirt packed into the seams,
    # black heel marks
    wear = smoothstep(-0.5, 1.5, noise(W, W, 400, seed + 4, 2.2))
    col = col * (1 - 0.10 * wear[..., None])
    seam = np.exp(-(de / 0.0012) ** 2)
    col = col * (1 - 0.55 * seam[..., None])
    heel = smoothstep(2.3, 3.0, noise(W, W, 30, seed + 5, 1.4, aniso=(1.0, 0.15)))
    col = col * (1 - 0.6 * heel[..., None])
    # height: each tile sits a hair higher or lower, soft seams, orange peel of wax
    lift = rng.normal(0, 0.00012, 64)[tid % 64]
    h = lift - 0.0005 * np.exp(-(de / 0.0010) ** 2) + noise(W, W, 8, seed + 6, 1.2) * 0.00002
    gloss = 0.75 - 0.35 * wear - 0.4 * heel - 0.3 * seam
    ao = cavity(h, px, 0.004, 0.0015)
    save(name, col, h, px, np.clip(gloss, 0.05, 1), 1.0, ao)

def floor_concrete(name, ca, W=1024, seed=40):
    """sealed concrete slab with saw-cut joints every metre (the basement)"""
    px = 2.0 / W
    y, x = np.mgrid[0:W, 0:W].astype(np.float64) * px
    lx, ly = np.mod(x, 1.0), np.mod(y, 1.0)
    de = np.minimum(np.minimum(lx, 1 - lx), np.minimum(ly, 1 - ly))
    n1 = noise(W, W, 300, seed, 2.2)
    n2 = noise(W, W, 20, seed + 1, 1.2)
    n3 = noise(W, W, 3, seed + 2, 0.4)
    col = rgb(*ca) * (1 + 0.10 * n1[..., None] + 0.04 * n2[..., None] + 0.03 * n3[..., None])
    stains = smoothstep(0.8, 2.0, noise(W, W, 150, seed + 3, 2.4))
    col = col * (1 - 0.3 * stains[..., None])
    cut = np.exp(-(de / 0.0018) ** 2)
    col = col * (1 - 0.6 * cut[..., None])
    crack_n = np.abs(noise(W, W, 200, seed + 4, 2.0))
    crack = smoothstep(0.03, 0.0, crack_n) * smoothstep(0.3, 1.2, noise(W, W, 200, seed + 5, 2.0))
    col = col * (1 - 0.5 * crack[..., None])
    h = -0.004 * cut - 0.0012 * crack + n2 * 0.00015 - smoothstep(1.8, 2.6, -n3) * 0.0005
    gloss = 0.35 + 0.2 * stains - 0.2 * cut
    ao = cavity(h, px, 0.008, 0.003)
    save(name, col, h, px, np.clip(gloss, 0.05, 1), 1.0, ao)

# ---- suspended acoustic ceiling ---------------------------------------------------------------------

def ceiling_tiles(W=1024, seed=60):
    px = 2.0 / W
    y, x = np.mgrid[0:W, 0:W].astype(np.float64) * px
    # the T-bar grid: along x = 0 and y = 0, y = 1 m (2 m x 1 m tiles, as before)
    dgx = np.minimum(x, 2.0 - x)
    ly = np.mod(y, 1.0)
    dgy = np.minimum(ly, 1.0 - ly)
    dg = np.minimum(dgx, dgy)
    bar = dg < 0.012
    # tegular tile edge: the tile face steps down to the grid
    edge = smoothstep(0.012, 0.030, dg)
    fiss = np.abs(noise(W, W, 30, seed, 1.6))
    fissures = smoothstep(0.08, 0.0, fiss) * smoothstep(-0.2, 0.8, noise(W, W, 60, seed + 1, 1.5))
    pin = smoothstep(2.2, 3.0, noise(W, W, 2, seed + 2, 0.1))
    tile_h = -0.012 + 0.010 * edge - fissures * 0.0012 - pin * 0.0006 + noise(W, W, 6, seed + 3, 1.0) * 0.00012
    h = np.where(bar, 0.0, tile_h)
    col = rgb(186, 182, 170) * (1 + 0.03 * noise(W, W, 200, seed + 4, 2.0))[..., None]
    col = col * (1 - 0.25 * fissures[..., None] - 0.2 * pin[..., None])
    # old water stains: brown tide-marks, darker at the ring
    sx, sy, sr = 1.35, 0.62, 0.22
    r = np.sqrt((x - sx) ** 2 + (y - sy) ** 2) + noise(W, W, 80, seed + 5, 2.0) * 0.03
    stain = smoothstep(sr, sr * 0.3, r) * 0.25 + np.exp(-((r - sr) / 0.012) ** 2) * 0.35
    stain = stain * (~bar)
    col = col * (1 - stain[..., None] * 0.5) + rgb(110, 80, 40) * (stain[..., None] * 0.3)
    col = np.where(bar[..., None], rgb(214, 214, 208), col)
    col = col * (1 - 0.12 * (1 - edge)[..., None] * (~bar)[..., None])
    gloss = np.where(bar, 0.6, 0.08)
    ao = cavity(h, px, 0.01, 0.006)
    save("ceiling_tile", col, h, px, gloss, 1.0, ao)

if __name__ == "__main__":
    which = sys.argv[1:] or ["wall", "floor", "ceiling"]
    if "wall" in which:
        wall_block()
    if "floor" in which:
        floor_vct("floor_tile", (143, 138, 124), (111, 107, 96))
        floor_vct("floor_safe", (45, 85, 122), (36, 71, 100), seed=30)
        floor_concrete("floor_base", (78, 76, 71))
    if "ceiling" in which:
        ceiling_tiles()
