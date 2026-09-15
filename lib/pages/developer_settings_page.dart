/// 开发者设置（二级页）：缓存维护 / 调试信息
library;

import 'package:flutter/material.dart';

import '../services/music_cache.dart';
import '../state/ui_settings.dart';

class DeveloperSettingsPage extends StatefulWidget {
  const DeveloperSettingsPage({super.key});

  @override
  State<DeveloperSettingsPage> createState() => _DeveloperSettingsPageState();
}

class _DeveloperSettingsPageState extends State<DeveloperSettingsPage> {
  double _cacheMb = 0;
  int _cacheCount = 0;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final mb = await MusicCache.totalSizeMb();
    final count = await MusicCache.countFiles();
    if (!mounted) return;
    setState(() {
      _cacheMb = mb;
      _cacheCount = count;
    });
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: fgPrimary.withOpacity(0.15)),
        ),
        title: Text('清理歌曲缓存', style: TextStyle(color: fgPrimary)),
        content: Text(
          '将删除本地缓存的全部歌曲文件（$_cacheCount 个，约 ${_cacheMb.toStringAsFixed(1)} MB）。\n播放历史与收藏不受影响。确定清理吗？',
          style: TextStyle(color: fgSecondary, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: fgSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清理', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearing = true);
    await MusicCache.clearAll();
    await _refresh();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('缓存已清理'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgBase,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: fgPrimary, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '开发者设置',
          style: TextStyle(
            color: fgPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                '调试与维护工具，后续功能会继续补充。',
                style: TextStyle(color: fgTertiary, fontSize: 12, height: 1.6),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: bgCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: fgPrimary.withOpacity(0.08)),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                title: Text(
                  '歌曲缓存',
                  style: TextStyle(color: fgPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  _cacheCount == 0 && _cacheMb == 0
                      ? '暂无缓存'
                      : '$_cacheCount 个文件 · ${_cacheMb.toStringAsFixed(1)} MB',
                  style: TextStyle(color: fgTertiary, fontSize: 11),
                ),
                trailing: _clearing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _cacheCount == 0 ? null : _clearCache,
                        child: Text(
                          '清理',
                          style: TextStyle(
                            color: _cacheCount == 0 ? fgHint : Colors.redAccent,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
