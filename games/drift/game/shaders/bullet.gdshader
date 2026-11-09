// Bullets (game/bulk/bullet_view.gd): a soft glowing slug in the owner's colour.
// INSTANCE_CUSTOM.x: the owner's slot (0..3), an index into `palette` (UiTheme.SLOT_COLORS, set by the view).
shader_type canvas_item;

uniform vec4 palette[4] : source_color;

varying vec4 v_color;

void vertex() {
	v_color = palette[clamp(int(INSTANCE_CUSTOM.x + 0.5), 0, 3)];
}

void fragment() {
	float r = length((UV - 0.5) * 2.0);
	float core = 1.0 - smoothstep(0.15, 0.5, r);
	float glow = 1.0 - smoothstep(0.35, 1.0, r);
	vec3 c = mix(v_color.rgb, vec3(1.0), core * 0.75);
	COLOR = vec4(c, max(core, glow * 0.65)) * COLOR;
}
