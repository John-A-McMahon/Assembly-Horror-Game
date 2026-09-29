# sdf.py -- a tiny sculpting kit for the asset scripts.
#
# Shapes are signed distance fields evaluated with numpy on a regular grid
# (metres). Every primitive is only evaluated inside its own bounding box
# (grown by the blend radius), so a hand with ~60 parts at 0.3 mm voxels is
# a few seconds, not minutes. OpenVDB turns the finished field into a mesh.
import numpy as np

def smin(a, b, k):
    """polynomial smooth minimum (blend radius k)"""
    if k <= 0:
        return np.minimum(a, b)
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b + (a - b) * h - k * h * (1.0 - h)

def smax(a, b, k):
    return -smin(-a, -b, k)

def normalize(v):
    v = np.asarray(v, np.float64)
    return v / np.linalg.norm(v)

# ---- primitives: p is (3, ...) block coordinates ------------------------------

def round_cone(p, a, b, ra, rb):
    """capsule from a (radius ra) to b (radius rb) -- iq's exact round cone"""
    a = np.asarray(a, np.float64); b = np.asarray(b, np.float64)
    ba = b - a
    l2 = ba.dot(ba)
    rr = ra - rb
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pa = p - a.reshape(3, *([1] * (p.ndim - 1)))
    y = np.tensordot(ba, pa, axes=(0, 0))
    z = y - l2
    xv = pa * l2 - ba.reshape(3, *([1] * (p.ndim - 1))) * y
    x2 = (xv * xv).sum(0)
    y2 = y * y * l2
    z2 = z * z * l2
    k = np.sign(rr) * rr * rr * x2
    d = np.where(np.sign(z) * a2 * z2 > k, np.sqrt(x2 + z2) * il2 - rb,
        np.where(np.sign(y) * a2 * y2 < k, np.sqrt(x2 + y2) * il2 - ra,
                 (np.sqrt(np.maximum(x2 * a2 * il2, 0.0)) + y * rr) * il2 - ra))
    return d

def ellipsoid(p, c, axes):
    """ellipsoid centre c; axes = 3 (not necessarily unit) orthogonal half-axes"""
    c = np.asarray(c, np.float64).reshape(3, *([1] * (p.ndim - 1)))
    q = p - c
    comps = []
    rad = []
    for ax in axes:
        ax = np.asarray(ax, np.float64)
        r = np.linalg.norm(ax)
        comps.append(np.tensordot(ax / r, q, axes=(0, 0)))
        rad.append(r)
    k0 = np.sqrt(sum((comps[i] / rad[i]) ** 2 for i in range(3)))
    k1 = np.sqrt(sum((comps[i] / (rad[i] * rad[i])) ** 2 for i in range(3)))
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)

def frame_axes(a_axis, hint):
    """orthogonal half-axis directions: along a_axis, and two others near hint"""
    u = normalize(a_axis)
    h = np.asarray(hint, np.float64)
    h = normalize(h - u * h.dot(u))
    w = np.cross(u, h)
    return u, h, w

def infinite_cyl_z(p, r, cx=0.0, cy=0.0):
    return np.sqrt((p[0] - cx) ** 2 + (p[1] - cy) ** 2) - r

# ---- the grid -------------------------------------------------------------------

