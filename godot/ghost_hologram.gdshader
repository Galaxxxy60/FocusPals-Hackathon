/*
	Ghost Hologram Shader — FocusPals
	Old computer / hologram effect for Tama's ghost silhouette.
	Applied as a spatial post-process on a camera quad (same as glitch_effect).

	intensity = 0.0: passthrough (no effect)
	intensity = 1.0: full hologram ghost (desaturated, scanlines, flicker, tint)
	Transition from 1→0 = materialization (hologram dissolves into solid Tama)
*/

shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled;

// Master intensity: 0 = solid (no effect), 1 = full hologram
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// Hologram color tint (cyan = old computer monitor)
uniform vec4 holo_color : source_color = vec4(0.3, 0.9, 1.0, 1.0);
// Desaturation: 0 = keep original colors, 1 = fully grayscale before tinting
uniform float desaturation : hint_range(0.0, 1.0) = 0.85;
// Scanline frequency and intensity
uniform float scanline_count : hint_range(50.0, 500.0) = 180.0;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.25;
// Flicker speed and amount
uniform float flicker_speed : hint_range(1.0, 20.0) = 8.0;
uniform float flicker_amount : hint_range(0.0, 0.5) = 0.08;
// Chromatic aberration (RGB split)
uniform float aberration : hint_range(0.0, 0.01) = 0.002;
// Random glitch block probability
uniform float glitch_rate : hint_range(0.0, 1.0) = 0.05;
uniform float glitch_strength : hint_range(0.0, 0.1) = 0.02;
// Edge glow boost (makes silhouette edges brighter)
uniform float edge_glow : hint_range(0.0, 3.0) = 1.2;
// Overall ghost alpha (how transparent the hologram is — lower = more ghostly)
uniform float ghost_alpha : hint_range(0.0, 1.0) = 0.35;
// Scan reveal: 0 = fully invisible, 1 = fully visible
// Sweeps top→bottom like a CRT powering on
uniform float fade_in : hint_range(0.0, 1.0) = 1.0;
// Scan line edge thickness (how soft the reveal edge is)
uniform float scan_edge : hint_range(0.001, 0.1) = 0.03;
// How much to tint vs keep original (0 = full original, 1 = full hologram color)
uniform float tint_strength : hint_range(0.0, 1.0) = 0.5;
// Screen texture
uniform sampler2D screen_texture : hint_screen_texture;

float random(float seed) {
	return fract(543.2543 * sin(dot(vec2(seed, seed), vec2(3525.46, -54.3415))));
}

float random2(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 final_color = vec3(0.0);
	float final_alpha = 0.0;

	if (intensity < 0.001) {
		// No effect — passthrough
		vec4 c = textureLod(screen_texture, uv, 0.0);
		final_color = c.rgb;
		final_alpha = c.a;
	} else {
		// ── Glitch block displacement ──
		float time_block = trunc(TIME * 6.0);
		float do_glitch = float(random(time_block) < glitch_rate * intensity);
		float block_y = trunc(uv.y * 30.0) / 30.0;
		float glitch_offset = (random(block_y + time_block) - 0.5) * glitch_strength * do_glitch * intensity;
		uv.x += glitch_offset;

		// ── Chromatic aberration (RGB split) ──
		float ab = aberration * intensity;
		float r = textureLod(screen_texture, uv + vec2(ab, 0.0), 0.0).r;
		float g = textureLod(screen_texture, uv, 0.0).g;
		float b = textureLod(screen_texture, uv - vec2(ab, 0.0), 0.0).b;
		float a = textureLod(screen_texture, uv, 0.0).a;
		vec3 color = vec3(r, g, b);

		if (a < 0.01) {
			// Transparent pixel — no hologram
			final_color = vec3(0.0);
			final_alpha = 0.0;
		} else {
			// ── Desaturation (wash out original colors → grayscale) ──
			float luma = dot(color, vec3(0.299, 0.587, 0.114));
			vec3 gray = vec3(luma);
			vec3 desaturated = mix(color, gray, desaturation * intensity);

			// ── Scanlines (horizontal CRT lines) ──
			float scanline = sin(SCREEN_UV.y * scanline_count * 3.14159) * 0.5 + 0.5;
			scanline = mix(1.0, scanline, scanline_strength * intensity);

			// ── Flicker (temporal brightness variation — subtle) ──
			float flicker = 1.0 - flicker_amount * intensity * sin(TIME * flicker_speed) * sin(TIME * flicker_speed * 0.7 + 1.3);

			// ── Color tinting (mix desaturated with hologram color) ──
			// tint_strength controls how much cyan vs original grayscale
			vec3 tinted = mix(desaturated, holo_color.rgb * luma * edge_glow, tint_strength * intensity);

			// ── Random horizontal noise lines (old TV interference — subtle) ──
			float noise_line = random2(vec2(trunc(SCREEN_UV.y * 400.0), trunc(TIME * 15.0)));
			float noise_mask = float(noise_line > 0.98) * 0.08 * intensity;

			// ── Combine everything ──
			vec3 holo_result = tinted * scanline * flicker + vec3(noise_mask);

			// ── Output holographic color, alpha passthrough (ALPHA_HASH controls visibility) ──
			final_color = mix(color, holo_result, intensity);
			final_alpha = a;  // Let ALPHA_HASH on the materials control pixel visibility
		}
	}

	ALBEDO = final_color;
	ALPHA = final_alpha;
}
