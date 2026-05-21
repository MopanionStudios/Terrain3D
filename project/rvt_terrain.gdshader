shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

/* The terrain depends on this shader to function. Don't change most things in vertex() or 
 * terrain normal calculations in fragment(). You probably only want to customize the 
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >>14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >>27u & 0x1Fu)
#define DECODE_OVER(control) int(control >>22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
group_uniforms shader_uniforms;
uniform vec3 _target_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform float _subdiv = 1.f;
uniform float _tessellation_level = 0.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_ao_affect_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
#define FILTER_LINEAR
#define FILTER_METHOD filter_linear_mipmap_anisotropic

uniform highp sampler2DArray _color_maps : source_color, FILTER_METHOD, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, FILTER_METHOD, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, FILTER_METHOD, repeat_enable;
group_uniforms;

// Public uniforms
group_uniforms shader_uniforms.general;
uniform float ground_level : hint_range(-1000., 1000.) = -20.0;
uniform float region_blend : hint_range(.001, 1., 0.001) = 0.25;
uniform highp sampler2DArray rvt_albedo : repeat_disable;

uniform bool flat_terrain_normals = false;
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
group_uniforms;

#define AUTO_SHADER
group_uniforms shader_uniforms.auto_shader;
uniform float auto_slope : hint_range(0, 10) = 1.0;
uniform float auto_height_reduction : hint_range(0, 1) = 0.1;
uniform int auto_base_texture : hint_range(0, 31) = 0;
uniform int auto_overlay_texture : hint_range(0, 31) = 1;
group_uniforms;

#define DISPLACEMENT
uniform float _displacement_scale : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform highp sampler2D _displacement_buffer : repeat_disable, filter_linear;

group_uniforms shader_uniforms.dual_scaling;
uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;
group_uniforms;

group_uniforms shader_uniforms.macro_variation;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;
uniform highp sampler2D noise_texture : source_color, FILTER_METHOD, repeat_enable;
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x
group_uniforms;


group_uniforms shader_uniforms.mipmaps;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;
uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float distant_normal_scale : hint_range(1.0, 10.0, 0.1) = 2.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
group_uniforms;

group_uniforms shader_uniforms.world_background_noise;
uniform bool world_noise_fragment_normals = false;
uniform int world_noise_max_octaves : hint_range(0, 15) = 4;
uniform int world_noise_min_octaves : hint_range(0, 15) = 2;
uniform float world_noise_lod_distance : hint_range(0., 40000., 1.) = 7500.;
uniform float world_noise_scale : hint_range(0.25, 20, 0.01) = 5.0;
uniform float world_noise_height : hint_range(-1000., 1000., 0.1) = 32.0;
uniform vec3 world_noise_offset = vec3(0.0);
group_uniforms;
varying vec2 world_noise_ddxy;


// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao;
	float ao_affect;
	float total_weight;
};

varying vec3 v_vertex;
varying float v_vertex_xz_dist;
varying vec3 v_camera_pos;

////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv) {
	vec2 r_uv = round(uv);
	ivec2 pos = ivec2(floor(r_uv * _region_texel_size)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[pos.y * _region_map_size + pos.x] * bounds - 1;
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

float interpolated_height(vec2 pos) {
	const vec2 offsets = vec2(0, 1);
	vec2 index_id = floor(pos);
	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	float h0 = texelFetch(_height_maps, index[0], 0).r;
	float h1 = texelFetch(_height_maps, index[1], 0).r;
	float h2 = texelFetch(_height_maps, index[2], 0).r;
	float h3 = texelFetch(_height_maps, index[3], 0).r;
	vec2 f = fract(pos);
	vec2 i = 1.0 - f;
	vec4 w = vec4(i.x * f.y, f.x * f.y, f.x * i.y, i.x * i.y);
	float h = h0 * w[0] + h1 * w[1] + h2 * w[2] + h3 * w[3];
	return h;
}

vec3 get_displacement(vec2 pos, float scale) {
	float s = floor(log2(1.0 / (scale * _vertex_density)));
	scale = pow(2.0, s) * 0.5;
	vec2 d_uv = (scale * pos - round(_target_pos.xz * _vertex_density * scale)) / (_mesh_size * 2.0) + 0.5;
	d_uv.x += s - 1.;
	d_uv.x /= log2(_subdiv);
	highp vec3 disp = vec3(0.);
	if (all(greaterThanEqual(d_uv, vec2(0.0))) && all(lessThanEqual(d_uv, vec2(1.0)))) {
		disp = textureLod(_displacement_buffer, d_uv, 0.).rgb * 2.0 - 1.0;
		disp *= _displacement_scale;
	}
	return disp;
}

// Takes in UV2 region space coordinates, returns 1.0 or 0.0 if a region is present or not.
float check_region(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int layer_index = 0;
	if (uint(pos.x | pos.y) < uint(_region_map_size)) {
		layer_index = clamp(_region_map[ pos.y * _region_map_size + pos.x ] - 1, -1, 0) + 1;
	}
	return float(layer_index);
}

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float get_region_blend(vec2 uv2) {
	uv2 -= 0.5011; // correct for floating point error
	const vec2 offset = vec2(0.0, 1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 blend_factor = vec2(2.0 + 126.0 * (1.0 - region_blend));
	vec2 f = fract(uv2);
	vec2 w = 1.0 / (1.0 + exp(blend_factor * log((1.0 - f) / f)));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
	return (1.0 - blend) * 2.0;
}

// World Noise Functions Start

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float get_noise_region_blend(vec2 uv2) {
	uv2 -= 0.5011; // correct for floating point error
	const vec2 offset = vec2(0.0, 1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 w = smoothstep(vec2(0.0), vec2(1.0), fract(uv2));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
    return 1.0 - blend * 2.0;
}

float hashf(float f) {
	return fract(sin(f) * 1e4);
}

float hashv2(vec2 v) {
	return fract(1e4 * sin(fma(17.0, v.x, v.y * 0.1)) * (0.1 + abs(sin(fma(v.y, 13.0, v.x)))));
}

// https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
	vec2 f2 = f * f, f3 = f2 * f, s = f - 1.0, s2 = s * s;
	vec2 u = f3 * fma(vec2(6.0), f2, fma(vec2(-15.0), f, vec2(10.0)));
	vec2 du = 30.0 * f2 * s2;

    vec2 p = floor(x);

	// Four corners in 2D of a tile
	float a = hashv2( p+vec2(0,0) );
    float b = hashv2( p+vec2(1,0) );
    float c = hashv2( p+vec2(0,1) );
    float d = hashv2( p+vec2(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   d - (b + k2);
	return vec3(fma(k2, u.y, fma(u.x, fma(k3, u.y, k1), k0)),
		 du * fma(vec2(k3), u.yx, vec2(k1, k2)));
}

float world_noise(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);

    int octaves = int( clamp(
		float(world_noise_max_octaves) - floor(v_vertex_xz_dist/(world_noise_lod_distance)),
		float(world_noise_min_octaves), float(world_noise_max_octaves))
	);
	
    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0;
    }
    return a;
}

float get_noise_height(const vec2 uv) {
	float weight = get_noise_region_blend(uv);
	// Only calculate world noise when it would be visible.
    if (weight <= 0.5) {
		return 0.0;
	}
	//TODO: Offset/scale UVs are semi-dependent upon region size 1024. Base on v_vertex.xz instead
	float noise = world_noise((uv + world_noise_offset.xz * 1024. / _region_size) * world_noise_scale * _region_size / 1024. * .1) *
            world_noise_height * 10. + world_noise_offset.y * 100.;
    weight = smoothstep(0.5, 1.0, weight);
    return mix(0.0, noise, weight);
}

// World Noise Functions End


void vertex() {
	// Save Camera Position to varying for access in later functions
	v_camera_pos = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Distance from target node to vertex on a flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _target_pos.xz);

	// Geomorph vertex across clipmap LODs, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float inv_scale = 1.0 / scale;
	float max_xz = max(abs(v_vertex.x - _target_pos.x), abs(v_vertex.z - _target_pos.z));
	float vertex_lerp = smoothstep(0.0, 1.0, (max_xz * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
	vec2 vertex_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
		// Shift from regular to symmetric
		mix(vertex_fract, vec2(vertex_fract.x, -vertex_fract.y),
			round(fract(round(mod(v_vertex.z * inv_scale, 4.0)) *
			round(mod(v_vertex.x * inv_scale, 4.0)) * 0.25))) :
		// Symmetric shift
		vertex_fract * round((fract(v_vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in region space. 0-1 covers 1 region, 1-2 is the next region, etc.
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	vec3 displacement = vec3(0.);
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && (hole
		)){
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height.
		float h;
		// This branch is static for each of the clipmap segments
		// Interpolated reads only occur where sub-texel values are required.
		if (scale < _vertex_spacing) {
			h = interpolated_height(UV);
		} else {
			ivec3 coord_a = get_index_coord(start_pos);
			ivec3 coord_b = get_index_coord(end_pos);
			h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, vertex_lerp);
		}

		// Apply background ground level and region blend, dont include texel offset
		h = mix(h, ground_level, smoothstep(0.0, 1.0, get_region_blend(UV * _region_texel_size)));

		// World Noise
		if (_background_mode == 2u) {
			vec2 nuv_a = start_pos * _region_texel_size;
			vec2 nuv_b = end_pos * _region_texel_size;
			float nh = mix(get_noise_height(nuv_a), get_noise_height(nuv_b), vertex_lerp);
			float nu = mix(get_noise_height(nuv_a + vec2(_region_texel_size, 0.0)),
				get_noise_height(nuv_b + vec2(_region_texel_size, 0.0)), vertex_lerp);
			float nv = mix(get_noise_height(nuv_a + vec2(0.0, _region_texel_size)),
				get_noise_height(nuv_b + vec2(0.0, _region_texel_size)), vertex_lerp);
			world_noise_ddxy = vec2(nh - nu, nh - nv);
			h += nh;
		}

		if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer)) {
			displacement = mix(get_displacement(start_pos, scale), get_displacement(end_pos, scale * 2.0), vertex_lerp);
		}

		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	// Include displacement without modifying v_vertex.
	VERTEX = (VIEW_MATRIX * vec4(v_vertex + displacement, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

float get_height(vec2 index_id, vec2 offset) {
	float height = texelFetch(_height_maps, get_index_coord(index_id + offset), 0).r;
	if (_background_mode != 0u) {
		float blend = get_region_blend(index_id * _region_texel_size + offset * _region_texel_size);
		height = mix(height, ground_level, smoothstep(0., 1., blend));
	}

	return height;
}


void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);

	vec4 rvt_region_tex = texture(rvt_albedo, region_uv);
	ALBEDO = rvt_region_tex.rgb;

}
