/// 多设备同步服务（纯局域网 WebRTC P2P，不改后端）
///
/// 架构（对应 docs/多设备同步-前端提示词.md）：
/// - 设备发现：bonsoir（mDNS）。主控广播 `_liquidmusic._tcp`（9001），
///   被控广播 `_liquidmusicf._tcp`（9002），双方互相浏览对方类型。
/// - 信令交换：局域网 HTTP。主控 HttpServer(9001) 提供 `/offer` `/ice`；
///   被控 HttpServer(9002) 提供 `/ice`（接主控 ICE）`/invite`（主控发起邀请）。
/// - 建连：被控为 WebRTC 发起方（createOffer → POST 主控 /offer → answer），
///   双方 ICE candidate 互推，DataChannel('sync') 打开后进入同步态。
/// - 同步：主控在 换歌/暂停/恢复/拖动 时广播 JSON 消息 + 每 5s 心跳；
///   被控按时间戳 + 时钟偏移对齐进度（漂移 >1.5s 自动修正）。
/// - 音频流：各设备自己通过现有接口拿同一首歌的 URL（消息只带歌曲元数据），
///   WebRTC 只传控制信号。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'sync_log.dart';

/// 被控端执行主控命令的桥（由 PlayerState 实现，main 里 bind）
abstract class SyncPlayerDelegate {
  /// 播放指定歌曲并对齐到 [at]（被控端自己通过现有接口解析歌曲 URL）。
  /// [autoplay] 为 false 时只加载不播放（主控处于暂停态）。
  Future<void> syncPlay(Song song, Duration at, bool autoplay);

  Future<void> syncPause();

  Future<void> syncResume();

  Future<void> syncSeek(Duration position);

  /// 正在执行 syncPlay（URL 加载中）？期间命令会被丢弃或缓冲。
  /// 主控/被控据此决定是否更新歌曲去重标识、是否等待。
  bool get syncBusy;

  /// 本机当前播放快照（主控心跳/被控漂移修正用）
  SyncSnapshot snapshot();
}

/// 本机播放快照
class SyncSnapshot {
  final Song? song;

  /// 当前歌最终可播放 URL（可能为空串：本地缓存直播时无法给出；
  /// 被控有 song 元数据时会自己解析，不依赖该字段）
  final String url;
  final Duration position;
  final bool playing;
  const SyncSnapshot({
    required this.song,
    required this.url,
    required this.position,
    required this.playing,
  });
}

/// 主控端为每个被控维护的独立连接（一对多）。
///
/// 每个被控拥有独立的 RTCPeerConnection/DataChannel/时钟偏移/看门狗时间戳，
/// 单台掉线不影响其他被控。被控端不使用本类（被控仍 1:1 连主控，
/// 复用 SyncService 的单值字段 _pc/_dc/_clockOffsetMs 等）。
class GuestConnection {
  /// 唯一标识："$deviceName@$host"，避免重名设备冲突
  final String id;

  /// 被控上报的设备名
  String deviceName;

  /// 被控信令地址（HTTP 推送目标 + ICE 回传目标）
  String host;

  /// 被控信令端口（默认 9002）
  int port;

  /// 该被控独立的 WebRTC 连接
  RTCPeerConnection? pc;

  /// 该被控独立的 DataChannel
  RTCDataChannel? dc;

  /// 该被控当前传输通道
  SyncTransport? transport;

  /// 该被控连接状态：connecting / synced
  SyncStatus status;

  /// 该被控独立时钟偏移（毫秒，主控时钟 - 被控时钟）
  int clockOffsetMs;

  /// 该被控最后收到消息时间（看门狗用）
  DateTime lastMessageAt;

  /// HTTP 模式：上次应用的歌曲标识（换歌检测）
  String? lastSongKey;

  /// 主控请求被控补采 IPv4 候选后，该被控是否已配合过一次重新协商
  bool peerRenegotiateHandled;

  /// 主控缺 IPv4 候选时标记，等 DataChannel open 后请该被控重新协商
  bool masterNeedRenegotiate;

  /// 该被控是否正从 HTTP 切回 WebRTC（下条 /offer 按新连接处理）
  bool expectingWebRtcOffer;

  /// 该被控 ICE 自动重连计数
  int iceRestartAttempts;

  /// 该被控是否正在 ICE restart 协商
  bool iceRestarting;

  /// 该被控 ICE restart 延迟定时器
  Timer? iceRestartTimer;

  /// 该被控首次建连 gathering 完无 IPv4 时是否补采过
  bool gatherRetryDone;

  /// 该被控本地已收集 ICE candidate 数（日志用）
  int localIceCount;

  /// 该被控远端 SDP 是否已 set
  bool remoteDescSet;

  /// 该被控 remote description 就绪前到达的远端 ICE candidate 缓冲
  final List<RTCIceCandidate> pendingRemoteCandidates = [];

  /// 该被控对端 ICE 回传地址（主控 → 被控 /ice）
  String peerIceUrl;

  /// 构造
  GuestConnection({
    required this.id,
    required this.deviceName,
    required this.host,
    required this.port,
    this.status = SyncStatus.connecting,
    this.clockOffsetMs = 0,
    DateTime? lastMessageAt,
    this.peerRenegotiateHandled = false,
    this.masterNeedRenegotiate = false,
    this.expectingWebRtcOffer = false,
    this.iceRestartAttempts = 0,
    this.iceRestarting = false,
    this.gatherRetryDone = false,
    this.localIceCount = 0,
    this.remoteDescSet = false,
    this.peerIceUrl = '',
  }) : lastMessageAt = lastMessageAt ?? DateTime.now();

  /// 是否已同步
  bool get isSynced => status == SyncStatus.synced;
}

/// 局域网发现的候选设备
class NearbyDevice {
  final String name;
  final String host;
  final int port;
  DateTime lastSeen;
  NearbyDevice({
    required this.name,
    required this.host,
    required this.port,
    required this.lastSeen,
  });
}

/// 同步角色
enum SyncRole { none, master, follower }

/// 同步状态：idle 未启用 / waiting 等待发现或选择 / connecting 建连中 /
/// synced 已同步（DataChannel 打开）
enum SyncStatus { idle, waiting, connecting, synced }

/// 当前使用的传输通道
enum SyncTransport { webrtc, http }

/// 用户选择的连接方式：auto 先 WebRTC，5s 不通自动降级 HTTP
enum SyncConnectMode { auto, webrtc, httpOnly }

