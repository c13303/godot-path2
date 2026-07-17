shader_type canvas_item;

instance uniform float float_amplitude = 0.0;
uniform float float_speed = 1.65;
instance uniform float float_phase = 0.0;

void vertex() {
	VERTEX.y += sin(TIME * float_speed + float_phase) * float_amplitude;
}
