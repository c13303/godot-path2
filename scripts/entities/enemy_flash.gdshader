shader_type canvas_item;

instance uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV) * COLOR;
	vec3 flashed = mix(base.rgb, vec3(base.a), flash_amount);
	COLOR = vec4(flashed, base.a);
}
