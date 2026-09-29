# hand.py -- sculpt the player's right hand (the view model) as a distance
# field, in hands.asm's local grip frame: the hand closes in a power grip
# round an object of radius GRIP_R lying along local Z (metres; the left
# hand is the same mesh mirrored by the game).
#
# Anatomy, not blobs: each finger is an elliptical cross-section swept along
# its curl round the grip (wider than it is thick, pads on the palm side,
# bony ridges at the joints, a nail plate on the last phalanx); the flesh is
# then pressed flat where it meets the grip. Tendons and veins are laid on
# the back of the hand by projecting paths onto the surface.
#
# build_field() -> Field; details(verts, normals) -> vertex displacement and
# the masks the texture bake reads (nail, knuckle redness, vein, ...).
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sdf import *

GRIP_R = 0.0156
Z = np.array([0.0, 0.0, 1.0])

# the four fingers: z along the grip, radius, and the angles (degrees round
# the grip, 0 = +X, 90 = +Y) of knuckle, middle joint, last joint, tip --
# the skeleton hands.asm used for its primitive hand
FINGERS = [
    (-0.0300, 0.0088, -60.0, -140.0, -205.0, -247.0),   # index
    (-0.0105, 0.0092, -58.0, -140.0, -207.0, -250.0),   # middle
    ( 0.0085, 0.0087, -56.0, -138.0, -204.0, -246.0),   # ring
    ( 0.0262, 0.0075, -54.0, -132.0, -195.0, -234.0),   # pinky
]
# width (along the grip) and thickness (radial) of a finger, as a fraction
# of its radius, along the finger: knuckle .. tip
PROFILE_S = [(0.00, 1.02, 0.95), (0.30, 0.97, 0.86), (0.55, 0.93, 0.80),
             (0.62, 0.95, 0.82), (0.80, 0.88, 0.76), (0.86, 0.90, 0.78),
             (0.97, 0.84, 0.70), (1.00, 0.60, 0.50)]

def lerp_profile(prof, s):
    ss = [p[0] for p in prof]
    return tuple(np.interp(s, ss, [p[k] for p in prof]) for k in (1, 2))

def fpoint(ang, rad, z):
    a = math.radians(ang)
    return np.array([rad * math.cos(a), rad * math.sin(a), z])

def finger_joints(f):
    z, r, *angs = f
    line = GRIP_R + 0.80 * r            # sinks into the grip: the flesh flattens
    mcp = fpoint(angs[0], line + 0.0160, z)
    return [mcp] + [fpoint(a, line, z) for a in angs[1:]], r

def radial(p):
    d = np.array([p[0], p[1], 0.0])
    return d / max(np.linalg.norm(d), 1e-9)

def finger_curve(js, n=90):
    """points along the finger (knuckle -> tip), their parameter s in 0..1
    and which joint segment they're on"""
    seg_len = [np.linalg.norm(js[i + 1] - js[i]) for i in range(3)]
    tot = sum(seg_len)
    pts, ss = [], []
    for k in range(n + 1):
        s = k / n
        d = s * tot
        i = 0
        while i < 2 and d > seg_len[i]:
            d -= seg_len[i]; i += 1
        t = min(d / seg_len[i], 1.0)
        a, b = js[i], js[i + 1]
        # phalanges are straight bones: chords round the grip, the joints
        # making corners (the grip flattens the pads between them) -- bowed
        # out a little so a chord does not cut deep into the grip
        p = a + (b - a) * t
        if i > 0:
            p = p + radial(p) * (math.sin(math.pi * t) * 0.0012)
        pts.append(p); ss.append(s)
    return np.array(pts), np.array(ss), np.cumsum([0] + seg_len) / tot

def sweep(F, pts, ss, prof, r, k=0.0, out_fn=radial):
    """a chain of ellipsoids along pts: width r*ws along Z, thickness r*wt
    along the outward direction"""
    for i in range(len(pts)):
        p = pts[i]
        t = pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]
        t = t / np.linalg.norm(t)
        ws, wt = lerp_profile(prof, ss[i])
        o = out_fn(p)
        o = o - t * o.dot(t); o /= np.linalg.norm(o)
        side = np.cross(t, o)
        ax = [t * r * wt * 0.9, o * r * wt, side * r * ws]
        F.apply(lambda q, c=p, ax=ax: ellipsoid(q, c, ax), *ell_box(p, ax), "union", k)

