@tool
extends Node3D

var compute_helper := ComputeHelper.new()
@export_tool_button("Rebake Terrain", "Bake") var rebake_action = _init_rvt_regions
@export var Terrain : Terrain3D
@export_enum("512:512", "1024:1024", "2048:2048", "4096:4096", "8192:8192") var resolution : int = 1024
var terrain_data : Terrain3DData

# Compute shader variables
var rd : RenderingDevice
var pipeline : RID
var mip_pipeline : RID

var shader_src := load("res://addons/terrain_3d/rvt.glsl")
var shader_spirv : RDShaderSPIRV
var shader : RID
var sampler_state : RID

var mip_shader_src := load("res://addons/terrain_3d/downsample.glsl")
var mip_shader_spirv : RDShaderSPIRV
var mip_shader : RID

var param_buffer : RID
var uv_scale_buffer : RID

var rvt_array_rid : RID
var rvt_tex : Texture2DArrayRD
var rvt_nor_array_rid : RID
var rvt_nor_tex : Texture2DArrayRD

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	
	shader_spirv = shader_src.get_spirv()
	mip_shader_spirv = mip_shader_src.get_spirv()
	
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	mip_shader = rd.shader_create_from_spirv(mip_shader_spirv)
	mip_pipeline = rd.compute_pipeline_create(mip_shader)
	
	var sampler_settings := RDSamplerState.new()
	sampler_settings.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_settings.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_settings.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_settings.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_settings.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_settings.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state = rd.sampler_create(sampler_settings)


func _gen_mipmaps(array_rid : RID, layer : int, size : int) -> void:
	var mip_count := int(log(size) / log(2)) + 1
	
	for m in range(1, mip_count):
		var src_view := RDTextureView.new()
		var src_slice := rd.texture_create_shared_from_slice(src_view, array_rid, layer, m - 1, 1, RenderingDevice.TEXTURE_SLICE_2D)
		
		var dest_view := RDTextureView.new()
		var dest_slice := rd.texture_create_shared_from_slice(dest_view, array_rid, layer, m, 1, RenderingDevice.TEXTURE_SLICE_2D)
		var dest_size := max(1, size / 2)
		
		var src_uniform = compute_helper._create_sampler(rd, sampler_state, 0, src_slice)
		var dest_uniform = compute_helper._create_uniform(0, dest_slice, RenderingDevice.UNIFORM_TYPE_IMAGE)
		
		var set0 = compute_helper._create_set(rd, mip_shader, 0, [dest_uniform])
		var set1 = compute_helper._create_set(rd, mip_shader, 1, [src_uniform])
		
		compute_helper.compile_compute(rd, [set0, set1], mip_pipeline, Vector2i(dest_size, dest_size))
		rd.free_rid(src_slice)
		rd.free_rid(dest_slice)

func _ready() -> void:
	terrain_data = Terrain.data
	call_deferred("_init_rvt_regions")


func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
		if mip_shader.is_valid():
			rd.free_rid(mip_shader)
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
	terrain_params.encode_float(8, float(region_location.x))
	terrain_params.encode_float(12, float(region_location.y))
	terrain_params.encode_s32(16, region_id)
	terrain_params.encode_s32(20, terrain_data.REGION_MAP_SIZE)
	
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
	
	var region_id = terrain_data.get_region_id(region.location)
	
	var albedo_rs_maps = Terrain.assets.get_albedo_array_rid()
	var nor_rs_maps = Terrain.assets.get_normal_array_rid()
	var albedo_maps = RenderingServer.texture_get_rd_texture(albedo_rs_maps)
	var normal_maps = RenderingServer.texture_get_rd_texture(nor_rs_maps)
	
	var control_rs_maps = terrain_data.get_control_maps_rid()
	var control_maps = RenderingServer.texture_get_rd_texture(control_rs_maps)
	
	var albedo_uniform = compute_helper._create_sampler(rd, sampler_state, 0, albedo_maps)
	var control_uniform = compute_helper._create_sampler(rd, sampler_state, 1, control_maps)
	var nor_uniform = compute_helper._create_sampler(rd, sampler_state, 2, normal_maps)
	
	# create baked albedo map for this region
	var alb_layer_rid := rd.texture_create_shared_from_slice(RDTextureView.new(), rvt_array_rid, region_id, 0)
	var nor_layer_rid := rd.texture_create_shared_from_slice(RDTextureView.new(), rvt_nor_array_rid, region_id, 0)
	var rvt_alb_uniform = compute_helper._create_uniform(0, alb_layer_rid, RenderingDevice.UNIFORM_TYPE_IMAGE)
	var rvt_nor_uniform = compute_helper._create_uniform(1, nor_layer_rid, RenderingDevice.UNIFORM_TYPE_IMAGE)

	var param_buffer_uniform = compute_helper._create_uniform(0, param_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)
	var uv_buffer_uniform = compute_helper._create_uniform(1, uv_scale_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)

	var set0 = compute_helper._create_set(rd, shader, 0, [rvt_alb_uniform, rvt_nor_uniform])
	var set1 = compute_helper._create_set(rd, shader, 1, [albedo_uniform, control_uniform, nor_uniform])
	var set2 = compute_helper._create_set(rd, shader, 2, [param_buffer_uniform, uv_buffer_uniform])

	compute_helper.compile_compute(rd, [set0, set1, set2], pipeline, Vector2i(resolution, resolution))

	_gen_mipmaps(rvt_array_rid, region_id, resolution)
	_gen_mipmaps(rvt_nor_array_rid, region_id, resolution)

	rd.free_rid(alb_layer_rid)
	rd.free_rid(nor_layer_rid)

func _init_rvt_regions() -> void:
	var max_regions := terrain_data.get_region_count()
	var mip_count := int(log(resolution) / log(2)) + 1

	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = resolution
	fmt.height = resolution
	fmt.array_layers = max_regions
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	fmt.mipmaps = mip_count

	if rvt_array_rid.is_valid():
		rd.free_rid(rvt_array_rid)
	if rvt_nor_array_rid.is_valid():
		rd.free_rid(rvt_nor_array_rid)

	rvt_array_rid = rd.texture_create(fmt, RDTextureView.new())
	rvt_nor_array_rid = rd.texture_create(fmt, RDTextureView.new())

	rvt_tex = Texture2DArrayRD.new()
	rvt_tex.texture_rd_rid = rvt_array_rid
	rvt_nor_tex = Texture2DArrayRD.new()
	rvt_nor_tex.texture_rd_rid = rvt_nor_array_rid
	
	Terrain.material.set_shader_param("rvt_region_albedo", rvt_tex)
	Terrain.material.set_shader_param("rvt_region_normal", rvt_nor_tex)

	for r in terrain_data.get_regions_active():
		_bake_region(r)
