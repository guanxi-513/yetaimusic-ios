/// 主题 / 皮肤系统：每个页面可独立设置背景（跟随全局 / 纯色 / 渐变 / 图片）
/// 支持一键预设主题（初音未来等）
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_settings.dart';

/// 背景类型
enum BgType {
  inherit, // 跟随全局（子页面用）
  solid, // 纯色
  gradient, // 渐变
  image, // 自定义图片
}

/// 单个页面的背景配置
class PageBg {
  final BgType type;
  final List<int> colors; // ARGB int 列表（solid 1 个，gradient 2~3 个）
  final String? imagePath; // 自定义图片本地路径
  final double overlayOpacity; // 图片/背景上的半透明黑遮罩（保证文字可读）

  const PageBg({
    this.type = BgType.inherit,
    this.colors = const [],
    this.imagePath,
    this.overlayOpacity = 0.35,
  });

  Map<String, dynamic> toJson() => {
    't': type.index,
    'c': colors,
    'i': imagePath,
    'o': overlayOpacity,
  };

  factory PageBg.fromJson(Map<String, dynamic> j) => PageBg(
    type: BgType.values[j['t'] as int? ?? 0],
    colors: (j['c'] as List?)?.cast<int>() ?? const [],
    imagePath: j['i'] as String?,
    overlayOpacity: (j['o'] as num?)?.toDouble() ?? 0.35,
  );

  PageBg copyWith({
    BgType? type,
    List<int>? colors,
    String? imagePath,
    double? overlayOpacity,
  }) => PageBg(
    type: type ?? this.type,
    colors: colors ?? this.colors,
    imagePath: imagePath ?? this.imagePath,
    overlayOpacity: overlayOpacity ?? this.overlayOpacity,
  );
}

/// 可设置背景的页面 ID
class BgPages {
  static const global = 'global';
  static const recommend = 'recommend';
  static const search = 'search';
  static const charts = 'charts';
  static const playlists = 'playlists';
  static const detail = 'detail';
  static const player = 'player';
  static const settings = 'settings';
  static const settingsDetail = 'settingsDetail';
  static const playerBar = 'playerBar';

  static const all = [
    global,
    recommend,
    search,
    charts,
    playlists,
    detail,
    player,
    settings,
    settingsDetail,
    playerBar,
  ];

  static const names = {
    global: '全局背景',
    recommend: '推荐页',
    search: '搜索页',
    charts: '榜单页',
    playlists: '我的歌单页',
    detail: '歌单详情页',
    player: '播放页',
    settings: '设置弹窗',
    settingsDetail: '设置二级页',
    playerBar: '播放胶囊栏',
  };
}

/// 主题预设
class ThemePreset {
  final String id;
  final String name;
  final String emoji;
  final Map<String, PageBg> bgs;

  const ThemePreset({
    required this.id,
    required this.name,
    required this.emoji,
    required this.bgs,
  });
}

/// 用户本地保存的预设：页面背景 + 全部 UI 参数（内容与分享包一致）
class CustomPreset {
  final String id;
  final String name;
  final Map<String, PageBg> bgs;
  final Map<String, dynamic> ui;

