#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Image buffers with encoded particle data
layout(rgba32f, set = 0, binding = 0) uniform restrict image2D input_particles; // R=pos.x, G=pos.y, B=vel.x, A=vel.y
layout(rgba32f, set = 1, binding = 0) uniform restrict image2D output_particles;

// Parameters
layout(push_constant, std430) uniform Params {
    float dt;
    float boids_count;
	float compute_texture_size;	
    float vision_radius;
    float alignment_force;
    float cohesion_force;
    float separation_force;
    float steering_force;
    float min_speed;
    float max_speed;
    float drag;
    float movement_randomness;
    float movement_scaling;
    float image_size;
	float zone_size_mult;
} params;

// Utility
vec2 limit(vec2 v, float max_val) {
    float mag = length(v);
    if (mag > max_val) return normalize(v) * max_val;
    return v;
}

// Random vec2
vec2 random_dir(uint id, float scale) {
    uint seed = id * 1664525u + 1013904223u;
    float ang = float(seed % 6283u) * 0.001f;
    return vec2(cos(ang), sin(ang)) * scale;
}

// Border clamp/wrap
void apply_border(inout vec2 pos, inout vec2 vel) {
	float zone_size = params.image_size * params.zone_size_mult;
    float half_size = zone_size * 0.5;
    if (pos.x < -half_size) pos.x = half_size;
    if (pos.x > half_size)  pos.x = -half_size;
    if (pos.y < -half_size) pos.y = half_size;
    if (pos.y > half_size)  pos.y = -half_size;
}

// Distance check with border wrapping
vec2 toroidal_diff(vec2 a, vec2 b, vec2 world_size) {
    vec2 d = b - a;
    // shift into [-0.5*world_size, 0.5*world_size]
    d -= world_size * round(d / world_size);
    return d;
}

// Prevent problems with normalize on zero vectors
vec2 safe_normalize(vec2 v) {
    float len = length(v);
    return len > 0.0001 ? v / len : vec2(0.0);
}

// Core Boids sim
void run_sim() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	int id = int(uv.y * params.compute_texture_size + uv.x);
	if (id >= params.boids_count || uv.x >= params.compute_texture_size || uv.y >= params.compute_texture_size) {
		return;
	}					
	vec4 pixel = imageLoad(input_particles, uv);
	
	vec2 pos = pixel.rg;
	vec2 vel = pixel.ba;

    // Accumulators
    vec2 align = vec2(0.0);
    vec2 coh = vec2(0.0);
    vec2 sep = vec2(0.0);
    int neighbor_count = 0;
	
	// World size
	float zone_size = params.image_size * params.zone_size_mult;

	// Neighbor checks with wrapping
    for (uint i = 0; i < uint(params.boids_count); i++) {
        if (i == id) continue;
		
		// Map particle index to 2D texel coordinates
		ivec2 other_uv = ivec2(i % int(params.compute_texture_size), i / params.compute_texture_size);
		vec4 other_pixel = imageLoad(input_particles, other_uv);
		
		// Get particle position
		vec2 other_pos = other_pixel.rg;
		vec2 other_vel = other_pixel.ba;
		
		// Distance between
		vec2 diff = toroidal_diff(pos, other_pos, vec2(zone_size)); // wrapped around
		float dist = length(diff);

        if (dist < params.vision_radius && dist > 0.0001) {
            neighbor_count++;
            align += other_vel;
            //coh += other_pos;
			coh += pos + diff; // accumulate the wrapped "other_pos"
            sep -= diff / (dist * dist); // stronger when closer
        }
    }

	// Normalize and adjust primary simulation forces
    if (neighbor_count > 0) {
        align = safe_normalize(align / neighbor_count) * params.alignment_force;
        coh = safe_normalize((coh / neighbor_count - pos)) * params.cohesion_force;
        sep = safe_normalize(sep) * params.separation_force;
    } else {
		align = vec2(0.0);
		coh   = vec2(0.0);
		sep   = vec2(0.0);
	}

    // Combine forces
    vec2 accel = align + coh + sep;

    // Add randomness
    accel += random_dir(id + uint(gl_WorkGroupID.x), params.movement_randomness);

    // Scale by global movement scaling
    accel *= params.movement_scaling;

    // Limit steering
    accel = limit(accel, params.steering_force);

    // Apply acceleration
    vel += accel * params.dt;

    // Apply damping
    vel *= params.drag;

    // Clamp speeds
    float speed = length(vel);
    if (speed < params.min_speed) vel = normalize(vel) * params.min_speed;
    if (speed > params.max_speed) vel = normalize(vel) * params.max_speed;

    // Integrate position using timestep
    pos += vel * params.dt;

    // Wraparound border
    apply_border(pos, vel);

    // Write back
	imageStore(output_particles, uv, vec4(pos, vel));
}

void main() {
    run_sim();
}
