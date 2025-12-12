shader_type canvas_item;

uniform float frames = 3.0;

varying float v_frame;
varying float v_alpha;

void vertex() {
	v_frame = INSTANCE_CUSTOM.x;
	v_alpha = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 uv = UV;
	uv.x = uv.x / frames + v_frame / frames;
	vec4 c = texture(TEXTURE, uv);
	c.a *= v_alpha;
	COLOR = c;
}
