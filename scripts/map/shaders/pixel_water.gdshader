shader_type canvas_item;

uniform sampler2D water_texture : filter_linear, repeat_disable;
uniform vec4 water_blue : source_color = vec4(0.050980, 0.749020, 1.0, 1.0);
uniform float tolerance : hint_range(0.0, 1.0, 0.001) = 0.08;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float water_mask = 1.0 - smoothstep(
		tolerance * 0.25,
		tolerance,
		distance(base.rgb, water_blue.rgb)
	);
	water_mask *= base.a;

	vec4 water = texture(water_texture, SCREEN_UV);
	COLOR = vec4(mix(base.rgb, water.rgb, water_mask), base.a);
}
