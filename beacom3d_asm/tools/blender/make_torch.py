# make_torch.py -- the flashlight in your right hand: a lathed tactical light
# (tail clicky, knurled body, finned head, steel bezel) plus a pocket clip,
# baked into assets/torch.bmsh + torch_albedo.png + torch_normal.png.
# Local frame as hands.asm: body along Z, head toward -Z, radius 0.0157 where
# the hand grips; the lens (drawn glowing by the game) sits at z = -0.1686.
#
#   blender -b --factory-startup --python tools/blender/make_torch.py -- [texture size]
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import clear, make_mesh
import bake as B

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RES = int(argv[0]) if argv else 1024
t0 = time.time()

# ---- the profile, tail to head: (radius, z, material) ------------------------------
# materials: 0 anodised body, 1 knurled grip, 2 steel, 3 rubber, 4 glass/reflector
R = 0.0157
PROFILE = []
def P(r, z, m):
    PROFILE.append((r, z, m))

P(0.0, 0.0842, 3)                  # the tail clicky: a rubber dome
P(0.0040, 0.0838, 3); P(0.0068, 0.0826, 3); P(0.0082, 0.0808, 3); P(0.0086, 0.0790, 3)
P(0.0086, 0.0782, 0)               # into the tail cap
P(0.0128, 0.0782, 0); P(0.0158, 0.0776, 0); P(0.0166, 0.0766, 0)      # crenellated rim
P(0.0168, 0.0740, 0)
P(0.0168, 0.0600, 1); P(0.0168, 0.0520, 1)                          # tail cap grip band
P(0.0168, 0.0512, 0); P(0.0162, 0.0506, 0); P(0.0152, 0.0500, 0)   # thread gap
P(0.0152, 0.0492, 0); P(0.0158, 0.0486, 0)
P(R, 0.0420, 0)
P(R, 0.0380, 1)                    # knurled grip: where your fingers are
P(R, -0.0900, 1)
P(R, -0.0940, 0)
for k in range(3):                 # three grip rings
    z = -0.0990 - k * 0.0078
    P(R, z, 0); P(0.0150, z - 0.0010, 0); P(0.0150, z - 0.0034, 0); P(R, z - 0.0044, 0)
P(R, -0.1250, 0)
# the head flares out, with cooling fins
zf = -0.1270
P(0.0162, zf, 0)
for k in range(5):
    z = zf - 0.0012 - k * 0.0050
    rr = 0.0170 + k * 0.0012
    P(rr + 0.0014, z, 0); P(rr + 0.0014, z - 0.0026, 0); P(rr, z - 0.0030, 0); P(rr, z - 0.0048, 0)
P(0.0236, -0.1540, 0); P(0.0238, -0.1596, 0)
P(0.0244, -0.1600, 2)              # the steel bezel
P(0.0248, -0.1610, 2); P(0.0248, -0.1692, 2); P(0.0244, -0.1705, 2)
P(0.0222, -0.1709, 2); P(0.0210, -0.1700, 2)
P(0.0206, -0.1690, 4)              # the lens face (the game draws the glow over it)
P(0.0100, -0.1688, 4); P(0.0, -0.1688, 4)

def lathe(profile, segs, v_scale=0.86):
    """rings of the profile round Z; UV: u round, v along the profile"""
    prof = np.array([(p[0], p[1]) for p in profile])
    mats = [p[2] for p in profile]
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(prof, axis=0), axis=1))])
    s = s / s[-1] * v_scale
    verts, faces, uvs, fmats = [], [], [], []
    for i, (r, z) in enumerate(prof):
        for j in range(segs + 1):             # duplicate the seam column for UVs
            a = 2 * math.pi * j / segs
            verts.append((r * math.cos(a), r * math.sin(a), z))
    W = segs + 1
    for i in range(len(prof) - 1):
        for j in range(segs):
            a, b = i * W + j, i * W + j + 1
            c, d = (i + 1) * W + j + 1, (i + 1) * W + j
            faces.append((a, b, c, d))
            uvs.append([(j / segs, s[i]), ((j + 1) / segs, s[i]), ((j + 1) / segs, s[i + 1]), (j / segs, s[i + 1])])
            fmats.append(max(mats[i], mats[i + 1]))   # a transition takes the special material
    return verts, faces, uvs, fmats

