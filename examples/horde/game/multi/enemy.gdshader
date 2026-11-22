// An enemy (the `enemy` MultiMesh view): a shadow, a body with an outline, two eyes toward its heading (the
// instance's rotation), a wobble, a white hit flash. INSTANCE_CUSTOM = {kind (an index into `kind_colors`), hit flash,
// HP share, radius in px}; the instance scale makes the unit quad ENEMY_QUAD_RADII radii each way (frame.odin), the
// 3.2 below. (VERTEX already holds the instance transform in vertex(): shapes are drawn from UV.)
shader_type canvas_item;

uniform vec4 kind_colors[3] : source_color;

varying vec4 v_custom;
varying float v_wobble;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_wobble = sin(TIME * 9.0 + float(INSTANCE_ID) * 1.7) * 0.08;
}

void fragment() {
	vec2 p = (UV - 0.5) * 3.2 / vec2(1.0 + v_wobble, 1.0 - v_wobble);
	int kind = int(v_custom.x + 0.5);
	vec3 body = v_custom.y > 0.5 ? vec3(1.0) : kind_colors[min(kind, 2)].rgb;
	vec4 c = vec4(0.0);
	float shadow = length(vec2(p.x, (p.y - 0.55) / 0.55));
	c = mix(c, vec4(0.0, 0.0, 0.0, 0.35), step(shadow, 1.0));
	float r = length(p);
	c = mix(c, vec4(body * 0.55, 1.0), step(r, 1.0));
	c = mix(c, vec4(body, 1.0), step(r, 0.82));
	// eyes toward +x (the heading)
	for (int i = 0; i < 2; i++) {
		vec2 eye = vec2(0.35, i == 0 ? 0.32 : -0.32);
		c = mix(c, vec4(1.0), step(length(p - eye), 0.2));
		c = mix(c, vec4(0.05, 0.05, 0.08, 1.0), step(length(p - eye - vec2(0.07, 0.0)), 0.1));
	}
	COLOR = c;
}
