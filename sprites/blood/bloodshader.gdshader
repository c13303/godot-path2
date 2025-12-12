shader_type canvas_item;

uniform float frames = 3.0;
uniform vec4 blood_color : source_color = vec4(0.6, 0.0, 0.0, 0.75);

varying float v_frame;

void vertex() {
	v_frame = INSTANCE_CUSTOM.r;
}

void fragment() {
	vec2 uv = UV;
	uv.x = uv.x / frames + v_frame / frames;

	vec4 tex = texture(TEXTURE, uv);

	vec4 c = blood_color;
	c.a *= tex.a;
	c.a = min(c.a, blood_color.a);

	COLOR = c;
}
