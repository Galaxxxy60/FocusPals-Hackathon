/*
	Glitch Effect Shader for Godot Engine 4
	Original by Yui Kinomoto @arlez80 — MIT License
	Adapted for FocusPals: spatial post-process on 3D camera quad.
*/

shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled;

// Master intensity: 0.0 = off, 1.0 = normal glitch, >1.0 = dramatic (quit effect)
uniform float intensity : hint_range(0.0, 10.0) = 0.0;
// Vibration strength
uniform float shake_power = 0.03;
// Vibration rate (probability of glitch frame)
uniform float shake_rate : hint_range(0.0, 1.0) = 0.2;
// Vibration speed
uniform float shake_speed = 5.0;
// Vibration block size
uniform float shake_block_size = 30.5;
// Color channel split amount
uniform float shake_color_rate : hint_range(0.0, 1.0) = 0.01;
// Screen texture (reads what was rendered BEFORE this quad)
uniform sampler2D screen_texture : hint_screen_texture;

float random(float seed) {
	return fract(543.2543 * sin(dot(vec2(seed, seed), vec2(3525.46, -54.3415))));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 pixel_color;

	if (intensity >= 0.001) {
		// At high intensity (>1), everything escalates dramatically
		float scaled_rate = min(shake_rate * intensity, 1.0);
		float scaled_power = shake_power * intensity;
		float scaled_color = shake_color_rate * intensity;
		// Speed + block size escalate for dramatic exit
		float scaled_speed = shake_speed + intensity * 3.0;
		float scaled_block = max(shake_block_size - intensity * 5.0, 3.0);

		float enable_shift = float(
			random(trunc(TIME * scaled_speed))
			< scaled_rate
		);

		uv.x += (
			random(
				(trunc(SCREEN_UV.y * scaled_block) / scaled_block)
			+	TIME
			) - 0.5
		) * scaled_power * enable_shift;

		// At extreme intensity, also shift Y (vertical tearing)
		if (intensity > 2.0) {
			uv.y += (
				random(
					(trunc(SCREEN_UV.x * scaled_block * 0.5) / (scaled_block * 0.5))
				+	TIME * 1.3
				) - 0.5
			) * scaled_power * 0.3 * enable_shift;
		}

		pixel_color = textureLod(screen_texture, uv, 0.0);
		pixel_color.r = mix(
			pixel_color.r,
			textureLod(screen_texture, uv + vec2(scaled_color, 0.0), 0.0).r,
			enable_shift
		);
		pixel_color.b = mix(
			pixel_color.b,
			textureLod(screen_texture, uv + vec2(-scaled_color, 0.0), 0.0).b,
			enable_shift
		);

		// At extreme intensity, fade to black (Tama dissolving)
		if (intensity > 3.0) {
			float fade = clamp((intensity - 3.0) / 5.0, 0.0, 1.0);
			pixel_color.rgb *= (1.0 - fade);
		}
	} else {
		pixel_color = textureLod(screen_texture, uv, 0.0);
	}

	ALBEDO = pixel_color.rgb;
	ALPHA = pixel_color.a;
}
