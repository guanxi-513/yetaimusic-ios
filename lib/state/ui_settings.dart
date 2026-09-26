/// 全局 UI 设置（设置页可调，shared_preferences 持久化）
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面风格预设
enum UiStyle {
  /// 液态玻璃：封面模糊 + 实时毛玻璃 + 玻璃卡片 + 青绿光效
  glass,

  /// 极简暗色：纯黑背景 + 扁平卡片，无模糊无光效
  plain,

  /// 暗色透明：封面模糊 + 详情页全透明透出下层 + 玻璃卡片
  transparent,

  /// 极简白色（暖白）：白底黑字，全局无玻璃无模糊
  white,
}

/// 当前界面风格（默认液态玻璃）
final ValueNotifier<UiStyle> uiStyle = ValueNotifier<UiStyle>(UiStyle.glass);

/// 歌曲卡片是否渲染毛玻璃背景模糊（默认 false：不渲染，提升列表滚动性能）
final ValueNotifier<bool> songCardBlur = ValueNotifier<bool>(false);

/// 与其他应用同时播放（默认 false）：开启后使用"共存型"音频焦点，
/// 打开抖音/视频等会抢音频焦点的应用时，本 App 的音乐不暂停、音量不变
final ValueNotifier<bool> keepPlayingWithOtherApps = ValueNotifier<bool>(false);

/// 锁屏歌词（默认 false）：锁屏亮屏时显示全屏歌词悬浮窗（网易云风格）
final ValueNotifier<bool> lockScreenLyrics = ValueNotifier<bool>(false);

/// 底部播放栏距屏幕底部的间距（单位 px，默认 24：比旧版固定 12 更远离导航栏）
/// 越大播放栏越靠上，设置页「自定义界面」可调
final ValueNotifier<double> miniPlayerBottomOffset = ValueNotifier<double>(
  24.0,
);

/// 应用音频焦点配置（启动时与开关切换时调用）：
/// Android：开 = gainTransientMayDuck（共存，其他应用抢焦点时我们只收 duck 事件，
///          just_audio 对 media 用途的 duck 不降音量不暂停 → 同时播放）
///          关 = gain（独占，其他应用抢焦点时暂停，Android 默认行为）
/// iOS：开 = playback + mixWithOthers（允许与其他 App 音频混合，刷抖音音乐不中断）
///      关 = playback 独占（默认，被其他 App 接管时暂停）
Future<void> applyAudioFocusConfig() async {
  try {
    final session = await AudioSession.instance;
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: keepPlayingWithOtherApps.value
            ? AVAudioSessionCategoryOptions.mixWithOthers
            : AVAudioSessionCategoryOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: keepPlayingWithOtherApps.value
            ? AndroidAudioFocusGainType.gainTransientMayDuck
            : AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ),
    );
    await session.setActive(true);
  } catch (_) {
    // 配置失败不影响播放（保持系统默认焦点行为）
  }
}

// ---------- 歌单详情页过渡动画三开关（默认全开，可自由组合） ----------

/// 封面飞入（Hero）：封面从列表飞入详情页头部
final ValueNotifier<bool> transitionHero = ValueNotifier<bool>(true);

/// 推入转场：详情页整页上滑淡入 + 缩放，背景模糊渐显
final ValueNotifier<bool> transitionPage = ValueNotifier<bool>(true);

/// 列表递进：歌曲项逐项上浮淡入
final ValueNotifier<bool> transitionStagger = ValueNotifier<bool>(true);

// ---------- UI 高度自定义开关（默认全开，可在「UI 高度自定义」三级页单独调整） ----------
// 与上方过渡动画三开关区别：这些是更细粒度的视觉开关，控制全局/二级/播放页模糊与关闭动画。
// 复用关系：卡片模糊→songCardBlur、打开动画→transitionHero、模糊过渡→transitionPage（这三项不再重复定义）。

/// 全局背景模糊（mini player 毛玻璃层，默认 true）
final ValueNotifier<bool> globalBlur = ValueNotifier<bool>(true);

/// 二级页面背景透明（默认 true：透出下层封面模糊）
final ValueNotifier<bool> secondaryTransparent = ValueNotifier<bool>(true);

