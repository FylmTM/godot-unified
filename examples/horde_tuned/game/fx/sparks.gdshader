// Sparks (game/fx/sparks.gd): each instance flies from its origin (the transform's) with velocity INSTANCE_CUSTOM.xy,
// born at INSTANCE_CUSTOM.z (seconds on `now`'s clock), living INSTANCE_CUSTOM.w; drag and gravity in closed form.
// It shrinks and fades as it ages, and collapses to nothing past its life. (VERTEX already holds the instance
// transform in vertex(): the flight is a translation, the shrink is the fragment's.)
shader_type canvas_item;

uniform float now;
const float GRAVITY = 260.0;
const float DRAG = 2.5;

varying float v_k;

void vertex() {
	float age = now - INSTANCE_CUSTOM.z;
	v_k = age / INSTANCE_CUSTOM.w;
	if (v_k < 0.0 || v_k >= 1.0) {
		VERTEX = vec2(0.0);
	} else {
		float fall = (1.0 - exp(-DRAG * age)) / DRAG;
		VERTEX += INSTANCE_CUSTOM.xy * fall + vec2(0.0, GRAVITY) * (age - fall) / DRAG;
	}
}

void fragment() {
	float r = length((UV - 0.5) * 2.0);
	if (r > 1.0 - 0.6 * v_k) {
		discard;
	}
	COLOR = vec4(COLOR.rgb, COLOR.a * (1.0 - v_k * v_k));
}
