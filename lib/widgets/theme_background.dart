/// 主题背景渲染组件：根据 ThemeState 中某个页面的配置渲染背景
/// 用法：ThemeBackground(pageId: BgPages.recommend, child: ...)
library;

import 'dart:io';
import 'package:flutter/material.dart';

import '../state/theme_state.dart';
import '../state/ui_settings.dart';

class ThemeBackground extends StatelessWidget {
  final String pageId;
  final Widget child;

  /// 是否铺满（默认 true）；false 时只在需要时绘制
  final bool fill;

  const ThemeBackground({
    super.key,
    required this.pageId,
    required this.child,
    this.fill = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeState,
      builder: (context, _) {
        // 极简白色优先级最高：盖过一切主题皮肤背景，强制暖白
        if (isLight) {
          return Container(
            color: const Color(0xFFF9FAF4),
            child: child,
          );
        }
        final raw = themeState.rawBg(pageId);
        // 在首页 IndexedStack 里的 tab 页 inherit 时透明，透出 home 全局背景；
        // 独立路由的二级页（歌单详情/播放/设置弹窗/设置二级页）inherit 时自己渲染全局背景
        const tabPages = {BgPages.recommend, BgPages.search, BgPages.charts, BgPages.playlists};
        if (raw.type == BgType.inherit && tabPages.contains(pageId)) {
          return child;
        }
        final bg = themeState.effectiveBg(pageId);
        return Container(
          decoration: _decoration(bg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 图片背景
              if (bg.type == BgType.image && bg.imagePath != null)
                Positioned.fill(
                  child: _ImageBg(path: bg.imagePath!),
                ),
              // 主题装饰光斑（仅全局 + 特定预设）
              if (pageId == BgPages.global) _decorBlobs(),
              // 遮罩
              if (bg.overlayOpacity > 0 &&
                  (bg.type == BgType.image || _needsOverlay()))
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black.withOpacity(bg.overlayOpacity),
                    ),
                  ),
                ),
              child,
            ],
          ),
        );
      },
    );
  }

  bool _needsOverlay() {
    // 深色预设需要一点遮罩增强对比；白色不需要
    final preset = themeState.activePreset;
    return preset != 'warmwhite';
  }

  BoxDecoration? _decoration(PageBg bg) {
    switch (bg.type) {
      case BgType.solid:
        if (bg.colors.isEmpty) return null;
        return BoxDecoration(color: Color(bg.colors.first));
      case BgType.gradient:
        if (bg.colors.length < 2) {
          return BoxDecoration(
            color: bg.colors.isNotEmpty ? Color(bg.colors.first) : null,
          );
        }
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: bg.colors.map(Color.new).toList(),
          ),
        );
      case BgType.image:
        return const BoxDecoration(color: Colors.black);
      case BgType.inherit:
        return null;
    }
  }

  /// 根据当前预设渲染装饰光斑
  Widget _decorBlobs() {
    final preset = themeState.activePreset;
    switch (preset) {
      case 'miku':
        return const _Blobs([
          _BlobSpec(0xFF39C5BB, 0.35, -100, -80, 360),
          _BlobSpec(0xFF1A7A8C, 0.30, -120, 120, 320),
          _BlobSpec(0xFF39C5BB, 0.18, 40, -60, 300),
        ]);
      case 'nightpurple':
        return const _Blobs([
          _BlobSpec(0xFF6C4FE0, 0.40, -80, -120, 340),
          _BlobSpec(0xFFE05A8A, 0.25, -100, 80, 300),
          _BlobSpec(0xFF3A2E8C, 0.35, 40, -140, 380),
        ]);
      case 'default':
      default:
        // 默认液态青绿：左侧弥散光
        return Builder(
          builder: (context) {
            final w = MediaQuery.sizeOf(context).width;
            return Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: w * 0.6,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        const Color(0xFF1DB954).withOpacity(0.30),
                        const Color(0xFF1DB954).withOpacity(0.08),
                        const Color(0xFF1DB954).withOpacity(0),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            );
          },
        );
    }
  }
}

class _ImageBg extends StatelessWidget {
  final String path;
  const _ImageBg({required this.path});

  @override
  Widget build(BuildContext context) {
    final image = path.startsWith('assets/')
        ? Image.asset(path, fit: BoxFit.cover)
        : (File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.cover)
            : const ColoredBox(color: Colors.black));
    // 稍微放大 6%，裁掉图片边缘可能的黑边/灰边
    return Transform.scale(
      scale: 1.06,
      child: image,
    );
  }
}

class _BlobSpec {
  final int color;
  final double opacity;
  final double left;
  final double top;
  final double size;
  const _BlobSpec(this.color, this.opacity, this.left, this.top, this.size);
}

class _Blobs extends StatelessWidget {
  final List<_BlobSpec> specs;
  const _Blobs(this.specs);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: specs.map((s) {
        return Positioned(
          left: s.left,
          top: s.top,
          child: IgnorePointer(
            child: Container(
              width: s.size,
              height: s.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(s.color).withOpacity(s.opacity),
                    Color(s.color).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
