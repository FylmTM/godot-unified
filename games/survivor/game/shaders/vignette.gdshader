// Screen-edge vignette for damage and low-HP feedback: `color` with alpha `intensity` at the edges, clear centre.
shader_type canvas_item;

uniform vec4 color : source_color = vec4(1.0, 0.15, 0.2, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 p = (UV - 0.5) * vec2(1.6, 1.0);
	float edge = smoothstep(0.55, 1.1, length(p) * 1.25);
	COLOR = vec4(color.rgb, color.a * edge * intensity);
}
