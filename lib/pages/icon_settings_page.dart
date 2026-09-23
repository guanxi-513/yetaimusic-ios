import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/app_icon_service.dart';
import '../state/ui_settings.dart';
import 'icon_crop_page.dart';

/// 设置 → 外观 → 应用图标：
/// 1) 三张预设桌面图标切换（Activity Alias）
/// 2) 用户上传图片：App 内头像 + 启动页显示 + 创建自定义桌面快捷方式
class IconSettingsPage extends StatefulWidget {
  const IconSettingsPage({super.key});

  @override
  State<IconSettingsPage> createState() => _IconSettingsPageState();
}

class _IconSettingsPageState extends State<IconSettingsPage> {
  final AppIconService _svc = AppIconService.instance;
  final ImagePicker _picker = ImagePicker();
  bool _busy = false;
  bool? _canPin;

  @override
  void initState() {
    super.initState();
    _svc.canPinShortcut().then((v) {
      if (mounted) setState(() => _canPin = v);
    });
  }

  Future<void> _pickAndCrop(ImageSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 100);
      if (picked == null) return;
      if (!mounted) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final cropped = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => IconCropPage(imageBytes: bytes),
          fullscreenDialog: true,
        ),
      );
      if (cropped == null) return;
      await _svc.saveAvatar(cropped);
      if (!mounted) return;
      _toast('已保存自定义头像，启动页将显示该图片');
    } catch (e) {
      if (!mounted) return;
      _toast('选择图片失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchPreset(String alias) async {
    final ok = await _svc.setAlias(alias);
    if (!mounted) return;
    if (ok) {
      _toast('已切换，桌面图标会闪一下，这是正常的');
    } else {
      _toast('当前平台不支持切换图标');
    }
  }

  Future<void> _pinShortcut() async {
    final ok = await _svc.pinShortcut(label: '液态音乐');
    if (!mounted) return;
    if (!ok) {
      _toast('创建失败：当前启动器不支持固定快捷方式');
    }
    // 成功时系统会自己弹确认/直接添加，无需提示
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: const TextStyle(fontSize: 13)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgBase,
      appBar: AppBar(
        backgroundColor: bgBase,
        title: Text('应用图标', style: TextStyle(color: fgPrimary)),
        iconTheme: IconThemeData(color: fgPrimary),
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: _svc,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _sectionTitle('桌面图标'),
              _card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final p in AppIconService.presets)
                        _presetItem(
                          p,
                          selected: _svc.currentAlias == p.alias,
                          onTap: () => _switchPreset(p.alias),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _sectionTitle('自定义图标'),
              _card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      _avatarPreview(),
                      const SizedBox(height: 14),
                      Text(
                        _svc.hasCustomAvatar ? '当前头像：自定义图片' : '当前头像：跟随预设桌面图标',
                        style: TextStyle(color: fgSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _outlineButton(
                              icon: Icons.photo_library_outlined,
                              label: '从相册选择',
                              onTap: _busy
                                  ? null
                                  : () => _pickAndCrop(ImageSource.gallery),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _outlineButton(
                              icon: Icons.photo_camera_outlined,
                              label: '拍照',
                              onTap: _busy
                                  ? null
                                  : () => _pickAndCrop(ImageSource.camera),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1DB954),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _svc.hasCustomAvatar ? _pinShortcut : null,
                          icon: const Icon(Icons.add_to_home_screen, size: 19),
                          label: const Text('创建桌面快捷方式'),
                        ),
                      ),
                      if (_canPin == false)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '当前启动器不支持固定快捷方式',
                            style: TextStyle(color: fgTertiary, fontSize: 11),
                          ),
                        ),
                      if (_svc.hasCustomAvatar)
                        TextButton(
                          onPressed: () async {
                            await _svc.clearAvatar();
                            if (mounted) _toast('已清除自定义头像');
                          },
                          child: Text(
                            '清除自定义头像',
                            style: TextStyle(
                              color: fgTertiary,
                              fontSize: 12,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Android 系统不支持 App 运行时直接替换桌面主图标。\n'
                        '上传图片会保存在应用内并显示在启动页；\n'
                        '「创建桌面快捷方式」可把自定义图片放到桌面，'
                        '点它即可启动 App。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: fgTertiary,
                          fontSize: 11,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      t,
      style: TextStyle(
        color: fgSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: bgCard,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: borderColor, width: 1),
    ),
    child: child,
  );

  Widget _presetItem(
    AppIconPreset p, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    const green = Color(0xFF1DB954);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? green : borderColor,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 38,
                  backgroundColor: fgPrimary.withValues(alpha: 0.06),
                  backgroundImage: AssetImage(p.asset),
                ),
                if (selected)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: green,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 13,
                        color: Colors.black,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            p.name,
            style: TextStyle(
              color: selected ? green : fgPrimary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(p.desc, style: TextStyle(color: fgTertiary, fontSize: 10)),
        ],
      ),
    );
  }

  /// 大头像：有自定义图显示文件，否则显示当前预设 asset
  Widget _avatarPreview() {
    ImageProvider img;
    if (_svc.hasCustomAvatar) {
      img = FileImage(File(_svc.avatarPath!));
    } else {
      final preset = AppIconService.presets.firstWhere(
        (p) => p.alias == _svc.currentAlias,
        orElse: () => AppIconService.presets.first,
      );
      img = AssetImage(preset.asset);
    }
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: CircleAvatar(
        radius: 46,
        backgroundColor: Colors.transparent,
        backgroundImage: img,
      ),
    );
  }

  Widget _outlineButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: fgPrimary,
        side: BorderSide(color: fgPrimary.withValues(alpha: 0.3)),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
