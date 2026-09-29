/// 单个页面的背景编辑：跟随全局 / 纯色 / 渐变 / 图片 + 遮罩调节
library;

import 'dart:io';
import 'package:flutter/material.dart';

import '../state/theme_state.dart';
import '../state/ui_settings.dart';
import '../widgets/theme_background.dart';
import 'theme_settings_page.dart';

class PageBgEditPage extends StatefulWidget {
  final String pageId;
  const PageBgEditPage({super.key, required this.pageId});

  @override
  State<PageBgEditPage> createState() => _PageBgEditPageState();
}

class _PageBgEditPageState extends State<PageBgEditPage> {
  late PageBg _bg;
  bool get isGlobal => widget.pageId == BgPages.global;

  // 可选颜色面板
  static const _palette = [
    0xFF000000, 0xFF0A0A0C, 0xFF1A1C20, 0xFF12102A,
    0xFF39C5BB, 0xFF1DB954, 0xFF6C4FE0, 0xFFE05A8A,
    0xFFFDFDFA, 0xFFF9FAF4, 0xFFFFFFFF, 0xFF6B7280,
  ];

  @override
  void initState() {
    super.initState();
    _bg = themeState.rawBg(widget.pageId);
  }

  void _update(PageBg bg) {
    setState(() => _bg = bg);
    themeState.setBg(widget.pageId, bg);
  }

  @override
  Widget build(BuildContext context) {
    return ThemeBackground(
      pageId: BgPages.settingsDetail,
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: fgPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(BgPages.names[widget.pageId] ?? widget.pageId,
            style: TextStyle(color: fgPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 背景类型选择
          if (!isGlobal) ...[
            _typeTile(BgType.inherit, '跟随全局', Icons.layers),
          ],
          _typeTile(BgType.solid, '纯色', Icons.circle),
          _typeTile(BgType.gradient, '渐变', Icons.gradient),
          _typeTile(BgType.image, '自定义图片', Icons.image),

          const SizedBox(height: 16),

          // 纯色：颜色选择
          if (_bg.type == BgType.solid) ...[
            _label('选择颜色'),
            _colorGrid(1),
          ],

          // 渐变：颜色选择
          if (_bg.type == BgType.gradient) ...[
            _label('渐变颜色（至少 2 个）'),
            _colorGrid(3),
          ],

          // 图片：选择按钮
          if (_bg.type == BgType.image) ...[
            _label('背景图片'),
            if (_bg.imagePath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 10,
                  child: Image.file(
                    File(_bg.imagePath!),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: () async {
                final path = await pickAndSaveImage();
                if (path != null) _update(_bg.copyWith(imagePath: path));
              },
              icon: const Icon(Icons.upload),
              label: Text(_bg.imagePath != null ? '更换图片' : '从相册选择'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1DB954)),
            ),
          ],

          // 遮罩透明度（纯色/渐变/图片均可调，保证文字可读）
          if (_bg.type != BgType.inherit) ...[
            const SizedBox(height: 16),
            _label('遮罩强度（压暗背景，让文字更清晰）'),
            Slider(
              value: _bg.overlayOpacity,
              min: 0,
              max: 0.8,
              onChanged: (v) => _update(_bg.copyWith(overlayOpacity: v)),
            ),
            Center(
              child: Text('${(_bg.overlayOpacity * 100).round()}%',
                  style: TextStyle(color: fgSecondary, fontSize: 12)),
            ),
          ],
        ],
        ),
      ),
    );
  }

  Widget _typeTile(BgType t, String name, IconData icon) {
    final selected = _bg.type == t;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF1DB954).withOpacity(0.15) : Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? const Color(0xFF1DB954) : Colors.white.withOpacity(0.12),
        ),
      ),
      child: ListTile(
        leading: Icon(icon, color: selected ? const Color(0xFF1DB954) : fgSecondary),
        title: Text(name, style: TextStyle(color: fgPrimary, fontSize: 14)),
        trailing: selected
            ? const Icon(Icons.check_circle, color: Color(0xFF1DB954), size: 20)
            : null,
        onTap: () {
          // 切换类型时给合理默认
          var colors = _bg.colors;
          if ((t == BgType.solid && colors.isEmpty) ) colors = const [0xFF0A0A0C];
          if (t == BgType.gradient && colors.length < 2) colors = const [0xFF000000, 0xFF0A0A0C];
          _update(_bg.copyWith(type: t, colors: colors));
        },
      ),
    );
  }

  Widget _colorGrid(int max) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _palette.map((c) {
        final selected = _bg.colors.contains(c);
        return GestureDetector(
          onTap: () {
            var colors = List<int>.from(_bg.colors);
            if (selected) {
              colors.remove(c);
            } else {
              if (colors.length >= max) colors.removeAt(0);
              colors.add(c);
            }
            if (max == 1) colors = [c];
            _update(_bg.copyWith(colors: colors));
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? const Color(0xFF1DB954) : Colors.white24,
                width: selected ? 3 : 1,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 4),
        child: Text(t,
            style: TextStyle(color: fgSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
      );
}
