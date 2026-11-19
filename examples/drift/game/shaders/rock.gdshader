// Rocks (game/multi/rock_view.gd): stone shaded by size, a bright rim, a white flash on a hit.
// INSTANCE_CUSTOM: x = size (0 small, 1 medium, 2 large), y = hit flash 0..1. UV.x: 0 centre .. 1 rim.
shader_type canvas_item;

uniform vec4 stone : source_color = vec4(0.47, 0.42, 0.40, 1.0);
uniform vec4 rim : source_color = vec4(0.78, 0.70, 0.62, 1.0);

varying float v_size;
varying float v_flash;

void vertex() {
	v_size = INSTANCE_CUSTOM.x;
	v_flash = INSTANCE_CUSTOM.y;
}

void fragment() {
	float edge = smoothstep(0.80, 0.93, UV.x);
	vec3 c = stone.rgb * (0.8 + 0.12 * v_size) * (0.85 + 0.15 * (1.0 - UV.x));
	c = mix(c, rim.rgb, edge);
	c = mix(c, vec3(1.0), v_flash * 0.85);
	COLOR = vec4(c, 1.0) * COLOR;
}
