// Damage-number digits (game/fx/numbers.gd): a seven-segment digit INSTANCE_CUSTOM.x, born at INSTANCE_CUSTOM.y on
// `now`'s clock, drifting INSTANCE_CUSTOM.z px/s sideways; it rises and fades over LIFE, then collapses.
shader_type canvas_item;

uniform float now;
const float LIFE = 0.7;
const float RISE = 40.0;

varying float v_k;
varying float v_digit;

// Which segments each digit lights: a b c d e f g as bits 0..6.
const int SEGMENTS[10] = int[](63, 6, 91, 79, 102, 109, 125, 7, 127, 111);

void vertex() {
	float age = now - INSTANCE_CUSTOM.y;
	v_k = age / LIFE;
	v_digit = INSTANCE_CUSTOM.x;
	if (v_k < 0.0 || v_k >= 1.0) {
		VERTEX = vec2(0.0);
	} else {
		VERTEX += vec2(INSTANCE_CUSTOM.z, -RISE) * age;
	}
}

float segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

void fragment() {
	vec2 p = vec2(UV.x * 1.2 - 0.1, UV.y * 1.2 - 0.1);  // 0..1 inside a margin
	int bits = SEGMENTS[clamp(int(v_digit + 0.5), 0, 9)];
	vec2 ends[14] = vec2[](
		vec2(0.15, 0.05), vec2(0.85, 0.05),  // a
		vec2(0.85, 0.05), vec2(0.85, 0.5),  // b
		vec2(0.85, 0.5), vec2(0.85, 0.95),  // c
		vec2(0.15, 0.95), vec2(0.85, 0.95),  // d
		vec2(0.15, 0.5), vec2(0.15, 0.95),  // e
		vec2(0.15, 0.05), vec2(0.15, 0.5),  // f
		vec2(0.15, 0.5), vec2(0.85, 0.5)  // g
	);
	float d = 10.0;
	for (int i = 0; i < 7; i++) {
		if ((bits & (1 << i)) != 0) {
			d = min(d, segment(p, ends[i * 2], ends[i * 2 + 1]));
		}
	}
	float fill = 1.0 - smoothstep(0.07, 0.11, d);
	float outline = 1.0 - smoothstep(0.13, 0.19, d);
	vec3 c = mix(vec3(0.0), COLOR.rgb, fill);
	COLOR = vec4(c, outline * (1.0 - v_k * v_k));
}