def clip_geometry():
    """a pocket clip along the body: a thin strip bent round the tail cap"""
    w, t = 0.0034, 0.0009
    path = [(0.0172, 0.066), (0.0182, 0.050), (0.0185, 0.020), (0.0180, 0.004), (0.0170, -0.002)]
    verts, faces, uvs = [], [], []
    n = len(path)
    ang = math.radians(100.0)           # round the side, away from the thumb
    ca, sa = math.cos(ang), math.sin(ang)
    for i, (r, z) in enumerate(path):
        for (dr, dw) in ((0, -w), (0, w), (t, w), (t, -w)):
            rr = r + dr
            # position on the body at angle ang, offset sideways by dw
            verts.append((rr * ca - dw * sa, rr * sa + dw * ca, z))
    for i in range(n - 1):
        for k in range(4):
            a, b = i * 4 + k, i * 4 + (k + 1) % 4
            faces.append((a, b, b + 4, a + 4))
            uvs.append([(0.02 + 0.24 * k / 4, 0.90 + 0.09 * i / (n - 1)), (0.02 + 0.24 * (k + 1) / 4, 0.90 + 0.09 * i / (n - 1)),
                        (0.02 + 0.24 * (k + 1) / 4, 0.90 + 0.09 * (i + 1) / (n - 1)), (0.02 + 0.24 * k / 4, 0.90 + 0.09 * (i + 1) / (n - 1))])
    faces.append((0, 3, 2, 1)); uvs.append([(0.3, 0.9), (0.32, 0.9), (0.32, 0.92), (0.3, 0.92)])
    e = (n - 1) * 4
    faces.append((e, e + 1, e + 2, e + 3)); uvs.append([(0.3, 0.93), (0.32, 0.93), (0.32, 0.95), (0.3, 0.95)])
    return verts, faces, uvs

def build(name, segs):
    v, f, uv, fm = lathe(PROFILE, segs)
    cv, cf, cuv = clip_geometry()
    off = len(v)
    v = v + cv
    f = f + [tuple(i + off for i in face) for face in cf]
    uv = uv + cuv
    fm = fm + [5] * len(cf)
    ob = make_mesh(name, v, f, smooth=True)
    me = ob.data
    lay = me.uv_layers.new(name="uv")
    flat = [c for face in uv for c in face]
    lay.data.foreach_set("uv", np.array(flat, np.float32).ravel())
    at = me.attributes.new("mat", "FLOAT", "FACE")
    at.data.foreach_set("value", np.array(fm, np.float32))
    # hard edges where the profile turns sharply
    B.activate(ob)
    bpy.ops.object.shade_auto_smooth(angle=math.radians(40))
    for m in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)
    return ob

clear()
low = build("torch_low", 40)
high = build("torch_high", 160)