/// 播放页背景模糊（默认 true：player_page BackdropFilter sigma32）
final ValueNotifier<bool> pageBlur = ValueNotifier<bool>(true);

/// 关闭动画丝滑过渡（默认 true；预留接线位，当前仅持久化）
final ValueNotifier<bool> closeAnimation = ValueNotifier<bool>(true);

/// 播放页背景风格（独立于主题预设，强制覆盖）
enum PlayerBgStyle {
  /// 跟随主题预设：玻璃/透明档=封面模糊（或清晰封面），极简档=纯色
  cover,

  /// 暖白实色
  white,

  /// 纯黑实色
  black,

  /// 全透明：播放页透出下层（路由 opaque:false 已满足）
  transparent,

  /// 自定义颜色
  custom,
}

/// 播放页背景风格（默认跟随预设，不破坏既有玻璃封面体验）
final ValueNotifier<PlayerBgStyle> playerBgStyle = ValueNotifier<PlayerBgStyle>(
  PlayerBgStyle.cover,
);

/// 自定义播放页背景色（ARGB int，默认深灰 0xFF1A1C20）
final ValueNotifier<int> customPlayerBgColor = ValueNotifier<int>(0xFF1A1C20);

/// 自定义播放页背景图片路径（空串 = 未设置；设置后任何主题预设下优先生效）
final ValueNotifier<String> customPlayerBgImage = ValueNotifier<String>('');

/// 自定义背景图上的半透明黑遮罩（默认 true：保证歌词/控件可读）
final ValueNotifier<bool> playerBgOverlay = ValueNotifier<bool>(true);

/// 遮罩透明度（0.0~0.8，默认 0.35）
final ValueNotifier<double> playerBgOverlayOpacity = ValueNotifier<double>(
  0.35,
);

// ---------- 主题色代理：随界面风格切换 ----------

/// 是否为极简白色（浅色主题）
bool get isLight => uiStyle.value == UiStyle.white;

/// 主文字 / 主要图标颜色
Color get fgPrimary => isLight ? const Color(0xFF1A1B1C) : Colors.white;

/// 次文字颜色
Color get fgSecondary => isLight ? const Color(0xFF6B7280) : Colors.white70;

/// 弱文字颜色（占位、说明）
Color get fgTertiary => isLight ? const Color(0xFF9CA3AF) : Colors.white38;

/// 更弱的文字（标签、注释）
Color get fgHint => isLight ? const Color(0xFFB6BAC2) : Colors.white24;

/// 页面根背景
Color get bgBase => isLight ? const Color(0xFFF9FAF4) : Colors.black;

/// 卡片底色（白档=纯白卡片；暗色档=深灰实色）
Color get bgCard => isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1A1C20);

/// 弹窗 / 浮层底色
Color get bgElevated =>
    isLight ? const Color(0xFFF2F1EC) : const Color(0xFF121216);

/// 分隔线 / 描边色
Color get borderColor =>
    isLight ? const Color(0xFFE4E3DD) : Colors.white.withOpacity(0.25);

/// 是否禁用一切玻璃 / 模糊效果（浅色极简档）
bool get noGlass => isLight || uiStyle.value == UiStyle.plain;

/// 启动时加载 UI 设置
Future<void> loadUiSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final styleName = prefs.getString('ui_style');
  uiStyle.value = UiStyle.values.firstWhere(
    (e) => e.name == styleName,
    orElse: () => UiStyle.glass,
  );
  songCardBlur.value = prefs.getBool('song_card_blur') ?? false;
  keepPlayingWithOtherApps.value =
      prefs.getBool('keep_playing_with_other_apps') ?? false;
  lockScreenLyrics.value = prefs.getBool('lock_screen_lyrics') ?? false;
  miniPlayerBottomOffset.value =
      prefs.getDouble('mini_player_bottom_offset') ?? 24.0;
  transitionHero.value = prefs.getBool('transition_hero') ?? true;
  transitionPage.value = prefs.getBool('transition_page') ?? true;
  transitionStagger.value = prefs.getBool('transition_stagger') ?? true;
  globalBlur.value = prefs.getBool('global_blur') ?? true;
  secondaryTransparent.value = prefs.getBool('secondary_transparent') ?? true;
  pageBlur.value = prefs.getBool('page_blur') ?? true;
  closeAnimation.value = prefs.getBool('close_animation') ?? true;
  final bgStyleName = prefs.getString('player_bg_style');
  playerBgStyle.value = PlayerBgStyle.values.firstWhere(
    (e) => e.name == bgStyleName,
    orElse: () => PlayerBgStyle.cover,
  );
  customPlayerBgColor.value =
      prefs.getInt('custom_player_bg_color') ?? 0xFF1A1C20;
  customPlayerBgImage.value = prefs.getString('custom_player_bg_image') ?? '';
  playerBgOverlay.value = prefs.getBool('player_bg_overlay') ?? true;
  playerBgOverlayOpacity.value =
      prefs.getDouble('player_bg_overlay_opacity') ?? 0.35;
}