WRIST = np.array([0.086, 0.004, 0.0])
ELBOW = np.array([0.254, 0.0205, 0.246])
BACK_C = np.array([0.054, -0.018, 0.0])
BACK_N = normalize((0.0074, -0.0113, 0.0))           # the back of the hand faces this way

# the thumb lies along the top of the grip, nail up, where the fingertips
# don't reach: base over the palm, tip toward the front of the grip
THUMB = [np.array(v) for v in ((0.050, 0.020, -0.002), (0.034, 0.029, -0.030),
                               (0.0143, 0.0207, -0.057), (0.0087, 0.0213, -0.079))]
THUMB_R = 0.0102
THUMB_PROF = [(0.00, 1.25, 1.15), (0.40, 1.05, 0.95), (0.62, 1.02, 0.90), (0.70, 1.05, 0.92),
              (0.93, 0.92, 0.78), (1.00, 0.62, 0.52)]

def thumb_out(p):
    # the thumbnail faces away from the grip
    return radial(p)

def polyline(pts, n):
    pts = np.asarray(pts, np.float64)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    t = np.linspace(0, cum[-1], n)
    return np.stack([np.interp(t, cum, pts[:, k]) for k in range(3)], 1)

def project(F, p, iters=6):
    """move points onto the zero surface of the field (trilinear + gradient)"""
    p = np.array(p, np.float64)
    for _ in range(iters):
        d, g = F.sample(p)
        gn = g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)
        p = p - gn * d[:, None]
    d, g = F.sample(p)
    return p, g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)

NAILS = []      # (centre, along, out, side, half length, half width)
JOINTS = []     # (centre, along, out, finger radius, which: 0 knuckle 1 middle 2 last)