class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  // ---------- 常量 ----------
  /// 主控信令端口（/offer /ice）
  static const int masterPort = 9001;

  /// 被控信令端口（/ice /invite）
  static const int followerPort = 9002;

  /// 主控 mDNS 服务类型
  static const String serviceTypeMaster = '_liquidmusic._tcp';

  /// 被控 mDNS 服务类型（与主控区分，主控浏览此类型列出被控设备）
  static const String serviceTypeFollower = '_liquidmusicf._tcp';

  /// 主控进度心跳间隔：
  /// WebRTC 下被控回 ack 保活；HTTP 下经 /command 即时推送。
  /// 心跳只负责"状态同步 + 漂移检测"，漂移修正由下面的阈值控制，
  /// 不再每次心跳都 seek，避免频繁 seek 导致音乐一卡一卡。
  static const Duration _heartbeatInterval = Duration(seconds: 5);

  /// 漂移修正阈值默认值：250ms（听感可接受的轻微偏差上限）。
  /// 实际阈值可在同步页 UI 调整（50-500ms），见 [driftSeekThresholdMs]。
  static const int kDefaultDriftThresholdMs = 250;

  /// 漂移修正阈值（毫秒，可调 50-500）：进度偏差超过此值才 seek 修正。
  /// 默认 250ms 最合适：低于此值听感无差异但易频繁 seek 卡顿，
  /// 过高则明显不同步。UI 调整后写入 SharedPreferences 持久化。
  static const String _prefDriftThresholdMs = 'sync_drift_threshold_ms';
  int _driftThresholdMs = kDefaultDriftThresholdMs;

  int get driftSeekThresholdMs => _driftThresholdMs;

  /// 设置漂移修正阈值（毫秒）。范围 50-500，超出自动钳位。
  /// 主控端调用：本地改 + 下次心跳自动下发给被控。
  /// 被控端调用：仅本地改（实际阈值由主控心跳覆盖）。
  /// 持久化到 SharedPreferences，重启后生效。
  Future<void> setDriftThresholdMs(int ms) async {
    final clamped = ms.clamp(50, 500);
    if (_driftThresholdMs == clamped) return;
    _driftThresholdMs = clamped;
    notifyListeners();
    await _persistDriftThreshold(clamped);
  }

  Future<void> _persistDriftThreshold(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefDriftThresholdMs, ms);
    } catch (_) {}
  }

  /// 从 SharedPreferences 加载上次设置的阈值（init 时调用一次）
  Future<void> _loadDriftThreshold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_prefDriftThresholdMs);
      if (v != null) _driftThresholdMs = v.clamp(50, 500);
    } catch (_) {}
  }

  /// 漂移修正最小间隔（冷却时间）：两次 seek 修正之间至少间隔 3s，
  /// 防止网络抖动或硬件时钟波动导致连续 seek 卡顿。
  static const Duration _driftSeekCooldown = Duration(seconds: 3);

  /// 同步看门狗超时：30s 没收到对端任何消息才判定断开
  static const Duration _watchdogTimeout = Duration(seconds: 30);

  /// ICE disconnected 后等待 5s 再自动重连
  static const Duration _iceRestartDelay = Duration(seconds: 5);

  /// ICE 自动重连最大次数，超过才提示用户
  static const int _maxIceRestarts = 3;

  /// 发现列表过期时间（3s 扫描周期 × 3）
  static const Duration _staleTimeout = Duration(seconds: 9);

  /// 建连超时：进入 connecting 后 15s 仍未 open 则报错回退
  static const Duration _connectTimeout = Duration(seconds: 15);

  /// auto 模式：WebRTC 5s 未 connected 即降级 HTTP 长轮询
  static const Duration _autoFallbackDelay = Duration(seconds: 5);

  /// HTTP 兼容模式兜底轮询间隔。
  /// 控制命令（切歌/暂停/继续/seek）由主控 POST /command 即时推送，
  /// 轮询只负责保活、RTT 对时、以及漏推时的状态兜底，500ms 足够且更省电。
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 单次轮询请求超时
  static const Duration _pollRequestTimeout = Duration(seconds: 3);

  static const String _modePrefKey = 'sync_connect_mode';

  // ---------- 状态 ----------
  SyncRole _role = SyncRole.none;
  SyncStatus _status = SyncStatus.idle;
  String _peerName = '';
  String _deviceName = '';

  SyncRole get role => _role;
  SyncStatus get status => _status;
  String get deviceName => _deviceName;

  /// 对端设备名：
  /// - 被控：主控设备名（单值）
  /// - 主控：所有已接入被控名拼接（如 "A、B"），无被控时返回空串
  String get peerName {
    if (_role != SyncRole.master) return _peerName;
    if (_guests.isEmpty) return '';
    return _guests.values.map((g) => g.deviceName).join('、');
  }

  /// 主控视角：所有已接入被控连接（只读）
  List<GuestConnection> get guests => List.unmodifiable(_guests.values);

  /// 主控视角：已接入被控总数
  int get guestCount => _guests.length;

  /// 主控视角：已同步（DataChannel 打开 / HTTP 会话建立）的被控数
  int get syncedGuestCount => _guests.values.where((g) => g.isSynced).length;

  /// 用户选择的连接方式（auto / WebRTC 强制 / HTTP 兼容）
  SyncConnectMode _connectMode = SyncConnectMode.auto;
  SyncConnectMode get connectMode => _connectMode;

  /// 当前生效通道（连接成功后才有值）
  SyncTransport? _transport;
  SyncTransport? get transport => _transport;

  /// 普通提示（非错误，如「已切换兼容模式」），UI 读一次后清空
  String? _lastNotice;
  String? takeNotice() {
    final n = _lastNotice;
    _lastNotice = null;
    return n;
  }

  /// 是否处于已同步的主控身份（本机操作需要广播给对方）
  /// 主控模式：至少一台被控已同步即视为已同步主控
  bool get isMaster =>
      _role == SyncRole.master && _guests.values.any((g) => g.isSynced);

  /// 是否已同步（DataChannel 打开 / HTTP 会话建立）
  /// 主控模式：至少一台被控已同步；被控模式：_status == synced
  bool get isSynced {
    if (_role == SyncRole.master) return _guests.values.any((g) => g.isSynced);
    return _status == SyncStatus.synced;
  }

  /// 是否启用了任一角色（页面据此显示状态）
  bool get active => _role != SyncRole.none;

  /// 主控视角：附近被控设备
  final List<NearbyDevice> _followers = [];
  List<NearbyDevice> get followers => List.unmodifiable(_followers);

  /// 被控视角：附近主控设备
  final List<NearbyDevice> _masters = [];
  List<NearbyDevice> get masters => List.unmodifiable(_masters);

  /// 最近一次断开的原因（UI 用来提示，读取后清空）
  String? _lastDisconnectReason;
  String? takeDisconnectReason() {
    final r = _lastDisconnectReason;
    _lastDisconnectReason = null;
    return r;
  }

  // ---------- 资源 ----------
  SyncPlayerDelegate? _delegate;

  /// 主控一对多：所有被控连接（key = "$deviceName@$host"，见 GuestConnection.id）
  /// 被控端不使用本字段（被控仍 1:1 连主控，复用下方单值 _pc/_dc 等）
  final Map<String, GuestConnection> _guests = {};

  /// 主控反查：RTCPeerConnection → guest（ICE/PC 状态回调里定位是哪台被控）
  final Map<RTCPeerConnection, GuestConnection> _guestByPc = {};

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  Timer? _pruneTimer;

  /// 建连 30s 超时定时器
  Timer? _connectTimer;

  /// auto 模式 5s WebRTC 未连通 → 降级 HTTP 的定时器
  Timer? _fallbackTimer;

  /// 被控 HTTP 兼容模式轮询定时器
  Timer? _pollTimer;

  /// 轮询请求在途标记（防止上一个 200ms 未返回就发下一个）
  bool _pollInFlight = false;

  /// 连续轮询失败次数（日志/降速用；成功清零）
  int _pollFailCount = 0;

  /// HTTP 模式上次应用的歌曲标识（用于判断换歌 vs 心跳式对齐）
  String? _lastHttpSongKey;

  /// HTTP 模式：是否正在应用一次 /state（防重入，避免换歌加载时叠加）
  bool _applyingState = false;

  /// 漂移修正状态：上次 seek 修正的时间戳（用于冷却控制）
  DateTime? _lastDriftSeekAt;

  /// 漂移修正状态：连续检测到超阈值偏差的心跳次数。
  /// 仅当连续 2 次心跳都超阈值才 seek，避免单次网络抖动触发误修正。
  int _driftOverCount = 0;

  /// 主动切换通道中：抑制 teardown 引发的失败/断线回调
  bool _switching = false;

  /// HTTP→WebRTC 切换中：若 WebRTC 建连失败，自动回到 HTTP 轮询
  bool _recoverToHttpOnFail = false;

  /// ICE disconnected 后延迟重连的定时器
  Timer? _iceRestartTimer;

  /// 是否正在进行 ICE restart 协商（防重入）
  bool _iceRestarting = false;

  /// 已进行的 ICE 自动重连次数（connected 后清零）
  int _iceRestartAttempts = 0;

  /// 首次建连 gathering 完无 IPv4 时，是否已补采过一次
  bool _gatherRetryDone = false;

  /// 主控：自己没收集到 IPv4 候选（热点虚拟网卡），需请被控发起一次重新协商
  bool _masterNeedRenegotiate = false;

  /// 被控：主控请求的补采重新协商，每条连接只配合一次，防互相循环
  bool _peerRenegotiateHandled = false;

  /// 被控：主控信令地址（ICE restart 重新 offer 时用）
  String _masterHost = '';
  int _masterPort = masterPort;

  DateTime _lastMessageAt = DateTime.now();

  /// 远端时钟 - 本地时钟（毫秒）；被控端通过 hello/welcome 交换估算
  int _clockOffsetMs = 0;

  /// HTTP 连接初始时钟突发校准：8 轮取最小 RTT 的 offset
  bool _clockBursting = false;
  int _clockBurstBestRtt = 1 << 30;

  /// 对端 ICE 回传地址（被控 → 主控 /ice；主控 → 被控 /ice）
  String _peerIceUrl = '';

  /// 本地已收集 ICE candidate 数（排查用日志）
  int _localIceCount = 0;

  /// 远端 SDP 是否已 set（之前到达的 candidate 需要缓冲，否则 addCandidate 失败）
  bool _remoteDescSet = false;

  /// remote description 就绪前到达的远端 ICE candidate
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  /// 日志（release 也保留 print，方便 logcat 过滤 [SYNC] 排查建连问题）
  String get _tag => _role == SyncRole.master
      ? 'HOST'
      : _role == SyncRole.follower
      ? 'GUEST'
      : 'CORE';
  void _log(String msg) {
    // 同时输出 logcat（print）与应用内日志页（SyncLog）
    final line = '[SYNC][$_tag] $msg';
    print(line);
    SyncLog.instance.log(line);
  }

  /// 绑定播放器桥（main 里调用一次）
  void bind(SyncPlayerDelegate delegate) => _delegate = delegate;

  /// 启动时读取持久化的连接方式 + 漂移阈值
  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_modePrefKey);
      _connectMode = SyncConnectMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => SyncConnectMode.auto,
      );
    } catch (_) {}
    await _loadDriftThreshold();
  }

  /// 切换连接方式（持久化）。被控同步中若显式指定通道，立即切换；
  /// auto 只改偏好，不动当前通道。
  Future<void> setConnectMode(SyncConnectMode mode) async {
    if (_connectMode == mode) return;
    _connectMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modePrefKey, mode.name);
    } catch (_) {}
    if (_role == SyncRole.follower && _status == SyncStatus.synced) {
      if (mode == SyncConnectMode.httpOnly &&
          _transport == SyncTransport.webrtc) {
        unawaited(followerSwitchTransport(SyncTransport.http));
      } else if (mode == SyncConnectMode.webrtc &&
          _transport == SyncTransport.http) {
        unawaited(followerSwitchTransport(SyncTransport.webrtc));
      }
    }
  }

  // ================= 主控：创建同步 =================

  /// 主控：注册 mDNS + 起信令服务器，等待被控加入。
  /// 返回本机设备名。
  Future<String> startHosting() async {
    if (_role == SyncRole.master) return _deviceName;
    await stop(); // 先清理旧状态
    await _initDeviceName();
    _role = SyncRole.master;
    _status = SyncStatus.waiting;
    notifyListeners();

    try {
      // 1. 信令服务器（先起，避免被控 offer 早于 mDNS 广播到达时被拒）
      _server = await HttpServer.bind(InternetAddress.anyIPv4, masterPort);
      _log('HttpServer bound on http://0.0.0.0:$masterPort');
      _server!.listen(
        _handleMasterRequest,
        onError: (e) => _log('主控信令服务异常: $e'),
      );

      // 2. mDNS 广播
      final service = BonsoirService(
        name: _deviceName,
        type: serviceTypeMaster,
        port: masterPort,
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
      _log('mDNS registered on port $masterPort (name=$_deviceName)');

      // 3. 浏览附近被控设备
      await _startDiscovery(serviceTypeFollower);

      // 4. 列表过期清理（每 3s 一轮，9s 未再见即移除）
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _pruneStale(_followers);
      });

      // 5. 枚举本机 IPv4 显示在等待页（热点场景被控需要手动输入此 IP）
      unawaited(refreshLocalIPv4s());
    } catch (e) {
      _log('创建同步失败: $e');
      await stop();
      _lastDisconnectReason = '创建同步失败：$e';
      notifyListeners();
    }
    return _deviceName;
  }

  /// 主控信令：/offer 收被控 SDP offer 回 answer；/ice 收被控 ICE
  /// 一对多：按 clientIp + deviceName 找/建 GuestConnection，每台被控独立 PC/DC。
  Future<void> _handleMasterRequest(HttpRequest req) async {
    try {
      final clientIp = req.connectionInfo?.remoteAddress.address ?? '?';
      if (req.method == 'POST' && req.uri.path == '/offer') {
        final body = await utf8.decoder.bind(req).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final deviceName = map['deviceName']?.toString() ?? '附近设备';
        final iceUrl = map['iceUrl']?.toString() ?? '';
        final isRestart = map['restart'] == true;
        // 按 deviceName+clientIp 找现有 guest（同台被控重连/切通道/补采）
        var g = _findGuest(deviceName, clientIp);
        final isRestartOfExisting = isRestart && g != null && g.pc != null;
        if (isRestartOfExisting) {
          // ICE 重启（或被控无 IPv4 补采）：复用该 guest 的 PC 重新协商。
          // 重启信令本身说明被控还活着，刷新看门狗避免误断
          g.lastMessageAt = DateTime.now();
          _log(
            'recv RESTART offer from $clientIp/${g.deviceName} '
            '(sdp=${(map['sdp']?.toString() ?? '').length})',
          );
          await g.pc!.setRemoteDescription(
            RTCSessionDescription(map['sdp'] as String, map['type'] as String),
          );
          final answer = await g.pc!.createAnswer();
          await g.pc!.setLocalDescription(answer);
          if (iceUrl.isNotEmpty) g.peerIceUrl = iceUrl;
          await _replyJson(req, {'sdp': answer.sdp, 'type': answer.type});
          _log('restart answer sent to $clientIp/${g.deviceName}');
          return;
        }
        // 新连接 / HTTP 切回 WebRTC / 首次 offer
        final fromHttpSwitch =
            g != null && g.isSynced && g.transport == SyncTransport.http;
        _log(
          'recv ${fromHttpSwitch ? 'SWITCH ' : ''}offer from $clientIp/$deviceName '
          '(sdp=${(map['sdp']?.toString() ?? '').length})',
        );
        // 新建或复用 guest 记录
        g ??= _upsertGuest(deviceName, clientIp);
        g.expectingWebRtcOffer = false;
        g.lastMessageAt = DateTime.now();
        // 主控整体 _status 只用于 UI/路由判断，保持 connecting（首台）或不动
        if (_status == SyncStatus.idle || _status == SyncStatus.waiting) {
          _status = SyncStatus.connecting;
        }
        notifyListeners();

        await _createPeerForGuest(g);
        // 主控不主动 createDataChannel，等被控的通道透传过来
        g.pc!.onDataChannel = (dc) => _onGuestDataChannel(g!, dc);
        await g.pc!.setRemoteDescription(
          RTCSessionDescription(map['sdp'] as String, map['type'] as String),
        );
        await _markRemoteDescReadyForGuest(g);
        final answer = await g.pc!.createAnswer();
        await g.pc!.setLocalDescription(answer);
        // 被控的 ICE 回传地址（主控把自己 candidate POST 过去）
        g.peerIceUrl = iceUrl;
        _log('answer sdp length=${answer.sdp?.length ?? 0}');
        await _replyJson(req, {'sdp': answer.sdp, 'type': answer.type});
        _log('answer sent to $clientIp/$deviceName');
      } else if (req.method == 'POST' && req.uri.path == '/ice') {
        final body = await utf8.decoder.bind(req).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final cand = map['candidate'] as Map<String, dynamic>?;
        // 按源 IP 匹配 guest（被控 /ice 不带 deviceName，源 IP 即唯一标识）
        final g = _findGuestByIp(clientIp);
        if (cand != null && g != null && g.pc != null) {
          final cStr = (cand['candidate'] as String?) ?? '';
          _log(
            'recv ICE ${cStr.length > 40 ? cStr.substring(0, 40) : cStr} '
            'from $clientIp/${g.deviceName}',
          );
          g.lastMessageAt = DateTime.now();
          await _addRemoteCandidateForGuest(
            g,
            RTCIceCandidate(
              cand['candidate'] as String?,
              cand['sdpMid'] as String?,
              (cand['sdpMLineIndex'] as num?)?.toInt() ?? 0,
            ),
          );
        }
        await _replyJson(req, {'ok': true});
      } else if (req.method == 'GET' && req.uri.path == '/state') {
        // HTTP 兼容模式：被控长轮询拉取最新播放状态（每次请求即保活）
        // 一对多：每台被控独立 HTTP 会话，按 deviceName+clientIp 找/建 guest
        final name = req.uri.queryParameters['deviceName'] ?? '附近设备';
        final port =
            int.tryParse(req.uri.queryParameters['port'] ?? '') ?? followerPort;
        final g = _upsertGuest(name, clientIp, port: port);
        _rememberGuestHttp(g, req, port);
        _enterGuestHttpSession(g, name);
        await _replyJson(req, _buildStateJson());
      } else if (req.method == 'POST' && req.uri.path == '/switch') {
        // 被控手动切换通道（一对多：按 deviceName+clientIp 定位 guest）
        final body = await utf8.decoder.bind(req).join();
        final map = body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        final to = map['to']?.toString();
        final name = map['deviceName']?.toString() ?? '附近设备';
        final g = _upsertGuest(name, clientIp);
        if (to == 'http') {
          // 被控要切 HTTP：主控拆掉该 guest 的旧 PC/DC（抑制关闭回调），进入 HTTP 会话
          _switching = true;
          await _teardownGuest(g);
          _switching = false;
          _rememberGuestHttp(
            g,
            req,
            (map['port'] as num?)?.toInt() ?? followerPort,
          );
          _enterGuestHttpSession(g, name);
        } else if (to == 'webrtc') {
          // 下一条 /offer 按新连接处理；期间看门狗靠 /switch 时间戳续命
          g.expectingWebRtcOffer = true;
          g.lastMessageAt = DateTime.now();
          _log('被控 $name 请求切回 WebRTC，等待新 offer');
        }
        await _replyJson(req, {'ok': true});
      } else if (req.method == 'POST' && req.uri.path == '/bye') {
        // 被控主动离开（一对多：按源 IP 定位 guest，只拆该台）
        await _replyJson(req, {'ok': true});
        final g = _findGuestByIp(clientIp);
        if (g != null) {
          _handleGuestDisconnect(g, '${g.deviceName} 已断开同步');
        }
      } else {
        await _replyJson(req, {'error': 'not found'}, status: 404);
      }
    } catch (e) {
      _log('主控信令处理失败: $e');
      try {
        await _replyJson(req, {'error': e.toString()}, status: 500);
      } catch (_) {}
    }
  }

  // ---------- 主控一对多：guest 索引/生命周期辅助 ----------

  /// 按 deviceName + clientIp 查找现有 guest（同台被控重连/切通道）
  /// 优先精确匹配 id；找不到则按 IP 匹配（被控 /ice 不带 deviceName）
  GuestConnection? _findGuest(String deviceName, String clientIp) {
    final id = '$deviceName@$clientIp';
    final byId = _guests[id];
    if (byId != null) return byId;
    // 兜底：按 IP 匹配（deviceName 可能在 /ice 时缺失）
    for (final g in _guests.values) {
      if (g.host == clientIp) return g;
    }
    return null;
  }

  /// 仅按源 IP 查找 guest（/ice /bye 路由用，被控不带 deviceName）
  GuestConnection? _findGuestByIp(String clientIp) {
    for (final g in _guests.values) {
      if (g.host == clientIp) return g;
    }
    return null;
  }

  /// 新建或更新 guest 记录（/offer /state /switch 路由用）
  /// 已存在则更新 port，不存在则新建并加入 _guests
  GuestConnection _upsertGuest(
    String deviceName,
    String clientIp, {
    int? port,
  }) {
    final id = '$deviceName@$clientIp';
    final existing = _guests[id];
    if (existing != null) {
      if (port != null) existing.port = port;
      return existing;
    }
    // 兜底：按 IP 找（deviceName 可能变化）
    final byIp = _findGuestByIp(clientIp);
    if (byIp != null) {
      byIp.deviceName = deviceName;
      if (port != null) byIp.port = port;
      return byIp;
    }
    final g = GuestConnection(
      id: id,
      deviceName: deviceName,
      host: clientIp,
      port: port ?? followerPort,
    );
    _guests[id] = g;
    _log('新建被控连接: $id');
    return g;
  }

  /// 主控：记录被控命令服务器地址（HTTP 主动推送目标），写入 guest
  void _rememberGuestHttp(GuestConnection g, HttpRequest req, int port) {
    final ip = req.connectionInfo?.remoteAddress.address;
    if (ip == null || ip.isEmpty || ip == '?') return;
    g.host = ip;
    g.port = port;
  }

  /// 主控 HTTP 模式：被控通过 GET /state 接入/保活 → 进入或维持 HTTP 会话。
  /// 一对多：每台被控独立判定，仅首次接入时改状态/通知。
  void _enterGuestHttpSession(GuestConnection g, String name) {
    final firstEntry = !g.isSynced || g.transport != SyncTransport.http;
    g.lastMessageAt = DateTime.now();
    if (!firstEntry) return;
    g.deviceName = name;
    g.transport = SyncTransport.http;
    g.status = SyncStatus.synced;
    _log('被控 $name 经 HTTP 兼容模式接入（命令主动推送）');
    _startWatchdog();
    _startHeartbeat();
    // 主控整体状态：至少一台 synced 即视为 synced
    if (_status != SyncStatus.synced) {
      _status = SyncStatus.synced;
    }
    notifyListeners();
    // 立即推送当前完整播放状态给该被控
    _pushCurrentStateToGuest(g);
  }

  /// 主控 HTTP 模式：把一条命令即时 POST 推送给指定被控（失败静默，
  /// 被控 500ms 轮询会兜底拉到最新状态，不影响主控本地播放）。
  Future<void> _httpPushToGuest(
    GuestConnection g,
    Map<String, dynamic> msg,
  ) async {
    if (g.host.isEmpty) return;
    try {
      final r = await http
          .post(
            Uri.parse('http://${g.host}:${g.port}/command'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(msg),
          )
          .timeout(const Duration(seconds: 2));
      if (r.statusCode != 200) {
        _log('命令推送失败：HTTP ${r.statusCode}（轮询兜底中）');
      }
    } catch (_) {
      // 静默：被控可能暂时不可达，500ms 轮询继续保活并补齐状态
    }
  }

  /// 主控：邀请附近被控设备加入（被控收到 /invite 后自动反向发起 offer）。
  /// 返回 false 表示邀请没送到（被控稍后不会发起连接）。
  /// 一对多：不因已有被控同步而拒绝新邀请，可连续邀请多台。
  Future<bool> inviteFollower(NearbyDevice device) async {
    final ip = await _localIp();
    final url = 'http://${device.host}:${device.port}/invite';
    _log('invite follower ${device.name} via $url (本机出口 IP=$ip)');
    final resp = await _postJson(url, {
      'name': _deviceName,
      'host': ip,
      'port': masterPort,
    });
    if (resp == null) {
      _log('invite 无响应：${device.name}');
      _lastDisconnectReason = '邀请发送失败：无法连接 ${device.name}，请确认双方在同一 Wi-Fi';
      notifyListeners();
      return false;
    }
    return true;
  }

  // ================= 被控：加入同步 =================

  /// 被控：扫描附近主控（mDNS 浏览 `_liquidmusic._tcp`）
  Future<void> startBrowsing() async {
    if (_role == SyncRole.follower) return;
    await stop();
    await _initDeviceName();
    _role = SyncRole.follower;
    _status = SyncStatus.waiting;
    notifyListeners();

    try {
      // 被控信令服务器（9002：接收主控 ICE / 邀请）
      _server = await HttpServer.bind(InternetAddress.anyIPv4, followerPort);
      _log('HttpServer bound on http://0.0.0.0:$followerPort');
      _server!.listen(
        _handleFollowerRequest,
        onError: (e) => _log('被控信令服务异常: $e'),
      );

      // 广播自己（主控设备列表能看到本机）
      final service = BonsoirService(
        name: _deviceName,
        type: serviceTypeFollower,
        port: followerPort,
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
      _log('mDNS registered on port $followerPort (name=$_deviceName)');

      // 浏览附近主控
      await _startDiscovery(serviceTypeMaster);
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _pruneStale(_masters);
      });
    } catch (e) {
      _log('加入同步失败: $e');
      await stop();
      _lastDisconnectReason = '加入同步失败：$e';
      notifyListeners();
    }
  }

  /// 被控信令：/ice 收主控 ICE；/invite 收主控邀请（自动反向发起连接）
  Future<void> _handleFollowerRequest(HttpRequest req) async {
    try {
      final clientIp = req.connectionInfo?.remoteAddress.address ?? '?';
      if (req.method == 'POST' && req.uri.path == '/ice') {
        final body = await utf8.decoder.bind(req).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final cand = map['candidate'] as Map<String, dynamic>?;
        if (cand != null && _pc != null) {
          final cStr = (cand['candidate'] as String?) ?? '';
          _log(
            'recv ICE from $clientIp ${cStr.length > 40 ? cStr.substring(0, 40) : cStr}',
          );
          await _addRemoteCandidate(
            RTCIceCandidate(
              cand['candidate'] as String?,
              cand['sdpMid'] as String?,
              (cand['sdpMLineIndex'] as num?)?.toInt() ?? 0,
            ),
          );
        }
        await _replyJson(req, {'ok': true});
      } else if (req.method == 'POST' && req.uri.path == '/command') {
        // HTTP 兼容模式：主控主动推送的控制命令（play/pause/resume/seek）。
        // 先回 200 再执行——syncPlay 可能耗时数十秒，不能占着 HTTP 连接。
        final body = await utf8.decoder.bind(req).join();
        final cmd = jsonDecode(body) as Map<String, dynamic>;
        await _replyJson(req, {'ok': true});
        unawaited(_handlePushCommand(cmd));
      } else if (req.method == 'POST' && req.uri.path == '/invite') {
        final body = await utf8.decoder.bind(req).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        await _replyJson(req, {'ok': true});
        // 主控邀请 → 自动向该主控发起 WebRTC 连接
        final name = map['name']?.toString() ?? '主控设备';
        final host = map['host']?.toString() ?? '';
        final port = (map['port'] as num?)?.toInt() ?? masterPort;
        _log('recv invite from $name ($host:$port)');
        if (host.isNotEmpty && !isSynced && _status != SyncStatus.connecting) {
          unawaited(
            connectToMaster(
              NearbyDevice(
                name: name,
                host: host,
                port: port,
                lastSeen: DateTime.now(),
              ),
            ),
          );
        }
      } else {
        await _replyJson(req, {'error': 'not found'}, status: 404);
      }
    } catch (e) {
      _log('被控信令处理失败: $e');
      try {
        await _replyJson(req, {'error': e.toString()}, status: 500);
      } catch (_) {}
    }
  }

  /// 被控：连接主控。按连接方式选择 WebRTC 或 HTTP 长轮询；
  /// auto 模式先走 WebRTC，5s 未连通自动降级 HTTP。
  /// [force] 用于已同步时手动切通道。
  Future<bool> connectToMaster(
    NearbyDevice master, {
    bool force = false,
  }) async {
    if ((isSynced || _status == SyncStatus.connecting) && !force) return false;
    _peerName = master.name;
    _status = SyncStatus.connecting;
    _transport = null;
    notifyListeners();
    _armConnectTimeout();

    try {
      await _ensureFollowerInfra();

      _masterHost = master.host;
      _masterPort = master.port;

      // HTTP 兼容模式（用户手选 / 模拟器）：不建 WebRTC，直接轮询
      if (_connectMode == SyncConnectMode.httpOnly) {
        await startHttpPolling(master.host, master.port, master.name);
        return true;
      }

      await _establishWebRtc();
      // auto：5s 没连上就降级 HTTP 长轮询
      if (_connectMode == SyncConnectMode.auto) {
        _armHttpFallback(master);
      }
      _log('setRemoteDescription(answer) 完成，等待 ICE connected…');
      return true;
    } catch (e) {
      if (!_switching) _failConnecting('连接失败：$e');
      return false;
    }
  }

  /// 被控侧 9002 信令服 + mDNS 广播（首次连接时补建）
  Future<void> _ensureFollowerInfra() async {
    if (_server == null) {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, followerPort);
      _log('HttpServer bound on http://0.0.0.0:$followerPort（连接时补建）');
      _server!.listen(_handleFollowerRequest);
    }
    if (_broadcast == null) {
      final service = BonsoirService(
        name: _deviceName,
        type: serviceTypeFollower,
        port: followerPort,
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
    }
  }

  /// 被控：建立/重建 WebRTC（offer → /offer → answer），不含模式判断
  Future<void> _establishWebRtc() async {
    _peerIceUrl = 'http://$_masterHost:$_masterPort/ice';
    await _createPeer();
    final dc = await _pc!.createDataChannel(
      'sync',
      RTCDataChannelInit()..ordered = true,
    );
    _onDataChannel(dc);
    await _sendOffer(iceRestart: false);
  }

  /// auto 模式：WebRTC 5s 未 open 自动降级 HTTP 长轮询
  void _armHttpFallback(NearbyDevice master) {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(_autoFallbackDelay, () {
      if (_status == SyncStatus.connecting &&
          _role == SyncRole.follower &&
          _transport == null) {
        _log('WebRTC ${_autoFallbackDelay.inSeconds}s 未连通，自动降级 HTTP 兼容模式');
        _lastNotice = 'WebRTC 不可用，已切换兼容模式（HTTP）';
        unawaited(_downgradeToHttp(master.host, master.port, master.name));
      }
    });
  }

  /// 拆掉进行中的 WebRTC 尝试并切到 HTTP 轮询（保留被控角色与浏览列表）
  Future<void> _downgradeToHttp(String host, int port, String peerName) async {
    _switching = true;
    _connectTimer?.cancel();
    _connectTimer = null;
    await _teardownConnection();
    _switching = false;
    await startHttpPolling(host, port, peerName);
  }

  /// 被控：绕过 mDNS，手动输入主控 IP 直连（热点 / mDNS 被路由器拦截场景）。
  /// 支持 "192.168.43.1" 或 "192.168.43.1:9001"。
  Future<bool> connectToMasterIp(String input) async {
    var host = input.trim();
    if (host.isEmpty || _status == SyncStatus.connecting) return false;
    var port = masterPort;
    if (host.startsWith('http://')) host = host.substring(7);
    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length != 2) {
        _notifyError('IP 格式不正确，示例：192.168.43.1');
        return false;
      }
      host = parts[0];
      port = int.tryParse(parts[1]) ?? masterPort;
    }
    final ipValid =
        InternetAddress.tryParse(host) != null &&
        !host.contains(':'); // tryParse 放行 IPv6，这里只收 IPv4
    if (!ipValid || host.split('.').length != 4) {
      _notifyError('IP 格式不正确，示例：192.168.43.1');
      return false;
    }
    _log('手动输入主控 IP 直连：$host:$port（不依赖 mDNS）');
    return connectToMaster(
      NearbyDevice(
        name: '手动连接 $host',
        host: host,
        port: port,
        lastSeen: DateTime.now(),
      ),
    );
  }

  // ================= HTTP 兼容模式：主控即时推送 + 被控兜底轮询 =================

  /// 被控：启动对主控 GET /state 的兜底轮询（保活/对时/漏推补齐）。
  /// 控制命令本身由主控 POST 到本机 9002/command 即时送达。
  Future<void> startHttpPolling(String host, int port, String peerName) async {
    _masterHost = host;
    _masterPort = port;
    _peerName = peerName;
    _transport = SyncTransport.http;
    _pollInFlight = false;
    _pollFailCount = 0;
    _lastHttpSongKey = null;
    _clockOffsetMs = 0;
    _clockBursting = false;
    _clockBurstBestRtt = 1 << 30;
    _status = SyncStatus.connecting;
    notifyListeners();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    _log('HTTP 兼容模式已启动：命令即时推送 + 500ms 兜底轮询 http://$host:$port/state');
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollInFlight = false;
  }

  Future<void> _pollOnce() async {
    if (_pollInFlight) return;
    if (_role != SyncRole.follower || _transport != SyncTransport.http) return;
    _pollInFlight = true;
    final t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      final uri = Uri.parse(
        'http://$_masterHost:$_masterPort/state'
        '?deviceName=${Uri.encodeComponent(_deviceName)}'
        '&port=$followerPort',
      );
      final r = await http.get(uri).timeout(_pollRequestTimeout);
      if (r.statusCode == 409) {
        // 主控已与其他设备 1:1 同步
        _handleDisconnect('主控已与其他设备同步');
        return;
      }
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final t1 = DateTime.now().millisecondsSinceEpoch;
      final m = jsonDecode(r.body) as Map<String, dynamic>;

      // RTT/2 对时（局域网 RTT 通常 <10ms）
      // 突发校准期间：只保留最小 RTT 的 offset（NTP-like）
      final serverTs = (m['ts'] as num?)?.toInt() ?? t1;
      final rtt = t1 - t0;
      if (_clockBursting) {
        if (rtt < _clockBurstBestRtt) {
          _clockBurstBestRtt = rtt;
          _clockOffsetMs = serverTs - ((t0 + t1) ~/ 2);
        }
      } else {
        _clockOffsetMs = serverTs - ((t0 + t1) ~/ 2);
      }

      final firstSync = _status != SyncStatus.synced;
      _lastMessageAt = DateTime.now();
      final remoteName = m['deviceName']?.toString();
      final nameChanged =
          remoteName != null &&
          remoteName.isNotEmpty &&
          remoteName != _peerName;
      if (nameChanged) _peerName = remoteName;
      _connectTimer?.cancel();
      _connectTimer = null;
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
      _status = SyncStatus.synced;
      if (_pollFailCount > 0) _log('轮询恢复');
      _pollFailCount = 0;
      // 看门狗与 UI 通知只在建连/恢复/对端变化时做，避免每 200ms 重建与刷新
      if (firstSync) {
        _log('HTTP 兼容模式已连接（rtt=${t1 - t0}ms）');
        _startWatchdog();
        notifyListeners();
        // 首次连接后做 8 轮突发时钟校准（取最小 RTT 的 offset）
        unawaited(_clockBurst());
      } else if (nameChanged) {
        notifyListeners();
      }

      // 状态应用与突发时钟校准并行——_applyHttpState 内有去重保护，
      // syncPlay 有 _syncBusy 保护，不会冲突
      unawaited(_applyHttpState(m));
    } catch (e) {
      _pollFailCount++;
      // 轮询保持运行不断重试；只在偶发与每分钟各打一条日志，避免刷屏
      if (_pollFailCount == 1 || _pollFailCount % 300 == 0) {
        _log('轮询失败 #$_pollFailCount（持续重试中）: $e');
      }
    } finally {
      _pollInFlight = false;
    }
  }

  /// HTTP 连接初始时钟突发校准（NTP-like）：
  /// 8 轮快速 GET /state，只做 RTT 对时，跳过状态应用，
  /// 取最小 RTT 的 offset 作为最终值（精度 <20ms）。
  Future<void> _clockBurst() async {
    const rounds = 8;
    _clockBursting = true;
    _clockBurstBestRtt = 1 << 30;
    final host = _masterHost;
    final port = _masterPort;
    if (host.isEmpty) {
      _clockBursting = false;
      return;
    }
    for (var i = 0; i < rounds; i++) {
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final r = await http
            .get(
              Uri.parse(
                'http://$host:$port/state'
                '?deviceName=${Uri.encodeComponent(_deviceName)}'
                '&port=$followerPort',
              ),
            )
            .timeout(const Duration(seconds: 2));
        if (r.statusCode == 200) {
          final t1 = DateTime.now().millisecondsSinceEpoch;
          final m = jsonDecode(r.body) as Map<String, dynamic>;
          final serverTs = (m['ts'] as num?)?.toInt() ?? t1;
          final rtt = t1 - t0;
          if (rtt < _clockBurstBestRtt) {
            _clockBurstBestRtt = rtt;
            _clockOffsetMs = serverTs - ((t0 + t1) ~/ 2);
          }
        }
      } catch (_) {}
      if (i < rounds - 1) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    _clockBursting = false;
    _log(
      '时钟突发校准完成: offset=${_clockOffsetMs}ms (minRtt=${_clockBurstBestRtt}ms)',
    );
  }

  /// 应用一次 /state：换歌走 play，其余按心跳逻辑对齐进度/播放态（复用协议）。
  /// play 走 unawaited（syncPlay 可能耗时数十秒），heartbeat 走 await（快）。
  /// syncBusy 期间不更新歌曲去重标识，下次轮询重新检测到换歌后重试。
  Future<void> _applyHttpState(Map<String, dynamic> m) async {
    if (_applyingState) return;
    _applyingState = true;
    try {
      final key = _httpSongKey(m);
      if (key != _lastHttpSongKey) {
        // syncBusy：上一首 syncPlay 正在加载，本次 play 会被丢弃，
        // 不更新 key，下次轮询（500ms 后）重新检测到换歌并重试
        if (_delegate?.syncBusy == true) return;
        _lastHttpSongKey = key;
        // 不 await：syncPlay 耗时数十秒，await 会持有 _applyingState
        // 阻塞后续所有轮询的心跳/暂停/seek 应用
        unawaited(_handleMessage({...m, 'type': 'play'}));
      } else {
        await _handleMessage({
          'type': 'heartbeat',
          'song': m['song'],
          'url': m['url'],
          'name': m['name'],
          'position': m['position'],
          'playing': m['playing'],
          'ts': m['ts'],
        });
      }
    } finally {
      _applyingState = false;
    }
  }

  /// 提取 /state 或 play 命令里的歌曲去重标识
  String? _httpSongKey(Map<String, dynamic> m) {
    final songMap = m['song'];
    if (songMap is Map) return '${songMap['id']}::${songMap['name']}';
    return '${m['url'] ?? ''}::${m['name'] ?? ''}';
  }

  /// 被控：处理主控 POST /command 主动推送的即时命令
  ///（play/pause/resume/seek）。与 500ms 兜底轮询共用同一套消息协议，
  /// 用 [_lastHttpSongKey] 去重，避免同一首歌被推送和轮询各播一次。
  /// 接受 connecting 和 synced 两种状态——首次 POST 可能比被控 own
  /// 第一次轮询响应更早到达。
  Future<void> _handlePushCommand(Map<String, dynamic> m) async {
    if (_role != SyncRole.follower ||
        _status == SyncStatus.idle ||
        _transport != SyncTransport.http) {
      return;
    }
    _lastMessageAt = DateTime.now();
    final type = m['type']?.toString();
    if (type == 'play') {
      final key = _httpSongKey(m);
      if (key == _lastHttpSongKey) return;
      // syncBusy 期间不更新 key：syncPlay 可能正在加载上一首，
      // 本次 play 会被 _syncBusy 丢弃，下次轮询需重新检测到换歌
      if (_delegate?.syncBusy == true) return;
      _lastHttpSongKey = key;
    }
    await _handleMessage(m);
  }

  /// 被控：同步中手动切换通道
  Future<void> followerSwitchTransport(SyncTransport target) async {
    if (_role != SyncRole.follower || _status != SyncStatus.synced) return;
    if (_transport == target) return;
    final host = _masterHost;
    final port = _masterPort;
    final name = _peerName;
    final wasHttp = _transport == SyncTransport.http;
    _switching = true;
    try {
      if (target == SyncTransport.http) {
        // 通知主控切 HTTP（主控随后忽略 DataChannel 关闭），再拆 WebRTC
        final r = await _postJson('http://$host:$port/switch', {
          'to': 'http',
          'deviceName': _deviceName,
          'port': followerPort,
        });
        if (r == null) throw '主控无响应';
        await _teardownConnection();
        _switching = false;
        await startHttpPolling(host, port, name);
        return;
      } else {
        // 通知主控即将重新 offer，停轮询，建 WebRTC
        _stopPolling();
        _lastMessageAt = DateTime.now();
        final r = await _postJson('http://$host:$port/switch', {
          'to': 'webrtc',
          'deviceName': _deviceName,
        });
        if (r == null) throw '主控无响应';
        _recoverToHttpOnFail = true;
        _status = SyncStatus.connecting;
        notifyListeners();
        _switching = false;
        await _establishWebRtc();
        _armConnectTimeout();
        _log('切回 WebRTC：offer 已发送，等待 ICE connected…');
      }
    } catch (e) {
      _log('切换通道失败: $e');
      _switching = false;
      _recoverToHttpOnFail = false;
      _notifyError('切换通道失败：$e');
      // 切 WebRTC 失败：拆掉半截 PC 并恢复 HTTP 轮询，避免直接掉线
      if (wasHttp) {
        _switching = true;
        await _teardownConnection();
        _switching = false;
        await startHttpPolling(host, port, name);
      }
    }
  }

  /// 被控：createOffer（可选 ICE restart）→ POST 主控 /offer → set answer。
  /// 首次连接与自动重连/补采共用。返回 false 表示协商失败。
  Future<bool> _sendOffer({required bool iceRestart}) async {
    final offer = await _pc!.createOffer(
      iceRestart
          ? const {
              'mandatory': {'IceRestart': true},
            }
          : const <String, dynamic>{},
    );
    await _pc!.setLocalDescription(offer);
    final ip = await _localIp();
    final offerUrl = 'http://$_masterHost:$_masterPort/offer';
    _log(
      'POST ${iceRestart ? 'restart ' : ''}offer to $offerUrl '
      '(本机出口 IP=$ip)',
    );
    final resp = await _postJson(offerUrl, {
      'sdp': offer.sdp,
      'type': offer.type,
      'deviceName': _deviceName,
      'iceUrl': 'http://$ip:$followerPort/ice',
      'restart': iceRestart,
    });
    if (resp == null || resp['sdp'] == null) {
      throw '主控无响应（可能已有设备同步中，或对方不在同一 Wi-Fi）';
    }
    await _pc!.setRemoteDescription(
      RTCSessionDescription(resp['sdp'] as String, resp['type'] as String),
    );
    await _markRemoteDescReady();
    return true;
  }

  // ================= WebRTC 建连与数据通道 =================

  /// 局域网直连：无需 STUN/TURN
  Future<void> _createPeer() async {
    _localIceCount = 0;
    _remoteDescSet = false;
    _pendingRemoteCandidates.clear();
    _iceRestartAttempts = 0;
    _iceRestarting = false;
    _gatherRetryDone = false;
    _masterNeedRenegotiate = false;
    _peerRenegotiateHandled = false;
    // 建连前确认本机 Wi-Fi IPv4（无位置权限时 WebRTC 可能只收集到 IPv6）
    unawaited(
      _enumerateIPv4s().then((ips) {
        _localIPv4s = ips;
        notifyListeners();
      }),
    );
    final pc = await createPeerConnection({'iceServers': []});
    pc.onIceCandidate = (c) {
      if (c.candidate == null) {
        // null candidate 表示 gathering 完成
        _log('local ICE gathering done, total=$_localIceCount');
        return;
      }
      final sdp = c.candidate!;
      // 局域网只用 IPv4：丢弃 IPv6/loopback，避免对端在 v6 上空转导致 ICE failed
      if (_isLoopbackOrV6(sdp)) {
        final preview = sdp.length > 60 ? sdp.substring(0, 60) : sdp;
        _log('skip v6/loopback: $preview');
        return;
      }
      _localIceCount++;
      _log(
        'local ICE #$_localIceCount: ${sdp.length > 80 ? sdp.substring(0, 80) : sdp}',
      );
      if (_peerIceUrl.isEmpty) return;
      // 双方 candidate 互推：POST 到对端信令服务的 /ice
      unawaited(
        _postJson(_peerIceUrl, {
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }),
      );
    };
    pc.onIceGatheringState = (state) {
      _log('ICE gathering = $state');
      if (state != RTCIceGatheringState.RTCIceGatheringStateComplete ||
          _localIceCount != 0) {
        return;
      }
      if (_role == SyncRole.follower &&
          _status == SyncStatus.connecting &&
          !_gatherRetryDone) {
        // 被控一个 IPv4 host candidate 都没收集到：IceRestart 重新 offer 强制收集
        _gatherRetryDone = true;
        _log('警告：没收集到 IPv4 host candidate，重新 offer 强制收集一次');
        unawaited(_regatherOffer());
      } else if (_role == SyncRole.master) {
        // 主控（热点机虚拟网卡 192.168.43.1 常见）：标记后请被控发起重新协商，
        // 主控是 answer 方不能自己 offer；restartIce() 置位，下轮协商时生效
        _log(
          '警告：主控没收集到 IPv4 host candidate（热点场景常见），'
          '将请求被控重新协商以补采候选',
        );
        _masterNeedRenegotiate = true;
        try {
          _pc?.restartIce();
        } catch (e) {
          _log('restartIce 调用失败: $e');
        }
        _requestRenegotiateIfReady();
      }
    };
    pc.onIceConnectionState = (state) {
      _log('ICE state = $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        // 连接恢复：清零重连计数
        _iceRestartAttempts = 0;
        _iceRestartTimer?.cancel();
        _iceRestartTimer = null;
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        if (_status == SyncStatus.synced &&
            !_switching &&
            _transport != SyncTransport.http) {
          // 同步中短暂断线很常见：5s 后由被控发起 ICE restart
          _scheduleIceRestart('ICE disconnected');
        }
        // 建连中的瞬时 disconnected 不立即报错，交给 15s 建连超时
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (_status == SyncStatus.connecting && !_switching) {
          _failConnecting(
            'ICE 连接失败。请检查：\n'
            '1. 两台手机是否在同一 Wi-Fi\n'
            '2. 是否授予了位置权限（Android 12+ 需要）\n'
            '3. 路由器是否开启了 AP 隔离',
          );
        } else if (_status == SyncStatus.synced &&
            !_switching &&
            _transport != SyncTransport.http) {
          _scheduleIceRestart('ICE failed');
        }
      }
    };
    pc.onConnectionState = (state) {
      _log('PC state = $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (_status == SyncStatus.connecting && !_switching) {
          _failConnecting('连接失败（$state）');
        } else if (_status == SyncStatus.synced &&
            !_switching &&
            _transport != SyncTransport.http) {
          _scheduleIceRestart('PC failed');
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed &&
          _status == SyncStatus.connecting &&
          !_switching) {
        // 同步中 PC closed 可能是自己 close 触发的，由 stop/teardown 负责收尾
        _failConnecting('连接失败（$state）');
      }
    };
    _pc = pc;
  }

  /// 主控一对多：为指定 guest 建独立 RTCPeerConnection。
  /// 逻辑与 [_createPeer] 相同，但所有状态写入 guest 而非单值字段，
  /// 回调闭包捕获该 guest，单台掉线不影响其他被控。
  Future<void> _createPeerForGuest(GuestConnection g) async {
    g.localIceCount = 0;
    g.remoteDescSet = false;
    g.pendingRemoteCandidates.clear();
    g.iceRestartAttempts = 0;
    g.iceRestarting = false;
    g.gatherRetryDone = false;
    g.masterNeedRenegotiate = false;
    g.peerRenegotiateHandled = false;
    // 建连前确认本机 Wi-Fi IPv4（无位置权限时 WebRTC 可能只收集到 IPv6）
    unawaited(
      _enumerateIPv4s().then((ips) {
        _localIPv4s = ips;
        notifyListeners();
      }),
    );
    final pc = await createPeerConnection({'iceServers': []});
    _guestByPc[pc] = g;
    pc.onIceCandidate = (c) {
      if (c.candidate == null) {
        _log(
          'local ICE gathering done for ${g.deviceName}, total=${g.localIceCount}',
        );
        return;
      }
      final sdp = c.candidate!;
      if (_isLoopbackOrV6(sdp)) {
        final preview = sdp.length > 60 ? sdp.substring(0, 60) : sdp;
        _log('skip v6/loopback: $preview');
        return;
      }
      g.localIceCount++;
      _log(
        'local ICE #${g.localIceCount} for ${g.deviceName}: '
        '${sdp.length > 80 ? sdp.substring(0, 80) : sdp}',
      );
      if (g.peerIceUrl.isEmpty) return;
      // 双方 candidate 互推：POST 到该被控信令服务的 /ice
      unawaited(
        _postJson(g.peerIceUrl, {
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }),
      );
    };
    pc.onIceGatheringState = (state) {
      _log('ICE gathering = $state (${g.deviceName})');
      if (state != RTCIceGatheringState.RTCIceGatheringStateComplete ||
          g.localIceCount != 0) {
        return;
      }
      // 主控没收集到 IPv4 host candidate（热点虚拟网卡 192.168.43.1 常见）：
      // 标记后请该被控发起重新协商以补采候选
      _log(
        '警告：主控对该被控 ${g.deviceName} 没收集到 IPv4 host candidate（热点场景常见），'
        '将请求被控重新协商以补采候选',
      );
      g.masterNeedRenegotiate = true;
      try {
        g.pc?.restartIce();
      } catch (e) {
        _log('restartIce 调用失败: $e');
      }
      _requestRenegotiateIfReadyForGuest(g);
    };
    pc.onIceConnectionState = (state) {
      _log('ICE state = $state (${g.deviceName})');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        g.iceRestartAttempts = 0;
        g.iceRestartTimer?.cancel();
        g.iceRestartTimer = null;
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        // 主控端只等待被控发起 ICE restart（避免双方同时重协商）
        if (g.isSynced && !_switching && g.transport != SyncTransport.http) {
          _log('ICE disconnected (${g.deviceName})，主控端等待被控发起重连…');
        }
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (g.status == SyncStatus.connecting && !_switching) {
          // 建连失败：移除该 guest，不影响其他被控
          _log('ICE failed (${g.deviceName}) 建连失败，移除该被控');
          _handleGuestDisconnect(g, '与 ${g.deviceName} 连接失败');
        } else if (g.isSynced &&
            !_switching &&
            g.transport != SyncTransport.http) {
          _log('ICE failed (${g.deviceName})，主控端等待被控发起重连…');
        }
      }
    };
    pc.onConnectionState = (state) {
      _log('PC state = $state (${g.deviceName})');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (g.status == SyncStatus.connecting && !_switching) {
          _handleGuestDisconnect(g, '与 ${g.deviceName} 连接失败');
        } else if (g.isSynced &&
            !_switching &&
            g.transport != SyncTransport.http) {
          _log('PC failed (${g.deviceName})，主控端等待被控发起重连…');
        }
      }
    };
    g.pc = pc;
  }

  /// 主控：标记该 guest 的远端 SDP 已就绪，补送缓冲的 early ICE candidate
  Future<void> _markRemoteDescReadyForGuest(GuestConnection g) async {
    g.remoteDescSet = true;
    if (g.pendingRemoteCandidates.isEmpty) return;
    _log(
      'flush ${g.pendingRemoteCandidates.length} 个缓冲的 early ICE (${g.deviceName})',
    );
    for (final c in g.pendingRemoteCandidates) {
      try {
        await g.pc?.addCandidate(c);
      } catch (e) {
        _log('补送缓冲 ICE 失败 (${g.deviceName}): $e');
      }
    }
    g.pendingRemoteCandidates.clear();
  }

  /// 主控：添加该 guest 的对端 ICE candidate；remote description 未就绪时先缓冲
  Future<void> _addRemoteCandidateForGuest(
    GuestConnection g,
    RTCIceCandidate c,
  ) async {
    final pc = g.pc;
    if (pc == null) return;
    if (!g.remoteDescSet) {
      g.pendingRemoteCandidates.add(c);
      _log(
        'early ICE 先缓冲 (${g.deviceName})，'
        '队列=${g.pendingRemoteCandidates.length}',
      );
      return;
    }
    try {
      await pc.addCandidate(c);
    } catch (e) {
      _log('addCandidate 失败 (${g.deviceName}): $e');
    }
  }

  /// 主控：在通道已开且自身缺 IPv4 候选时，请该被控发起一次 IceRestart 重新协商
  void _requestRenegotiateIfReadyForGuest(GuestConnection g) {
    if (_role != SyncRole.master || !g.masterNeedRenegotiate) return;
    if (!g.isSynced || g.dc == null) return;
    g.masterNeedRenegotiate = false;
    _sendToGuest(g, {'type': 'renegotiate'});
    _log('已请求 ${g.deviceName} 重新协商以补采热点 IPv4 候选');
  }

  /// 同步中连接断开：5s 后由被控发起 ICE restart（主控只等待，避免双方同时重协商）
  void _scheduleIceRestart(String why) {
    if (_role != SyncRole.follower) {
      _log('$why，主控端等待被控发起重连…');
      return;
    }
    if (_iceRestartTimer != null || _iceRestarting) return;
    _log('$why，${_iceRestartDelay.inSeconds}s 后尝试自动重连…');
    _iceRestartTimer = Timer(_iceRestartDelay, () {
      _iceRestartTimer = null;
      unawaited(_tryIceRestart(why));
    });
  }

  /// 被控：通过信令通道重新 offer（IceRestart），复用现有 PC/DataChannel
  Future<void> _tryIceRestart(String why) async {
    if (_status != SyncStatus.synced || _role != SyncRole.follower) return;
    if (_iceRestarting) return;
    if (_iceRestartAttempts >= _maxIceRestarts) {
      _handleDisconnect('网络连接不稳定，连续 $_maxIceRestarts 次自动重连均失败');
      return;
    }
    _iceRestartAttempts++;
    _iceRestarting = true;
    _log('ICE 自动重连 第 $_iceRestartAttempts/$_maxIceRestarts 次（$why）');
    // 重连走 HTTP 信令通道（不经过 DataChannel），期间刷新看门狗计时
    _lastMessageAt = DateTime.now();
    try {
      final ok = await _sendOffer(iceRestart: true);
      if (ok) {
        _lastMessageAt = DateTime.now();
        _log('ICE restart 协商完成，等待 ICE 重新 connected…');
      } else {
        throw '主控无响应';
      }
    } catch (e) {
      _log('ICE restart 失败: $e');
    } finally {
      _iceRestarting = false;
    }
  }

  /// 首次建连 gathering 完仍无 IPv4：IceRestart 重新 offer 一次（不占重连次数）
  Future<void> _regatherOffer() async {
    if (_status != SyncStatus.connecting || _role != SyncRole.follower) return;
    try {
      final ok = await _sendOffer(iceRestart: true);
      _log(ok ? '重新收集候选协商完成，等待新 candidate…' : '重新收集候选无响应');
    } catch (e) {
      _log('重新收集候选失败（交给建连超时处理）: $e');
    }
  }

  /// 主控在通道已开且自身缺 IPv4 候选时，请被控发起一次 IceRestart 重新协商。
  /// 被控重启 offer 时主控 createAnswer 会重新收集，热点虚拟网卡的候选由此补上。
  void _requestRenegotiateIfReady() {
    if (_role != SyncRole.master || !_masterNeedRenegotiate) return;
    if (_status != SyncStatus.synced || _dc == null) return;
    _masterNeedRenegotiate = false;
    _send({'type': 'renegotiate'});
    _log('已请求被控重新协商以补采热点 IPv4 候选');
  }

  /// 被控应主控要求做一次补采重新协商（不计入断线自动重连次数，每条连接只一次）
  Future<void> _peerRequestedRestart() async {
    if (_role != SyncRole.follower || _status != SyncStatus.synced) return;
    if (_iceRestarting) return;
    _iceRestarting = true;
    try {
      final ok = await _sendOffer(iceRestart: true);
      _log(ok ? '应主控要求重新协商完成，双方重新收集候选…' : '应主控要求重新协商无响应');
    } catch (e) {
      _log('应主控要求重新协商失败: $e');
    } finally {
      _iceRestarting = false;
    }
  }

  /// candidate 是否为 IPv6 / loopback（局域网同步一律丢弃）
  bool _isLoopbackOrV6(String candidate) {
    final s = candidate.toLowerCase();
    return s.contains('::') ||
        s.contains('127.0.0.1') ||
        s.contains('localhost');
  }

  /// 本机局域网 IPv4（热点网关如 192.168.43.1 也在此），供 UI 展示给对端手动输入
  List<String> _localIPv4s = const [];
  List<String> get localIPv4s => List.unmodifiable(_localIPv4s);

  /// 重新枚举本机 IPv4（UI 的刷新按钮用）
  Future<void> refreshLocalIPv4s() async {
    _localIPv4s = await _enumerateIPv4s(log: true);
    notifyListeners();
  }

  /// 枚举本机全部非环回 IPv4 并写日志：
  /// 用来确认 WebRTC 应能收集到 10./192.168./172.16-31. 的 host candidate。
  /// Android 12+ 未授位置权限时该枚举可能为空。
  Future<List<String>> _enumerateIPv4s({bool log = true}) async {
    final result = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (a.isLoopback || ip.startsWith('169.254')) continue;
          result.add(ip);
          if (log) {
            final lan = _isPrivateIPv4(ip);
            _log(
              'iface ${i.name} IPv4=$ip'
              '${lan ? '（局域网地址，期望成为 host candidate）' : ''}',
            );
          }
        }
      }
      if (log && result.isEmpty) {
        _log('未枚举到任何局域网 IPv4！请检查 Wi-Fi 连接与位置权限');
      }
    } catch (e) {
      if (log) _log('枚举本机 IPv4 失败（可能缺位置权限）: $e');
    }
    return result;
  }

  /// 常见私网段：10.0.0.0/8、192.168.0.0/16、172.16.0.0/12
  bool _isPrivateIPv4(String ip) {
    if (ip.startsWith('10.') || ip.startsWith('192.168.')) return true;
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// 标记远端 SDP 已就绪：把此前缓冲的 early ICE candidate 补送给 WebRTC
  Future<void> _markRemoteDescReady() async {
    _remoteDescSet = true;
    if (_pendingRemoteCandidates.isEmpty) return;
    _log('flush ${_pendingRemoteCandidates.length} 个缓冲的 early ICE');
    for (final c in _pendingRemoteCandidates) {
      try {
        await _pc?.addCandidate(c);
      } catch (e) {
        _log('补送缓冲 ICE 失败: $e');
      }
    }
    _pendingRemoteCandidates.clear();
  }

  /// 添加对端 ICE candidate；remote description 未就绪时先缓冲
  Future<void> _addRemoteCandidate(RTCIceCandidate c) async {
    final pc = _pc;
    if (pc == null) return;
    if (!_remoteDescSet) {
      _pendingRemoteCandidates.add(c);
      _log(
        'early ICE 先缓冲（remote SDP 未就绪），队列=${_pendingRemoteCandidates.length}',
      );
      return;
    }
    try {
      await pc.addCandidate(c);
    } catch (e) {
      _log('addCandidate 失败: $e');
    }
  }

  /// DataChannel 就绪回调（双方都会走这里：被控主动建，主控透传收到）
  void _onDataChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (state) {
      // 代际守卫：降级/切换通道后旧 PC 迟到的状态事件一律忽略
      if (!identical(_dc, dc)) {
        _log('忽略旧 DataChannel 事件: $state');
        return;
      }
      _log('DataChannel state = $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        // 正在主动切通道（如下降到 HTTP）时，旧通道迟到的 open 不承认
        if (_switching) {
          _log('通道切换中，忽略旧 DataChannel open');
          return;
        }
        _connectTimer?.cancel();
        _connectTimer = null;
        _fallbackTimer?.cancel();
        _fallbackTimer = null;
        _iceRestartTimer?.cancel();
        _iceRestartTimer = null;
        _iceRestartAttempts = 0;
        _iceRestarting = false;
        _recoverToHttpOnFail = false;
        _transport = SyncTransport.webrtc;
        _lastHttpSongKey = null;
        _log(
          _role == SyncRole.master
              ? 'channel open（被控已接入/WebRTC）'
              : 'datachannel open',
        );
        _lastMessageAt = DateTime.now();
        _status = SyncStatus.synced;
        notifyListeners();
        if (_role == SyncRole.follower) {
          // 切到 WebRTC 后停掉 HTTP 轮询
          _stopPolling();
          // 被控先发 hello，主控回 welcome 完成时钟偏移校准
          _send({
            'type': 'hello',
            'deviceName': _deviceName,
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
        } else if (_role == SyncRole.master) {
          // 主控：被控一加入就推当前播放状态（中途加入也能对齐）
          _pushCurrentState();
          _startHeartbeat();
          // 若主控缺热点 IPv4 候选（gathering complete 早于 open），现在补发请求
          _requestRenegotiateIfReady();
        }
        _startWatchdog();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        // 自动重连期间/等待重连/已切 HTTP/主动切换 时 SCTP closed 不判死，
        // 由重启流程、HTTP 轮询或 30s 看门狗兜底
        if (!_iceRestarting &&
            _iceRestartTimer == null &&
            !_switching &&
            _transport != SyncTransport.http &&
            _status == SyncStatus.synced) {
          _handleDisconnect('同步已断开');
        }
      }
    };
    dc.onMessage = (msg) {
      // 旧通道的迟到消息不喂看门狗、不参与状态应用
      if (!identical(_dc, dc)) return;
      _lastMessageAt = DateTime.now();
      try {
        final map = jsonDecode(msg.text) as Map<String, dynamic>;
        unawaited(_handleMessage(map));
      } catch (e) {
        _log('消息解析失败: $e');
      }
    };
  }

  /// 主控一对多：指定 guest 的 DataChannel 就绪回调。
  /// 逻辑与 [_onDataChannel] 相同，但状态写入 guest，open 时推当前状态给该被控。
  void _onGuestDataChannel(GuestConnection g, RTCDataChannel dc) {
    g.dc = dc;
    dc.onDataChannelState = (state) {
      // 代际守卫：切换通道后旧 PC 迟到的状态事件一律忽略
      if (!identical(g.dc, dc)) {
        _log('忽略旧 DataChannel 事件 (${g.deviceName}): $state');
        return;
      }
      _log('DataChannel state = $state (${g.deviceName})');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (_switching) {
          _log('通道切换中，忽略旧 DataChannel open (${g.deviceName})');
          return;
        }
        g.iceRestartTimer?.cancel();
        g.iceRestartTimer = null;
        g.iceRestartAttempts = 0;
        g.iceRestarting = false;
        g.transport = SyncTransport.webrtc;
        _log('channel open（被控 ${g.deviceName} 已接入/WebRTC）');
        g.lastMessageAt = DateTime.now();
        g.status = SyncStatus.synced;
        // 主控整体状态：至少一台 synced 即视为 synced
        if (_status != SyncStatus.synced) {
          _status = SyncStatus.synced;
        }
        notifyListeners();
        // 被控一加入就推当前播放状态（中途加入也能对齐）
        _pushCurrentStateToGuest(g);
        _startHeartbeat();
        // 若主控缺热点 IPv4 候选（gathering complete 早于 open），现在补发请求
        _requestRenegotiateIfReadyForGuest(g);
        _startWatchdog();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        // 自动重连期间/等待重连/已切 HTTP/主动切换 时 SCTP closed 不判死，
        // 由重启流程、HTTP 轮询或 30s 看门狗兜底
        if (!g.iceRestarting &&
            g.iceRestartTimer == null &&
            !_switching &&
            g.transport != SyncTransport.http &&
            g.isSynced) {
          _handleGuestDisconnect(g, '${g.deviceName} 同步已断开');
        }
      }
    };
    dc.onMessage = (msg) {
      if (!identical(g.dc, dc)) return;
      g.lastMessageAt = DateTime.now();
      try {
        final map = jsonDecode(msg.text) as Map<String, dynamic>;
        unawaited(_handleMessage(map, guest: g));
      } catch (e) {
        _log('消息解析失败 (${g.deviceName}): $e');
      }
    };
  }

  // ================= 消息协议（JSON over DataChannel） =================

  /// 收到对端消息（双方共用入口）
  /// [guest] 非空表示主控收到某被控的消息（hello/ack/bye 等），按该 guest 处理；
  /// 为空表示被控收到主控消息，按单值字段处理。
  Future<void> _handleMessage(
    Map<String, dynamic> m, {
    GuestConnection? guest,
  }) async {
    final type = m['type']?.toString();
    switch (type) {
      case 'hello':
        // 主控：回应 welcome 给该被控，带回被控原始时间戳做 RTT/2 时钟校准
        if (_role == SyncRole.master && guest != null) {
          final echoTs =
              (m['ts'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          _sendToGuest(guest, {
            'type': 'welcome',
            'echoTs': echoTs,
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
        }
        break;
      case 'ack':
        // 被控对心跳的保活应答（仅用于喂主控看门狗：lastMessageAt 已在 onMessage 更新）
        break;
      case 'renegotiate':
        // 主控缺 IPv4 候选（热点）→ 被控重新 offer 触发双方补采；每条连接只配合一次
        if (_role == SyncRole.follower &&
            _status == SyncStatus.synced &&
            !_peerRenegotiateHandled) {
          _peerRenegotiateHandled = true;
          _log('主控请求重新协商（补采热点候选）');
          unawaited(_peerRequestedRestart());
        }
        break;
      case 'welcome':
        // 被控：RTT/2 估算时钟偏移（offset = 主控时钟 - 本地时钟）
        final echo = (m['echoTs'] as num?)?.toInt() ?? 0;
        final masterTs = (m['ts'] as num?)?.toInt() ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        final rtt = now - echo;
        if (rtt >= 0) {
          _clockOffsetMs = masterTs - (echo + rtt ~/ 2);
        }
        _log('时钟偏移校准: ${_clockOffsetMs}ms (rtt=$rtt)');
        break;
      case 'play':
        final d = _delegate;
        if (d == null) break;
        final target = _targetPosition(m);
        Song? song;
        if (m['song'] is Map) {
          try {
            song = Song.fromJson((m['song'] as Map).cast<String, dynamic>());
          } catch (_) {}
        }
        final autoplay = m['playing'] != false;
        if (song != null) {
          // 首选：带完整元数据 → 被控自己解析 URL（缓存/各源接口）
          await d.syncPlay(song, target, autoplay);
        } else {
          // 兜底：只有裸 URL（协议兼容）
          final url = m['url']?.toString() ?? '';
          if (url.isEmpty) break;
          await d.syncPlay(
            Song(
              id: 0,
              name: m['name']?.toString() ?? '同步歌曲',
              artists: [
                if ((m['artist']?.toString() ?? '').isNotEmpty)
                  m['artist'].toString(),
              ],
              album: '',
              cover: m['cover']?.toString() ?? '',
              duration: 0,
            ),
            target,
            autoplay,
          );
        }
        break;
      case 'pause':
        await _delegate?.syncPause();
        break;
      case 'resume':
        await _delegate?.syncResume();
        break;
      case 'seek':
        await _delegate?.syncSeek(_targetPosition(m));
        break;
      case 'heartbeat':
        // 被控：按心跳持续修正漂移；并回 ack 给主控保活
        if (_role == SyncRole.follower) {
          _send({'type': 'ack'});
          // 心跳现在带 song 信息——检测换歌（play 命令可能因
          // race/丢弃而漏掉，心跳作为兜底换歌通道）
          final key = _httpSongKey(m);
          if (key != null &&
              key != _lastHttpSongKey &&
              _delegate?.syncBusy != true) {
            _lastHttpSongKey = key;
            _log('心跳检测到换歌: $key');
            unawaited(_handleMessage({...m, 'type': 'play'}));
            break;
          }
          // 主控下发的漂移阈值：被控被动同步（主控统一管控）
          final remoteDrift = (m['drift'] as num?)?.toInt();
          if (remoteDrift != null &&
              remoteDrift != _driftThresholdMs &&
              remoteDrift >= 50 &&
              remoteDrift <= 500) {
            _driftThresholdMs = remoteDrift;
            notifyListeners();
            _log('主控下发阈值: ${remoteDrift}ms');
            // 持久化（不阻塞当前消息处理）
            unawaited(_persistDriftThreshold(remoteDrift));
          }
          final d = _delegate;
          if (d != null) {
            final snap = d.snapshot();
            final expected = _targetPosition(m);
            final remotePlaying = m['playing'] == true;
            if (remotePlaying != snap.playing) {
              remotePlaying ? await d.syncResume() : await d.syncPause();
            }
            final drift = snap.position - expected;
            // 漂移修正策略（避免频繁 seek 导致音乐一卡一卡）：
            // 1. 阈值（默认 250ms，UI 可调 50-500）：低于此值听感无差异，不修正
            // 2. 冷却 3s：两次 seek 修正之间至少间隔 3 秒
            // 3. 连续 2 次超阈值才修正：避免单次网络抖动触发误修正
            final threshold = Duration(milliseconds: _driftThresholdMs);
            if (remotePlaying && drift.abs() > threshold) {
              _driftOverCount++;
              final now = DateTime.now();
              final cooldownPassed =
                  _lastDriftSeekAt == null ||
                  now.difference(_lastDriftSeekAt!) > _driftSeekCooldown;
              if (_driftOverCount >= 2 && cooldownPassed) {
                _log(
                  '漂移修正 ${drift.inMilliseconds}ms（连续 $_driftOverCount 次超阈值）',
                );
                await d.syncSeek(expected);
                _lastDriftSeekAt = now;
                _driftOverCount = 0;
              } else if (!cooldownPassed) {
                // 冷却中，跳过本次但保留计数（下次心跳若仍超阈值会再判）
              }
            } else {
              // 偏差在阈值内，重置连续计数
              if (_driftOverCount > 0) _driftOverCount = 0;
            }
          }
        }
        break;
      case 'bye':
        // 一对多：主控收到某被控 bye → 只拆该被控；被控收到主控 bye → 全断
        if (guest != null) {
          _handleGuestDisconnect(guest, '${guest.deviceName} 已断开同步');
        } else {
          _handleDisconnect('对方已断开同步');
        }
        break;
    }
  }

  /// 把消息里的 position + ts（发送方时钟）换算成本地目标进度
  Duration _targetPosition(Map<String, dynamic> m) {
    final pos = (m['position'] as num?)?.toDouble() ?? 0.0;
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    if (ts <= 0) return Duration(milliseconds: (pos * 1000).round());
    // 发送时刻换算到本地时钟，加上网络传输耗时
    final sendLocalMs = ts - _clockOffsetMs;
    final elapsed = DateTime.now().millisecondsSinceEpoch - sendLocalMs;
    final ms = (pos * 1000).round() + elapsed;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  // ---------- 主控对外通知（PlayerState 各钩子调用） ----------

  /// 主控换歌：广播完整歌曲元数据（被控自己解析 URL）
  void notifyPlay(Song song, String url, {bool playing = true}) {
    if (!isMaster) return;
    final pos = _delegate?.snapshot().position ?? Duration.zero;
    _send({
      'type': 'play',
      'url': url,
      'name': song.name,
      'artist': song.artistText,
      'cover': song.cover,
      'song': song.toJson(),
      'position': pos.inMilliseconds / 1000.0,
      'playing': playing,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 主控播放/暂停状态变化（统一入口：UI、通知栏、线控都会走到这）
  void notifyPlayingChanged(bool playing) {
    if (!isMaster) return;
    final snap = _delegate?.snapshot();
    _send({
      'type': playing ? 'resume' : 'pause',
      'position': (snap?.position.inMilliseconds ?? 0) / 1000.0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 主控拖动进度
  void notifySeek(Duration position) {
    if (!isMaster) return;
    _send({
      'type': 'seek',
      'position': position.inMilliseconds / 1000.0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 主控：被控刚加入时推送当前完整播放状态
  void _pushCurrentState() {
    final snap = _delegate?.snapshot();
    final song = snap?.song;
    if (song == null) return;
    _send({
      'type': 'play',
      'url': snap!.url,
      'name': song.name,
      'artist': song.artistText,
      'cover': song.cover,
      'song': song.toJson(),
      'position': snap.position.inMilliseconds / 1000.0,
      'playing': snap.playing,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 主控一对多：把当前完整播放状态推送给指定被控（中途加入也能对齐）
  void _pushCurrentStateToGuest(GuestConnection g) {
    if (!g.isSynced) return;
    final snap = _delegate?.snapshot();
    final song = snap?.song;
    if (song == null) return;
    _sendToGuest(g, {
      'type': 'play',
      'url': snap!.url,
      'name': song.name,
      'artist': song.artistText,
      'cover': song.cover,
      'song': song.toJson(),
      'position': snap.position.inMilliseconds / 1000.0,
      'playing': snap.playing,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 主控：定时进度心跳（与传输方式无关）。
  /// WebRTC 走 DataChannel（被控回 ack 保活）；HTTP 走 /command 即时推送，
  /// 被控据此持续修正播放态与漂移（偏差 >800ms 且冷却 3s 才 seek，不打断播放）。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    void emit() {
      if (!isMaster) return;
      final snap = _delegate?.snapshot();
      final song = snap?.song;
      _send({
        'type': 'heartbeat',
        'position': (snap?.position.inMilliseconds ?? 0) / 1000.0,
        'playing': snap?.playing ?? false,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'song': song?.toJson(),
        'url': snap?.url ?? '',
        'name': song?.name ?? '',
        // 主控下发漂移阈值，被控接收后同步更新（主控统一管控）
        'drift': _driftThresholdMs,
      });
    }

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => emit());
  }

  /// HTTP 兼容模式：构造当前播放状态（字段与 WebRTC play/heartbeat 消息一致）
  Map<String, dynamic> _buildStateJson() {
    final snap = _delegate?.snapshot();
    final song = snap?.song;
    return {
      'url': snap?.url ?? '',
      'name': song?.name ?? '',
      'artist': song?.artistText ?? '',
      'cover': song?.cover ?? '',
      'song': song?.toJson(),
      'position': (snap?.position.inMilliseconds ?? 0) / 1000.0,
      'playing': snap?.playing ?? false,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'deviceName': _deviceName,
    };
  }

  /// 看门狗：超时无消息判定断开（WebRTC 靠 ack/信令，HTTP 靠轮询）
  /// 一对多：主控模式遍历所有 guest，单台超时只移除该被控，不影响其他被控。
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      // 主控一对多：逐个 guest 检查，超时的单独断开
      if (_role == SyncRole.master) {
        if (_guests.isEmpty) return;
        final now = DateTime.now();
        // 拷贝一份避免遍历中修改原 Map
        final snapshot = _guests.values.toList();
        for (final g in snapshot) {
          if (!g.isSynced) continue;
          if (now.difference(g.lastMessageAt) > _watchdogTimeout) {
            _handleGuestDisconnect(
              g,
              g.transport == SyncTransport.http
                  ? '${g.deviceName} 长时间无响应，已断开'
                  : '${g.deviceName} 同步超时断开',
            );
          }
        }
        return;
      }
      // 被控：1:1 单值字段
      if (_status != SyncStatus.synced) return;
      // HTTP 模式：若正有一次轮询在途（_applyHttpState 异步执行中也算保活），
      // 跳过本次检查，避免换歌加载等长耗时操作被误判为断开。
      if (_transport == SyncTransport.http && _pollInFlight) return;
      if (DateTime.now().difference(_lastMessageAt) > _watchdogTimeout) {
        _handleDisconnect(
          _transport == SyncTransport.http ? 'HTTP 兼容模式长时间无响应，已断开' : '同步超时断开',
        );
      }
    });
  }

  // ================= 设备发现（mDNS） =================

  /// 浏览指定类型服务；resolved 事件里拿 host:port
  Future<void> _startDiscovery(String type) async {
    final d = BonsoirDiscovery(type: type, printLogs: false);
    await d.ready;
    _discovery = d;
    d.eventStream?.listen((event) {
      switch (event.type) {
        case BonsoirDiscoveryEventType.discoveryServiceFound:
          // found 只有名称，需要 resolve 拿 IP
          event.service?.resolve(d.serviceResolver);
          break;
        case BonsoirDiscoveryEventType.discoveryServiceResolved:
          final s = event.service;
          if (s is ResolvedBonsoirService && s.host != null) {
            final list = type == serviceTypeFollower ? _followers : _masters;
            _upsertDevice(
              list,
              NearbyDevice(
                name: _normalizeServiceName(s.name),
                host: s.host!,
                port: s.port,
                lastSeen: DateTime.now(),
              ),
            );
          }
          break;
        case BonsoirDiscoveryEventType.discoveryServiceLost:
          final name = _normalizeServiceName(event.service?.name ?? '');
          _removeDevice(
            type == serviceTypeFollower ? _followers : _masters,
            name,
          );
          break;
        default:
          break;
      }
    }, onError: (e) => _log('mDNS 浏览异常: $e'));
    await d.start();
  }

  void _upsertDevice(List<NearbyDevice> list, NearbyDevice device) {
    final i = list.indexWhere((e) => e.name == device.name);
    if (i >= 0) {
      device.lastSeen = list[i].lastSeen.isAfter(device.lastSeen)
          ? list[i].lastSeen
          : device.lastSeen;
      list[i] = device;
    } else {
      list.add(device);
      _log(
        identical(list, _masters)
            ? 'found host ${device.name} at ${device.host}:${device.port}'
            : 'found follower ${device.name} at ${device.host}:${device.port}',
      );
    }
    notifyListeners();
  }

  void _removeDevice(List<NearbyDevice> list, String name) {
    final before = list.length;
    list.removeWhere((e) => e.name == name);
    if (list.length != before) notifyListeners();
  }

  /// 心跳式重扫的等效实现：9s 没再见到就认为离线
  void _pruneStale(List<NearbyDevice> list) {
    final now = DateTime.now();
    final before = list.length;
    list.removeWhere((e) => now.difference(e.lastSeen) > _staleTimeout);
    if (list.length != before) notifyListeners();
  }

  /// mDNS 实例名可能被平台加了后缀/转义，做轻量清洗
  String _normalizeServiceName(String raw) {
    var name = raw.replaceAll(RegExp(r'\\.'), '.').trim();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    return name;
  }

  // ================= 建连超时 / 失败 / 清理 =================

  /// 15s 建连超时：未 open 则报错并回到等待状态（不再无限转圈）
  void _armConnectTimeout() {
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (_status == SyncStatus.connecting) {
        _failConnecting(
          '连接超时（15s）。请检查位置权限是否授予、'
          '两台手机是否在同一 Wi-Fi、路由器是否开启 AP 隔离',
        );
      }
    });
  }

  /// 非建连态的错误提示（如手动输入 IP 格式不对）：只通知 UI 弹条，不动连接
  void _notifyError(String reason) {
    _log('提示: $reason');
    _lastDisconnectReason = reason;
    notifyListeners();
  }

  /// 建连失败统一出口：保留角色与发现列表，仅拆连接回 waiting，并给 UI 一条提示
  void _failConnecting(String reason) {
    if (_status != SyncStatus.connecting) return;
    // HTTP→WebRTC 手动切换失败：拆掉半截 PC，回到 HTTP 轮询，不断线
    if (_recoverToHttpOnFail &&
        _role == SyncRole.follower &&
        _masterHost.isNotEmpty) {
      _recoverToHttpOnFail = false;
      _log('切回 WebRTC 失败，恢复 HTTP 兼容模式：$reason');
      final host = _masterHost;
      final port = _masterPort;
      final name = _peerName;
      unawaited(() async {
        _switching = true;
        await _teardownConnection();
        _switching = false;
        await startHttpPolling(host, port, name);
      }());
      return;
    }
    // auto 模式 WebRTC 在 5s 判定前就硬失败：立即降级 HTTP，不直接报错
    if (_role == SyncRole.follower &&
        _connectMode == SyncConnectMode.auto &&
        (_fallbackTimer?.isActive ?? false) &&
        _masterHost.isNotEmpty) {
      _log('WebRTC 提前失败，立即降级 HTTP：$reason');
      _lastNotice = 'WebRTC 不可用，已切换兼容模式（HTTP）';
      final host = _masterHost;
      final port = _masterPort;
      final name = _peerName;
      unawaited(_downgradeToHttp(host, port, name));
      return;
    }
    _log('建连失败：$reason');
    _connectTimer?.cancel();
    _connectTimer = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _stopPolling();
    _lastDisconnectReason = reason;
    _peerName = '';
    _status = SyncStatus.waiting;
    unawaited(_teardownConnection());
    notifyListeners();
  }

  /// 仅拆掉当前 WebRTC 连接（不停服务器/广播/浏览，回到等待或浏览状态）
  Future<void> _teardownConnection() async {
    _connectTimer?.cancel();
    _connectTimer = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    _iceRestarting = false;
    _iceRestartAttempts = 0;
    _gatherRetryDone = false;
    _masterNeedRenegotiate = false;
    _peerRenegotiateHandled = false;
    _transport = null;
    // 注意：_masterHost/_masterPort 保留（HTTP 轮询与重切通道仍要用）
    try {
      _dc?.close();
    } catch (_) {}
    _dc = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _peerIceUrl = '';
    _clockOffsetMs = 0;
    _remoteDescSet = false;
    _pendingRemoteCandidates.clear();
    _localIceCount = 0;
  }

  /// 断开处理：双方各自恢复独立播放，UI 提示
  void _handleDisconnect(String reason) {
    if (_role == SyncRole.none) return;
    _log('断开: $reason');
    unawaited(stop());
    _lastDisconnectReason = reason;
    notifyListeners();
  }

  /// 主动离开（UI 断开按钮 / 退出同步页）
  /// 一对多：主控模式广播 bye 给所有被控（WebRTC 走 DataChannel，HTTP 走 /command），
  /// 被控收到 bye 后自行断开。
  Future<void> leave() async {
    if (_role == SyncRole.none) return;
    if (_role == SyncRole.follower && _transport == SyncTransport.http) {
      // 被控 HTTP 模式：POST /bye 通知主控
      try {
        await _postJson('http://$_masterHost:$_masterPort/bye', {
          'deviceName': _deviceName,
        });
      } catch (_) {}
    } else {
      // 主控广播 bye 给所有被控 / 被控 WebRTC bye 给主控
      _send({'type': 'bye'});
      // 给 bye 一点发送时间
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await stop();
    notifyListeners();
  }

  /// 主控一对多：仅断开指定被控（UI 单独断开按钮 / 看门狗超时 / 对方 bye 用）
  /// 广播 bye 给该被控后移除其连接资源，不影响其他被控。
  Future<void> disconnectGuest(GuestConnection g) async {
    if (_role != SyncRole.master) return;
    if (!_guests.containsKey(g.id)) return;
    _sendToGuest(g, {'type': 'bye'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await _teardownGuest(g);
    _guests.remove(g.id);
    // 没有被控了：主控回到等待状态（保留角色/发现/服务器）
    if (_guests.isEmpty && _status == SyncStatus.synced) {
      _status = SyncStatus.waiting;
    }
    notifyListeners();
  }

  /// 主控一对多：仅拆掉指定被控的 WebRTC 连接（不停服务器/广播/浏览）
  Future<void> _teardownGuest(GuestConnection g) async {
    g.iceRestartTimer?.cancel();
    g.iceRestartTimer = null;
    g.iceRestarting = false;
    g.iceRestartAttempts = 0;
    g.gatherRetryDone = false;
    g.masterNeedRenegotiate = false;
    g.peerRenegotiateHandled = false;
    g.expectingWebRtcOffer = false;
    g.transport = null;
    final pc = g.pc;
    if (pc != null) _guestByPc.remove(pc);
    try {
      g.dc?.close();
    } catch (_) {}
    g.dc = null;
    try {
      await g.pc?.close();
    } catch (_) {}
    g.pc = null;
    g.peerIceUrl = '';
    g.clockOffsetMs = 0;
    g.remoteDescSet = false;
    g.pendingRemoteCandidates.clear();
    g.localIceCount = 0;
    g.status = SyncStatus.idle;
  }

  /// 主控一对多：单台被控断开处理（看门狗超时 / 对方 bye / 连接失败）
  /// 移除该被控并提示 UI；其他被控不受影响。
  void _handleGuestDisconnect(GuestConnection g, String reason) {
    if (_role != SyncRole.master) return;
    if (!_guests.containsKey(g.id)) return;
    _log('被控断开: $reason (${g.deviceName})');
    unawaited(() async {
      await _teardownGuest(g);
      _guests.remove(g.id);
      // 没有被控了：主控回到等待状态
      if (_guests.isEmpty) {
        _status = SyncStatus.waiting;
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        _watchdogTimer?.cancel();
        _watchdogTimer = null;
      }
      _lastDisconnectReason = reason;
      notifyListeners();
    }());
  }

  /// 全量清理（停止广播/浏览/服务器/连接/定时器）
  /// 一对多：同时清理所有被控连接（guest 的 PC/DC/定时器）
  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    _iceRestarting = false;
    _iceRestartAttempts = 0;
    _gatherRetryDone = false;
    _masterNeedRenegotiate = false;
    _peerRenegotiateHandled = false;
    _transport = null;
    _pollInFlight = false;
    _pollFailCount = 0;
    _lastHttpSongKey = null;
    _applyingState = false;
    _clockBursting = false;
    _clockBurstBestRtt = 1 << 30;
    _switching = false;
    _recoverToHttpOnFail = false;
    // 先置 idle/none：下面 close() 触发的状态回调一律忽略，避免误判为断线重连
    _status = SyncStatus.idle;
    _role = SyncRole.none;
    // 一对多：清理所有被控连接（PC/DC/ICE 定时器）
    for (final g in _guests.values.toList()) {
      await _teardownGuest(g);
    }
    _guests.clear();
    _guestByPc.clear();
    try {
      _dc?.close();
    } catch (_) {}
    _dc = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _peerIceUrl = '';
    _masterHost = '';
    _remoteDescSet = false;
    _pendingRemoteCandidates.clear();
    _localIceCount = 0;
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _followers.clear();
    _masters.clear();
    _peerName = '';
    _clockOffsetMs = 0;
  }

  // ================= 工具 =================

  /// 发送 JSON 消息：
  /// - 主控一对多：遍历所有已同步被控，WebRTC 走各自 DataChannel，HTTP 走各自 /command
  /// - 被控 HTTP 模式 → POST 即时推送到主控（实际上被控只回 ack，走 /command 接收方向）
  /// - 被控 WebRTC → DataChannel；未就绪时静默丢弃
  void _send(Map<String, dynamic> msg) {
    if (_role == SyncRole.master) {
      // 一对多广播：遍历所有已同步被控
      for (final g in _guests.values.toList()) {
        if (!g.isSynced) continue;
        _sendToGuest(g, msg);
      }
      return;
    }
    // 被控：1:1 单值字段
    if (_status != SyncStatus.synced) return;
    final dc = _dc;
    if (dc == null) return;
    try {
      dc.send(RTCDataChannelMessage(jsonEncode(msg)));
    } catch (e) {
      _log('发送失败: $e');
    }
  }

  /// 主控一对多：把消息发送给指定被控（WebRTC 走 DataChannel，HTTP 走 /command）
  void _sendToGuest(GuestConnection g, Map<String, dynamic> msg) {
    if (!g.isSynced) return;
    if (g.transport == SyncTransport.http) {
      unawaited(_httpPushToGuest(g, msg));
      return;
    }
    final dc = g.dc;
    if (dc == null) return;
    try {
      dc.send(RTCDataChannelMessage(jsonEncode(msg)));
    } catch (e) {
      _log('发送失败 (${g.deviceName}): $e');
    }
  }

  /// 设备名：型号为主（如 "2210132C"），持久化；异常时随机后缀兜底
  Future<void> _initDeviceName() async {
    if (_deviceName.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('sync_device_name');
    if (saved != null && saved.isNotEmpty) {
      _deviceName = saved;
      return;
    }
    String model = '';
    try {
      final info = await DeviceInfoPlugin().deviceInfo;
      model = (info.data['model'] ?? '').toString().trim();
    } catch (_) {}
    final suffix = DateTime.now().millisecondsSinceEpoch
        .remainder(10000)
        .toString();
    _deviceName = model.isNotEmpty ? '$model-$suffix' : '液态音乐-$suffix';
    try {
      await prefs.setString('sync_device_name', _deviceName);
    } catch (_) {}
  }

  /// 本机局域网 IPv4（信令互推地址用）
  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254')) {
            return a.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<Map<String, dynamic>?> _postJson(
    String url,
    Map<String, dynamic> body,
  ) async {
    try {
      final r = await http
          .post(
            Uri.parse(url),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      final preview = r.body.length > 80 ? r.body.substring(0, 80) : r.body;
      _log('POST $url -> status=${r.statusCode} body=$preview');
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      _log('POST $url 失败: $e');
      return null;
    }
  }

  Future<void> _replyJson(
    HttpRequest req,
    Map<String, dynamic> body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}
