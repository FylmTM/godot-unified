// MultiMesh views (enemies, projectiles): toon-lit flat colour, white hit flash from INSTANCE_CUSTOM.r,
// a spawn pop-in from INSTANCE_CUSTOM.g (age in seconds), optional emission.
shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform vec3 albedo : source_color = vec3(0.23, 0.43, 0.65);
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float rim = 0.35;
uniform bool pop_in = true;
// Instance positions are on the floor plane (y = 0); lift the mesh so it stands on it.
uniform float lift = 0.0;

varying float flash;

void vertex() {
	flash = INSTANCE_CUSTOM.r;
	// Age 0 means "no custom data" (a host that doesn't fill it): full size, no pop-in.
	if (pop_in && INSTANCE_CUSTOM.g > 0.0) {
		float s = clamp(INSTANCE_CUSTOM.g * 4.0, 0.0, 1.0);
		VERTEX *= s * (1.0 + 0.15 * sin(s * 3.14159));
	}
	VERTEX *= 1.0 + flash * 0.12;
	VERTEX.y += lift;
}

void fragment() {
	ALBEDO = mix(albedo, vec3(1.0), flash * 0.85);
	EMISSION = emission_color * emission_energy + vec3(flash * 0.6);
	ROUGHNESS = 0.7;
	RIM = rim;
	RIM_TINT = 0.2;
}