class Field:
    """a distance field on a grid over [lo, hi] with voxel size h"""

    def __init__(self, lo, hi, h, far=0.01):
        self.lo = np.asarray(lo, np.float64)
        self.h = h
        self.n = np.ceil((np.asarray(hi) - self.lo) / h).astype(int) + 1
        self.d = np.full(tuple(self.n), far, np.float32)
        self.far = far
        print("field", self.n, "voxels", int(np.prod(self.n)))

    def block(self, bmin, bmax):
        i0 = np.maximum(np.floor((np.asarray(bmin) - self.lo) / self.h).astype(int), 0)
        i1 = np.minimum(np.ceil((np.asarray(bmax) - self.lo) / self.h).astype(int) + 1, self.n)
        if np.any(i1 <= i0):
            return None, None
        sl = tuple(slice(i0[k], i1[k]) for k in range(3))
        axes = [self.lo[k] + self.h * np.arange(i0[k], i1[k]) for k in range(3)]
        p = np.stack(np.meshgrid(*axes, indexing="ij"))
        return sl, p

    def apply(self, fn, bmin, bmax, op="union", k=0.0):
        """combine fn(p) into the field inside the box (grown by k + 2 voxels)"""
        g = k + 2 * self.h
        sl, p = self.block(np.asarray(bmin) - g, np.asarray(bmax) + g)
        if sl is None:
            return
        v = fn(p)
        cur = self.d[sl].astype(np.float64)
        if op == "union":
            cur = smin(cur, v, k)
        elif op == "sub":
            cur = smax(cur, -v, k)
        elif op == "inter":
            cur = smax(cur, v, k)
        elif op == "add":            # displacement: v is an offset (negative = outward)
            cur = cur + v
        self.d[sl] = cur.astype(np.float32)

    def sample(self, pts):
        """trilinear value and central-difference gradient at points (N,3)"""
        def tri(q):
            g = (q - self.lo) / self.h
            i = np.clip(np.floor(g).astype(int), 0, self.n - 2)
            f = np.clip(g - i, 0.0, 1.0)
            out = np.zeros(len(q))
            for dx in (0, 1):
                for dy in (0, 1):
                    for dz in (0, 1):
                        w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * \
                            (f[:, 2] if dz else 1 - f[:, 2])
                        out += w * self.d[i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz]
            return out
        pts = np.asarray(pts, np.float64)
        e = self.h
        grad = np.stack([(tri(pts + e * np.eye(3)[k]) - tri(pts - e * np.eye(3)[k])) / (2 * e)
                         for k in range(3)], 1)
        return tri(pts), grad

    def mesh(self, iso=0.0, adaptivity=0.0):
        """OpenVDB polygoniser -> (verts Nx3 metres, faces list of tuples)"""
        import openvdb as vdb
        g = vdb.FloatGrid(self.far)
        g.copyFromArray(self.d)
        pts, tris, quads = g.convertToPolygons(iso, adaptivity)
        pts = np.asarray(pts, np.float64) * self.h + self.lo
        faces = [tuple(t) for t in np.asarray(tris)] + [tuple(q) for q in np.asarray(quads)]
        # openvdb winds for its own handedness; make normals point outward
        return pts, faces

def seg_box(a, b, r):
    a = np.asarray(a, np.float64); b = np.asarray(b, np.float64)
    return np.minimum(a, b) - r, np.maximum(a, b) + r

def ell_box(c, axes):
    c = np.asarray(c, np.float64)
    e = np.sqrt(sum(np.asarray(ax, np.float64) ** 2 for ax in axes))
    return c - e, c + e

# ---- hard-surface primitives (axis aligned) ------------------------------------------

def cyl_z(p, cx, cy, r, z0, z1, rr=0.0):
    """capped cylinder along Z from z0 to z1 (any order), edges rounded by rr"""
    za, zb = min(z0, z1), max(z0, z1)
    d_r = np.sqrt((p[0] - cx) ** 2 + (p[1] - cy) ** 2) - (r - rr)
    d_z = np.abs(p[2] - (za + zb) / 2) - ((zb - za) / 2 - rr)
    out = np.sqrt(np.maximum(d_r, 0) ** 2 + np.maximum(d_z, 0) ** 2)
    return out + np.minimum(np.maximum(d_r, d_z), 0) - rr

def rbox(p, c, half, rr=0.0):
    """box centre c, half sizes, edges rounded by rr"""
    q = [np.abs(p[k] - c[k]) - (half[k] - rr) for k in range(3)]
    out = np.sqrt(sum(np.maximum(qk, 0) ** 2 for qk in q))
    return out + np.minimum(np.maximum(np.maximum(q[0], q[1]), q[2]), 0) - rr

def torus_z(p, cx, cy, cz, R, r):
    """torus round the Z axis through (cx, cy), in the plane z = cz"""
    q = np.sqrt((p[0] - cx) ** 2 + (p[1] - cy) ** 2) - R
    return np.sqrt(q * q + (p[2] - cz) ** 2) - r

def lathe_z(p, cx, cy, zs, rs):
    """solid of revolution round the Z axis through (cx, cy): radius rs(z)
    interpolated from the (zs increasing) profile; approximate distance"""
    rad = np.sqrt((p[0] - cx) ** 2 + (p[1] - cy) ** 2)
    zc = np.clip(p[2], zs[0], zs[-1])
    rp = np.interp(zc, zs, rs)
    d_r = rad - rp
    d_z = np.maximum(zs[0] - p[2], p[2] - zs[-1])
    out = np.sqrt(np.maximum(d_r, 0) ** 2 + np.maximum(d_z, 0) ** 2)
    return out + np.minimum(np.maximum(d_r, d_z), 0)
