# make_sleeve.py -- your hoodie sleeve: a hollow knit shell round the forearm
# with a ribbed cuff at the wrist and soft folds bunched above it, baked into
# assets/sleeve.bmsh + sleeve_albedo.png + sleeve_normal.png. Same local frame
# as the hand (hand.py): it follows the forearm from the wrist to the elbow.
#
#   blender -b --factory-startup --python tools/blender/make_sleeve.py -- [texture size]
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import clear, make_mesh, fix_normals
from sdf import Field, normalize
import bake as B
import hand

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RES = int(argv[0]) if argv else 1024
t0 = time.time()

A = normalize(hand.ELBOW - hand.WRIST)                  # along the forearm
UP = normalize(np.array([0.0, 1.0, 0.0]) - A * A[1])
SIDE = np.cross(A, UP)
S_OPEN = 0.012          # the cuff's mouth, metres from the wrist along the arm
S_CUFF = 0.052          # where the ribbed cuff ends and the sleeve balloons
S_END = 0.22            # off screen, and short of the near plane
TH = 0.0022             # cloth thickness

def radii(s):
    """half-widths (side, up) of the sleeve at s"""
    # the forearm under it: rw 0.0255 + 0.008 t, rt 0.017 + 0.0095 t over 0.215 m
    t = np.clip(s / 0.215, 0, 1.4)
    fw, ft = 0.0255 + 0.0080 * t, 0.0170 + 0.0095 * t
    cuff = 1.0 - np.clip((s - S_CUFF) / 0.035, 0, 1)
    cuff = cuff * cuff * (3 - 2 * cuff)
    loose = 0.0100 + 0.0045 * np.clip((s - S_CUFF) / 0.12, 0, 1)
    return fw + 0.0032 + (1 - cuff) * loose, ft + 0.0034 + (1 - cuff) * loose * 1.1

rng = np.random.default_rng(3)
WAVES = [(rng.uniform(0, 6.283), rng.integers(1, 4), rng.uniform(0.3, 1.0)) for _ in range(5)]

def folds(s, th):
    """outward displacement of the cloth (metres): bunched rings above the
    cuff that wander round the arm, and a couple of long diagonal creases"""
    ring_s = s + sum(0.0045 * a * np.sin(k * th + ph) for ph, k, a in WAVES)
    amp = 0.0022 * np.clip((s - S_CUFF + 0.004) / 0.012, 0, 1) * np.exp(-np.maximum(s - S_CUFF, 0) / 0.11)
    ring = np.cos(ring_s / 0.0135 * 2 * np.pi)
    ring = np.sign(ring) * np.abs(ring) ** 0.6              # sharper crests
    diag = 0.0012 * np.sin((s * 1.0 + th * 0.020) / 0.030 * 2 * np.pi) * np.clip((s - S_CUFF) / 0.05, 0, 1)
    cuff_bulge = 0.0008 * np.exp(-((s - (S_CUFF - 0.006)) / 0.006) ** 2)
    return amp * ring + diag + cuff_bulge

def sleeve_sdf(p):
    q = p - hand.WRIST.reshape(3, 1, 1, 1)
    s = np.tensordot(A, q, axes=(0, 0))
    a = np.tensordot(SIDE, q, axes=(0, 0))
    b = np.tensordot(UP, q, axes=(0, 0))
    rw, rt = radii(s)
    th = np.arctan2(b / rt, a / rw)
    k0 = np.sqrt((a / rw) ** 2 + (b / rt) ** 2)
    d = (k0 - 1.0) * np.minimum(rw, rt) - folds(s, th)
    shell = np.maximum(d, -(d + TH))
    # the mouth of the cuff, rolled round (a small torus-like lip), and the far end
    shell = np.maximum(shell, S_OPEN - s)
    shell = np.maximum(shell, s - S_END)
    return shell

