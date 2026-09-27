import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../state/ui_settings.dart';

/// 液态玻璃容器：真实折射（把背景模糊后作为着色器纹理、在圆角边缘带做透镜式
/// 位移采样 + 三通道色散 + 边缘高光），叠加手势跟随高光与滚动视差折射。
///
/// 通过 `ui.ImageFilter.shader`（Impeller 专用）把 [FragmentShader] 作为
/// BackdropFilter 的 filter，需要 `ui.ImageFilter.isShaderFilterSupported`。
/// 关闭或不可用时自动降级为普通毛玻璃（BackdropFilter 高斯模糊）。
class LiquidGlass extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double blurSigma;
  final ValueListenable<double> scrollFraction;
  final int replayKey;

  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.blurSigma = 20,
    required this.scrollFraction,
    this.replayKey = 0,
  });

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _programFuture;
  ui.FragmentProgram? _program;
  bool _shaderFailed = false;
  late final AnimationController _reveal;
  final ValueNotifier<Offset> _highlight = ValueNotifier(Offset.zero);
  final ValueNotifier<bool> _highlightOn = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _loadShader();
    _reveal.forward();
  }

  @override
  void didUpdateWidget(covariant LiquidGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replayKey != widget.replayKey) _reveal.forward(from: 0);
  }

  @override
  void dispose() {
    _reveal.dispose();
    _highlight.dispose();
    _highlightOn.dispose();
    super.dispose();
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_programFuture ??= ui.FragmentProgram.fromAsset(
        'assets/shaders/liquid_glass.frag',
      ));
      if (!mounted) return;
      setState(() => _program = program);
    } catch (_) {
      if (!mounted) return;
      setState(() => _shaderFailed = true);
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _highlight.value = e.localPosition;
    _highlightOn.value = true;
  }

  void _onPointerMove(PointerMoveEvent e) {
    _highlight.value = e.localPosition;
    _highlightOn.value = true;
  }

  void _onPointerEnd() => _highlightOn.value = false;

  /// 构建背景滤镜：先高斯模糊，再把模糊结果喂给折射着色器。
  /// 着色器 float 槽位：uSize(0-1 引擎自设)、uHighlight(2-3)、
  /// uHighlightOn(4)、uParallax(5)、uFill(6-9)。
  ui.ImageFilter _buildFilter(bool light, double t) {
    final blur = ui.ImageFilter.blur(
      sigmaX: widget.blurSigma * t,
      sigmaY: widget.blurSigma * t,
    );
    final program = _program;
    if (!liquidGlassNav.value ||
        _shaderFailed ||
        program == null ||
        !ui.ImageFilter.isShaderFilterSupported) {
      return blur;
    }

    try {
      final shader = program.fragmentShader();
      shader.setFloat(2, _highlight.value.dx);
      shader.setFloat(3, _highlight.value.dy);
      shader.setFloat(4, _highlightOn.value ? 1.0 : 0.0);
      shader.setFloat(5, widget.scrollFraction.value.clamp(0.0, 1.0));
      // 玻璃填充色：浅色白、深色黑，低浓度磨砂质感
      if (light) {
        shader.setFloat(6, 1.0);
        shader.setFloat(7, 1.0);
        shader.setFloat(8, 1.0);
        shader.setFloat(9, 0.09);
      } else {
        shader.setFloat(6, 0.0);
        shader.setFloat(7, 0.0);
        shader.setFloat(8, 0.0);
        shader.setFloat(9, 0.15);
      }
      return ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(shader),
        inner: blur,
      );
    } catch (_) {
      return blur;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        uiStyle,
        liquidGlassNav,
        _highlight,
        _highlightOn,
        _reveal,
        widget.scrollFraction,
      ]),
      builder: (context, _) {
        final light = isLight;
        final t = Curves.easeOutCubic.transform(_reveal.value);

        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Transform.scale(
            scale: 0.96 + 0.04 * t,
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: (_) => _onPointerEnd(),
              onPointerCancel: (_) => _onPointerEnd(),
              behavior: HitTestBehavior.translucent,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: BackdropFilter(
                        filter: _buildFilter(light, t),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            widget.borderRadius,
                          ),
                          border: Border.all(
                            color: light
                                ? Colors.white.withOpacity(0.35)
                                : Colors.white.withOpacity(0.14),
                            width: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: widget.child,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