# ---- the material -------------------------------------------------------------------------
def torch_material():
    mat = bpy.data.materials.new("torch")
    mat.use_nodes = True
    nt = mat.node_tree
    N, L = nt.nodes, nt.links
    for n in list(N):
        N.remove(n)
    out = N.new("ShaderNodeOutputMaterial")
    tc = N.new("ShaderNodeTexCoord")
    geo = N.new("ShaderNodeNewGeometry")
    mat_at = N.new("ShaderNodeAttribute"); mat_at.attribute_name = "mat"; mat_at.attribute_type = "GEOMETRY"
    sepxyz = N.new("ShaderNodeSeparateXYZ"); L.new(tc.outputs["Object"], sepxyz.inputs[0])
    X, Y, Zc = sepxyz.outputs

    def m(op, a, b=None):
        n = N.new("ShaderNodeMath"); n.operation = op
        for sock, val in ((n.inputs[0], a), (n.inputs[1], b)):
            if val is None: continue
            if isinstance(val, (int, float)): sock.default_value = float(val)
            else: L.new(val, sock)
        return n.outputs[0]

    def is_mat(k):
        return m("LESS_THAN", m("ABSOLUTE", m("SUBTRACT", mat_at.outputs["Fac"], float(k))), 0.5)

    def mixc(fac, a, b):
        n = N.new("ShaderNodeMix"); n.data_type = "RGBA"
        for sock, val in ((n.inputs[0], fac), (n.inputs[6], a), (n.inputs[7], b)):
            if isinstance(val, tuple): sock.default_value = val + ((1.0,) if len(val) == 3 else ())
            elif isinstance(val, float): sock.default_value = val
            else: L.new(val, sock)
        return n.outputs[2]

    def noise(scale, detail=3.0):
        n = N.new("ShaderNodeTexNoise")
        n.inputs["Scale"].default_value = scale
        n.inputs["Detail"].default_value = detail
        L.new(tc.outputs["Object"], n.inputs["Vector"])
        return n.outputs["Fac"]

    # cylindrical coordinates: arc length round the body and z
    ang = m("ARCTAN2", Y, X)
    arc = m("MULTIPLY", ang, R)
    # diamond knurling: two helices crossing
    k = 2 * math.pi / 0.0016
    h1 = m("ABSOLUTE", m("SINE", m("MULTIPLY", m("ADD", arc, Zc), k)))
    h2 = m("ABSOLUTE", m("SINE", m("MULTIPLY", m("SUBTRACT", arc, Zc), k)))
    knurl = m("MINIMUM", h1, h2)                     # pyramids
    knurl = m("POWER", knurl, 0.6)
    is_knurl = is_mat(1)
    # wear: bare aluminium on raised edges (pointiness) and the knurl tips
    pt = m("SUBTRACT", geo.outputs["Pointiness"], 0.5)
    wearn = noise(900.0, 4.0)
    wear = m("MINIMUM", m("ADD", m("MULTIPLY", m("MULTIPLY", pt, 18.0), wearn), m("MULTIPLY", m("MULTIPLY", is_knurl, m("POWER", knurl, 8.0)), 0.8)), 1.0)
    wear = m("MAXIMUM", wear, 0.0)
    # colours (linear)
    anod = mixc(m("MULTIPLY", noise(300.0), 0.3), (0.018, 0.019, 0.022), (0.030, 0.031, 0.036))
    body = mixc(wear, anod, (0.36, 0.36, 0.37))
    body = mixc(m("MULTIPLY", m("SUBTRACT", 1.0, knurl), m("MULTIPLY", is_knurl, 0.6)), body, (0.008, 0.008, 0.009))
    steel = mixc(m("MULTIPLY", noise(1500.0), 0.5), (0.50, 0.50, 0.52), (0.62, 0.62, 0.64))
    rubber = mixc(m("MULTIPLY", noise(2000.0), 0.4), (0.012, 0.012, 0.012), (0.025, 0.025, 0.024))
    glass = (0.55, 0.55, 0.52)
    clip = mixc(m("MULTIPLY", wear, 0.3), (0.022, 0.022, 0.026), (0.30, 0.30, 0.32))
    col = body
    col = mixc(is_mat(2), col, steel)
    col = mixc(is_mat(3), col, rubber)
    col = mixc(is_mat(4), col, glass)
    col = mixc(is_mat(5), col, clip)
    # grime in the grooves: occlusion from the bake is multiplied in later
    em_alb = N.new("ShaderNodeEmission"); L.new(col, em_alb.inputs["Color"])
    # relief: knurling on the grip bands, a fine brushed grain elsewhere
    brushed = N.new("ShaderNodeTexNoise"); brushed.inputs["Scale"].default_value = 3000.0
    sc = N.new("ShaderNodeMapping"); sc.inputs["Scale"].default_value = (1.0, 1.0, 0.02)
    L.new(tc.outputs["Object"], sc.inputs[0]); L.new(sc.outputs[0], brushed.inputs["Vector"])
    height = m("ADD", m("MULTIPLY", knurl, is_knurl), m("MULTIPLY", brushed.outputs["Fac"], 0.08))
    bump = N.new("ShaderNodeBump")
    bump.inputs["Distance"].default_value = 0.00035
    L.new(height, bump.inputs["Height"])
    diff = N.new("ShaderNodeBsdfDiffuse"); L.new(bump.outputs["Normal"], diff.inputs["Normal"])
    # gloss
    gl = m("ADD", 0.55, m("MULTIPLY", wear, 0.3))
    gl = m("SUBTRACT", gl, m("MULTIPLY", is_knurl, 0.15))
    gl = m("ADD", m("MULTIPLY", gl, m("SUBTRACT", 1.0, is_mat(2))), m("MULTIPLY", is_mat(2), 0.92))
    gl = m("MULTIPLY", gl, m("SUBTRACT", 1.0, m("MULTIPLY", is_mat(3), 0.85)))
    em_gl = N.new("ShaderNodeEmission"); L.new(gl, em_gl.inputs["Color"])
    return mat, out, dict(albedo=em_alb.outputs[0], gloss=em_gl.outputs[0], normal=diff.outputs[0])

mat, out, shaders = torch_material()
high.data.materials.append(mat)
def use(which):
    L = mat.node_tree.links
    for l in list(out.inputs["Surface"].links):
        L.remove(l)
    L.new(shaders[which], out.inputs["Surface"])

img_alb = B.new_image("alb", RES)
use("albedo"); B.bake(high, low, "EMIT", img_alb, samples=4, extrusion=0.0008, ray_dist=0.002)
img_gl = B.new_image("gloss", RES, noncolor=True)
use("gloss"); B.bake(high, low, "EMIT", img_gl, samples=2, extrusion=0.0008, ray_dist=0.002)
img_n = B.new_image("nrm", RES, noncolor=True)
use("normal"); B.bake(high, low, "NORMAL", img_n, samples=4, extrusion=0.0008, ray_dist=0.002)
w = bpy.data.worlds.new("w"); bpy.context.scene.world = w
w.light_settings.distance = 0.006
img_ao = B.new_image("ao", RES // 2, noncolor=True)
B.bake(high, low, "AO", img_ao, samples=32, extrusion=0.0008, ray_dist=0.002)
B.finish(img_alb, img_n, img_gl, img_ao, os.path.join(OUT, "torch"), ao_amount=0.6)
B.write_bmsh(low, os.path.join(OUT, "torch.bmsh"))
print("done in %.0fs" % (time.time() - t0))
