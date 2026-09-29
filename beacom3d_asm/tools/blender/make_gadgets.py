# make_gadgets.py -- the gadget in your left hand, as hard-surface props:
#   gadget_gun    the frame most gadgets are built on (hands.asm L_GUN)
#   gadget_hook   the hookshot / grabber body (L_HOOK)
#   gadget_tip    the hook itself, on the front while it isn't flying (L_HOOKTIP)
# Local frame as hands.asm: the hand grips along Z round the origin (radius
# ~0.0175 from z = +0.075 to -0.05); forward is -Z. The bodies start ahead
# of the thumb (z < -0.09) and hang off a neck, so the sculpted hand's thumb
# never sinks into them. The muzzle and tip sit where the game draws the
# glowing core (0, 0.032, -0.252) and launches the hook (0, 0.034, -0.26).
#
#   blender -b --factory-startup --python tools/blender/make_gadgets.py -- [texture size] [gun|hook|tip ...]
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import clear, make_mesh, fix_normals
from sdf import *
import bake as B

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RES = int(argv[0]) if argv and argv[0].isdigit() else 1024
WHICH = [a for a in argv if not a.isdigit()] or ["gun", "hook", "tip"]

# materials
RUBBER, WHITE, DARK, BRASS, GREEN, STEEL, CORE = range(7)

class Prop:
    """parts (material, sdf) unioned with blend k; cuts subtracted"""
    def __init__(self):
        self.parts = []
        self.cuts = []
    def add(self, mat, fn, box, k=0.0):
        self.parts.append((mat, fn, box, k))
    def cut(self, fn, box, k=0.0):
        self.cuts.append((fn, box, k))
    def field(self, lo, hi, h):
        F = Field(lo, hi, h, far=0.003)
        for mat, fn, box, k in self.parts:
            F.apply(fn, box[0], box[1], "union", k)
        for fn, box, k in self.cuts:
            F.apply(fn, box[0], box[1], "sub", k)
        return F
    def materials(self, pts):
        """per point: the material of the nearest part"""
        best = np.full(len(pts), 1e9)
        mat = np.zeros(len(pts))
        p = pts.T.reshape(3, -1, 1, 1)
        for m, fn, box, k in self.parts:
            d = np.abs(fn(p).reshape(-1))
            closer = d < best
            best = np.where(closer, d, best)
            mat = np.where(closer, m, mat)
        return mat

def box_z(cx, cy, r, z0, z1):
    return ((cx - r, cy - r, min(z0, z1)), (cx + r, cy + r, max(z0, z1)))

def squash_x(fn, s):
    """the shape narrowed across (x) by s"""
    def g(p):
        q = p.copy()
        q[0] = q[0] / s
        return fn(q) * min(s, 1.0)
    return g

def groove_on(body, slab, depth):
    """a groove: the band of body's surface inside slab"""
    return lambda p: np.maximum(slab(p), np.abs(body(p)) - depth)

def grip(P, neck_to_y):
    # rubber grip with a flared pommel
    zs = [-0.047, -0.042, 0.064, 0.072, 0.078, 0.081]
    rs = [0.0178, 0.0172, 0.0172, 0.0194, 0.0180, 0.0100]
    P.add(RUBBER, lambda p: lathe_z(p, 0, 0, zs, rs), box_z(0, 0, 0.02, -0.05, 0.085))
    # a metal guard ring in front of the hand
    P.add(DARK, lambda p: cyl_z(p, 0, 0, 0.0215, -0.055, -0.046, 0.0015), box_z(0, 0, 0.022, -0.056, -0.045), 0.0)
    # the neck up to the body
    a, b = np.array([0.0, 0.002, -0.052]), np.array([0.0, neck_to_y - 0.004, -0.108])
    P.add(DARK, lambda p: round_cone(p, a, b, 0.0145, 0.0165), seg_box(a, b, 0.017), 0.004)

