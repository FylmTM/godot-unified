// XP gems: glowing, spinning and bobbing by their age (INSTANCE_CUSTOM.g), phase-shifted per instance.
shader_type spatial;
render_mode unshaded;

uniform vec3 color : source_color = vec3(0.36, 1.0, 0.69);
uniform float energy = 2.2;

void vertex() {
	float t = INSTANCE_CUSTOM.g * 2.5 + float(INSTANCE_ID) * 0.37;
	float c = cos(t);
	float s = sin(t);
	VERTEX = vec3(c * VERTEX.x + s * VERTEX.z, VERTEX.y, -s * VERTEX.x + c * VERTEX.z);
	VERTEX.y += 0.45 + 0.12 * sin(t * 1.7);
	VERTEX *= clamp(INSTANCE_CUSTOM.g * 5.0, 0.0, 1.0);
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO = color * energy * (0.65 + 0.35 * facing);
}
