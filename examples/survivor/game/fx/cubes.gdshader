// Cubes (game/fx/cubes.gd): each instance flies from its origin (the transform's; the basis is its size and first
// turn) with velocity INSTANCE_CUSTOM.xyz, born at INSTANCE_CUSTOM.w (seconds on `now`'s clock); its spray's gravity
// and life are the node's (instance uniforms). Drag and gravity in closed form; it tumbles about its flight, shrinks to
// nothing over its life, and collapses past it.
shader_type spatial;
render_mode unshaded, cull_disabled, world_vertex_coords;

uniform float now;
instance uniform float gravity;
instance uniform float life = 1.0;
const float DRAG = 2.0;
const float SPIN = 6.283; // radians per second at most, either way

void vertex() {
	float age = now - INSTANCE_CUSTOM.w;
	float k = age / life;
	vec3 center = MODEL_MATRIX[3].xyz;
	if (k < 0.0 || k >= 1.0) {
		VERTEX = center;
	} else {
		float fall = (1.0 - exp(-DRAG * age)) / DRAG;
		vec3 flight = INSTANCE_CUSTOM.xyz * fall + vec3(0.0, gravity, 0.0) * (age - fall) / DRAG;
		vec3 v = (VERTEX - center) * (1.0 - k);
		float speed = length(INSTANCE_CUSTOM.xyz);
		if (speed > 0.001) {
			vec3 axis = INSTANCE_CUSTOM.xyz / speed;
			float angle = (fract(sin(float(INSTANCE_ID) * 12.9898) * 43758.5453) * 2.0 - 1.0) * SPIN * age;
			v = v * cos(angle) + cross(axis, v) * sin(angle) + axis * dot(axis, v) * (1.0 - cos(angle));
		}
		VERTEX = center + flight + v;
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
