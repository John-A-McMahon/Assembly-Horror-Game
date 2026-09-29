# preview_hand.py -- sculpt the hand and render it where the game holds the
# flashlight, to judge the shape before baking.
#   blender -b --factory-startup --python tools/blender/preview_hand.py -- out.png [close]
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import *
import hand

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out = os.path.abspath(argv[0] if argv else "preview_hand.png")
close = len(argv) > 1

clear()
import time; t0 = time.time()
F = hand.build_field()
print("TIME field %.1f" % (time.time() - t0))
v, f = F.mesh()
ob = make_mesh("hand", v, f)
fix_normals(ob)
print("TIME mesh %.1f" % (time.time() - t0))
mat = bpy.data.materials.new("skin")
mat.use_nodes = True
bsdf = mat.node_tree.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.62, 0.40, 0.31, 1)
bsdf.inputs["Roughness"].default_value = 0.5
bsdf.inputs["Subsurface Weight"].default_value = 0.3
bsdf.inputs["Subsurface Radius"].default_value = (0.004, 0.0015, 0.001)
ob.data.materials.append(mat)
# the flashlight body for context
import bmesh
bpy.ops.mesh.primitive_cylinder_add(radius=0.0157, depth=0.244, location=(0, 0, -0.048), vertices=48)
torch = bpy.context.active_object
dm = bpy.data.materials.new("metal")
dm.use_nodes = True
dm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.02, 0.02, 0.025, 1)
dm.node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 1.0
dm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.35
torch.data.materials.append(dm)

cam = game_camera(640, 360)
M = pose_matrix(ROT_TORCH, POS_TORCH)
ob.matrix_world = M
torch.matrix_world = M @ torch.matrix_world
cycles(20)
spot("key", (0.3, 0.6, 0.4), POS_TORCH, 40, 0.6)
spot("fill", (-0.5, -0.2, 0.2), POS_TORCH, 6, 1.0, (0.6, 0.7, 1.0))
spot("rim", (0.4, 0.1, -1.2), POS_TORCH, 20, 0.5)
from mathutils import Vector
views = {"close": (0.02, 0.10, 0.16), "side": (0.20, -0.02, 0.0), "top": (-0.05, 0.18, 0.02),
         "under": (0.05, -0.2, 0.05), "front": (-0.02, 0.03, -0.2), "tips": (-0.06, 0.12, 0.0), "thumb": (0.05, 0.12, -0.06)}
for vname in (argv[1:] or ["game"]):
    if vname == "zoom":
        cam.location = (0, 0, 0); cam.data.angle_y = math.radians(13)
        cam.rotation_euler = look_rot((0.185, -0.175, -0.31))
    elif vname == "game":
        cam.location = (0, 0, 0); cam.rotation_euler = (0, 0, 0); cam.data.angle_y = math.radians(72)
    else:
        off = Vector(views[vname])
        cam.location = Vector(POS_TORCH) + off
        cam.rotation_euler = look_rot(-off)
        cam.data.angle_y = math.radians(40)
    render(out.replace(".png", "_" + vname + ".png"))
