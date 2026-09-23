import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

/// 预设图标定义（alias 名与原生 Manifest 中一致）
class AppIconPreset {
  final String alias;
  final String name;
  final String desc;
  final String asset;
  const AppIconPreset(this.alias, this.name, this.desc, this.asset);
}

/// 应用图标：3 张预设图标的 Activity Alias 切换 + 用户自定义头像（App 内 +
/// 桌面快捷方式）。Android 不允许运行时替换主图标，自定义图走 Pin Shortcut。
class AppIconService extends ChangeNotifier {
  AppIconService._();
  static final AppIconService instance = AppIconService._();

  static const MethodChannel _channel = MethodChannel('app_icon');
  static const String _prefsAliasKey = 'app_icon_alias';
  static const String _prefsAvatarKey = 'app_custom_avatar_path';
  static const String _avatarFileName = 'custom_icon.png';

  static const List<AppIconPreset> presets = [
    AppIconPreset(
      'AliasDefault',
      '头像版',
      '完整头像（默认）',
      'assets/icons/ic_launcher_default.png',
    ),
    AppIconPreset(
      'AliasEyes',
      '双眼版',
      '双眼特写',
      'assets/icons/ic_launcher_eyes.png',
    ),
    AppIconPreset(
      'AliasSingle',
      '单眼版',
      '单眼特写',
      'assets/icons/ic_launcher_single.png',
    ),
  ];

  String _currentAlias = 'AliasDefault';
  String get currentAlias => _currentAlias;

  String? _avatarPath;
  String? get avatarPath => _avatarPath;
  bool get hasCustomAvatar => _avatarPath != null;

  bool? _canPin;

  /// 启动时读当前 alias 与自定义头像路径
  Future<void> init() async {
    try {
      final a = await _channel.invokeMethod<String>('getCurrentIcon');
      if (a != null) _currentAlias = a;
    } catch (_) {
      // 非 Android 平台：回退到本地缓存
      final prefs = await SharedPreferences.getInstance();
      _currentAlias = prefs.getString(_prefsAliasKey) ?? 'AliasDefault';
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsAvatarKey);
      if (saved != null && await File(saved).exists()) {
        _avatarPath = saved;
      }
    } catch (_) {}
    notifyListeners();
  }

  /// 切换桌面预设图标（Android 会闪一下启动器）
  Future<bool> setAlias(String alias) async {
    if (alias == _currentAlias) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', alias) ?? false;
      if (ok) {
        _currentAlias = alias;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsAliasKey, alias);
        notifyListeners();
      }
      return ok;
    } on PlatformException catch (e) {
      debugPrint('setIcon failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 保存裁剪后的自定义头像到 documents 目录，返回路径
  Future<String> saveAvatar(Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$_avatarFileName');
    await file.writeAsBytes(bytes, flush: true);
    _avatarPath = file.path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsAvatarKey, file.path);
    notifyListeners();
    return file.path;
  }

  Future<void> clearAvatar() async {
    if (_avatarPath != null) {
      try {
        await File(_avatarPath!).delete();
      } catch (_) {}
    }
    _avatarPath = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsAvatarKey);
    notifyListeners();
  }

  /// 当前启动器是否支持固定快捷方式（Android 8+ 主流启动器）
  Future<bool> canPinShortcut() async {
    if (_canPin != null) return _canPin!;
    try {
      _canPin = await _channel.invokeMethod<bool>('canPinShortcut') ?? false;
    } catch (_) {
      _canPin = false;
    }
    return _canPin!;
  }

  /// 用当前自定义头像创建桌面快捷方式。返回 false 表示系统不支持/用户拒绝。
  Future<bool> pinShortcut({String label = '液态音乐'}) async {
    final path = _avatarPath;
    if (path == null) return false;
    try {
      return await _channel.invokeMethod<bool>('pinShortcut', <String, dynamic>{
            'imagePath': path,
            'label': label,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
