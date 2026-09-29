# bake.py -- turn a dense sculpt into a game asset: a low-poly mesh with UVs
# (the .bmsh the game loads) and textures baked from the dense one in Cycles:
#   <name>_albedo.png   colour (sRGB), ambient occlusion multiplied in
#   <name>_normal.png   tangent-space normal (+Y = +t, the game's texture
#                       rows run top to bottom); alpha = gloss
#
# .bmsh: "BMSH", uint32 vertex count, then per vertex 8 floats:
#        position xyz, normal xyz, u, t -- plain triangles, no index buffer.
import bpy, bmesh, struct, math, os
import numpy as np

def mesh_arrays(ob):
    me = ob.data
    n = len(me.vertices)
    co = np.zeros(n * 3); me.vertices.foreach_get("co", co)
    no = np.zeros(n * 3); me.vertices.foreach_get("normal", no)
    return co.reshape(-1, 3), no.reshape(-1, 3)

def set_coords(ob, co):
    ob.data.vertices.foreach_set("co", np.asarray(co, np.float64).ravel())
    ob.data.update()

def add_point_colour(ob, name, cols):
    """cols (N,4) floats per vertex"""
    me = ob.data
    at = me.color_attributes.new(name, "FLOAT_COLOR", "POINT")
    at.data.foreach_set("color", np.asarray(cols, np.float32).ravel())

def activate(ob, others=()):
    bpy.ops.object.select_all(action="DESELECT")
    for o in others:
        o.select_set(True)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob

def subdivide(ob, levels=1):
    activate(ob)
    m = ob.modifiers.new("sub", "SUBSURF")
    m.levels = levels
    m.render_levels = levels
    bpy.ops.object.modifier_apply(modifier=m.name)

def decimate(ob, faces):
    activate(ob)
    cur = len(ob.data.polygons)
    m = ob.modifiers.new("dec", "DECIMATE")
    m.ratio = min(1.0, faces / max(cur, 1))
    m.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=m.name)
    tri = ob.modifiers.new("tri", "TRIANGULATE")
    bpy.ops.object.modifier_apply(modifier=tri.name)
    print("decimated", cur, "->", len(ob.data.polygons))

