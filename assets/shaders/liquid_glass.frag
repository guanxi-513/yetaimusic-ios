#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uRefraction;
uniform float uDispersion;
uniform float uHighlightOn;
uniform vec2 uHighlight;
uniform float uReveal;

out vec4 fragColor;

float roundedBoxSDF(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 spectral(float t) {
  return 0.5 + 0.5 * cos(6.2831853 * (t + vec3(0.0, 0.33, 0.67)));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;

  vec2 halfSize = uSize * 0.5;
  float dist = roundedBoxSDF(frag - halfSize, halfSize, 22.0);
  float edge = 1.0 - smoothstep(0.0, 1.2, abs(dist));
  float rim = 1.0 - smoothstep(0.0, 1.4, abs(dist));

  vec3 col = vec3(0.0);
  float alpha = 0.0;

  // 顶部厚度高光
  float sheen = smoothstep(0.0, 0.85, uv.y) * 0.08;
  col += vec3(1.0) * sheen;
  alpha += sheen * 0.5;

  // 边缘色散镶边
  col += spectral(uv.x * 0.7 + uv.y * 0.35) * edge * uDispersion * 0.3;
  alpha += edge * uDispersion * 0.15;

  // 边缘高光
  col += vec3(1.0) * rim * 0.15;
  alpha += rim * 0.15;

  // 手势跟手液态涟漪
  float d = length(frag - uHighlight);
  float ripple = exp(-d / (uSize.y * 0.15));
  col += vec3(0.9, 0.95, 1.0) * ripple * uHighlightOn * 0.4;
  alpha += ripple * uHighlightOn * 0.2;

  // 过渡
  alpha *= uReveal;

  fragColor = vec4(col, clamp(alpha, 0.0, 1.0));
}