def gun():
    P = Prop()
    grip(P, 0.032)
    cy = 0.032
    zs = [-0.228, -0.221, -0.205, -0.180, -0.150, -0.122, -0.104, -0.092]
    rs = [0.0170, 0.0232, 0.0290, 0.0322, 0.0328, 0.0300, 0.0235, 0.0120]
    shell = squash_x(lambda p: lathe_z(p, 0, cy, zs, rs), 0.86)
    P.add(WHITE, shell, box_z(0, cy, 0.034, -0.23, -0.09), 0.003)
    # the core: a glass tube seen through a window on each side
    P.add(CORE, lambda p: cyl_z(p, 0, cy, 0.0205, -0.186, -0.118, 0.004), box_z(0, cy, 0.021, -0.19, -0.115))
    for sx in (-1, 1):
        c = (sx * 0.030, cy, -0.152)
        P.cut(lambda p, c=c: rbox(p, c, (0.012, 0.0085, 0.030), 0.004), ((c[0] - 0.013, cy - 0.01, -0.183), (c[0] + 0.013, cy + 0.01, -0.121)), 0.0008)
    # panel seams: a ring and a line along the top
    P.cut(groove_on(shell, lambda p: np.abs(p[2] + 0.168) - 0.0004, 0.0007), box_z(0, cy, 0.035, -0.172, -0.164))
    P.cut(groove_on(shell, lambda p: np.maximum(np.abs(p[0]) - 0.0004, cy + 0.01 - p[1]), 0.0007), box_z(0, cy, 0.035, -0.23, -0.09))
    # vents on top, toward the front
    for k in range(4):
        zc = -0.196 + k * 0.0065
        c = (0.0, cy + 0.031, zc)
        P.cut(lambda p, c=c: rbox(p, c, (0.009, 0.006, 0.0013), 0.0008), ((-0.01, cy + 0.02, zc - 0.002), (0.01, cy + 0.04, zc + 0.002)))
    # a sight rail
    P.add(DARK, lambda p: rbox(p, (0, cy + 0.0335, -0.150), (0.0038, 0.0030, 0.026), 0.0010), ((-0.005, cy + 0.029, -0.178), (0.005, cy + 0.038, -0.122)), 0.0008)
    # the metal nozzle, bored out for the glow, and three prongs round it
    nz = [-0.246, -0.241, -0.229, -0.221]
    nr = [0.0150, 0.0172, 0.0172, 0.0200]
    P.add(DARK, lambda p: lathe_z(p, 0, cy, nz, nr), box_z(0, cy, 0.021, -0.247, -0.22), 0.001)
    P.cut(lambda p: cyl_z(p, 0, cy, 0.0105, -0.26, -0.236, 0.0), box_z(0, cy, 0.011, -0.26, -0.235))
    for ang in (90.0, 210.0, 330.0):
        a = math.radians(ang)
        u = np.array([math.cos(a), math.sin(a), 0.0])
        p0 = np.array([0, cy, -0.205]) + u * 0.027
        p1 = np.array([0, cy, -0.262]) + u * 0.022
        P.add(STEEL, lambda p, p0=p0, p1=p1: round_cone(p, p0, p1, 0.0042, 0.0026), seg_box(p0, p1, 0.005), 0.0015)
    return P, (-0.042, -0.024, -0.27), (0.042, 0.075, 0.086)

def hook():
    P = Prop()
    grip(P, 0.034)
    cy = 0.034
    # brass spool housing, a crank on its side
    P.add(BRASS, lambda p: cyl_z(p, 0, cy, 0.0305, -0.124, -0.094, 0.003), box_z(0, cy, 0.031, -0.125, -0.093), 0.002)
    for z in (-0.101, -0.109, -0.117):              # chain wound round it, showing in a slot
        P.add(STEEL, lambda p, z=z: torus_z(p, 0, cy, z, 0.0300, 0.0026), box_z(0, cy, 0.034, z - 0.003, z + 0.003))
    P.cut(lambda p: rbox(p, (0.0, cy + 0.030, -0.109), (0.013, 0.006, 0.0115), 0.002), ((-0.014, cy + 0.02, -0.121), (0.014, cy + 0.04, -0.097)))
    a, b = np.array([0.029, cy, -0.109]), np.array([0.041, cy, -0.109])
    P.add(BRASS, lambda p: round_cone(p, a, b, 0.0075, 0.0068), seg_box(a, b, 0.008), 0.001)
    c1, c2 = np.array([0.041, cy, -0.109]), np.array([0.043, cy + 0.016, -0.100])
    P.add(DARK, lambda p: round_cone(p, c1, c2, 0.0030, 0.0028), seg_box(c1, c2, 0.004), 0.001)
    # the green barrel, machined rings
    zs = [-0.204, -0.199, -0.130, -0.124]
    rs = [0.0255, 0.0266, 0.0274, 0.0262]
    barrel = lambda p: lathe_z(p, 0, cy, zs, rs)
    P.add(GREEN, barrel, box_z(0, cy, 0.028, -0.205, -0.123), 0.001)
    for z in (-0.143, -0.160, -0.177):
        P.cut(lambda p, z=z: torus_z(p, 0, cy, z, 0.0272, 0.0009), box_z(0, cy, 0.029, z - 0.001, z + 0.001))
    # front collar and the muzzle
    P.add(BRASS, lambda p: cyl_z(p, 0, cy, 0.0305, -0.217, -0.201, 0.002), box_z(0, cy, 0.031, -0.218, -0.2), 0.001)
    mz = [-0.252, -0.246, -0.228, -0.216]
    mr = [0.0100, 0.0125, 0.0135, 0.0160]
    P.add(DARK, lambda p: lathe_z(p, 0, cy, mz, mr), box_z(0, cy, 0.017, -0.253, -0.215), 0.001)
    return P, (-0.042, -0.024, -0.26), (0.050, 0.070, 0.086)