/// 切换「封面飞入」并持久化
Future<void> setTransitionHero(bool value) async {
  transitionHero.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_hero', value);
}

/// 切换「推入转场」并持久化
Future<void> setTransitionPage(bool value) async {
  transitionPage.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_page', value);
}

/// 切换「列表递进」并持久化
Future<void> setTransitionStagger(bool value) async {
  transitionStagger.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_stagger', value);
}

/// 切换界面风格并持久化
Future<void> setUiStyle(UiStyle style) async {
  uiStyle.value = style;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ui_style', style.name);
}

/// 切换歌曲卡片毛玻璃并持久化
Future<void> setSongCardBlur(bool value) async {
  songCardBlur.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('song_card_blur', value);
}

/// 切换「与其他应用同时播放」并持久化 + 立即应用音频焦点配置
Future<void> setKeepPlayingWithOtherApps(bool value) async {
  keepPlayingWithOtherApps.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('keep_playing_with_other_apps', value);
  unawaited(applyAudioFocusConfig());
}

/// 切换「锁屏歌词」并持久化（悬浮窗权限申请由设置页处理）
Future<void> setLockScreenLyrics(bool value) async {
  lockScreenLyrics.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('lock_screen_lyrics', value);
}

/// 调整底部播放栏距底部的间距（px）并持久化；越大越靠上
Future<void> setMiniPlayerBottomOffset(double value) async {
  miniPlayerBottomOffset.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble('mini_player_bottom_offset', value);
}

// ---------- UI 高度自定义开关的 setter（持久化） ----------

/// 切换「全局背景模糊」并持久化
Future<void> setGlobalBlur(bool value) async {
  globalBlur.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('global_blur', value);
}

/// 切换「二级页面背景透明」并持久化
Future<void> setSecondaryTransparent(bool value) async {
  secondaryTransparent.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('secondary_transparent', value);
}

/// 切换「播放页背景模糊」并持久化
Future<void> setPageBlur(bool value) async {
  pageBlur.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('page_blur', value);
}

/// 切换「关闭动画丝滑过渡」并持久化
Future<void> setCloseAnimation(bool value) async {
  closeAnimation.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('close_animation', value);
}

/// 切换「播放页背景风格」并持久化
Future<void> setPlayerBgStyle(PlayerBgStyle value) async {
  playerBgStyle.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('player_bg_style', value.name);
}

/// 设置「播放页自定义背景色」（ARGB int）并持久化
Future<void> setCustomPlayerBgColor(int value) async {
  customPlayerBgColor.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('custom_player_bg_color', value);
}

/// 设置「自定义播放背景图片」路径并持久化（传空串 = 清除）
Future<void> setCustomPlayerBgImage(String path) async {
  customPlayerBgImage.value = path;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('custom_player_bg_image', path);
}

/// 切换「自定义背景半透明遮罩」并持久化
Future<void> setPlayerBgOverlay(bool value) async {
  playerBgOverlay.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('player_bg_overlay', value);
}

/// 调整「自定义背景遮罩透明度」（0.0~0.8）并持久化
Future<void> setPlayerBgOverlayOpacity(double value) async {
  playerBgOverlayOpacity.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble('player_bg_overlay_opacity', value);
}
