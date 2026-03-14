/*
	Ghost Hologram Shader — FocusPals
	Old computer / wireframe hologram effect for Tama's ghost silhouette.
	Applied as a spatial post-process on a camera quad (same as glitch_effect).

	intensity = 0.0: passthrough (no effect)
	intensity = 1.0: full hologram ghost (scanlines, flicker, tint)
	Transition from 1→0 = materialization (hologram dissolves into solid Tama)
*/

shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled;

// Master intensity: 0 = solid (no effect), 1 = full hologram
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// Hologram color tint (cyan = old computer monitor)
uniform vec4 holo_color : source_color = vec4(0.3, 0.9, 1.0, 1.0);
// Scanline frequency and intensity
uniform float scanline_count : hint_range(50.0, 500.0) = 180.0;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.35;
// Flicker speed and amount
uniform float flicker_speed : hint_range(1.0, 20.0) = 8.0;
uniform float flicker_amount : hint_range(0.0, 0.5) = 0.15;
// Chromatic aberration (RGB split)
uniform float aberration : hint_range(0.0, 0.01) = 0.003;
// Random glitch block probability
uniform float glitch_rate : hint_range(0.0, 1.0) = 0.08;
uniform float glitch_strength : hint_range(0.0, 0.1) = 0.03;
// Edge glow boost (makes silhouette edges brighter)
uniform float edge_glow : hint_range(0.0, 3.0) = 1.5;
// Overall ghost alpha (how transparent the hologram is)
uniform float ghost_alpha : hint_range(0.0, 1.0) = 0.6;
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
			// ── Luminance for edge/brightness detection ──
			float luma = dot(color, vec3(0.299, 0.587, 0.114));

			// ── Scanlines (horizontal CRT lines) ──
			float scanline = sin(SCREEN_UV.y * scanline_count * 3.14159) * 0.5 + 0.5;
			scanline = mix(1.0, scanline, scanline_strength * intensity);

			// ── Flicker (temporal brightness variation) ──
			float flicker = 1.0 - flicker_amount * intensity * sin(TIME * flicker_speed) * sin(TIME * flicker_speed * 0.7 + 1.3);

			// ── Color tinting (mix original with hologram color) ──
			vec3 tinted = mix(color, holo_color.rgb * luma * edge_glow, intensity * 0.8);

			// ── Random horizontal noise lines (old TV interference) ──
			float noise_line = random2(vec2(trunc(SCREEN_UV.y * 400.0), trunc(TIME * 15.0)));
			float noise_mask = float(noise_line > 0.97) * 0.15 * intensity;

			// ── Combine everything ──
			final_color = tinted * scanline * flicker + vec3(noise_mask);

			// ── Alpha: ghost is more transparent at higher intensity ──
			final_alpha = a * mix(1.0, ghost_alpha, intensity);
		}
	}

	ALBEDO = final_color;
	ALPHA = final_alpha;
}
