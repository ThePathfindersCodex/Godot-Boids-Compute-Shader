extends TextureRect

# CONFIG
var shader_local_size := 512
@onready var image_size : int = %ComputeBoids.size.x
var zone_size_mult : int = 8

# STARTUP
var boids_count : int = 1024 * 5
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
#var rd := RenderingServer.create_local_rendering_device()
var rdmain := RenderingServer.get_rendering_device()
var textureRD: Texture2DRD
var shader : RID
var pipeline : RID
var uniform_set : RID
var output_tex : RID
var fmt := RDTextureFormat.new()
var view := RDTextureView.new()
var buffers : Array[RID] = []
var uniforms : Array[RDUniform] = []
var output_tex_uniform : RDUniform

func _ready():
	randomize()
	fmt.width = image_size
	fmt.height = image_size
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
					| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
					| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
					| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT \
					| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	view = RDTextureView.new()
	textureRD = Texture2DRD.new()
	
	RenderingServer.call_on_render_thread(restart_simulation)

func restart_simulation():
	boids_count = start_boids_count

	# Build new random boids
	var start_data : Dictionary = StartupManager.build_random_boids(self)
	rebuild_buffers(start_data)

func rebuild_buffers(data: Dictionary):
	buffers.clear()
	uniforms.clear()

	# Convert Vector2 lists to PackedFloat32Array
	var pos_pf := PackedFloat32Array()
	for v in data["pos"]:
		pos_pf.append(v.x)
		pos_pf.append(v.y)

	var vel_pf := PackedFloat32Array()
	for v in data["vel"]:
		vel_pf.append(v.x)
		vel_pf.append(v.y)

	var pos_bytes : PackedByteArray = pos_pf.to_byte_array()
	var vel_bytes : PackedByteArray = vel_pf.to_byte_array()

	# IN BUFFERS
	buffers.append(rdmain.storage_buffer_create(pos_bytes.size(), pos_bytes))   # 0 in_pos_buffer
	buffers.append(rdmain.storage_buffer_create(vel_bytes.size(), vel_bytes))   # 1 in_vel_buffer

	# OUT BUFFERS (copy of input)
	for b in [pos_bytes, vel_bytes]:
		buffers.append(rdmain.storage_buffer_create(b.size(), b))  # 2 out_pos_buffer, 3 out_vel_buffer

	# Output texture
	var output_img := Image.create(image_size, image_size, false, Image.FORMAT_RGBAF)
	#texture = ImageTexture.create_from_image(output_img)
	output_tex = rdmain.texture_create(fmt, view, [output_img.get_data()])
	textureRD.texture_rd_rid = output_tex

	# UNIFORMS (storage buffers)
	for i in range(4):
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(buffers[i])
		uniforms.append(u)

	# IMAGE TEXTURE OUTPUT (binding 4)
	output_tex_uniform = RDUniform.new()
	output_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_tex_uniform.binding = 4
	output_tex_uniform.add_id(output_tex)
	uniforms.append(output_tex_uniform)

	# SHADER + PIPELINE
	var shader_file := load("res://compute_boids.glsl") as RDShaderFile
	shader = rdmain.shader_create_from_spirv(shader_file.get_spirv())
	pipeline = rdmain.compute_pipeline_create(shader)
	uniform_set = rdmain.uniform_set_create(uniforms, shader, 0)

func compute_stage(run_mode:int):
	# default to 1D dispatch for boids
	var global_size_x : int = int(float(boids_count) / shader_local_size) + 1
	var global_size_y : int = 1

	# use 2D dispatch for CLEAR stage
	if (run_mode == 1):
		global_size_x = image_size
		global_size_y = image_size

	var compute_list := rdmain.compute_list_begin()
	rdmain.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rdmain.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	# PUSH CONSTANT PARAMETERS
	var params := PackedFloat32Array([
		dt,
		float(boids_count),
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
		draw_radius,
		camera_center.x,
		camera_center.y,
		zoom,
		float(run_mode),
		0.0
	])
	var params_bytes := PackedByteArray()
	params_bytes.append_array(params.to_byte_array())

	rdmain.compute_list_set_push_constant(compute_list, params_bytes, params_bytes.size())
	rdmain.compute_list_dispatch(compute_list, global_size_x, global_size_y, 1)
	rdmain.compute_list_end()
	#rdmain.submit()
	#rdmain.sync()

func _process(_delta):
	RenderingServer.call_on_render_thread(run_simulation)

func run_simulation():
	# RUN COMPUTE STAGES: 0 = simulate, 1 = clear, 2 = draw
	for run_mode in [0, 1, 2]:
		compute_stage(run_mode)

	# --- Swap results back into input buffers ---
	swap_buffer_bindings()
	
	# UPDATE TEXTURE ON SCREEN
	texture = textureRD

# FRAME BUFFER SWAP LOGIC
var swap_flag : int = 0
func swap_buffer_bindings():
	if (dt == 0):
		return
	
	swap_flag = 1 - swap_flag   # toggle between 0 and 1
	var pos_in_index = swap_flag * 2       # 0 or 2
	var vel_in_index = pos_in_index + 1    # 1 or 3
	var pos_out_index = 2 - pos_in_index   # if 0to2, if 2to0
	var vel_out_index = pos_out_index + 1  # 3 or 1
	
	# rebuild uniforms for bindings 0 and 1
	uniforms[0] = RDUniform.new()
	uniforms[0].uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniforms[0].binding = 0
	uniforms[0].add_id(buffers[pos_in_index])
	uniforms[1] = RDUniform.new()
	uniforms[1].uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniforms[1].binding = 1
	uniforms[1].add_id(buffers[vel_in_index])
	uniforms[2] = RDUniform.new()
	uniforms[2].uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniforms[2].binding = 2
	uniforms[2].add_id(buffers[pos_out_index])
	uniforms[3] = RDUniform.new()
	uniforms[3].uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniforms[3].binding = 3
	uniforms[3].add_id(buffers[vel_out_index])
	
	# rebuild uniform set
	uniform_set = rdmain.uniform_set_create(uniforms, shader, 0)

# HANDLE MOUSE INPUTS
var dragging := false
var last_mouse_pos := Vector2()
func _gui_input(event):
	if event is InputEventMouseButton:
		# Handle zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clamp(zoom * 1.05, MIN_ZOOM, MAX_ZOOM)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clamp(zoom / 1.05, MIN_ZOOM, MAX_ZOOM)

		# Start/stop panning with right mouse button
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			dragging = event.pressed
			last_mouse_pos = event.position

	elif event is InputEventMouseMotion and dragging:
		# Convert drag delta to world space based on zoom
		var delta : Vector2 = (event.position - last_mouse_pos) / zoom
		last_mouse_pos = event.position
		camera_center -= delta
