extends Object
class_name MMMapGenerator


static var mesh_maps : Dictionary = {}
static var debug_index : int = 0

static var error_texture : MMTexture


const SHADERS_PATH : String = "res://addons/material_maker/map_generator"
const MAP_DEFINITIONS : Dictionary = {
	position = {
		type="simple",
		vertex = "position_vertex",
		fragment = "common_fragment",
		postprocess=["dilate"]
	},
	normal = { type="simple", vertex = "normal_vertex", fragment = "normal_fragment", postprocess=["dilate"] },
	tangent = { type="simple", vertex = "tangent_vertex", fragment = "normal_fragment", postprocess=["dilate"] },
	ambient_occlusion = { type="bvh", vertex = "ao_vertex", fragment = "ao_fragment", mode=0, postprocess=["dilate"] },
	bent_normals = { type="bvh", vertex = "ao_vertex", fragment = "ao_fragment", mode=1, postprocess=["dilate"] },
	thickness = { type="bvh", vertex = "ao_vertex", fragment = "ao_fragment", mode=2, postprocess=["dilate"] },
	curvature = { type="curvature", vertex = "curvature_vertex", fragment = "common_fragment", postprocess=["dilate"] },
	seams = { type="simple", vertex = "position_vertex", fragment = "common_fragment", postprocess=["seams_1", "seams_2"] },
	adjacency = { type="adjacency", vertex = "normal_vertex", fragment = "common_fragment", postprocess=["adjacency_dilate"] },
}


class DefaultProgress:
	var text : String
	var progress : int = 0
	
	func set_text(t : String):
		text = t
	
	func set_progress(v : float):
		if int(v*100.0) > progress:
			progress = int(v*100.0)
			print(text+" ("+str(progress)+"%)")


class UIProgress:
	var text : String
	var progress : int = 0
	
	func set_text(t : String):
		text = t
	
	func set_progress(v : float):
		if int(v*100.0) > progress:
			progress = int(v*100.0)
			mm_globals.main_window.set_tip_text(text+" ("+str(progress)+"%)", 0.0 if (progress >= 100) else 1.0)


