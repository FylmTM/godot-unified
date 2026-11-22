// A gem (the `gem` MultiMesh view): a bobbing diamond. INSTANCE_CUSTOM = {value, phase 0..1}.
shader_type canvas_item;

varying float v_size;

void vertex() {
	v_size = 0.55 + 0.15 * INSTANCE_CUSTOM.x;
	VERTEX.y += sin(TIME * 5.0 + INSTANCE_CUSTOM.y * 6.2831) * 2.0;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = abs(p.x) / 0.7 + abs(p.y);
	if (d > v_size) {
		discard;
	}
	COLOR = d > v_size - 0.15 ? vec4(0.8, 1.0, 1.0, 1.0) : vec4(0.3, 0.9, 1.0, 1.0);
}