def tip():
    P = Prop()
    cy = 0.034
    P.add(BRASS, lambda p: ellipsoid(p, (0, cy, -0.262), [(0.0135, 0, 0), (0, 0.0135, 0), (0, 0, 0.018)]),
          ell_box((0, cy, -0.262), [(0.0135, 0, 0), (0, 0.0135, 0), (0, 0, 0.018)]))
    for ang in (90.0, 210.0, 330.0):
        a = math.radians(ang)
        u = np.array([math.cos(a), math.sin(a), 0.0])
        c = np.array([0, cy, 0])
        p0 = c + np.array([0, 0, -0.270]) + u * 0.004
        p1 = c + np.array([0, 0, -0.284]) + u * 0.020
        p2 = c + np.array([0, 0, -0.278]) + u * 0.030
        p3 = c + np.array([0, 0, -0.266]) + u * 0.031
        for (q0, q1, r0, r1) in ((p0, p1, 0.0045, 0.0038), (p1, p2, 0.0038, 0.0030), (p2, p3, 0.0030, 0.0009)):
            P.add(STEEL, lambda p, q0=q0, q1=q1, r0=r0, r1=r1: round_cone(p, q0, q1, r0, r1), seg_box(q0, q1, r0 + 0.001), 0.002)
    return P, (-0.036, -0.004, -0.29), (0.036, 0.072, -0.24)

# ---- material ---------------------------------------------------------------------------

PALETTE = {  # linear albedo, gloss, relief
    RUBBER: ((0.018, 0.018, 0.019), 0.18, "stipple"),
    WHITE: ((0.62, 0.63, 0.62), 0.55, "polymer"),
    DARK: ((0.035, 0.036, 0.040), 0.50, "brushed"),
    BRASS: ((0.45, 0.30, 0.10), 0.75, "brushed"),
    GREEN: ((0.035, 0.12, 0.045), 0.60, "brushed"),
    STEEL: ((0.30, 0.30, 0.31), 0.85, "brushed"),
    CORE: ((0.55, 0.85, 0.95), 0.95, "none"),
}

def prop_material():
    mat = bpy.data.materials.new("prop")
    mat.use_nodes = True
    nt = mat.node_tree
    N, L = nt.nodes, nt.links
    for n in list(N):
        N.remove(n)
    out = N.new("ShaderNodeOutputMaterial")
    tc = N.new("ShaderNodeTexCoord")
    geo = N.new("ShaderNodeNewGeometry")
    at = N.new("ShaderNodeAttribute"); at.attribute_name = "mat"
    M = at.outputs["Fac"]

    def m(op, a, b=None):
        n = N.new("ShaderNodeMath"); n.operation = op
        for sock, val in ((n.inputs[0], a), (n.inputs[1], b)):
            if val is None: continue
            if isinstance(val, (int, float)): sock.default_value = float(val)
            else: L.new(val, sock)
        return n.outputs[0]

    def mixc(fac, a, b):
        n = N.new("ShaderNodeMix"); n.data_type = "RGBA"
        for sock, val in ((n.inputs[0], fac), (n.inputs[6], a), (n.inputs[7], b)):
            if isinstance(val, tuple): sock.default_value = val + ((1.0,) if len(val) == 3 else ())
            elif isinstance(val, float): sock.default_value = val
            else: L.new(val, sock)
        return n.outputs[2]

    def noise(scale, detail=3.0, stretch=None):
        n = N.new("ShaderNodeTexNoise")
        n.inputs["Scale"].default_value = scale
        n.inputs["Detail"].default_value = detail
        v = tc.outputs["Object"]
        if stretch:
            mp = N.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = stretch
            L.new(v, mp.inputs[0]); v = mp.outputs[0]
        L.new(v, n.inputs["Vector"])
        return n.outputs["Fac"]

    def is_mat(k):
        return m("LESS_THAN", m("ABSOLUTE", m("SUBTRACT", M, float(k))), 0.5)

    edge = m("MAXIMUM", m("MULTIPLY", m("SUBTRACT", geo.outputs["Pointiness"], 0.52), 12.0), 0.0)
    wear = m("MINIMUM", m("MULTIPLY", edge, noise(700.0, 4.0)), 1.0)
    grime = m("POWER", noise(120.0, 3.0), 2.5)
    col, gloss, height = None, None, None
    for k, (c, g, relief) in PALETTE.items():
        sel = is_mat(k)
        cc = mixc(m("MULTIPLY", noise(400.0), 0.25), tuple(x * 0.85 for x in c), tuple(min(1, x * 1.15) for x in c))
        if k in (WHITE,):
            cc = mixc(m("MULTIPLY", grime, 0.25), cc, (0.35, 0.33, 0.29))
            cc = mixc(m("MULTIPLY", wear, 0.6), cc, (0.9, 0.9, 0.88))
        if k in (GREEN, DARK):
            cc = mixc(m("MULTIPLY", wear, 0.9), cc, (0.55, 0.55, 0.56))
        if k == BRASS:
            cc = mixc(m("MULTIPLY", m("POWER", noise(90.0, 3.0), 2.0), 0.6), cc, (0.16, 0.12, 0.05))
            cc = mixc(m("MULTIPLY", wear, 0.8), cc, (0.80, 0.62, 0.30))
        if relief == "stipple":
            v = N.new("ShaderNodeTexVoronoi"); v.inputs["Scale"].default_value = 1600.0
            L.new(tc.outputs["Object"], v.inputs["Vector"])
            hh = m("MINIMUM", m("MULTIPLY", v.outputs["Distance"], 2.5), 1.0)
        elif relief == "brushed":
            hh = m("MULTIPLY", noise(4000.0, 2.0, (1.0, 1.0, 0.03)), 0.25)
        elif relief == "polymer":
            hh = m("MULTIPLY", noise(2500.0, 2.0), 0.12)
        else:
            hh = None
        gg = m("SUBTRACT", g, m("MULTIPLY", grime, 0.2))
        col = mixc(sel, col if col is not None else (0, 0, 0), cc)
        gloss = m("ADD", gloss if gloss is not None else 0.0, m("MULTIPLY", sel, gg))
        if hh is not None:
            height = m("ADD", height if height is not None else 0.0, m("MULTIPLY", sel, hh))
    bump = N.new("ShaderNodeBump"); bump.inputs["Distance"].default_value = 0.00012
    L.new(height, bump.inputs["Height"])
    diff = N.new("ShaderNodeBsdfDiffuse"); L.new(bump.outputs["Normal"], diff.inputs["Normal"])
    em = N.new("ShaderNodeEmission"); L.new(col, em.inputs["Color"])
    em_gl = N.new("ShaderNodeEmission"); L.new(gloss, em_gl.inputs["Color"])
    return mat, out, dict(albedo=em.outputs[0], gloss=em_gl.outputs[0], normal=diff.outputs[0])

