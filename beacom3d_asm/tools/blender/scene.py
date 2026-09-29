# scene.py -- Blender helpers shared by the asset scripts: meshes from numpy,
# the game's first-person camera, preview renders.
import bpy, math
import numpy as np
from mathutils import Matrix

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def make_mesh(name, verts, faces, smooth=True):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.validate()
    me.update()
    if smooth:
        me.shade_smooth()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob

def fix_normals(ob):
    """make the faces point outward"""
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    ob.select_set(False)

def pose_matrix(cols, pos, mirror=False):
    """hands.asm's place(): world = pos + R * S * local, R given as 3 columns"""
    R = np.array(cols, np.float64).reshape(3, 3).T      # columns -> matrix
    M = np.eye(4)
    M[:3, :3] = R
    if mirror:
        M[:3, 0] *= -1.0
    M[:3, 3] = pos
    return Matrix(M.tolist())

ROT_TORCH = (0.990, -0.139, 0.0, 0.139, 0.990, 0.0, 0.0, 0.0, 1.0)
POS_TORCH = (0.195, -0.195, -0.33)
ROT_GUN = (0.990, 0.139, 0.0, -0.139, 0.990, 0.0, 0.0, 0.0, 1.0)
POS_GUN = (-0.20, -0.21, -0.37)

def game_camera(w=1280, h=720, fov_deg=72.0):
    """the game's camera at the origin looking down -Z, +Y up"""
    cam = bpy.data.cameras.new("cam")
    cam.sensor_fit = "VERTICAL"
    cam.angle_y = math.radians(fov_deg)
    cam.clip_start = 0.01
    ob = bpy.data.objects.new("cam", cam)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    sc = bpy.context.scene
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    return ob

def spot(name, loc, target, energy, size=0.3, color=(1, 0.94, 0.84), spot_deg=None):
    kind = "SPOT" if spot_deg else "AREA"
    L = bpy.data.lights.new(name, kind)
    L.energy = energy
    L.color = color
    if kind == "AREA":
        L.size = size
    else:
        L.spot_size = math.radians(spot_deg)
        L.shadow_soft_size = size
    ob = bpy.data.objects.new(name, L)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    d = np.asarray(target) - np.asarray(loc)
    from mathutils import Vector
    ob.rotation_euler = Vector(d).to_track_quat("-Z", "Y").to_euler()
    return ob

def cycles(samples=64, device="CPU"):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = samples
    sc.cycles.device = device
    sc.cycles.use_denoising = True
    sc.view_settings.view_transform = "AgX" if "AgX" in [i.identifier for i in
        sc.view_settings.bl_rna.properties["view_transform"].enum_items] else "Filmic"
    w = bpy.data.worlds.new("w")
    w.color = (0.02, 0.02, 0.025)
    sc.world = w

def render(path):
    bpy.context.scene.render.filepath = path
    bpy.context.scene.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)

def look_rot(direction, up=(0.0, 1.0, 0.0)):
    """camera rotation looking along direction with +Y up (the game's convention)"""
    from mathutils import Matrix, Vector
    f = Vector(direction).normalized()
    r = f.cross(Vector(up)).normalized()
    u = r.cross(f)
    return Matrix((r, u, -f)).transposed().to_euler()
