# preview_asset.py -- render exported game assets (assets/*.bmsh + albedo)
# from the game's camera, held where hands.asm holds the flashlight: a check
# of what the game will load, independent of the game's shader.
#   blender -b --factory-startup --python tools/blender/preview_asset.py -- out.png hand sleeve torch
import sys, os, math, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from scene import *

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))
argv = sys.argv[sys.argv.index("--") + 1:]
out = os.path.abspath(argv[0])
names = argv[1:]

def load_bmsh(name):
    with open(os.path.join(ASSETS, name + ".bmsh"), "rb") as f:
        assert f.read(4) == b"BMSH"
        n = struct.unpack("<I", f.read(4))[0]
        a = np.frombuffer(f.read(n * 32), np.float32).reshape(n, 8)
    faces = [(i, i + 1, i + 2) for i in range(0, n, 3)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(a[:, :3].tolist(), [], faces)
    uv = me.uv_layers.new(name="uv")
    uv.data.foreach_set("uv", np.stack([a[:, 6], 1.0 - a[:, 7]], 1).astype(np.float32).ravel())
    me.shade_smooth()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(os.path.join(ASSETS, name + "_albedo.png"))
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    me.materials.append(mat)
    return ob

clear()
M = pose_matrix(ROT_TORCH, POS_TORCH)
for n in names:
    ob = load_bmsh(n)
    ob.matrix_world = M
cam = game_camera(960, 540)
cycles(24)
spot("key", (0.0, 0.3, 0.2), POS_TORCH, 25, 0.5)
spot("fill", (-0.5, -0.2, 0.2), POS_TORCH, 6, 1.0, (0.6, 0.7, 1.0))
render(out)
