// The start circle on the floor: a pulsing ring with a faint fill and dashes. `fade` 0..1 hides it; `urgency`
// 0..1 (a player nearing the edge) warms it towards orange and speeds up the pulse.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 color : source_color = vec3(0.36, 0.88, 1.0);
uniform float radius = 4.0;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float urgency : hint_range(0.0, 1.0) = 0.0;
uniform vec3 hot_color : source_color = vec3(1.0, 0.54, 0.24);
uniform float half_extent = 8.0;  // the plane is 2 * half_extent wide (16 m: radius up to ~7.4 m)

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * half_extent;
	float d = length(p);
	float pulse = 0.5 + 0.5 * sin(TIME * (3.0 + 9.0 * urgency));
	float ring = 1.0 - smoothstep(0.06 + 0.06 * urgency, 0.14 + 0.05 * pulse + 0.12 * urgency, abs(d - radius));
	float fill = (1.0 - smoothstep(radius - 0.1, radius, d)) * 0.07;
	float angle = atan(p.y, p.x);
	float dashes = step(0.5, fract(angle * 6.0 / 3.14159 + TIME * 0.25));
	float outer = (1.0 - smoothstep(0.02, 0.06, abs(d - radius - 0.45))) * dashes * 0.55;
	float wave = (1.0 - smoothstep(0.0, 0.25, abs(d - fract(TIME * 0.6) * radius))) * 0.12 * step(d, radius);
	float a = (ring * (0.65 + 0.35 * pulse) * (1.0 + urgency) + fill + outer + wave) * fade;
	ALBEDO = mix(color, hot_color, urgency) * a * 1.6;
}
