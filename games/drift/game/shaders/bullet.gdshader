// Bullets (game/bulk/bullet_view.gd): a soft glowing slug in the owner's colour.
// INSTANCE_CUSTOM.x: the slot of the owner (0..3), an index into `palette` (UiTheme.PLAYER_COLORS, set by the view);
// -1 once the owner has left (a pale grey).
shader_type canvas_item;

uniform vec4 palette[4] : source_color;

varying vec4 v_color;

void vertex() {
	int slot = int(floor(INSTANCE_CUSTOM.x + 0.5));
	v_color = slot < 0 ? vec4(0.8, 0.8, 0.85, 1.0) : palette[min(slot, 3)];
}

void fragment() {
	float r = length((UV - 0.5) * 2.0);
	float core = 1.0 - smoothstep(0.15, 0.5, r);
	float glow = 1.0 - smoothstep(0.35, 1.0, r);
	vec3 c = mix(v_color.rgb, vec3(1.0), core * 0.75);
	COLOR = vec4(c, max(core, glow * 0.65)) * COLOR;
}
