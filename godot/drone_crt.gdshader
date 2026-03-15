shader_type canvas_item;

// CRT old-school effect for the drone's screen SubViewport
// Applied as overlay on top of the text content

uniform float scanline_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float scanline_count : hint_range(10.0, 200.0) = 80.0;
uniform float flicker_speed : hint_range(0.0, 20.0) = 8.0;
uniform float flicker_intensity : hint_range(0.0, 0.15) = 0.04;
uniform float vignette_intensity : hint_range(0.0, 2.0) = 0.8;
uniform float curvature : hint_range(0.0, 0.1) = 0.02;
uniform float chromatic_aberration : hint_range(0.0, 5.0) = 1.2;
uniform float glow_intensity : hint_range(0.0, 1.0) = 0.15;
uniform vec4 tint_color : source_color = vec4(0.3, 0.9, 0.6, 1.0);

vec2 curve_uv(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) * curvature;
    uv = uv + uv * offset * offset;
    uv = uv * 0.5 + 0.5;
    return uv;
}

void fragment() {
    vec2 uv = curve_uv(UV);

    // Out of bounds after curvature = black
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        COLOR = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    // Chromatic aberration (RGB split)
    vec2 ca_offset = vec2(chromatic_aberration / 256.0, 0.0);
    float r = texture(TEXTURE, uv + ca_offset).r;
    float g = texture(TEXTURE, uv).g;
    float b = texture(TEXTURE, uv - ca_offset).b;
    float a = texture(TEXTURE, uv).a;
    vec4 col = vec4(r, g, b, a);

    // Scanlines
    float scanline = sin(uv.y * scanline_count * TAU) * 0.5 + 0.5;
    scanline = pow(scanline, 1.5);
    col.rgb -= scanline * scanline_intensity * 0.5;

    // Flicker (subtle brightness variation)
    float flicker = 1.0 - flicker_intensity * sin(TIME * flicker_speed + uv.y * 3.0);
    col.rgb *= flicker;

    // Phosphor glow (boost bright pixels)
    float luminance = dot(col.rgb, vec3(0.299, 0.587, 0.114));
    col.rgb += luminance * glow_intensity * tint_color.rgb;

    // Vignette (dark edges)
    vec2 vig_uv = uv * (1.0 - uv.yx);
    float vig = vig_uv.x * vig_uv.y * 15.0;
    vig = pow(vig, vignette_intensity * 0.5);
    col.rgb *= vig;

    COLOR = col;
}