def build_field(h=0.0005):
    NAILS.clear(); JOINTS.clear()
    F = Field((-0.052, -0.062, -0.105), (0.205, 0.058, 0.185), h, far=0.004)

    def ELL(c, ax, k):
        F.apply(lambda p, c=c, ax=ax: ellipsoid(p, c, ax), *ell_box(c, ax), "union", k)

    # ---- the hand's body: back (flat, bony) and palm (fleshy) ---------------
    ELL(BACK_C, [(-0.0290, -0.0188, 0.0), BACK_N * 0.0115, (0, 0, 0.0385)], 0.008)
    ELL((0.037, 0.003, 0.0), [(0.0110, 0.0030, 0.0), (0.0062, -0.0232, 0.0), (0, 0, 0.037)], 0.006)
    ELL((0.047, 0.015, 0.021), [(0.013, 0.0, 0.0), (0.0, -0.0115, 0.0), (0, 0, 0.0145)], 0.006)  # hypothenar
    ELL((0.043, 0.017, -0.013), [(0.0140, -0.004, 0.0), (0.004, 0.0125, 0.0), (0, 0, 0.0170)], 0.007)  # thenar

    # ---- wrist and forearm: an oval, flatter front to back ---------------------
    ELL(WRIST, [(0.017, 0, 0), (0, 0.0165, 0), (0, 0, 0.0255)], 0.012)
    fa = polyline([WRIST, WRIST + (ELBOW - WRIST) * 0.72], 40)
    fdir = normalize(ELBOW - WRIST)
    for i, c in enumerate(fa):
        s = i / (len(fa) - 1)
        rw = 0.0255 + 0.0080 * s          # across (roughly local Z)
        rt = 0.0170 + 0.0095 * s          # front to back
        up = normalize(np.array([0.0, 1.0, 0.0]) - fdir * fdir[1])
        side = np.cross(fdir, up)
        ax = [fdir * 0.012, up * rt, side * rw]
        F.apply(lambda p, c=c, ax=ax: ellipsoid(p, c, ax), *ell_box(c, ax), "union", 0.006 if s < 0.15 else 0.003)

    # ---- the fingers ---------------------------------------------------------------
    for f in FINGERS:
        js, r = finger_joints(f)
        # metacarpal: from the back of the hand out to the knuckle
        base = np.array([0.062, -0.012, f[0] * 0.78])
        F.apply(lambda p, a=base, b=js[0], r=r: round_cone(p, a, b, r * 0.85, r * 0.95),
                *seg_box(base, js[0], r * 1.1), "union", 0.007)
        pts, ss, joint_s = finger_curve(js)
        sweep(F, pts, ss, PROFILE_S, r, 0.0)
        for w, sj in enumerate(joint_s[:3]):
            i = int(round(sj * (len(pts) - 1)))
            t = normalize(pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)])
            JOINTS.append((pts[i], t, radial(pts[i]), r, w))
        # the knuckle: a bony dome on the back
        c = js[0] + radial(js[0]) * r * 0.10
        ELL(c, [(r * 0.95, 0, 0), (0, r * 0.95, 0), (0, 0, r * 0.80)], 0.004)
        # palm-side pads of each phalanx, pressed on the grip later
        for s0, s1 in ((joint_s[0], joint_s[1]), (joint_s[1], joint_s[2]), (joint_s[2], 1.0)):
            sm = s0 + (s1 - s0) * (0.55 if s1 < 1.0 else 0.45)
            i = int(round(sm * (len(pts) - 1)))
            p = pts[i]
            o = radial(p)
            t = normalize(pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)])
            ln = (s1 - s0) * np.linalg.norm(js[1] - js[0]) * 1.6
            ax = [t * max(ln * 0.30, r * 0.55), o * r * 0.55, Z * r * 0.78]
            ELL(p - o * r * 0.30, ax, 0.002)
        # the nail plate, a little proud of the skin on the last phalanx
        i = int(round((joint_s[2] + (1 - joint_s[2]) * 0.58) * (len(pts) - 1)))
        p = pts[i]
        o = radial(p)
        t = normalize(pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)])
        _, wt = lerp_profile(PROFILE_S, ss[i])
        ax = [t * r * 0.72, o * r * 0.30, Z * r * 0.66]
        ELL(p + o * (r * wt * 0.80), ax, 0.0006)
        NAILS.append((p + o * (r * wt * 0.80), t, o, Z, r * 0.72, r * 0.66))

    # ---- the thumb, laid along the grip ------------------------------------------------
    tp = polyline(THUMB, 60)
    ts = np.linspace(0, 1, len(tp))
    sweep(F, tp, ts, THUMB_PROF, THUMB_R, 0.0, thumb_out)
    for (a, b) in ((THUMB[0], THUMB[1]),):
        F.apply(lambda p, a=a, b=b: round_cone(p, a, b, 0.0125, 0.0112), *seg_box(a, b, 0.013), "union", 0.007)
    # thumbnail
    i = int(len(tp) * 0.86)
    p = tp[i]; o = thumb_out(p); t = normalize(tp[i + 1] - tp[i - 1])
    o = normalize(o - t * o.dot(t))
    ax = [t * 0.0068, o * 0.0030, np.cross(t, o) * 0.0066]
    ELL(p + o * THUMB_R * 0.95 * 0.80, ax, 0.0006)
    NAILS.append((p + o * THUMB_R * 0.95 * 0.80, t, o, np.cross(t, o), 0.0068, 0.0066))
    j = int(len(tp) * 0.66)
    JOINTS.append((tp[j], normalize(tp[j + 1] - tp[j - 1]), thumb_out(tp[j]), THUMB_R, 2))
    # the web between thumb and index
    web_a, web_b = np.array([0.036, -0.016, -0.030]), np.array([0.034, 0.022, -0.031])
    F.apply(lambda p: round_cone(p, web_a, web_b, 0.0075, 0.0055), *seg_box(web_a, web_b, 0.009), "union", 0.007)

    # ---- flesh pressed flat on the grip ------------------------------------------------
    F.apply(lambda p: infinite_cyl_z(p, GRIP_R + 0.0003), (-0.02, -0.02, -0.105), (0.02, 0.02, 0.185),
            "sub", 0.0022)

    # ---- forearm ends inside the sleeve ------------------------------------------------
    F.apply(lambda p: p[0] - 0.198, (0.18, -0.06, 0.1), (0.205, 0.06, 0.185), "inter", 0.0)
    return F

