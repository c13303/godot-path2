shader_type canvas_item;

uniform sampler2D water_texture : filter_nearest, repeat_disable;
uniform vec4 water_blue : source_color = vec4(0.050980, 0.749020, 1.0, 1.0);
uniform float tolerance : hint_range(0.0, 1.0, 0.001) = 0.08;
uniform int frame_count = 14;
uniform vec2 frame_size_px = vec2(13.0, 13.0);
uniform float animation_fps : hint_range(1.0, 30.0, 1.0) = 8.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float water_mask = 1.0 - smoothstep(
		tolerance * 0.25,
		tolerance,
		distance(base.rgb, water_blue.rgb)
	);
	water_mask *= base.a;

	float safe_frame_count = max(float(frame_count), 1.0);
	float frame_index = floor(mod(TIME * animation_fps, safe_frame_count));
	vec2 atlas_pixel = floor(UV / TEXTURE_PIXEL_SIZE);
	vec2 tiled_pixel = mod(atlas_pixel, frame_size_px) + vec2(0.5);
	vec2 sheet_size_px = vec2(frame_size_px.x * safe_frame_count, frame_size_px.y);
	vec2 water_uv = vec2(
		(frame_index * frame_size_px.x + tiled_pixel.x) / sheet_size_px.x,
		tiled_pixel.y / sheet_size_px.y
	);
	vec4 water = texture(water_texture, water_uv);

	COLOR = vec4(mix(base.rgb, water.rgb, water_mask), base.a);
}
