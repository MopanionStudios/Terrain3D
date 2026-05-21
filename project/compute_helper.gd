class_name ComputeHelper


func _image_to_rid(rd : RenderingDevice, img : Image, used_for_image : bool, persistent : bool) -> RID:
	img.convert(Image.FORMAT_RGBA8)
	img.decompress()
	var img_size = img.get_size()
	var img_data = img.get_data()

	var img_rd_view = RDTextureView.new()

	var img_format = RDTextureFormat.new()
	img_format.width = img_size.x
	img_format.height = img_size.y
	img_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM

	if used_for_image && !persistent:
		img_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	elif used_for_image &&  persistent:
		img_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	else:
		img_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var img_rid = rd.texture_create(img_format, img_rd_view, [img_data])

	return img_rid


func _create_uniform(binding : int, id : RID, type : RenderingDevice.UniformType) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(id)
	return uniform


func _create_sampler(rd : RenderingDevice, sampler_state : RID, binding : int, id : RID) -> RDUniform:
	
	if !sampler_state.is_valid():
		printerr("Sampler state not valid!")

	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler_state)
	uniform.add_id(id)
	return uniform


func _create_set(rd : RenderingDevice, shader : RID, set_num : int, uniforms : Array) -> RID:
	var created_set = rd.uniform_set_create(uniforms, shader, set_num)
	return created_set


func compile_compute(rd : RenderingDevice, sets : Array, _pipeline : RID, size : Vector2i):

	if size.x == 0 and size.y == 0:
		return

	var x_groups = (size.x - 1) / 8 + 1
	var y_groups = (size.y - 1) / 8 + 1
	var z_groups = 1
	
	var compute_list:= rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)

	for s in sets.size():
		rd.compute_list_bind_uniform_set(compute_list, sets[s], s)

	#rd.compute_list_set_push_constant(compute_list, push_const, push_const.size())
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
	rd.compute_list_end()

	for s in sets.size():
		rd.free_rid(sets[s])
