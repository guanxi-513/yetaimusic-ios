/// 锁屏歌词悬浮窗（独立 Flutter 引擎，overlay isolate）
///
/// flutter_overlay_window 在 showOverlay 时启动独立引擎，从本文件的
/// overlayMain() 入口跑 UI。数据经 FlutterScreenOverlay.shareData 与
/// 主 isolate 双向通信（协议见 lock_screen_lyrics_service.dart）。
///
/// 网易云风格：半透明黑背景 + 歌词滚动（当前行主题色高亮）+
/// 上一首/播放暂停/下一首 + 左上角退出（关闭悬浮窗，不解锁手机）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题色（与主 App secondary 一致）
const Color _accent = Color(0xFFE05A8A);

/// 歌词行模型（overlay isolate 内不 import 主 App 的模型，避免拖依赖）
class _OLine {
  final int t;
  final String text;
  final String? trans;
  const _OLine(this.t, this.text, this.trans);

  factory _OLine.fromMap(Map map) => _OLine(
    (map['t'] as num?)?.toInt() ?? 0,
    (map['text'] as String?) ?? '',
    map['trans'] as String?,
  );
}

/// 悬浮窗根组件（公共：入口函数 overlayMain() 定义在 main.dart，
/// flutter_overlay_window 原生按函数名在 main 库查找入口）
///
/// [prefsTransport]=true 时用于锁屏 Activity 引擎（main.dart 按 route
/// 分流）：数据从 SharedPreferences 轮询读取（lock_overlay_state/tick），
/// 命令仍走 lock_overlay_msg 通道。
class LockLyricsOverlayApp extends StatelessWidget {
  const LockLyricsOverlayApp({super.key, this.prefsTransport = false});

  final bool prefsTransport;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _LockLyricsOverlay(prefsTransport: prefsTransport),
    );
  }
}

class _LockLyricsOverlay extends StatefulWidget {
  const _LockLyricsOverlay({this.prefsTransport = false});

  final bool prefsTransport;

  @override
  State<_LockLyricsOverlay> createState() => _LockLyricsOverlayState();
}

class _LockLyricsOverlayState extends State<_LockLyricsOverlay> {
  final ScrollController _scroll = ScrollController();

  /// Activity 引擎的 prefs 数据轮询
  Timer? _pollTimer;

  String _title = '';
  String _artist = '';
  List<_OLine> _lines = const [];
  int _index = -1;
  bool _playing = false;

