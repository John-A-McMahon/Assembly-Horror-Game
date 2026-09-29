# make_hand.py -- sculpt, detail and bake the player's hand into assets/:
#   hand.bmsh, hand_albedo.png, hand_normal.png
#
#   "C:/Program Files/Blender Foundation/Blender 5.0/blender.exe" -b --factory-startup \
#       --python tools/blender/make_hand.py -- [texture size] [low-poly triangles]
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import clear, make_mesh, fix_normals
import bake as B
import hand

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RES = int(argv[0]) if len(argv) > 0 else 1024
TRIS = int(argv[1]) if len(argv) > 1 else 4500
os.makedirs(OUT, exist_ok=True)
t0 = time.time()

# ---- shape -------------------------------------------------------------------------
clear()
F = hand.build_field()
v, f = F.mesh()
low = make_mesh("hand_low", v, f)
fix_normals(low)
high = make_mesh("hand_high", v, f)
fix_normals(high)
B.subdivide(high, 1)
co, no = B.mesh_arrays(high)
disp, masks = hand.details(co, no)
B.set_coords(high, co + no * disp[:, None])
B.add_point_colour(high, "masks", np.stack([masks["nail"], masks["red"], masks["lunula"], masks["crease"]], 1))
print("high", len(high.data.polygons), "faces  %.0fs" % (time.time() - t0))
B.decimate(low, TRIS)
B.unwrap(low)
# the grip, so the fingers get contact shadows in the AO bake
bpy.ops.mesh.primitive_cylinder_add(radius=hand.GRIP_R, depth=0.30, location=(0, 0, -0.03), vertices=64)
grip = bpy.context.active_object