def build(name, P, lo, hi, tris, res, h=0.0003):
    t0 = time.time()
    clear()
    F = P.field(lo, hi, h)
    v, f = F.mesh()
    low = make_mesh(name + "_low", v, f); fix_normals(low)
    high = make_mesh(name + "_high", v, f); fix_normals(high)
    co, _ = B.mesh_arrays(high)
    mats = P.materials(co)
    at = high.data.attributes.new("mat", "FLOAT", "POINT")
    at.data.foreach_set("value", mats.astype(np.float32))
    B.decimate(low, tris)
    B.unwrap(low, margin=0.006, angle=50.0)
    mat, out, shaders = prop_material()
    high.data.materials.append(mat)
    def use(which):
        Ls = mat.node_tree.links
        for l in list(out.inputs["Surface"].links):
            Ls.remove(l)
        Ls.new(shaders[which], out.inputs["Surface"])
    kw = dict(extrusion=0.0008, ray_dist=0.002)
    img_alb = B.new_image("alb", res)
    use("albedo"); B.bake(high, low, "EMIT", img_alb, samples=4, **kw)
    img_gl = B.new_image("gloss", res, noncolor=True)
    use("gloss"); B.bake(high, low, "EMIT", img_gl, samples=1, **kw)
    img_n = B.new_image("nrm", res, noncolor=True)
    use("normal"); B.bake(high, low, "NORMAL", img_n, samples=4, **kw)
    w = bpy.data.worlds.new("w"); bpy.context.scene.world = w
    w.light_settings.distance = 0.01
    img_ao = B.new_image("ao", res // 2, noncolor=True)
    B.bake(high, low, "AO", img_ao, samples=32, **kw)
    B.finish(img_alb, img_n, img_gl, img_ao, os.path.join(OUT, name), ao_amount=0.7)
    B.write_bmsh(low, os.path.join(OUT, name + ".bmsh"))
    print(name, "done in %.0fs" % (time.time() - t0))

if "gun" in WHICH:
    P, lo, hi = gun()
    build("gadget_gun", P, lo, hi, 3000, RES)
if "hook" in WHICH:
    P, lo, hi = hook()
    build("gadget_hook", P, lo, hi, 3000, RES)
if "tip" in WHICH:
    P, lo, hi = tip()
    build("gadget_tip", P, lo, hi, 700, RES // 2)
