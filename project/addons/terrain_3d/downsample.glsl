#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform writeonly image2D dst_mip;
layout(set = 1, binding = 0) uniform sampler2D src_mip;

void main() {
    ivec2 ssC = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dst_size = imageSize(dst_mip);
    if (any(greaterThanEqual(ssC, dst_size))) {
        return;
    }
    vec2 uv = (vec2(ssC) + 0.5) / vec2(dst_size);
    imageStore(dst_mip, ssC, textureLod(src_mip, uv, 0.0));
}