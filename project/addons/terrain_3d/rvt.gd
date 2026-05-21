@tool
extends Node3D

var compute_helper := ComputeHelper.new()
@export var Terrain : Terrain3D
var terrain_data : Terrain3DData

# Compute shader variables
var rd : RenderingDevice
var pipeline : RID

var shader_src := load("res://addons/terrain_3d/rvt.glsl")
var shader_spirv : RDShaderSPIRV
var shader : RID
var sampler_state : RID

var param_buffer : RID
var uv_scale_buffer : RID

var rvt_array_rid : RID
var rvt_tex : Texture2DArrayRD

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	
	shader_spirv = shader_src.get_spirv()
	
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)


func _ready() -> void:
	terrain_data = Terrain.data
	sampler_state = rd.sampler_create(RDSamplerState.new())
	call_deferred("_init_rvt_regions")


func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
		if param_buffer.is_valid():
			rd.free_rid(param_buffer)
		if uv_scale_buffer.is_valid():
			rd.free_rid(uv_scale_buffer)
		if sampler_state.is_valid():
			rd.free_rid(sampler_state)

func _prepare_buffers(region : Terrain3DRegion):
	# terrain_params
	if param_buffer.is_valid():
		rd.free_rid(param_buffer)
	
	var region_size : float = Terrain.region_size
	var region_location : Vector2i = region.location
	var region_id : int = terrain_data.get_region_id(region_location)
	
	var terrain_params := PackedByteArray()
	terrain_params.resize(32)
	terrain_params.encode_float(0, region_size)
	terrain_params.encode_float(4, Terrain.vertex_spacing)
	terrain_params.encode_float(16, float(region_location.x))
	terrain_params.encode_float(20, float(region_location.y))
	terrain_params.encode_s32(24, region_id)
	terrain_params.encode_s32(28, terrain_data.REGION_MAP_SIZE)
	
	param_buffer = rd.uniform_buffer_create(terrain_params.size(), terrain_params)
	
	# uv scale buffer
	
	if uv_scale_buffer.is_valid():
		rd.free_rid(uv_scale_buffer)
	
	var uv_scale_arr = Terrain.assets.get_texture_uv_scales()
	uv_scale_arr.resize(32)
	var uv_buffer = uv_scale_arr.to_byte_array()
	
	uv_scale_buffer = rd.storage_buffer_create(uv_buffer.size(), uv_buffer)

func _bake_region(region : Terrain3DRegion) -> void:
	_prepare_buffers(region)
	
	var albedo_rs_maps = Terrain.assets.get_albedo_array_rid()
	var albedo_maps = RenderingServer.texture_get_rd_texture(albedo_rs_maps)
	
	var control_rs_maps = terrain_data.get_control_maps_rid()
	var control_maps = RenderingServer.texture_get_rd_texture(control_rs_maps)
	
	var albedo_uniform = compute_helper._create_sampler(rd, sampler_state, 0, albedo_maps)
	var control_uniform = compute_helper._create_sampler(rd, sampler_state, 1, control_maps)
	
	# create baked albedo map for this region
	var layer_rid := rd.texture_create_shared_from_slice(RDTextureView.new(), rvt_array_rid, terrain_data.get_region_id(region.location), 0)
	var rvt_uniform = compute_helper._create_uniform(0, layer_rid, RenderingDevice.UNIFORM_TYPE_IMAGE)
	
	var param_buffer_uniform = compute_helper._create_uniform(0, param_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)
	var uv_buffer_uniform = compute_helper._create_uniform(1, uv_scale_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	
	var set0 = compute_helper._create_set(rd, shader, 0, [rvt_uniform])
	var set1 = compute_helper._create_set(rd, shader, 1, [albedo_uniform, control_uniform])
	var set2 = compute_helper._create_set(rd, shader, 2, [param_buffer_uniform, uv_buffer_uniform])
	
	compute_helper.compile_compute(rd, [set0, set1, set2], pipeline, Vector2i(Terrain.region_size, Terrain.region_size))
	
	rd.free_rid(layer_rid)

func _init_rvt_regions() -> void:
	var max_regions := terrain_data.get_region_count()
	
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = Terrain.region_size
	fmt.height = Terrain.region_size
	fmt.array_layers = max_regions
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	
	rvt_array_rid = rd.texture_create(fmt, RDTextureView.new())
	
	rvt_tex = Texture2DArrayRD.new()
	rvt_tex.texture_rd_rid = rvt_array_rid
	Terrain.material.set_shader_param("rvt_albedo", rvt_tex)
	
	for r in terrain_data.get_regions_active():
		_bake_region(r)