# ---- the skin material on the dense mesh ----------------------------------------------
def skin_material():
    mat = bpy.data.materials.new("skin")
    mat.use_nodes = True
    nt = mat.node_tree
    N, L = nt.nodes, nt.links
    for n in list(N):
        N.remove(n)
    out = N.new("ShaderNodeOutputMaterial")
    tc = N.new("ShaderNodeTexCoord")
    attr = N.new("ShaderNodeAttribute"); attr.attribute_name = "masks"
    sep = N.new("ShaderNodeSeparateColor"); L.new(attr.outputs["Color"], sep.inputs[0])
    nail, red, lun = sep.outputs[0], sep.outputs[1], sep.outputs[2]
    crease = attr.outputs["Alpha"]

    def noise(scale, detail=4.0, rough=0.55, dist=0.0):
        n = N.new("ShaderNodeTexNoise")
        n.inputs["Scale"].default_value = scale
        n.inputs["Detail"].default_value = detail
        n.inputs["Roughness"].default_value = rough
        n.inputs["Distortion"].default_value = dist
        L.new(tc.outputs["Object"], n.inputs["Vector"])
        return n.outputs["Fac"]

    def mix(fac, a, b, blend="MIX"):
        m = N.new("ShaderNodeMix"); m.data_type = "RGBA"; m.blend_type = blend
        for sock, val in ((m.inputs[0], fac), (m.inputs[6], a), (m.inputs[7], b)):
            if isinstance(val, (tuple, list)):
                sock.default_value = tuple(val) + ((1.0,) if len(val) == 3 else ())
            elif isinstance(val, float):
                sock.default_value = val
            else:
                L.new(val, sock)
        return m.outputs[2]

    def math_(op, a, b=None, clamp=False):
        m = N.new("ShaderNodeMath"); m.operation = op; m.use_clamp = clamp
        for sock, val in ((m.inputs[0], a), (m.inputs[1], b)):
            if val is None:
                continue
            if isinstance(val, float):
                sock.default_value = val
            else:
                L.new(val, sock)
        return m.outputs[0]

    def ramp(fac, stops):
        r = N.new("ShaderNodeValToRGB")
        L.new(fac, r.inputs[0])
        el = r.color_ramp.elements
        el[0].position, el[0].color = stops[0][0], tuple(stops[0][1]) + (1,)
        el[1].position, el[1].color = stops[-1][0], tuple(stops[-1][1]) + (1,)
        for pos, col in stops[1:-1]:
            e = el.new(pos); e.color = tuple(col) + (1,)
        return r.outputs[0]

    # ---- albedo (linear) ----
    base = ramp(noise(160.0, 5.0, 0.6), [(0.30, (0.58, 0.36, 0.27)), (0.55, (0.62, 0.39, 0.29)),
                                        (0.75, (0.63, 0.37, 0.28))])
    fine = noise(600.0, 3.0, 0.5)
    c = mix(math_("MULTIPLY", math_("SUBTRACT", fine, 0.5), 0.25), base, (0.68, 0.48, 0.40), "MIX")
    # blotchy redness and a cooler, bluish cast where veins sit near the surface
    blot = math_("POWER", noise(90.0, 3.0, 0.5), 3.0)
    c = mix(math_("MULTIPLY", blot, 0.45), c, (0.58, 0.28, 0.22))
    veins = math_("SUBTRACT", 1.0, math_("ABSOLUTE", math_("SUBTRACT", noise(55.0, 2.0, 0.4, 0.6), 0.5)))
    veins = math_("POWER", veins, 26.0)
    c = mix(math_("MULTIPLY", veins, 0.30), c, (0.30, 0.25, 0.33))
    # freckles
    vor = N.new("ShaderNodeTexVoronoi"); vor.inputs["Scale"].default_value = 520.0
    L.new(tc.outputs["Object"], vor.inputs["Vector"])
    frk = math_("MULTIPLY", math_("LESS_THAN", vor.outputs["Distance"], 0.11),
                math_("GREATER_THAN", noise(40.0, 2.0), 0.58))
    c = mix(math_("MULTIPLY", frk, 0.35), c, (0.24, 0.11, 0.07))
    # knuckles and fingertips flush red, creases shadowed
    c = mix(math_("MULTIPLY", red, 0.45), c, (0.56, 0.26, 0.21))
    c = mix(math_("MULTIPLY", crease, 0.55), c, (0.20, 0.08, 0.06))
    # nails: pink over the bed, the pale half-moon at the cuticle
    nailc = mix(lun, (0.55, 0.34, 0.31), (0.74, 0.60, 0.56))
    nailc = mix(math_("MULTIPLY", noise(700.0, 2.0), 0.25), nailc, (0.70, 0.56, 0.52))
    c = mix(nail, c, nailc)
    albedo = c

    # ---- relief: pores and fine lines, none on the nails ----
    vp = N.new("ShaderNodeTexVoronoi"); vp.inputs["Scale"].default_value = 1500.0
    L.new(tc.outputs["Object"], vp.inputs["Vector"])
    pores = math_("MINIMUM", math_("MULTIPLY", vp.outputs["Distance"], 3.2), 1.0)
    lines = ramp(noise(1800.0, 2.0, 0.5, 1.2), [(0.45, (1, 1, 1)), (0.5, (0.6, 0.6, 0.6)), (0.55, (1, 1, 1))])
    bw = N.new("ShaderNodeRGBToBW"); L.new(lines, bw.inputs[0])
    height = math_("MULTIPLY", pores, bw.outputs[0])
    height = math_("MULTIPLY", height, math_("SUBTRACT", 1.0, nail))
    bump = N.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = 0.00004
    L.new(height, bump.inputs["Height"])
    diff = N.new("ShaderNodeBsdfDiffuse")
    L.new(bump.outputs["Normal"], diff.inputs["Normal"])

    # ---- gloss: oilier on knuckles, shiny nails, dull in the pores ----
    gloss = math_("ADD", 0.30, math_("MULTIPLY", red, 0.12))
    gloss = math_("ADD", gloss, math_("MULTIPLY", math_("SUBTRACT", pores, 1.0), 0.15))
    gloss = math_("ADD", math_("MULTIPLY", gloss, math_("SUBTRACT", 1.0, nail)), math_("MULTIPLY", nail, 0.85))

    em_alb = N.new("ShaderNodeEmission"); L.new(albedo, em_alb.inputs["Color"])
    em_gl = N.new("ShaderNodeEmission"); L.new(gloss, em_gl.inputs["Color"])
    return mat, out, dict(albedo=em_alb.outputs[0], gloss=em_gl.outputs[0], normal=diff.outputs[0])

mat, out, shaders = skin_material()
high.data.materials.append(mat)

def use(which):
    L = mat.node_tree.links
    for l in list(out.inputs["Surface"].links):
        L.remove(l)
    L.new(shaders[which], out.inputs["Surface"])

# ---- bakes ----------------------------------------------------------------------------
grip.hide_render = True
img_alb = B.new_image("alb", RES)
use("albedo"); B.bake(high, low, "EMIT", img_alb, samples=4)
img_gl = B.new_image("gloss", RES // 2, noncolor=True)
use("gloss"); B.bake(high, low, "EMIT", img_gl, samples=2)
img_n = B.new_image("nrm", RES, noncolor=True)
use("normal"); B.bake(high, low, "NORMAL", img_n, samples=4)
grip.hide_render = False
w = bpy.data.worlds.new("w"); bpy.context.scene.world = w
w.light_settings.distance = 0.018
img_ao = B.new_image("ao", RES // 2, noncolor=True)
B.bake(high, low, "AO", img_ao, samples=48)

# gloss is half size: resize into the normal map's alpha
gl = B.pixels(img_gl)
gl_big = B.upscale(gl, RES, RES)
img_gl2 = B.new_image("gloss2", RES, noncolor=True)
img_gl2.pixels.foreach_set(gl_big.astype(np.float32).ravel())
B.finish(img_alb, img_n, img_gl2, img_ao, os.path.join(OUT, "hand"), ao_amount=0.7)
B.write_bmsh(low, os.path.join(OUT, "hand.bmsh"))
print("done in %.0fs" % (time.time() - t0))
