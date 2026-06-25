shader_type canvas_item;
render_mode unshaded, blend_mix;

const int MAX_DROPLETS = 128;

uniform int droplet_count = 0;
uniform vec2 droplets[MAX_DROPLETS];
uniform float radius_px = 13.0;
uniform float threshold = 1.05;
uniform float softness = 0.42;
uniform vec4 core_color : source_color = vec4(0.74, 0.96, 1.0, 0.92);
uniform vec4 edge_color : source_color = vec4(0.18, 0.63, 1.0, 0.48);

varying vec2 local_position;

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	float field = 0.0;
	float radius_sq = radius_px * radius_px;
	for (int index = 0; index < MAX_DROPLETS; index++) {
		if (index >= droplet_count) {
			break;
		}
		vec2 offset = local_position - droplets[index];
		field += radius_sq / max(dot(offset, offset), 1.0);
	}

	float edge_alpha = smoothstep(threshold - softness, threshold, field);
	float core_alpha = smoothstep(threshold, threshold + softness, field);
	vec4 color = mix(edge_color, core_color, core_alpha);
	color.a *= edge_alpha;
	COLOR = color;
}
