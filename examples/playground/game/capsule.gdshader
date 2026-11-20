// The capsule MultiMesh: a unit sphere stretched into each instance's capsule. INSTANCE_CUSTOM.x is the radius,
// .y the half length of the segment along the instance's y (frame.odin's Capsule kind); the colour is the instance's.
shader_type spatial;

varying vec3 tint;

void vertex() {
	VERTEX = VERTEX * INSTANCE_CUSTOM.x + vec3(0.0, sign(VERTEX.y) * INSTANCE_CUSTOM.y, 0.0);
	tint = COLOR.rgb;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.8;
}
