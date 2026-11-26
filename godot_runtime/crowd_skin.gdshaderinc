// unified's crowd skinning: what a crowd's spatial shader includes to pose a baked character (unified's crowd bake)
// from its bone texture, so a whole crowd is one MultiMesh, one draw call a pass, and its animation costs no node:
//   #include "res://unified/godot_runtime/crowd_skin.gdshaderinc"
// Its one uniform is the bake's Image as a texture (UnifiedCrowdClips.apply sets it). The texture holds the clip table
// in its header row (UnifiedCrowdClips says the layout), so the material needs nothing else, whatever the clips.
//
// In vertex(), the game picks the clip and the seconds into it (from its instance's custom data, say) and skins:
//   mat4 skin = unified_crowd_skinning(clip, seconds, CUSTOM0, CUSTOM1);
//   VERTEX = (skin * vec4(VERTEX, 1.0)).xyz;
//   NORMAL = normalize(mat3(skin) * NORMAL);
// The bake's mesh carries each vertex's four bones in CUSTOM0 and their weights in CUSTOM1, and its masked parts'
// UV2.x (a masked material's index plus one; 0 elsewhere) for the game's own look. A loop wraps, a one-shot
// holds its first frame before its start and its last past its end, and two frames' matrices blend entry by entry:
// UnifiedCrowdClips.matrices computes the same on the CPU.

uniform sampler2D unified_crowd_bones : filter_nearest, repeat_disable;

// The bone texture's texel at column `x`, row `row`.
vec4 unified_crowd_texel(int x, int row) {
	return texelFetch(unified_crowd_bones, ivec2(x, row), 0);
}

// The clips the texture holds.
int unified_crowd_clip_count() {
	return int(texelFetch(unified_crowd_bones, ivec2(0, 0), 0).r);
}

// Clip `clip`'s header texel, the clip clamped to the table: (first row, frames, frames a second, loops).
vec4 unified_crowd_clip(int clip) {
	int last = max(unified_crowd_clip_count() - 1, 0);
	return texelFetch(unified_crowd_bones, ivec2(1 + clamp(clip, 0, last), 0), 0);
}

// Clip `clip`'s length in seconds.
float unified_crowd_clip_length(int clip) {
	vec4 header = unified_crowd_clip(clip);
	return (header.g - 1.0) / header.b;
}

// The skinning matrix of a vertex bound to `bones` (four bone indices) with `weights` in clip `clip` at `seconds` into
// it: each bone's matrix blended between the clip's two frames around that time, summed by weight.
mat4 unified_crowd_skinning(int clip, float seconds, vec4 bones, vec4 weights) {
	vec4 header = unified_crowd_clip(clip);
	int frames = int(header.g + 0.5);
	float clip_length = (header.g - 1.0) / header.b;
	float held = header.a > 0.5 ? mod(seconds, clip_length) : clamp(seconds, 0.0, clip_length);
	float at = held * header.b;
	int frame = clamp(int(floor(at)), 0, frames - 2);
	float blend = at - float(frame);
	int row = int(header.r + 0.5) + frame;
	vec4 r0 = vec4(0.0);
	vec4 r1 = vec4(0.0);
	vec4 r2 = vec4(0.0);
	for (int k = 0; k < 4; k++) {
		if (weights[k] > 0.0) {
			int x = int(bones[k] + 0.5) * 3;
			r0 += weights[k] * mix(unified_crowd_texel(x, row), unified_crowd_texel(x, row + 1), blend);
			r1 += weights[k] * mix(unified_crowd_texel(x + 1, row), unified_crowd_texel(x + 1, row + 1), blend);
			r2 += weights[k] * mix(unified_crowd_texel(x + 2, row), unified_crowd_texel(x + 2, row + 1), blend);
		}
	}
	// the rows of a 3x4 matrix, as a column-major mat4
	return transpose(mat4(r0, r1, r2, vec4(0.0, 0.0, 0.0, 1.0)));
}
