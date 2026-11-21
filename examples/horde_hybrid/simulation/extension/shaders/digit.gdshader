// A damage-number digit (draw.odin's digit batch): seven segments lighting INSTANCE_CUSTOM.x in COLOR, outlined
// black (Odin moves and fades it).
shader_type canvas_item;

varying float v_digit;

// Which segments each digit lights: a b c d e f g as bits 0..6.
const int SEGMENTS[10] = int[](63, 6, 91, 79, 102, 109, 125, 7, 127, 111);

void vertex() {
	v_digit = INSTANCE_CUSTOM.x;
}

float segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

void fragment() {
	vec2 p = vec2(UV.x * 1.2 - 0.1, UV.y * 1.2 - 0.1);
	int bits = SEGMENTS[clamp(int(v_digit + 0.5), 0, 9)];
	vec2 ends[14] = vec2[](
		vec2(0.15, 0.05), vec2(0.85, 0.05),
		vec2(0.85, 0.05), vec2(0.85, 0.5),
		vec2(0.85, 0.5), vec2(0.85, 0.95),
		vec2(0.15, 0.95), vec2(0.85, 0.95),
		vec2(0.15, 0.5), vec2(0.15, 0.95),
		vec2(0.15, 0.05), vec2(0.15, 0.5),
		vec2(0.15, 0.5), vec2(0.85, 0.5)
	);
	float d = 10.0;
	for (int i = 0; i < 7; i++) {
		if ((bits & (1 << i)) != 0) {
			d = min(d, segment(p, ends[i * 2], ends[i * 2 + 1]));
		}
	}
	float fill = 1.0 - smoothstep(0.07, 0.11, d);
	float outline = 1.0 - smoothstep(0.13, 0.19, d);
	COLOR = vec4(mix(vec3(0.0), COLOR.rgb, fill), outline * COLOR.a);
}
