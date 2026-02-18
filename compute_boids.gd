extends TextureRect

# CONFIG
var compute_texture_size :int= 256 # Holds up to 256*256 pixel particles
var viewport_size :int= 800 # 944
var shader_local_size_x := 16
var shader_local_size_y := 16
@onready var image_size = compute_texture_size
var zone_size_mult : int = 32 # wrap around border world size

# STARTUP
var boids_count : int = 1024 * 10
var start_boids_count : int = boids_count

# BOIDS PARAMETERS
var dt : float = 0.1 #0.25
var paused_dt : float = dt # only used for pause/resume feature
var vision_radius : float = 100.0
var alignment_force : float = 1.0
var cohesion_force : float = 1.0
var separation_force : float = 1.0
var steering_force : float = 5.0
var min_speed : float = 0.5
var max_speed : float = 6.0
var drag : float = 0.98
var movement_randomness : float = 0.2
var movement_scaling : float = 1.0

# DRAW
var draw_radius : float = 20.0

# CAMERA
var camera_center : Vector2 = Vector2.ZERO
var zoom : float = 0.5 #0.82
const MIN_ZOOM := 0.1
const MAX_ZOOM := 5.0

# RENDERER SETUP
var rdmain := RenderingServer.get_rendering_device()
var textureRD: Texture2DRD
var shader : RID
var pipeline : RID
var fmt := RDTextureFormat.new()
var view := RDTextureView.new()
var input_particles : RID
var output_particles : RID
var multimesh := MultiMesh.new()
var quadmesh := QuadMesh.new()
var render_material := ShaderMaterial.new()

func _ready():
	randomize()

	fmt.width = compute_texture_size
	fmt.height = compute_texture_size
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
					| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
					| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
					| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT \
					| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	view = RDTextureView.new()
	textureRD = Texture2DRD.new()
	
	RenderingServer.call_on_render_thread(restart_simulation)

func _exit_tree():
	if textureRD:
		textureRD.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_compute_resources)

func _free_compute_resources():
	if input_particles:
		rdmain.free_rid(input_particles)
	if output_particles:
		rdmain.free_rid(output_particles)
	if shader:
		rdmain.free_rid(shader)
	# TODO: consider other RIDs

func restart_simulation():
	boids_count = start_boids_count

	# Build new random boids
	var start_data : Dictionary = StartupManager.build_random_boids(self)
	rebuild_buffers(start_data)

func rebuild_buffers(data: Dictionary):
	var img_particles := Image.create(
		compute_texture_size,
		compute_texture_size,
		false,
		Image.FORMAT_RGBAF
	)

	for i in boids_count:
		var x :int= i % compute_texture_size
		@warning_ignore("integer_division")
		var y :int= i / compute_texture_size
		img_particles.set_pixel(
			x, y,
			Color(data["pos"][i].x, data["pos"][i].y, data["vel"][i].x, data["vel"][i].y)
		)

	var data_particles := img_particles.get_data()
	input_particles = rdmain.texture_create(fmt, RDTextureView.new(), [data_particles])
	output_particles = rdmain.texture_create(fmt, RDTextureView.new(), [data_particles])

	# Output texture
	textureRD.texture_rd_rid = output_particles

	# multimesh/instance/mesh/material
	#var mask :GradientTexture2D= preload("res://grad2d_softcircle_mask.tres")
	var mask :Texture2D= preload("res://triangle.png")
	render_material.shader = preload("res://particle_draw.gdshader")
	render_material.set_shader_parameter("alpha_tex", mask)
	render_material.set_shader_parameter("particle_buffer", textureRD)
	render_material.set_shader_parameter("camera_center", camera_center)
	render_material.set_shader_parameter("zoom", zoom)
	render_material.set_shader_parameter("compute_texture_size", compute_texture_size)
	render_material.set_shader_parameter("min_speed", min_speed)
	render_material.set_shader_parameter("max_speed", max_speed)
	render_material.set_shader_parameter("viewport_size", Vector2(viewport_size, viewport_size))
	%MMI.material = render_material # 2D

	quadmesh.size = Vector2.ONE
	multimesh.instance_count = 0 # can only set other values when instance_count==0
	multimesh.mesh = quadmesh
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = false
	multimesh.use_custom_data = false
	multimesh.instance_count = boids_count # actual point count
	for i in range(boids_count):
		multimesh.set_instance_transform_2d(i, Transform2D())

	%MMI.multimesh = multimesh

	# SHADER + PIPELINE
	var shader_file := load("res://compute_boids.glsl") as RDShaderFile
	shader = rdmain.shader_create_from_spirv(shader_file.get_spirv())
	pipeline = rdmain.compute_pipeline_create(shader)

