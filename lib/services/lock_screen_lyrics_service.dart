/// 锁屏歌词服务（主 isolate）
///
/// 流程：
/// 1. MainActivity 通过 LockScreenWatcher 监听 SCREEN_OFF/ON + 解锁事件，
///    经 MethodChannel "liquid_music/lock_screen" 推给本服务
/// 2. 锁屏 + 亮屏 + 开关开启 + 正在播放 → 启动 LockScreenActivity
///    （网易云同款方案：普通 Activity + FLAG_SHOW_WHEN_LOCKED 显示在锁屏
///    之上，不需要悬浮窗权限、不受 ROM 锁屏层限制；独立 Flutter 引擎按
///    route "lock_lyrics" 分流只跑歌词 UI）
/// 3. 本服务把歌曲全量/进度 tick 写进 SharedPreferences（lock_overlay_state/
///    lock_overlay_tick），Activity 引擎轮询读取
/// 4. Activity 的控制命令（toggle/next/prev/seek/close）经
///    lock_overlay_msg 写回，本服务轮询读走操作 PlayerState
/// 5. 解锁 / 息屏 / 手动退出 / 开关关闭 → finish Activity
///
/// 全链路日志写入 [LockLog]（设置页「查看锁屏日志」可看），排查 MIUI 等机型
/// 锁屏不显示问题：广播是否到达 → 决策走哪个分支 → Activity 是否启动。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lock_log.dart';
import '../state/player_state.dart';
import '../state/ui_settings.dart';

class LockScreenLyricsService {
  LockScreenLyricsService._();

  /// 厂商权限指引是否已展示过（首次开启锁屏歌词时弹一次）
  static Future<bool> get guideShown async =>
      (await SharedPreferences.getInstance()).getBool(
        'lock_lyrics_guide_shown',
      ) ==
      true;

