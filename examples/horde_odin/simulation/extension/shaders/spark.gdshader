// A spark (draw.odin's spark batch): a soft dot in COLOR, its size the instance scale (Odin moves and fades it).
shader_type canvas_item;

void fragment() {
	float r = length((UV - 0.5) * 2.0);
	if (r > 1.0) {
		discard;
	}
	COLOR = vec4(COLOR.rgb, COLOR.a * (1.0 - smoothstep(0.6, 1.0, r)));
}