clear()
F = Field((0.085, -0.075, -0.07), (0.33, 0.085, 0.26), 0.0005, far=0.004)
# evaluate in slabs along x to keep the memory down
nx = F.n[0]
step = 40
for i0 in range(0, nx, step):
    i1 = min(nx, i0 + step)
    xs = F.lo[0] + F.h * np.arange(i0, i1)
    ys = F.lo[1] + F.h * np.arange(F.n[1])
    zs = F.lo[2] + F.h * np.arange(F.n[2])
    p = np.stack(np.meshgrid(xs, ys, zs, indexing="ij"))
    F.d[i0:i1] = np.clip(sleeve_sdf(p), -F.far, F.far).astype(np.float32)
print("field %.0fs" % (time.time() - t0))
v, f = F.mesh()
low = make_mesh("sleeve_low", v, f); fix_normals(low)
B.decimate(low, 3000)
# cylindrical coordinates for the knit: along the arm, round the arm. The
# folds are real geometry in the game mesh; the knit is baked straight onto
# it (no dense mesh: the cloth is thinner than a bake cage could miss)
co, no = B.mesh_arrays(low)
q = co - hand.WRIST
s = q @ A
th = (np.arctan2(q @ UP, q @ SIDE) + np.pi / 2) % (2 * np.pi)   # wraps at the UV seam
cuff = (s < S_CUFF).astype(float)
rad = np.outer(q @ SIDE, SIDE) + np.outer(q @ UP, UP)      # away from the arm's axis
inner = ((no * rad).sum(1) < 0).astype(float)               # the inside of the sleeve
B.add_point_colour(low, "cyl", np.stack([s, th, cuff, inner], 1))

def cylinder_uvs(ob):
    """u round the arm (the seam underneath, out of sight), v along it; the
    inside of the cuff gets its own strip at the top of the texture"""
    me = ob.data
    co, _ = B.mesh_arrays(ob)
    q = co - hand.WRIST
    s = q @ A
    th = np.arctan2(q @ UP, q @ SIDE)
    u = ((th + np.pi / 2) / (2 * np.pi)) % 1.0          # seam at the bottom
    lay = me.uv_layers.new(name="uv")
    uv = np.zeros((len(me.loops), 2))
    for poly in me.polygons:
        vs = [me.loops[li].vertex_index for li in poly.loop_indices]
        c = co[vs].mean(0) - hand.WRIST
        rad = SIDE * (c @ SIDE) + UP * (c @ UP)
        inside = np.dot(np.asarray(poly.normal), rad) < 0
        us = u[vs].copy()
        if us.max() - us.min() > 0.5:                  # straddles the seam
            us[us < 0.5] += 1.0
        for k, li in enumerate(poly.loop_indices):
            sv = s[vs[k]]
            if inside:
                v = 0.90 + np.clip((sv - S_OPEN) / 0.05, 0, 1) * 0.09
            else:
                v = 0.01 + np.clip((sv - S_OPEN) / (S_END - S_OPEN), 0, 1) * 0.87
            uv[li] = (us[k] * 0.98 + 0.01, v)
    lay.data.foreach_set("uv", uv.astype(np.float32).ravel())

cylinder_uvs(low)
print("mesh %.0fs" % (time.time() - t0))

