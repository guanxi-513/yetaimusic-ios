import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../state/ui_settings.dart';

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
    this.blurSigma = 18,
    required this.scrollFraction,
    this.replayKey = 0,
  });

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _programFuture;
  ui.FragmentShader? _shader;
  bool _shaderFailed = false;
  late final AnimationController _reveal;
  final ValueNotifier<Offset> _highlight = ValueNotifier(Offset.zero);
  final ValueNotifier<bool> _highlightOn = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
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
      final program = await (_programFuture ??= ui.FragmentProgram.fromAsset('assets/shaders/liquid_glass.frag'));
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      if (!mounted) return;
      setState(() => _shaderFailed = true);
    }
  }

  void _onPointerDown(PointerDownEvent e) { _highlight.value = e.localPosition; _highlightOn.value = true; }
  void _onPointerMove(PointerMoveEvent e) { _highlight.value = e.localPosition; _highlightOn.value = true; }
  void _onPointerEnd() => _highlightOn.value = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([uiStyle, liquidGlassNav]),
      builder: (context, _) {
        final light = isLight;
        final liquid = liquidGlassNav.value && !_shaderFailed;

        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(_reveal.value);
              return Transform.scale(
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
                            filter: ui.ImageFilter.blur(sigmaX: widget.blurSigma * t, sigmaY: widget.blurSigma * t),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: light ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.12),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (liquid && _shader != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ListenableBuilder(
                              listenable: Listenable.merge([_highlight, _highlightOn, _reveal, widget.scrollFraction]),
                              builder: (context, _) => CustomPaint(
                                painter: _GlassPainter(
                                  shader: _shader!,
                                  highlight: _highlight.value,
                                  highlightOn: _highlightOn.value,
                                  reveal: t,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(widget.borderRadius),
                              border: Border.all(color: light ? Colors.white.withOpacity(0.25) : Colors.white.withOpacity(0.15), width: 0.5),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        child: widget.child,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _GlassPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final Offset highlight;
  final bool highlightOn;
  final double reveal;

  _GlassPainter({required this.shader, required this.highlight, required this.highlightOn, required this.reveal});

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, 1.0);
    shader.setFloat(3, 0.8);
    shader.setFloat(4, highlightOn ? 1.0 : 0.0);
    shader.setFloat(5, highlight.dx);
    shader.setFloat(6, size.height - highlight.dy);
    shader.setFloat(7, reveal);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      highlight != old.highlight || highlightOn != old.highlightOn || reveal != old.reveal;
}