  const CustomPreset({
    required this.id,
    required this.name,
    required this.bgs,
    required this.ui,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bgs': bgs.map((k, v) => MapEntry(k, v.toJson())),
    'ui': ui,
  };

  factory CustomPreset.fromJson(Map<String, dynamic> j) => CustomPreset(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '未命名预设',
    bgs: ((j['bgs'] as Map?) ?? {}).map(
      (k, v) => MapEntry(
        k as String,
        PageBg.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    ui: Map<String, dynamic>.from((j['ui'] as Map?) ?? {}),
  );
}

// 颜色常量
const int _black = 0xFF000000;
const int _charcoal = 0xFF0A0A0C;
const int _miku = 0xFF39C5BB; // 初音青绿
const int _mikuDeep = 0xFF0E3A4A; // 初音深蓝
const int _mikuDark = 0xFF061824;
const int _warmWhite = 0xFFFDFDFA;
const int _warmCream = 0xFFF9FAF4;

/// 内置预设主题
final List<ThemePreset> kPresets = [
  ThemePreset(
    id: 'default',
    name: '液态青绿（默认）',
    emoji: '🎧',
    bgs: {
      BgPages.global: const PageBg(
        type: BgType.gradient,
        colors: [_black, _charcoal, 0xFF0D0D10],
      ),
      for (final p in [
        BgPages.recommend,
        BgPages.search,
        BgPages.charts,
        BgPages.playlists,
        BgPages.detail,
        BgPages.player,
        BgPages.settings,
        BgPages.settingsDetail,
      ])
        p: const PageBg(type: BgType.inherit),
    },
  ),
  ThemePreset(
    id: 'miku',
    name: '初音未来',
    emoji: '🎤',
    bgs: {
      BgPages.global: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/global.jpg',
        overlayOpacity: 0.45,
      ),
      BgPages.recommend: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/recommend.jpg',
        overlayOpacity: 0.4,
      ),
      BgPages.search: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/search.jpg',
        overlayOpacity: 0.45,
      ),
      BgPages.charts: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/charts.jpg',
        overlayOpacity: 0.45,
      ),
      BgPages.playlists: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/playlists.jpg',
        overlayOpacity: 0.4,
      ),
      BgPages.detail: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/detail.jpg',
        overlayOpacity: 0.5,
      ),
      BgPages.player: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/player.jpg',
        overlayOpacity: 0.4,
      ),
      BgPages.settings: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/settings.jpg',
        overlayOpacity: 0.55,
      ),
      BgPages.settingsDetail: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/settings_detail.jpg',
        overlayOpacity: 0.5,
      ),
      BgPages.playerBar: const PageBg(
        type: BgType.image,
        imagePath: 'assets/theme/miku/player_bar.jpg',
        overlayOpacity: 0.25,
      ),
    },
  ),
  ThemePreset(
    id: 'nightpurple',
    name: '暗夜霓虹紫',
    emoji: '🌃',
    bgs: {
      BgPages.global: const PageBg(
        type: BgType.gradient,
        colors: [0xFF12102A, 0xFF1A1233, 0xFF20122E],
      ),
      BgPages.player: const PageBg(
        type: BgType.gradient,
        colors: [0xFF1A1233, 0xFF12102A],
        overlayOpacity: 0.3,
      ),
      for (final p in [
        BgPages.recommend,
        BgPages.search,
        BgPages.charts,
        BgPages.playlists,
        BgPages.detail,
      ])
        p: const PageBg(type: BgType.inherit),
    },
  ),
];

/// 主题状态管理器（全局单例，ChangeNotifier）
class ThemeState extends ChangeNotifier {
  final Map<String, PageBg> _bgs = {
    for (final p in BgPages.all) p: const PageBg(),
  };

  String _activePreset = 'default';
  String get activePreset => _activePreset;

  /// 用户本地保存的预设（与内置预设混排展示）
  final List<CustomPreset> _customPresets = [];
  List<CustomPreset> get customPresets => List.unmodifiable(_customPresets);

  ThemeState() {
    _load();
  }

  /// 获取某个页面的有效背景（inherit 时递归到全局）
  PageBg effectiveBg(String pageId) {
    final bg = _bgs[pageId] ?? const PageBg();
    if (bg.type == BgType.inherit && pageId != BgPages.global) {
      return _bgs[BgPages.global] ?? const PageBg();
    }
    return bg;
  }

  /// 获取某个页面的原始配置（设置页用）
  PageBg rawBg(String pageId) => _bgs[pageId] ?? const PageBg();

  /// 设置某个页面的背景
  Future<void> setBg(String pageId, PageBg bg) async {
    _bgs[pageId] = bg;
    _activePreset = 'custom';
    notifyListeners();
    await _save();
  }

  /// 应用预设主题（一键换肤）
  Future<void> applyPreset(ThemePreset preset) async {
    _bgs
      ..clear()
      ..addAll(preset.bgs);
    _activePreset = preset.id;
    notifyListeners();
    await _save();
  }

