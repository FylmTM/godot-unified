// Gems (game/multi/gem_view.gd): the instance colour (extract fades it before expiry) with a glint that sweeps
// across now and then. INSTANCE_CUSTOM.x: the gem's age in seconds. UV.x: 0 centre .. 1 rim.
shader_type canvas_item;

varying float v_age;

void vertex() {
	v_age = INSTANCE_CUSTOM.x;
}

void fragment() {
	float glint = pow(max(0.0, sin(v_age * 3.0 + UV.y * 6.2832)), 8.0);
	vec3 c = COLOR.rgb * (1.15 - 0.35 * UV.x) + vec3(glint * 0.6);
	c = mix(c, vec3(1.0, 0.97, 0.85), smoothstep(0.85, 1.0, UV.x) * 0.6);
	COLOR = vec4(c, COLOR.a);
}