# dorsal veins: rough paths over the back of the hand, projected onto it
VEINS = [
    [(0.095, -0.020, 0.012), (0.075, -0.030, 0.006), (0.058, -0.034, -0.004), (0.044, -0.036, -0.016)],
    [(0.070, -0.031, 0.020), (0.058, -0.034, 0.010), (0.050, -0.036, 0.004), (0.036, -0.040, -0.004)],
    [(0.058, -0.034, 0.010), (0.046, -0.037, 0.018), (0.034, -0.041, 0.022)],
    [(0.100, -0.012, -0.018), (0.080, -0.022, -0.016), (0.066, -0.029, -0.020)],
]

def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)

def details(v, n, seed=7):
    """fine sculpt on the dense mesh: v, n (N,3) -> displacement along the
    normal (metres, + out) and the masks the texture bake reads"""
    rng = np.random.default_rng(seed)
    disp = np.zeros(len(v))
    nail = np.zeros(len(v))
    lunula = np.zeros(len(v))
    red = np.zeros(len(v))
    crease = np.zeros(len(v))
    for (c, t, o, sd, a, b) in NAILS:
        q = v - c
        u = q @ t / a                      # -1 cuticle .. +1 free edge
        w = q @ sd / b
        h = q @ o
        facing = smoothstep(0.2, 0.6, n @ o)
        near = (np.abs(h) < 0.004) & (facing > 0)
        # a rounded rectangle (superellipse) in the nail frame
        e = (np.abs(u) ** 2.4 + np.abs(w) ** 2.4) ** (1 / 2.4)
        inside = smoothstep(1.03, 0.94, e) * facing * near
        nail = np.maximum(nail, inside)
        # the nail fold: a groove round the cuticle and the sides
        groove = np.exp(-((e - 1.02) / 0.07) ** 2) * facing * near * smoothstep(0.9, 0.3, u)
        disp -= groove * 0.00022
        # the nail plate: smooth and a touch proud
        disp += inside * 0.00008
        # the pale half-moon at the cuticle
        lunula = np.maximum(lunula, inside * smoothstep(-0.45, -0.75, u) * smoothstep(1.0, 0.6, np.abs(w)))
        red = np.maximum(red, near * facing * smoothstep(1.25, 1.02, e) * (1 - inside) * 0.7)
    for (c, t, o, r, which) in JOINTS:
        q = v - c
        s = q @ t
        side = q @ np.cross(t, o)
        dors = smoothstep(0.15, 0.75, n @ o)
        palm = smoothstep(0.2, 0.7, -(n @ o))
        ext = (0.0045, 0.0034, 0.0026)[which]
        amp = (0.00006, 0.00011, 0.00008)[which]
        per = (0.0011, 0.0010, 0.0009)[which]
        near = np.linalg.norm(q, axis=1) < r * 1.8
        # wrinkles: arcs round the joint, strongest at its top
        de = np.sqrt(s ** 2 + (side * 0.45) ** 2)
        ph = rng.uniform(0, 6.283)
        wav = np.sin(de / per * 6.283 + ph + 0.8 * np.sin(side / r * 5.0))
        m = np.exp(-(de / ext) ** 2) * dors * np.exp(-(side / (r * 0.85)) ** 2) * near
        disp -= m * amp * np.clip(wav, -0.2, 1.0)
        red = np.maximum(red, m * (0.55 if which == 0 else 0.4))
        # the palm-side crease under each joint
        pc = np.exp(-(s / 0.0007) ** 2) * palm * near * np.exp(-(side / (r * 0.9)) ** 2)
        disp -= pc * 0.00030
        crease = np.maximum(crease, pc)
    return disp, dict(nail=nail, lunula=lunula, red=red, crease=crease)

if __name__ == "__main__":
    import time
    t = time.time()
    F = build_field()
    v, f = F.mesh()
    print("mesh", len(v), "verts", len(f), "faces", "%.1fs" % (time.time() - t))