func compute_stage(_run_mode:int,input_set,output_set):
	var global_size_x : int
	var global_size_y : int
	
	# Dispatch group size
	global_size_x = int(ceil(float(compute_texture_size) / float(shader_local_size_x)))
	global_size_y = int(ceil(float(compute_texture_size) / float(shader_local_size_y)))
	
	var compute_list := rdmain.compute_list_begin()
	rdmain.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rdmain.compute_list_bind_uniform_set(compute_list, input_set, 0)
	rdmain.compute_list_bind_uniform_set(compute_list, output_set, 1)
	
	# PUSH CONSTANT PARAMETERS
	var params := PackedFloat32Array([
		dt,
		float(boids_count),
		compute_texture_size,
		vision_radius,
		alignment_force,
		cohesion_force,
		separation_force,
		steering_force,
		min_speed,
		max_speed,
		drag,
		movement_randomness,
		movement_scaling,
		float(image_size),
		float(zone_size_mult),
		0.0
	])
	var params_bytes := PackedByteArray()
	params_bytes.append_array(params.to_byte_array())
	rdmain.compute_list_set_push_constant(compute_list, params_bytes, params_bytes.size())

	# finish list and proceed to compute
	rdmain.compute_list_dispatch(compute_list, global_size_x, global_size_y, 1)
	rdmain.compute_list_end()

func _process(_delta):
	RenderingServer.call_on_render_thread(run_simulation)

func run_simulation():
	# Flip buffers via uniformsets
	var frame_flip = flip_buffers()
	var input_set  = frame_flip[0]
	var output_set = frame_flip[1]
	
	# RUN SIM STEP
	compute_stage(0,input_set,output_set)

	# UPDATE MATERIAL BUFFERS
	render_material.set_shader_parameter("particle_buffer", textureRD)
	render_material.set_shader_parameter("camera_center", camera_center)
	render_material.set_shader_parameter("zoom", zoom)
	render_material.set_shader_parameter("min_speed", min_speed)
	render_material.set_shader_parameter("max_speed", max_speed)

	rdmain.free_rid(input_set)
	rdmain.free_rid(output_set)

var ping : bool = false
func flip_buffers():
	# Flip buffers
	ping = !ping
	var read_main  : RID
	var read_sec   : RID
	var write_main : RID
	var write_sec  : RID
	if ping:
		read_main  = output_particles
		write_main = input_particles
	else:
		read_main  = input_particles
		write_main = output_particles

	# use correct output image
	if textureRD:
		textureRD.texture_rd_rid = write_main
	
	# Create uniform sets
	var input_set  := _create_uniform_set(read_main,  read_sec,  0)
	var output_set := _create_uniform_set(write_main, write_sec, 1)
	
	return [input_set,output_set]

func _create_uniform_set(texture_rd: RID, texture_rd2: RID, _uniform_set: int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rd)
	
	var uniform2 := RDUniform.new()
	uniform2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform2.binding = 1
	uniform2.add_id(texture_rd2)
	
	var new_set = [uniform, uniform2]
	
	return rdmain.uniform_set_create(new_set, shader, _uniform_set)
