/// 主题皮肤设置页：预设主题一键换肤 + 各页面背景独立自定义
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../state/theme_state.dart';
import '../state/ui_settings.dart';
import '../services/theme_share_service.dart';
import '../widgets/theme_background.dart';
import 'page_bg_edit_page.dart';

class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

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
          title: Text('主题皮肤', style: TextStyle(color: fgPrimary)),
          actions: [
            IconButton(
              icon: Icon(Icons.restart_alt, color: fgPrimary.withOpacity(0.7)),
              tooltip: '重置 UI 设置',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1C20),
                    title: Text(
                      '重置 UI 设置？',
                      style: TextStyle(color: fgPrimary),
                    ),
                    content: Text(
                      '将所有背景和主题恢复为默认液态青绿，不影响登录和歌单数据。',
                      style: TextStyle(color: fgSecondary, fontSize: 13),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text('取消', style: TextStyle(color: fgSecondary)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(
                          '重置',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await themeState.resetToDefault();
                }
              },
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: themeState,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 主题分享 / 导入
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1DB954),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('分享我的主题'),
                        onPressed: () => _showShareDialog(context),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: fgPrimary,
                          side: BorderSide(color: fgPrimary.withOpacity(0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('输入码导入'),
                        onPressed: () => _showImportDialog(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _label('预设主题（一键换肤）'),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.2,
                  children: [
                    for (final p in kPresets)
                      _PresetCard(
                        emoji: p.emoji,
                        name: p.name,
                        selected: themeState.activePreset == p.id,
                        onTap: () => themeState.applyPreset(p),
                      ),
                    // 用户本地保存的预设（与内置预设混排），长按删除
                    for (final p in themeState.customPresets)
                      _PresetCard(
                        emoji: '⭐',
                        name: p.name,
                        selected: themeState.activePreset == p.id,
                        onTap: () => themeState.applyCustomPreset(p),
                        onLongPress: () => _confirmDeletePreset(context, p),
                      ),
                  ],
                ),
                if (themeState.customPresets.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '⭐ 为本地预设，长按可删除',
                      style: TextStyle(color: fgTertiary, fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 24),
                _label('各页面背景（高级自定义）'),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.07),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < BgPages.all.length; i++) ...[
                        _PageBgTile(pageId: BgPages.all[i]),
                        if (i < BgPages.all.length - 1)
                          Divider(
                            height: 1,
                            color: fgPrimary.withOpacity(0.08),
                            indent: 16,
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      t,
      style: TextStyle(
        color: fgSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _PresetCard extends StatelessWidget {
  final String emoji;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  /// 长按回调（本地预设用来删除）
  final VoidCallback? onLongPress;

  const _PresetCard({
    required this.emoji,
    required this.name,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? const Color(0xFF1DB954)
                : fgPrimary.withOpacity(0.1),
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_circle,
                color: Color(0xFF1DB954),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

class _PageBgTile extends StatelessWidget {
  final String pageId;
  const _PageBgTile({required this.pageId});

  @override
  Widget build(BuildContext context) {
    final bg = themeState.rawBg(pageId);
    final String desc;
    switch (bg.type) {
      case BgType.inherit:
        desc = pageId == BgPages.global ? '未设置' : '跟随全局';
      case BgType.solid:
        desc = '纯色';
      case BgType.gradient:
        desc = '渐变';
      case BgType.image:
        desc = '自定义图片';
    }
    final canFollow = pageId != BgPages.global;
    final following = bg.type == BgType.inherit;
    return ListTile(
      title: Text(
        BgPages.names[pageId] ?? pageId,
        style: TextStyle(color: fgPrimary, fontSize: 14),
      ),
      subtitle: Text(desc, style: TextStyle(color: fgTertiary, fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canFollow)
            GestureDetector(
              onTap: () => _toggleFollow(),
              child: AnimatedScale(
                scale: following ? 1.0 : 0.85,
                duration: const Duration(milliseconds: 250),
                curve: Curves.elasticOut,
                child: AnimatedRotation(
                  turns: following ? 0 : 0.5,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: following
                          ? const Color(0xFF1DB954)
                          : Colors.white.withOpacity(0.08),
                      border: Border.all(
                        color: following
                            ? const Color(0xFF1DB954)
                            : Colors.white.withOpacity(0.2),
                        width: 1.5,
                      ),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: following
                          ? const Icon(
                              Icons.check,
                              key: ValueKey('check'),
                              size: 20,
                              color: Colors.white,
                            )
                          : Icon(
                              Icons.add,
                              key: ValueKey('add'),
                              size: 20,
                              color: Colors.white.withOpacity(0.4),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          if (canFollow) const SizedBox(width: 8),
          _thumb(bg),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PageBgEditPage(pageId: pageId)),
      ),
    );
  }

  void _toggleFollow() {
    final bg = themeState.rawBg(pageId);
    if (bg.type == BgType.inherit) {
      // 取消跟随：设为默认纯色（深色半透明）
      themeState.setBg(
        pageId,
        const PageBg(
          type: BgType.solid,
          colors: [0xFF1A1C20],
          overlayOpacity: 0.0,
        ),
      );
    } else {
      // 恢复跟随全局
      themeState.setBg(pageId, const PageBg(type: BgType.inherit));
    }
  }

  Widget _thumb(PageBg bg) {
    Widget? content;
    if (bg.type == BgType.solid && bg.colors.isNotEmpty) {
      content = ColoredBox(color: Color(bg.colors.first));
    } else if (bg.type == BgType.gradient && bg.colors.isNotEmpty) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: bg.colors.map(Color.new).toList(),
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      );
    } else if (bg.type == BgType.image && bg.imagePath != null) {
      content = Image.file(File(bg.imagePath!), fit: BoxFit.cover);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (content != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: 34, height: 34, child: content),
          ),
        const SizedBox(width: 6),
        Icon(Icons.chevron_right, color: fgSecondary, size: 20),
      ],
    );
  }
}

/// 选图片并保存到应用目录
Future<String?> pickAndSaveImage() async {
  final picker = ImagePicker();
  final xfile = await picker.pickImage(
    source: ImageSource.gallery,
    imageQuality: 90,
  );
  if (xfile == null) return null;
  final dir = await getApplicationDocumentsDirectory();
  final bgDir = Directory('${dir.path}/theme_bgs');
  if (!bgDir.existsSync()) bgDir.createSync(recursive: true);
  final name = 'bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final saved = await File(xfile.path).copy('${bgDir.path}/$name');
  return saved.path;
}

// ==================== 主题分享 / 导入弹窗 ====================

void _showShareDialog(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ShareDialog(),
  );
}

void _showImportDialog(BuildContext context) {
  showDialog(context: context, builder: (ctx) => _ImportDialog());
}

/// 弹窗命名本地预设：默认填「我的预设 N」并全选，直接输入即可覆盖
Future<String?> _askPresetName(BuildContext context) async {
  final controller = TextEditingController(
    text: '我的预设 ${themeState.customPresets.length + 1}',
  );
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1C20),
      title: Text('保存为本地预设', style: TextStyle(color: fgPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: fgPrimary),
        decoration: InputDecoration(
          hintText: '预设名称',
          hintStyle: TextStyle(color: fgPrimary.withOpacity(0.25)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: fgPrimary.withOpacity(0.3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF1DB954)),
          ),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('取消', style: TextStyle(color: fgSecondary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1DB954),
          ),
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null) return null;
  final trimmed = name.trim();
  return trimmed.isEmpty ? '未命名预设' : trimmed;
}

/// 把当前主题存成本地预设（分享成功 / 导入成功后调用）
Future<void> _saveCurrentAsPreset(BuildContext context) async {
  final name = await _askPresetName(context);
  if (name == null || !context.mounted) return;
  await themeState.saveCurrentAsPreset(name);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已保存预设「$name」'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 长按本地预设卡片时的删除确认
Future<void> _confirmDeletePreset(BuildContext context, CustomPreset p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1C20),
      title: Text('删除预设？', style: TextStyle(color: fgPrimary)),
      content: Text(
        '将删除本地预设「${p.name}」及其图片，不影响当前已应用的主题。',
        style: TextStyle(color: fgSecondary, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('取消', style: TextStyle(color: fgSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (ok == true) await themeState.deleteCustomPreset(p.id);
}

class _ShareDialog extends StatefulWidget {
  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  bool _busy = true;
  String? _code;
  String? _error;

  /// 上传进度 0.0~1.0（1.0 表示图片已发完，服务器正在生成分享码）
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final code = await ThemeShareService.share(
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _code = code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1C20),
      title: Text('分享我的主题', style: TextStyle(color: fgPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 6,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF1DB954),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _progress >= 1.0
                        ? '图片已上传，正在生成分享码...'
                        : '正在上传配置和图片... ${(_progress * 100).round()}%',
                    style: TextStyle(color: fgSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          if (_code != null) ...[
            Text(
              '分享成功，把下面 6 位码发给朋友：',
              style: TextStyle(color: fgSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1DB954).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1DB954)),
              ),
              child: Text(
                _code!,
                style: const TextStyle(
                  color: Color(0xFF1DB954),
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制分享码'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _code!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined, size: 16),
              label: const Text('保存为本地预设'),
              onPressed: () => _saveCurrentAsPreset(context),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            _code != null ? '完成' : '关闭',
            style: TextStyle(color: fgSecondary),
          ),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1C20),
      title: Text(
        _done ? '导入成功' : '导入分享主题',
        style: TextStyle(color: fgPrimary),
      ),
      content: _done
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF1DB954),
                  size: 44,
                ),
                const SizedBox(height: 12),
                Text('主题已应用', style: TextStyle(color: fgPrimary, fontSize: 14)),
                const SizedBox(height: 6),
                Text(
                  '也可以再存一份到本地预设，之后一键切换',
                  style: TextStyle(color: fgSecondary, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '输入朋友给你的 6 位分享码',
                  style: TextStyle(color: fgSecondary, fontSize: 13),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _controller,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fgPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 6,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'ABC234',
                    hintStyle: TextStyle(
                      color: fgPrimary.withOpacity(0.25),
                      letterSpacing: 6,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: fgPrimary.withOpacity(0.3)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF1DB954)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_busy)
                  const CircularProgressIndicator(color: Color(0xFF1DB954)),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
      actions: _done
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('完成', style: TextStyle(color: fgSecondary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                ),
                onPressed: () => _saveCurrentAsPreset(context),
                child: const Text('保存为本地预设'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: Text('取消', style: TextStyle(color: fgSecondary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                ),
                onPressed: _busy ? null : _startImport,
                child: const Text('应用主题'),
              ),
            ],
    );
  }

  Future<void> _startImport() async {
    final code = _controller.text.trim();
    if (code.length != 6) {
      setState(() => _error = '请输入完整 6 位码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ThemeShareService.import(code);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }
}