static func generate(mesh : Mesh, map : String, size : int, texture : MMTexture):
	assert(mesh != null)
	print("Generating %s map for mesh %s" % [ map, str(mesh) ])
	var progress
	if mm_globals.main_window:
		progress = UIProgress.new()
	else:
		progress = DefaultProgress.new()
	progress.set_text("Generating "+map+" map")
	progress.set_progress(0)
	var pixels : int = size/4
	var map_definition : Dictionary = MAP_DEFINITIONS[map]
	var mesh_pipeline : MMMeshRenderingPipeline = MMMeshRenderingPipeline.new()
	var vertex_shader : String = load(SHADERS_PATH+"/"+map_definition.vertex+".tres").text
	var fragment_shader : String = load(SHADERS_PATH+"/"+map_definition.fragment+".tres").text
	match map_definition.type:
		"simple":
			mesh_pipeline.mesh = mesh
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			await mesh_pipeline.render(Vector2i(size, size), 3, texture)
		"curvature":
			var curvature_generator : MMCurvatureGenerator = MMCurvatureGenerator.new()
			var thread : Thread = Thread.new()
			thread.start(curvature_generator.generate.bind(mesh))
			while thread.is_alive():
				await mm_globals.get_tree().process_frame
				progress.set_progress(curvature_generator.get_progress())
			mesh_pipeline.mesh = thread.wait_to_finish()
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			await mesh_pipeline.render(Vector2i(size, size), 3, texture)
		"adjacency":
			var adjacency_generator : MMAdjacencyGenerator = MMAdjacencyGenerator.new()
			var thread : Thread = Thread.new()
			thread.start(adjacency_generator.generate.bind(mesh))
			while thread.is_alive():
				await mm_globals.get_tree().process_frame
				progress.set_progress(adjacency_generator.get_progress())
			mesh_pipeline.mesh = thread.wait_to_finish()
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			await mesh_pipeline.render(Vector2i(size, size), 3, texture)
		"bvh":
			mesh_pipeline.mesh = mesh
			var bvh : MMTexture = MMTexture.new()
			bvh.set_texture(MMBvhGenerator.generate(mesh))
			var ray_count = mm_globals.get_config("bake_ray_count")
			var ao_ray_dist = -mesh.get_aabb().size.length() if map == "thickness" else mm_globals.get_config("bake_ao_ray_dist")
			var ao_ray_bias = mm_globals.get_config("bake_ao_ray_bias")
			var denoise_radius = mm_globals.get_config("bake_denoise_radius")
			mesh_pipeline.add_parameter_or_texture("bvh_data", "sampler2D", bvh)
			mesh_pipeline.add_parameter_or_texture("prev_iteration_tex", "sampler2D", texture)
			mesh_pipeline.add_parameter_or_texture("max_dist", "float", ao_ray_dist)
			mesh_pipeline.add_parameter_or_texture("bias_dist", "float", ao_ray_bias)
			mesh_pipeline.add_parameter_or_texture("iteration", "int", 1)
			mesh_pipeline.add_parameter_or_texture("mode", "int", map_definition.mode)
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			print("Casting %d rays..." % ray_count)
			for i in range(ray_count):
				progress.set_progress(float(i)/ray_count)
				mesh_pipeline.set_parameter("iteration", i+1)
				mesh_pipeline.set_parameter("prev_iteration_tex", texture)
				await mesh_pipeline.render(Vector2i(size, size), 3, texture)
			
			if map == "bent_normals":
				print("Normalizing...")
				var normalize_pipeline : MMComputeShader = MMComputeShader.new()
				normalize_pipeline.clear()
				normalize_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
				await normalize_pipeline.set_shader(load("res://addons/material_maker/map_generator/normalize_compute.tres").text, 3)
				await normalize_pipeline.render(texture, Vector2i(size, size))
			
			# Denoise
			if true:
				print("Denoising...")
				var denoise_pipeline : MMComputeShader = MMComputeShader.new()
				denoise_pipeline.clear()
				denoise_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
				denoise_pipeline.add_parameter_or_texture("radius", "int", 3)
				await denoise_pipeline.set_shader(load("res://addons/material_maker/map_generator/denoise_compute.tres").text, 3)
				await denoise_pipeline.render(texture, Vector2i(size, size))

	# Extend the map past seams
	if pixels > 0 and map_definition.has("postprocess"):
		print("Postprocessing...")
		#texture.save_to_file("d:/debug_x_%d.png" % debug_index)
		debug_index += 1
		for p in map_definition.postprocess:
			var postprocess_pipeline : MMComputeShader = MMComputeShader.new()
			postprocess_pipeline.clear()
			postprocess_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
			postprocess_pipeline.add_parameter_or_texture("pixels", "int", pixels)
			match p:
				"adjacency_dilate", "dilate":
					var seams_map : MMTexture = await get_map(mesh, "seams", false, true)
					postprocess_pipeline.add_parameter_or_texture("seams_map", "sampler2D", seams_map)
			await postprocess_pipeline.set_shader(load("res://addons/material_maker/map_generator/"+p+"_compute.tres").text, 3)
			await postprocess_pipeline.render(texture, Vector2i(size, size))
			#texture.save_to_file("d:/debug_%d.png" % debug_index)
			debug_index += 1
		progress.set_progress(1.0)

static var busy : bool = false

static func get_map(mesh : Mesh, map : String, force_generate : bool = false, parallel : bool = false) -> MMTexture:
	if mesh == null:
		if error_texture == null:
			error_texture = MMTexture.new()
			var image : Image = Image.create(1, 1, 0, Image.FORMAT_RGBAH)
			image.fill(Color(1.0, 0.0, 0.0))
			error_texture.set_texture(ImageTexture.create_from_image(image))
		return error_texture
	if ! mesh_maps.has(mesh):
		mesh_maps[mesh] = {}
	if force_generate:
		mesh_maps[mesh].erase(map)
	while true:
		if mesh_maps[mesh].has(map):
			break
		if parallel or not busy:
			busy = true
			var texture : MMTexture = MMTexture.new()
			mesh_maps[mesh][map] = texture
			await generate(mesh, map, 2048, texture)
			busy = false
			break
		await mm_globals.get_tree().process_frame
	return mesh_maps[mesh][map] as MMTexture