  static Future<void> markGuideShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lock_lyrics_guide_shown', true);
  }

  static const MethodChannel _lockChannel = MethodChannel(
    'liquid_music/lock_screen',
  );

  static PlayerState? _player;
  static bool _showing = false;

  /// overlay 引擎是否已 ready（每次 show 重建引擎，需重新握手）
  static bool _overlayReady = false;

  /// 本次锁屏会话中用户手动关闭过（点亮屏幕不再自动弹出，息屏后重置）
  static bool _manuallyClosed = false;

  /// 上次推送的换歌标识 / 歌词行数 / 歌词行 / 播放状态
  static String _lastSongKey = '';
  static int _lastLyricsCount = -1;
  static int _lastIndex = -999;
  static int _lastPlaying = -1;

  /// 初始化：注册原生监听 + overlay 回传命令处理。
  /// main() 中 PlayerState 创建后调用一次。
  static void init(PlayerState player) {
    _player = player;
    player.addListener(_onPlayerChanged);
    _lockChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onLockState':
          final args = call.arguments as Map?;
          final screenOn = args?['screenOn'] == true;
          final keyguard = args?['keyguard'] == true;
          LockLog.instance.log(
            '收到原生锁屏事件: screenOn=$screenOn keyguard=$keyguard',
          );
          await _handleLockState(screenOn, keyguard);
          break;
        case 'onWatcherStarted':
          LockLog.instance.log('原生广播监听注册成功');
          break;
      }
    });
    // 启动原生广播监听
    unawaited(
      _lockChannel
          .invokeMethod('start')
          .then((ok) {
            LockLog.instance.log('已请求原生注册广播监听: result=$ok');
          })
          .catchError((e) {
            LockLog.instance.log('原生注册监听失败: $e');
          }),
    );
  }

  /// 设置开关被关闭（设置页调用）：立即收起悬浮窗
  static Future<void> onDisabled() async {
    _manuallyClosed = false;
    await _hide();
  }

  /// 诊断：不锁屏直接显示锁屏歌词界面（设置页「立即测试」调用）。
  /// 能显示 → 显示链路正常，锁屏无反应是广播/冻结问题；
  /// 不能显示 → Activity 启动被系统拦截。
  static Future<void> testShow() async {
    LockLog.instance.log('===== 手动测试显示 =====');
    await _show();
  }

  // ---------- 锁屏状态机 ----------

  static Future<void> _handleLockState(bool screenOn, bool keyguard) async {
    if (!lockScreenLyrics.value) {
      LockLog.instance.log('跳过显示: 锁屏歌词开关未开启');
      return;
    }

    if (screenOn && keyguard) {
      // 锁屏 + 亮屏：显示歌词（用户点亮屏幕看歌的场景）
      if (_manuallyClosed) {
        LockLog.instance.log('跳过显示: 本次锁屏已手动关闭');
      } else if (_player?.current == null) {
        LockLog.instance.log('跳过显示: 当前无播放歌曲');
      } else {
        await _show();
      }
    } else if (!screenOn) {
      // 息屏：收起省电；重置手动关闭标记，下次亮屏重新弹出
      _manuallyClosed = false;
      await _hide();
    } else {
      // 亮屏 + 已解锁（USER_PRESENT / 解锁瞬间）：收起回到锁屏
      _manuallyClosed = false;
      await _hide();
    }
  }

  static Future<void> _show() async {
    if (_showing) {
      LockLog.instance.log('显示跳过: 锁屏歌词已在显示中');
      return;
    }
    _showing = true;
    _overlayReady = false;
    _lastSongKey = '';
    _lastLyricsCount = -1;
    _lastIndex = -999;
    _lastPlaying = -1;
    try {
      // Activity 方案（网易云同款）：普通 Activity + FLAG_SHOW_WHEN_LOCKED
      // 显示在锁屏之上，不需要悬浮窗权限、不受 ROM 锁屏层限制
      await _lockChannel.invokeMethod('startLockScreenActivity');
      LockLog.instance.log('锁屏 Activity 已启动');
      // 启动 prefs 命令通道轮询（activity→主方向）
      _startPolling();
      // Activity 引擎轮询 prefs 取数据，无需握手，直接推全量并开始 tick
      _overlayReady = true;
      _pushSong();
    } catch (e) {
      _showing = false;
      LockLog.instance.log('锁屏 Activity 启动失败: $e');
    }
  }

  static Future<void> _hide() async {
    if (!_showing) return;
    _showing = false;
    _overlayReady = false;
    _stopPolling();
    try {
      await _lockChannel.invokeMethod('finishLockScreenActivity');
      LockLog.instance.log('锁屏歌词已关闭');
    } catch (e) {
      LockLog.instance.log('关闭锁屏 Activity 失败: $e');
    }
  }

  // ---------- overlay → 主 isolate 命令 ----------

  /// SharedPreferences 命令通道轮询定时器。
  /// fork 包的 shareData 在 overlay 引擎侧被 native 覆盖的 messenger 回环拦截
  /// （WindowSetup.messenger 被 plugin attach overlay 引擎时覆盖），overlay→主
  /// 方向的 shareData 永远到不了主端，故改走 prefs：overlay 写入、主端轮询读走。
  static Timer? _pollTimer;

  static void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(_pollOverlayMessages()),
    );
  }

  static void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  static Future<void> _pollOverlayMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 关键：Dart 层 SharedPreferences 有内存缓存，getString 只读缓存。
      // overlay 引擎是另一个 FlutterEngine，它的写入只有 reload() 后才可见，
      // 否则主端永远读到 null（退出/切歌/暂停全部失灵的直接原因）。
      await prefs.reload();
      // 原生窗口添加结果（fork patch 写入，诊断锁屏层不显示）
      final native = prefs.getString('lock_overlay_native');
      if (native != null) {
        await prefs.remove('lock_overlay_native');
        LockLog.instance.log('[原生] $native');
      }
      // Activity 被返回键/系统回收关闭（LockScreenActivity.onDestroy 写入）：
      // 重置显示状态，否则主端一直认为"已在显示中"，下次亮屏不再弹出
      final closed = prefs.getInt('lock_overlay_activity_closed');
      if (closed != null) {
        await prefs.remove('lock_overlay_activity_closed');
        if (_showing) {
          _showing = false;
          _overlayReady = false;
          _manuallyClosed = true;
          LockLog.instance.log('锁屏歌词界面已退出');
        }
      }
      // 诊断信息（一次性，读走即删）
      final dbg = prefs.getString('lock_overlay_dbg');
      if (dbg != null) {
        await prefs.remove('lock_overlay_dbg');
        LockLog.instance.log('[overlay] $dbg');
      }
      // 控制命令（一次性；overlay 端 _send 写入，type 含 ready/toggle/next/...）
      final raw = prefs.getString('lock_overlay_msg');
      if (raw != null) {
        await prefs.remove('lock_overlay_msg');
        final m = jsonDecode(raw);
        if (m is Map) _onOverlayMessage(m);
      }
    } catch (_) {}
  }

  static void _onOverlayMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'dbg') {
      // overlay 引擎的诊断信息（initState/收到数据/UI 错误）
      LockLog.instance.log('[overlay] ${message['msg']}');
      return;
    }
    if (type == 'ready') {
      // overlay 引擎就绪：推全量歌词 + 当前状态
      _overlayReady = true;
      LockLog.instance.log('overlay 引擎已就绪，推送歌词数据');
      _pushSong();
      return;
    }
    final ps = _player;
    if (ps == null) return;
    switch (type) {
      case 'toggle':
        unawaited(ps.togglePlay());
        break;
      case 'next':
        unawaited(ps.next());
        break;
      case 'prev':
        unawaited(ps.previous());
        break;
      case 'seek':
        // 新协议：args 直接是毫秒数（overlay 端 _send('seek', t)）
        final args = message['args'];
        final ms = args is num
            ? args.toInt()
            : (args is Map ? ((args['ms'] as num?)?.toInt() ?? 0) : 0);
        unawaited(ps.seek(Duration(milliseconds: ms)));
        break;
      case 'close':
        // 左上角退出：关闭悬浮窗（不解锁手机），本次锁屏不再自动弹出
        _manuallyClosed = true;
        LockLog.instance.log('用户点击退出按钮，本次锁屏不再自动弹出');
        unawaited(_hide());
        break;
    }
  }

  // ---------- 主 isolate → overlay 数据 ----------

  /// PlayerState 变化：换歌/歌词加载完成推全量，行/播放状态变化推 tick
  static void _onPlayerChanged() {
    if (!_showing || !_overlayReady) return;
    final ps = _player;
    final song = ps?.current;
    if (ps == null || song == null) return;

    final key = '${song.id}::${song.name}';
    // 歌词是异步加载的：推送时可能还是 0 行，加载完成后行数变化要重推全量，
    // 否则悬浮窗永远显示"暂无歌词"
    final lyricsCount = ps.lyrics.length;
    if (key != _lastSongKey || lyricsCount != _lastLyricsCount) {
      _pushSong();
      return;
    }
    final index = ps.currentLyricIndex;
    final playing = ps.playing ? 1 : 0;
    if (index != _lastIndex || playing != _lastPlaying) {
      _lastIndex = index;
      _lastPlaying = playing;
      _share({'type': 'tick', 'index': index, 'playing': ps.playing});
    }
  }

  /// 推全量歌曲数据（换歌 / overlay ready）
  static void _pushSong() {
    final ps = _player;
    final song = ps?.current;
    if (ps == null || song == null) {
      LockLog.instance.log('推送歌词跳过: 当前无歌曲');
      return;
    }

    final key = '${song.id}::${song.name}';
    _lastSongKey = key;
    _lastIndex = ps.currentLyricIndex;
    _lastPlaying = ps.playing ? 1 : 0;

    final detail = ps.currentDetail;
    final artist = song.artists.join(' / ');
    final lyrics = ps.lyrics
        .asMap()
        .entries
        .map(
          (e) => {
            't': e.value.time.inMilliseconds,
            'text': e.value.text.isEmpty ? '♪' : e.value.text,
            'trans': ps.translationAt(e.key),
          },
        )
        .toList();
    _lastLyricsCount = lyrics.length;

    LockLog.instance.log('推送歌词: ${song.name}（${lyrics.length} 行）');
    _share({
      'type': 'song',
      'title': song.name,
      'artist': artist,
      'album': (detail != null && detail.album.isNotEmpty)
          ? detail.album
          : song.album,
      'lyrics': lyrics,
      'index': _lastIndex,
      'playing': ps.playing,
    });
  }

  /// 推数据给锁屏 Activity 引擎（song 全量 / tick）。
  /// Activity 引擎是独立 FlutterEngine，shareData 只路由到 overlay 悬浮窗
  /// 引擎到不了 Activity —— 统一走 prefs（Activity 端 150ms 轮询读走即删）。
  static Future<void> _share(Object data) async {
    try {
      final key = (data is Map && data['type'] == 'song')
          ? 'lock_overlay_state'
          : 'lock_overlay_tick';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(data));
    } catch (e) {
      LockLog.instance.log('推送歌词数据失败: $e');
    }
  }
}