def unwrap(ob, margin=0.004, angle=62.0):
    activate(ob)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin,
                             area_weight=0.0, correct_aspect=True, scale_to_bounds=True)
    bpy.ops.uv.pack_islands(rotate=True, margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")

def new_image(name, res, noncolor=False, alpha=True):
    img = bpy.data.images.new(name, res, res, alpha=alpha, float_buffer=False)
    img.colorspace_settings.name = "Non-Color" if noncolor else "sRGB"
    return img

def bake_target_material(low, img):
    """the low mesh's material: just an active image node to bake into"""
    mat = bpy.data.materials.new("bake_" + img.name)
    mat.use_nodes = True
    nt = mat.node_tree
    node = nt.nodes.new("ShaderNodeTexImage")
    node.image = img
    nt.nodes.active = node
    low.data.materials.clear()
    low.data.materials.append(mat)

def bake(high, low, kind, img, samples=1, extrusion=0.0015, margin=16, ray_dist=0.004):
    """bake high's shading onto low's UVs; high=None bakes low's own material
    onto itself (its details are all in the shader, none in a denser mesh)"""
    sc = bpy.context.scene
    if high is None:
        return self_bake(low, kind, img, samples, margin)
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    bake_target_material(low, img)
    activate(low, [high])
    rb = sc.render.bake
    rb.use_selected_to_active = True
    rb.cage_extrusion = extrusion
    rb.max_ray_distance = ray_dist
    rb.margin = margin
    rb.margin_type = "EXTEND"
    rb.use_clear = True
    rb.normal_space = "TANGENT"
    kw = {}
    if kind == "NORMAL":
        kw = dict(normal_space="TANGENT", normal_r="POS_X", normal_g="POS_Y", normal_b="POS_Z")
    import time; t = time.time()
    bpy.ops.object.bake(type=kind, use_selected_to_active=True, cage_extrusion=extrusion,
                        max_ray_distance=ray_dist, margin=margin, use_clear=True, **kw)
    print("baked", kind, img.size[0], "in %.0fs" % (time.time() - t))

def self_bake(ob, kind, img, samples, margin):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    for mat in ob.data.materials:
        nt = mat.node_tree
        node = nt.nodes.get("bake_target") or nt.nodes.new("ShaderNodeTexImage")
        node.name = "bake_target"
        node.image = img
        nt.nodes.active = node
    activate(ob)
    kw = {}
    if kind == "NORMAL":
        kw = dict(normal_space="TANGENT", normal_r="POS_X", normal_g="POS_Y", normal_b="POS_Z")
    import time; t = time.time()
    bpy.ops.object.bake(type=kind, use_selected_to_active=False, margin=margin, use_clear=True, **kw)
    print("baked", kind, img.size[0], "(self) in %.0fs" % (time.time() - t))

def pixels(img):
    a = np.zeros(img.size[0] * img.size[1] * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(img.size[1], img.size[0], 4)

def save_png(arr, path, noncolor=False):
    h, w, _ = arr.shape
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=True, float_buffer=False)
    img.colorspace_settings.name = "Non-Color" if noncolor else "sRGB"
    img.pixels.foreach_set(np.clip(arr, 0, 1).astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    bpy.context.scene.render.image_settings.compression = 100
    img.save()
    print("wrote", path)

def upscale(arr, w, h):
    """nearest-ish bilinear resize for a small AO bake"""
    sh, sw = arr.shape[:2]
    ys = np.linspace(0, sh - 1, h); xs = np.linspace(0, sw - 1, w)
    y0 = np.floor(ys).astype(int); x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, sh - 1); x1 = np.minimum(x0 + 1, sw - 1)
    fy = (ys - y0)[:, None, None]; fx = (xs - x0)[None, :, None]
    a = arr[y0][:, x0] * (1 - fx) + arr[y0][:, x1] * fx
    b = arr[y1][:, x0] * (1 - fx) + arr[y1][:, x1] * fx
    return a * (1 - fy) + b * fy

def write_bmsh(ob, path):
    me = ob.data
    me.calc_loop_triangles()
    uv = me.uv_layers.active.data
    cn = me.corner_normals
    out = []
    for tri in me.loop_triangles:
        for li in tri.loops:
            lp = me.loops[li]
            p = me.vertices[lp.vertex_index].co
            n = cn[li].vector
            u, v = uv[li].uv
            out.append((p.x, p.y, p.z, n.x, n.y, n.z, u, 1.0 - v))
    arr = np.asarray(out, np.float32)
    with open(path, "wb") as fh:
        fh.write(b"BMSH")
        fh.write(struct.pack("<I", len(arr)))
        fh.write(arr.tobytes())
    print("wrote", path, len(arr) // 3, "triangles", os.path.getsize(path) // 1024, "KB")

def finish(albedo_img, normal_img, gloss_img, ao_img, out_prefix, ao_amount=0.85):
    """albedo * AO -> <prefix>_albedo.png; normal (green flipped for the
    game's top-down rows) + gloss in alpha -> <prefix>_normal.png"""
    A = pixels(albedo_img)
    res = A.shape[0]
    if ao_img is not None:
        ao = pixels(ao_img)[..., :1]
        if ao.shape[0] != res:
            ao = upscale(ao, res, res)
        A[..., :3] *= (1.0 - ao_amount) + ao_amount * ao
    A[..., 3] = 1.0
    save_png(A, out_prefix + "_albedo.png")
    N = pixels(normal_img)
    N[..., 1] = 1.0 - N[..., 1]
    N[..., 3] = pixels(gloss_img)[..., 0] if gloss_img is not None else 0.3
    save_png(N, out_prefix + "_normal.png", noncolor=True)
