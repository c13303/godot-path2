shader_type canvas_item;

// Tiles a horizontal N-frame animation strip across the whole background quad
// and cycles through the frames over time.
// The source texture is a strip of `frame_count` frames laid out left-to-right,
// each frame `tile_px` wide (e.g. 128x32 = 4 frames of 32x32).
uniform sampler2D anim_tex : filter_nearest, repeat_disable;
uniform vec2 region_px = vec2(4128.0, 3552.0); // size of the background quad in pixels
uniform float tile_px = 32.0;                   // size of one tile / frame in pixels
uniform int frame_count = 4;
uniform float fps = 6.0;

void fragment() {
	vec2 tuv = UV * region_px / tile_px; // position in tile units across the map
	vec2 local = fract(tuv);             // position within the current tile (0..1)

	float f = floor(mod(TIME * fps, float(frame_count)));

	vec2 samp;
	samp.x = (f + local.x) / float(frame_count);
	samp.y = local.y;

	COLOR = texture(anim_tex, samp);
}