  /// 用户手动滚动歌词后 4 秒内不自动跟随
  bool _userScrolling = false;
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    // 诊断：UI 已挂载（若主端日志有此行但屏幕黑 → 渲染问题；无此行 → 引擎没跑）
    unawaited(_dbg('overlay UI initState 完成'));
    if (widget.prefsTransport) {
      // Activity 引擎：轮询 prefs 取歌曲/进度数据，命令走 _send
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => unawaited(_pollData()),
      );
      return;
    }
    // overlay 引擎启动后立即向主 isolate 报 ready（主端收到后推全量数据）
    unawaited(_send('ready'));
    FlutterScreenOverlay.overlayListener.listen(
      _onMessage,
      onError: (e) => unawaited(_dbg('listener错误: $e')),
    );
  }

  /// Activity 引擎：轮询读取主 isolate 写入的歌曲全量 + 进度 tick
  Future<void> _pollData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final state = prefs.getString('lock_overlay_state');
      if (state != null) {
        await prefs.remove('lock_overlay_state');
        final m = jsonDecode(state);
        if (m is Map) _onMessage(m);
      }
      final tick = prefs.getString('lock_overlay_tick');
      if (tick != null) {
        await prefs.remove('lock_overlay_tick');
        final m = jsonDecode(tick);
        if (m is Map) _onMessage(m);
      }
    } catch (_) {}
  }

  /// overlay 端诊断信息回传主 isolate 记入锁屏日志。
  /// 注意：fork 包的 shareData 在 overlay 引擎侧会被 native 覆盖的 messenger
  /// 回环拦截（消息发回 overlay 自己），overlay→主方向必须走 SharedPreferences
  /// 命令通道（插件自动注册到 overlay 引擎，进程内共享，主端 150ms 轮询）。
  static Future<void> _dbg(String msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lock_overlay_dbg', msg);
    } catch (_) {}
  }

  /// 发命令给主 isolate（ready/播放暂停/切歌/退出/seek）
  static Future<void> _send(String type, [dynamic args]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'lock_overlay_msg',
        jsonEncode({
          'type': type,
          'args': args,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _resumeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onMessage(dynamic message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'song':
        final raw = (message['lyrics'] as List?) ?? const [];
        setState(() {
          _title = (message['title'] as String?) ?? '';
          _artist = (message['artist'] as String?) ?? '';
          _lines = raw.map((e) => _OLine.fromMap(e as Map)).toList();
          _index = (message['index'] as num?)?.toInt() ?? -1;
          _playing = message['playing'] == true;
        });
        _dbg('收到 song 数据: ${_lines.length} 行，index=$_index');
        WidgetsBinding.instance.addPostFrameCallback((_) => _follow(true));
        break;
      case 'tick':
        setState(() {
          _index = (message['index'] as num?)?.toInt() ?? _index;
          _playing = message['playing'] == true;
        });
        _follow(false);
        break;
    }
  }

  /// 自动跟随：把当前行滚到可视区约 1/3 处
  void _follow(bool instant) {
    if (_userScrolling || _lines.isEmpty || _index < 0) return;
    if (!_scroll.hasClients) return;
    const extent = 64.0;
    final viewport = _scroll.position.viewportDimension;
    final target = (_index * extent - viewport / 2 + extent / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (instant) {
      _scroll.jumpTo(target);
    } else if ((_scroll.offset - target).abs() > 1) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _markUserScroll() {
    _userScrolling = true;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 4), () {
      _userScrolling = false;
      _follow(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // fullCover 窗口里 SafeArea 的 inset 传递不可靠，手动取 max(系统 inset, 固定值)
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top > 40 ? mq.padding.top : 44.0;
    final bottomPad = mq.padding.bottom > 16 ? mq.padding.bottom : 24.0;
    return Scaffold(
      // 半透明黑背景：透出锁屏壁纸保持沉浸感
      backgroundColor: Colors.black.withOpacity(0.85),
      body: Column(
        children: [
          // ---------- 顶部：退出 + 歌名/歌手 ----------
          Padding(
            padding: EdgeInsets.fromLTRB(4, topPad, 16, 0),
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.comfortable,
                  icon: const Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () => unawaited(_send('close')),
                ),
                const Spacer(),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_artist.isNotEmpty)
                        Text(
                          _artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ---------- 歌词区 ----------
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Text(
                      '暂无歌词',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 14,
                      ),
                    ),
                  )
                : NotificationListener<UserScrollNotification>(
                    onNotification: (n) {
                      if (n.direction == ScrollDirection.idle) return false;
                      _markUserScroll();
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      itemExtent: 64,
                      itemCount: _lines.length,
                      itemBuilder: (context, i) {
                        final active = i == _index;
                        final line = _lines[i];
                        return GestureDetector(
                          onTap: () => unawaited(_send('seek', _lines[i].t)),
                          behavior: HitTestBehavior.opaque,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  line.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: active
                                        ? _accent
                                        : Colors.white.withOpacity(0.45),
                                    fontSize: active ? 19 : 15,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                                if (active &&
                                    line.trans != null &&
                                    line.trans!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    line.trans!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: _accent.withOpacity(0.65),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          // ---------- 底部控制按钮 ----------
          Padding(
            padding: EdgeInsets.only(bottom: bottomPad + 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  visualDensity: VisualDensity.comfortable,
                  icon: const Icon(
                    Icons.skip_previous,
                    color: Colors.white,
                    size: 44,
                  ),
                  onPressed: () => unawaited(_send('prev')),
                ),
                IconButton(
                  visualDensity: VisualDensity.comfortable,
                  icon: Icon(
                    _playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 64,
                  ),
                  onPressed: () => unawaited(_send('toggle')),
                ),
                IconButton(
                  visualDensity: VisualDensity.comfortable,
                  icon: const Icon(
                    Icons.skip_next,
                    color: Colors.white,
                    size: 44,
                  ),
                  onPressed: () => unawaited(_send('next')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
