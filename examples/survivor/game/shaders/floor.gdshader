// Arena floor: dark slate with a 2 m grid, a brighter 10 m grid and a border band near the walls.
shader_type spatial;
render_mode diffuse_toon, specular_disabled;

uniform vec3 base_color : source_color = vec3(0.16, 0.18, 0.23);
uniform vec3 line_color : source_color = vec3(0.22, 0.25, 0.32);
uniform vec3 major_color : source_color = vec3(0.27, 0.31, 0.40);
uniform vec3 edge_color : source_color = vec3(0.10, 0.11, 0.15);
uniform float half_size = 30.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid_line(vec2 p, float spacing, float width) {
	vec2 g = abs(fract(p / spacing + 0.5) - 0.5) * spacing;
	vec2 aa = fwidth(p) * 1.2;
	vec2 l = 1.0 - smoothstep(vec2(width) - aa, vec2(width) + aa, g);
	return max(l.x, l.y);
}

void fragment() {
	vec2 p = world_pos.xz;
	vec3 c = base_color;
	c = mix(c, line_color, grid_line(p, 2.0, 0.03));
	c = mix(c, major_color, grid_line(p, 10.0, 0.06));
	float edge = max(abs(p.x), abs(p.y));
	c = mix(c, edge_color, smoothstep(half_size - 4.0, half_size, edge) * 0.8);
	// Soft centre lift so the middle reads brighter than the corners.
	c *= 1.0 + 0.12 * (1.0 - smoothstep(0.0, half_size, length(p)));
	ALBEDO = c;
	ROUGHNESS = 1.0;
}
