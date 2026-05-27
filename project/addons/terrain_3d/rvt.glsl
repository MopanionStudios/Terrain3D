#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#define DIV_255 0.0039215686

layout(rgba16, set = 0, binding = 0) uniform writeonly image2D blended_albedo;

layout(set = 1, binding = 0) uniform sampler2DArray albedo_array;
layout(set = 1, binding = 1) uniform sampler2DArray controlmap_array;

layout(set = 2, binding = 0) uniform TerrainParams {
    float region_size;
    float vertex_density;
    vec2 region_location;
    int layer_index;
    int region_map_size;
} terrain_params;

layout(set = 2, binding = 1, std430) readonly buffer UvBuffer {
    float uv_scale_array[32];
} uv_scale_buffer;

void main() {
    ivec2 ssC = ivec2(gl_GlobalInvocationID.xy);
    ivec2 tex_size = imageSize(blended_albedo);

    if (any(greaterThanEqual(ssC, tex_size))) { // too large, do nothing
        return;
    }

    vec2 uv = vec2(ssC) / vec2(tex_size);
	ivec2 control_size = textureSize(controlmap_array, 0).xy;
	ivec2 control_coord = ivec2(uv * vec2(control_size));

    vec4 control_map = texelFetch(controlmap_array, ivec3(control_coord, terrain_params.layer_index), 0);
    uint control = floatBitsToUint(control_map.r);

    int base_id = int(control >> 27u & 0x1Fu);
    int overlay_id = int(control >> 22u & 0x1Fu);
    float blend = float(control >> 14u & 0xFFu) * DIV_255;

    ivec2 base_alb_size = textureSize(albedo_array, 0).xy;
    vec2 alb_uv = vec2(ssC) / vec2(base_alb_size);
    vec2 base_uv = alb_uv * uv_scale_buffer.uv_scale_array[base_id];

    vec4 base_albedo = textureLod(albedo_array, vec3(base_uv, float(base_id)), 0.0);
    vec4 final_albedo = base_albedo;
    if (blend > 0.0) {
        vec2 overlay_uv = alb_uv * uv_scale_buffer.uv_scale_array[overlay_id];
        vec4 overlay_albedo = textureLod(albedo_array, vec3(overlay_uv, float(overlay_id)), 0.0);
        final_albedo = mix(base_albedo, overlay_albedo, blend);
    }

    imageStore(blended_albedo, ssC, vec4(final_albedo.rgb, 1.0));
}