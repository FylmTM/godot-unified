// A damaged enemy's HP bar (the `bar` MultiMesh view): INSTANCE_CUSTOM.x is the HP share.
shader_type canvas_item;

varying float v_hp;

void vertex() {
	v_hp = INSTANCE_CUSTOM.x;
}

void fragment() {
	COLOR = UV.x < v_hp ? vec4(0.9, 0.2, 0.2, 1.0) : vec4(0.0, 0.0, 0.0, 0.6);
}
