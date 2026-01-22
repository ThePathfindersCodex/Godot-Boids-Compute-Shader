shader_type canvas_item;
uniform sampler2D alpha_tex : filter_linear, repeat_disable;
uniform sampler2D particle_buffer : filter_nearest, repeat_disable;
uniform int compute_texture_size;
uniform vec2 viewport_size;
uniform float min_speed = 0.0;
uniform float max_speed = 1.0;
uniform vec2 camera_center;
uniform float zoom;
varying flat int v_instance_id;

void vertex() {
	int id = INSTANCE_ID;
	v_instance_id = id;
	ivec2 texel = ivec2(id % compute_texture_size,
						id / compute_texture_size);
	vec4 data = texelFetch(particle_buffer, texel, 0);
	vec2 pos = data.rg;
	vec2 vel = data.ba;

	// transform pos
	vec2 world_pos = pos;
	vec2 view_pos = (world_pos - camera_center) * zoom;
	vec2 screen_center = viewport_size * 0.5;

	float radius = 10.0 * zoom;
	
	// direction
	vec2 dir = normalize(vec2(vel.x, -vel.y) + vec2(1e-6));
	float angle = atan(dir.y, dir.x);
	// up is forward
	angle += PI * 0.5;

	float c = cos(angle);
	float s = sin(angle);
	mat2 rot = mat2(vec2(c,-s), vec2(s,c));

	// Move pivot to tip of triangle
	vec2 tip_offset = vec2(0.0, -0.5); // adjust depending on mesh
	vec2 local = VERTEX - tip_offset;

	local *= radius;
	local = rot * local;
	local += tip_offset * radius;

	VERTEX = view_pos + screen_center + local;
}

vec3 jet_colormap(float t) {
	t = clamp(t, 0.0, 1.0);
	float r = clamp(1.5 - abs(4.0 * t - 3.0), 0.0, 1.0);
	float g = clamp(1.5 - abs(4.0 * t - 2.0), 0.0, 1.0);
	float b = clamp(1.5 - abs(4.0 * t - 1.0), 0.0, 1.0);
	return vec3(r, g, b);
}

void fragment() {
	int id = v_instance_id;
	ivec2 texel = ivec2(id % compute_texture_size,
						id / compute_texture_size);
	vec4 data = texelFetch(particle_buffer, texel, 0);
	vec2 vel = data.ba;
	
	// --- Compute color from speed ---
	float speed = length(vel);
	float t = clamp((speed - min_speed) / (max_speed - min_speed), 0.0, 1.0);
	vec3 rgb = jet_colormap(t);
	vec4 color = vec4(rgb, 1.0);

	// --- Rotation anchor debug ---
	vec2 anchor_uv = vec2(0.5, 0.5); // adjust if needed
	float anchor_radius = 0.05;
	float da = distance(UV, anchor_uv);
	if (da < anchor_radius) {
		COLOR = vec4(1.0, 0.0, 0.0, 1.0); // red = rotation anchor
	}
	else {
		// Sample and set
		float alpha = texture(alpha_tex, UV).a;
		if(alpha < 0.001) discard;
		COLOR = vec4(color.rgb, color.a * alpha);
	}
}
