#[compute]
#version 450
layout(local_size_x = 512, local_size_y = 1, local_size_z = 1) in;

struct MyVec2 { vec2 v; };

// Input
layout(set = 0, binding = 0, std430) buffer InPosBuffer { MyVec2 data[]; } in_pos_buffer;
layout(set = 0, binding = 1, std430) buffer InVelBuffer { MyVec2 data[]; } in_vel_buffer;

// Output
layout(set = 0, binding = 2, std430) buffer OutPosBuffer { MyVec2 data[]; } out_pos_buffer;
layout(set = 0, binding = 3, std430) buffer OutVelBuffer { MyVec2 data[]; } out_vel_buffer;

// Render target
layout(set = 0, binding = 4, rgba32f) uniform image2D OUTPUT_TEXTURE;

// Parameters
layout(push_constant, std430) uniform Params {
    float dt;
    float boids_count;
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
    float draw_radius;
    float camera_center_x;
    float camera_center_y;
    float zoom;
    float run_mode; // 0=sim, 1=clear, 2=draw 
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
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(params.boids_count)) return;

    vec2 pos = in_pos_buffer.data[id].v;
    vec2 vel = in_vel_buffer.data[id].v;

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
		vec2 other = in_pos_buffer.data[i].v;
		vec2 diff = toroidal_diff(pos, other, vec2(zone_size)); // wrapped around
		float dist = length(diff);

        if (dist < params.vision_radius && dist > 0.0001) {
            neighbor_count++;
            align += in_vel_buffer.data[i].v;
            //coh += other;
			coh += pos + diff; // accumulate the wrapped "other"
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

    // Write out
    out_pos_buffer.data[id].v = pos;
    out_vel_buffer.data[id].v = vel;
}

// Clear
void clear_texture() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    imageStore(OUTPUT_TEXTURE, pixel, vec4(vec3(0.1),1.0)); // slight off-black	
    //imageStore(OUTPUT_TEXTURE, pixel, vec4(0.0)); // transparent
}

// Jet colormap (Blue - Cyan - Green - Yellow - Red)
vec3 jet_colormap(float t) {
    t = clamp(t, 0.0, 1.0);

    float r = clamp(1.5 - abs(4.0 * t - 3.0), 0.0, 1.0);
    float g = clamp(1.5 - abs(4.0 * t - 2.0), 0.0, 1.0);
    float b = clamp(1.5 - abs(4.0 * t - 1.0), 0.0, 1.0);

    return vec3(r, g, b);
}
// Viridis colormap
vec3 viridis(float t) {
    t = clamp(t, 0.0, 1.0);
    return vec3(
        0.267 + t * (0.633 - 0.267),
        0.004 + t * (0.867 - 0.004),
        0.329 + t * (0.267 - 0.329)
    );
}

// Draw a filled triangle
void draw_triangle(vec2 screen_pos, vec2 dir, float draw_size, vec4 color) {
    // Normalize direction
    vec2 n_dir = length(dir) > 0.0001 ? normalize(dir) : vec2(0.0, -1.0); // default pointing up

    // Perpendicular vector
    vec2 perp = vec2(-n_dir.y, n_dir.x);

    // Triangle vertices
    vec2 tip    = screen_pos + n_dir * draw_size;           // front
    vec2 left   = screen_pos - n_dir * draw_size * 0.5 + perp * draw_size * 0.5; // back left
    vec2 right  = screen_pos - n_dir * draw_size * 0.5 - perp * draw_size * 0.5; // back right

    // Compute bounding box to limit pixel iteration
    ivec2 min_pix = ivec2(floor(min(tip, min(left, right))));
    ivec2 max_pix = ivec2(ceil(max(tip, max(left, right))));

    for (int x = min_pix.x; x <= max_pix.x; x++) {
        for (int y = min_pix.y; y <= max_pix.y; y++) {
            vec2 p = vec2(x, y);

            // Barycentric coordinates for triangle test
            vec2 v0 = right - tip;
            vec2 v1 = left - tip;
            vec2 v2 = p - tip;

            float d00 = dot(v0, v0);
            float d01 = dot(v0, v1);
            float d11 = dot(v1, v1);
            float d20 = dot(v2, v0);
            float d21 = dot(v2, v1);

            float denom = d00 * d11 - d01 * d01;
            float a = (d11 * d20 - d01 * d21) / denom;
            float b = (d00 * d21 - d01 * d20) / denom;
            float c = 1.0 - a - b;

            if (a >= 0.0 && b >= 0.0 && c >= 0.0) {
                imageStore(OUTPUT_TEXTURE, ivec2(x, y), color);
            }
        }
    }
}

// Draw with camera + zoom
void draw_texture() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(params.boids_count)) return;

    vec2 pos = out_pos_buffer.data[id].v;
    vec2 image_size_vec = vec2(params.image_size, params.image_size);

    // Transform into screen space (camera + zoom)
    vec2 rel = pos - vec2(params.camera_center_x, params.camera_center_y);
    rel *= params.zoom;
    vec2 screen_pos = rel + image_size_vec * 0.5;

    // Compute draw size in screen pixels (scale draw_radius by zoom)
    float draw_size = params.draw_radius * params.zoom;

    // Discard if outside image (with margin = draw_size)
    if (screen_pos.x < -draw_size || screen_pos.x >= image_size_vec.x + draw_size ||
		screen_pos.y < -draw_size || screen_pos.y >= image_size_vec.y + draw_size) {
		return;
    }
	
	// Get velocity direction and color
	vec2 vel = out_vel_buffer.data[id].v;
	float speed = length(vel);
	float t = clamp((speed - params.min_speed) / (params.max_speed - params.min_speed), 0.0, 1.0);
	vec3 color = jet_colormap(t);
	//vec3 color = viridis(t);
	
	// Draw filled triangle at screen_pos - pointing towards velocity
	draw_triangle(screen_pos, vel, draw_size, vec4(color, 1.0));
}

void main() {
    if (params.run_mode == 0 && params.dt > 0.0) {
        run_sim();
    } else if (params.run_mode == 1) {
        clear_texture();
    } else if (params.run_mode == 2) {
        draw_texture();
    }
}