def cloth_material():
    mat = bpy.data.materials.new("cloth")
    mat.use_nodes = True
    nt = mat.node_tree
    N, L = nt.nodes, nt.links
    for n in list(N):
        N.remove(n)
    out = N.new("ShaderNodeOutputMaterial")
    tc = N.new("ShaderNodeTexCoord")
    at = N.new("ShaderNodeAttribute"); at.attribute_name = "cyl"
    sep = N.new("ShaderNodeSeparateColor"); L.new(at.outputs["Color"], sep.inputs[0])
    S, TH_, CUFF = sep.outputs
    INNER = at.outputs["Alpha"]

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

    def noise(scale, detail=3.0, vec=None):
        n = N.new("ShaderNodeTexNoise")
        n.inputs["Scale"].default_value = scale
        n.inputs["Detail"].default_value = detail
        L.new(vec if vec is not None else tc.outputs["Object"], n.inputs["Vector"])
        return n.outputs["Fac"]

    # arc length round the arm (approximately: angle x mean radius)
    arc = m("MULTIPLY", TH_, 0.036)
    # jersey knit: rows of little V stitches (two slanted waves per wale)
    wale, course = 0.0011, 0.00085
    col_i = m("DIVIDE", arc, wale)
    row_i = m("DIVIDE", S, course)
    v1 = m("ABSOLUTE", m("SINE", m("MULTIPLY", col_i, math.pi)))
    slant = m("SINE", m("MULTIPLY", m("ADD", row_i, m("MULTIPLY", m("ABSOLUTE", m("SUBTRACT", m("FRACT", col_i), 0.5)), 1.4)), 2 * math.pi))
    knit = m("MULTIPLY", m("POWER", v1, 0.5), m("ADD", 0.6, m("MULTIPLY", slant, 0.4)))
    # the cuff: 1x1 rib, raised ribs along the arm
    rib = m("POWER", m("ABSOLUTE", m("SINE", m("MULTIPLY", m("DIVIDE", arc, 0.0021), math.pi))), 0.7)
    height = mixc(CUFF, knit, rib)
    fuzz = noise(2500.0, 2.0)
    bw = N.new("ShaderNodeRGBToBW"); L.new(height, bw.inputs[0])
    h = m("ADD", bw.outputs[0], m("MULTIPLY", fuzz, 0.25))
    bump = N.new("ShaderNodeBump"); bump.inputs["Distance"].default_value = 0.0003
    L.new(h, bump.inputs["Height"])
    diff = N.new("ShaderNodeBsdfDiffuse"); L.new(bump.outputs["Normal"], diff.inputs["Normal"])
    # colour: charcoal heather -- light and dark fibres, a little lint, the
    # cuff a touch darker, the inside darker still
    base = mixc(m("MULTIPLY", noise(900.0, 4.0), 1.0), (0.030, 0.032, 0.036), (0.055, 0.057, 0.062))
    heather = m("GREATER_THAN", noise(3000.0, 1.0), 0.62)
    base = mixc(m("MULTIPLY", heather, 0.35), base, (0.085, 0.085, 0.09))
    base = mixc(m("MULTIPLY", m("SUBTRACT", 1.0, bw.outputs[0]), 0.5), base, (0.012, 0.012, 0.014))
    wear = m("POWER", noise(60.0, 3.0), 3.0)
    base = mixc(m("MULTIPLY", wear, 0.5), base, (0.075, 0.074, 0.072))
    base = mixc(m("MULTIPLY", CUFF, 0.35), base, (0.020, 0.021, 0.024))
    base = mixc(m("MULTIPLY", INNER, 0.6), base, (0.010, 0.010, 0.011))
    em = N.new("ShaderNodeEmission"); L.new(base, em.inputs["Color"])
    gl = m("ADD", 0.08, m("MULTIPLY", fuzz, 0.05))
    em_gl = N.new("ShaderNodeEmission"); L.new(gl, em_gl.inputs["Color"])
    return mat, out, dict(albedo=em.outputs[0], gloss=em_gl.outputs[0], normal=diff.outputs[0])

mat, out, shaders = cloth_material()
low.data.materials.append(mat)
def use(which):
    L = mat.node_tree.links
    for l in list(out.inputs["Surface"].links):
        L.remove(l)
    L.new(shaders[which], out.inputs["Surface"])

img_alb = B.new_image("alb", RES)
use("albedo"); B.bake(None, low, "EMIT", img_alb, samples=4)
img_gl = B.new_image("gloss", RES, noncolor=True)
use("gloss"); B.bake(None, low, "EMIT", img_gl, samples=1)
img_n = B.new_image("nrm", RES, noncolor=True)
use("normal"); B.bake(None, low, "NORMAL", img_n, samples=4)
w = bpy.data.worlds.new("w"); bpy.context.scene.world = w
w.light_settings.distance = 0.02
img_ao = B.new_image("ao", RES // 2, noncolor=True)
B.bake(None, low, "AO", img_ao, samples=32)
B.finish(img_alb, img_n, img_gl, img_ao, os.path.join(OUT, "sleeve"), ao_amount=0.8)
B.write_bmsh(low, os.path.join(OUT, "sleeve.bmsh"))
print("done in %.0fs" % (time.time() - t0))
