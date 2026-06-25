shader_type canvas_item;
render_mode unshaded, blend_mix;

const int MAX_DROPLETS = 128;

uniform int droplet_count = 0;
uniform vec2 droplets[MAX_DROPLETS];
uniform float droplet_radii[MAX_DROPLETS];
uniform float radius_px = 13.0;
uniform float threshold = 1.05;
uniform float softness = 0.42;
uniform vec4 spray_color : source_color = vec4(0.482, 0.863, 1.0, 0.6);

varying vec2 local_position;

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	float field = 0.0;
	for (int index = 0; index < MAX_DROPLETS; index++) {
		if (index >= droplet_count) {
			break;
		}
		vec2 offset = local_position - droplets[index];
		float droplet_radius = droplet_radii[index] > 0.0 ? droplet_radii[index] : radius_px;
		float droplet_radius_sq = droplet_radius * droplet_radius;
		field += droplet_radius_sq / max(dot(offset, offset), 1.0);
	}

	float edge_alpha = softness <= 0.0 ? step(threshold, field) : smoothstep(threshold - softness, threshold, field);
	vec4 color = spray_color;
	color.a *= edge_alpha;
	COLOR = color;
}
