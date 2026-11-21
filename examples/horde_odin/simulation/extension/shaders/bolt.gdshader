// A bolt (the `bolt` MultiMesh view): a glowing head at the quad's +x end and a streak fading behind it, along the
// instance's rotation (its heading). INSTANCE_CUSTOM.x is the shooter's slot, an index into `palette`.
shader_type canvas_item;

uniform vec4 palette[4] : source_color;

varying vec4 v_color;

void vertex() {
	v_color = palette[min(int(INSTANCE_CUSTOM.x + 0.5), 3)];
}

void fragment() {
	// UV.x 0 (tail) .. 1 (head); UV.y across
	float across = abs(UV.y - 0.5) * 2.0;
	float head = length(vec2((UV.x - 0.88) * 4.0, across));
	float core = 1.0 - smoothstep(0.2, 0.5, head);
	float trail = UV.x * UV.x * (1.0 - smoothstep(0.1, 0.6 * UV.x + 0.1, across));
	vec3 c = mix(v_color.rgb, vec3(1.0), core);
	COLOR = vec4(c, max(core, trail * 0.7));
}