  /// 把当前主题（页面背景 + 全部 UI 参数）保存为本地预设。
  /// 自定义图片会复制进预设自己的目录，之后原图被删也不影响该预设。
  Future<CustomPreset> saveCurrentAsPreset(String name) async {
    final id = 'u_${DateTime.now().millisecondsSinceEpoch}';
    final dir = await _presetDir(id);

    var slot = 0;
    // 把本地图片复制到预设目录，返回新路径；asset 内置图保持原样
    Future<String> copyImg(String src) async {
      final dst = '${dir.path}/img_${slot++}${_extOf(src)}';
      await File(src).copy(dst);
      return dst;
    }

    final bgs = <String, PageBg>{};
    for (final pageId in BgPages.all) {
      final bg = rawBg(pageId);
      final path = bg.imagePath;
      if (bg.type == BgType.image &&
          path != null &&
          !path.startsWith('assets/')) {
        try {
          bgs[pageId] = bg.copyWith(imagePath: await copyImg(path));
          continue;
        } catch (_) {
          // 复制失败则退回原路径，至少不丢配置
        }
      }
      bgs[pageId] = bg;
    }

    final ui = exportUiSettings();
    final playerImg = customPlayerBgImage.value;
    if (playerImg.isNotEmpty && !playerImg.startsWith('assets/')) {
      try {
        ui['customPlayerBgImage'] = await copyImg(playerImg);
      } catch (_) {
        // 同上
      }
    }

    final preset = CustomPreset(id: id, name: name, bgs: bgs, ui: ui);
    _customPresets.add(preset);
    notifyListeners();
    await _saveCustomPresets();
    return preset;
  }

  /// 应用本地预设：先套背景，再套 UI 参数
  Future<void> applyCustomPreset(CustomPreset preset) async {
    _bgs
      ..clear()
      ..addAll(preset.bgs);
    _activePreset = preset.id;
    notifyListeners();
    await importUiSettings(preset.ui);
    await _save();
  }

  /// 删除本地预设，并清掉它自己目录里的图片
  Future<void> deleteCustomPreset(String id) async {
    _customPresets.removeWhere((p) => p.id == id);
    if (_activePreset == id) _activePreset = 'custom';
    try {
      final base = await getApplicationDocumentsDirectory();
      final target = Directory('${base.path}/theme_presets/$id');
      if (target.existsSync()) target.deleteSync(recursive: true);
    } catch (_) {
      // 目录删不掉不影响预设列表
    }
    notifyListeners();
    await _saveCustomPresets();
    await _save();
  }

  Future<Directory> _presetDir(String id) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/theme_presets/$id');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '.jpg';
    var ext = path.substring(i).toLowerCase();
    if (ext.length > 5) ext = '.jpg';
    return ext;
  }

  /// 重置所有 UI 背景设置回默认液态青绿预设（不动用户数据/登录态）
  Future<void> resetToDefault() async {
    final def = kPresets.firstWhere((p) => p.id == 'default');
    _bgs
      ..clear()
      ..addAll(def.bgs);
    _activePreset = def.id;
    notifyListeners();
    await _save();
  }

  static const _key = 'theme_bgs_v1';
  static const _keyPreset = 'theme_preset';
  static const _keyPresets = 'theme_custom_presets_v1';

  Future<void> _saveCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyPresets,
      jsonEncode(_customPresets.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _bgs.map((k, v) => MapEntry(k, jsonEncode(v.toJson())));
    await prefs.setString(_key, jsonEncode(map));
    await prefs.setString(_keyPreset, _activePreset);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _activePreset = prefs.getString(_keyPreset) ?? 'default';
      final raw = prefs.getString(_key);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((k, v) {
          _bgs[k] = PageBg.fromJson(
            jsonDecode(v as String) as Map<String, dynamic>,
          );
        });
      }
      // 本地预设列表
      final rawPresets = prefs.getString(_keyPresets);
      if (rawPresets != null) {
        final list = jsonDecode(rawPresets) as List;
        _customPresets
          ..clear()
          ..addAll(
            list.map(
              (e) => CustomPreset.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
      }
      notifyListeners();
    } catch (_) {
      // 解析失败保持默认
    }
  }
}

/// 全局主题状态单例
final themeState = ThemeState();
