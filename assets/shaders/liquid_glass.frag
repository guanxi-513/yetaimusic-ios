#version 460 core
precision highp float;
#include <flutter/runtime_effect.glsl>

// 液态玻璃折射着色器 —— 用于 BackdropFilter + ImageFilter.shader（Impeller）
// 真实折射：把已模糊的背景（uInput sampler，由引擎自动绑定）作为纹理，
// 在边缘带内用圆角矩形 SDF 的梯度把采样坐标掰弯（透镜式位移），边缘叠加色散。
// 算法移植自 Kyant0/AndroidLiquidGlass 的 RoundedRectRefractionShader。
//
// 引擎约定：
//  - 第一个 float uniform 必须是 vec2，引擎自动写入输入纹理尺寸
//  - 第一个 sampler2D 由引擎自动绑定为过滤输入（模糊后的背景）
//  - uniform 名字无强制要求；float 索引按声明顺序、跳过 sampler 计数

uniform vec2 uSize;          // 引擎自动设置（纹理尺寸，float 槽 0-1）
uniform sampler2D uInput;    // 引擎自动绑定（模糊后的背景，sampler 跳过计数）
uniform vec2 uHighlight;     // 手势高光中心（像素，float 槽 2-3）
uniform float uHighlightOn;  // 手势高光开关（槽 4）
uniform float uParallax;     // 滚动视差 0..1（槽 5）
uniform vec4 uFill;          // 玻璃填充 rgb + 浓度 a（槽 6-9）

out vec4 fragColor;

// ---- 圆角矩形 SDF（移植自 Backdrop Shaders.kt）----
float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 corner = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(corner, 0.0)) - radius;
  float inside = min(max(corner.x, corner.y), 0.0);
  return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 corner = abs(coord) - (halfSize - vec2(radius));
  if (corner.x >= 0.0 || corner.y >= 0.0) {
    return sign(coord) * normalize(max(corner, 0.0));
  } else {
    float gradX = step(corner.y, corner.x);
    return sign(coord) * vec2(gradX, 1.0 - gradX);
  }
}

float circleMap(float x) {
  return 1.0 - sqrt(1.0 - x * x);
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 uv = coord / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // 设计参数（可后续暴露到设置）
  float radius = 22.0;
  float refractionHeight = 12.0; // 边缘折射带宽度（px）
  float refractionAmount = 6.0;  // 边缘最大位移（px），越大透镜感越强

  vec2 halfSize = uSize * 0.5;
  vec2 centered = coord - halfSize;

  float sd = sdRoundedRect(centered, halfSize, radius);
  vec3 col = vec3(0.0);

  if (-sd >= refractionHeight) {
    // 中心区：不折射，直接采样模糊背景
    col = texture(uInput, uv).rgb;
  } else {
    // 边界带：透镜式折射（越靠边缘位移越大）
    float sdc = min(sd, 0.0);
    float d = circleMap(1.0 - (-sdc) / refractionHeight) * refractionAmount;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    vec2 grad = normalize(gradSdRoundedRect(centered, halfSize, gradRadius));

    // 滚动视差折射：折射方向随滚动轻微倾斜
    grad.x += uParallax * 0.3;
    grad = normalize(grad);

    vec2 disp = (d * grad) / uSize;

    // 色散：R/G/B 三通道不同位移（蓝偏移最大，符合光学色散规律）
    float ca = (centered.x * centered.y) / (halfSize.x * halfSize.y);
    float r = texture(uInput, uv + disp * (0.8 * ca)).r;
    float g = texture(uInput, uv + disp * (1.0 * ca)).g;
    float b = texture(uInput, uv + disp * (1.2 * ca)).b;
    col = vec3(r, g, b);

    // 边缘方向性高光（光从左上方入射，dot(grad, normal) 模拟表面反光）
    vec2 normal = normalize(vec2(0.35, 0.85));
    float edgeLight = pow(max(dot(grad, normal), 0.0), 3.0);
    col += vec3(1.0) * edgeLight * 0.5;
  }

  // 玻璃填充色（浅色白 / 深色冷白），按浓度混合出磨砂质感
  col = mix(col, uFill.rgb, uFill.a);

  // 手势跟随高光（柔和的圆形表面反光）
  if (uHighlightOn > 0.5) {
    float glow = exp(-pow(length(coord - uHighlight) / (uSize.y * 0.35), 2.0));
    col += vec3(1.0) * glow * 0.22;
  }

  fragColor = vec4(col, 1.0);
}