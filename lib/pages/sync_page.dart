/// 多设备同步页：主控（创建同步）/ 被控（加入同步）
///
/// 同一 Wi-Fi 下：主控点歌/切歌/暂停/拖动，被控实时跟播同一首歌同进度。
/// 局域网 mDNS 发现 + WebRTC DataChannel 控制信号，音频流各设备自取。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/sync_service.dart';
import '../state/ui_settings.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  /// 连接中防抖（避免重复点击同一设备）
  String? _connectingTo;

  /// 手动输入主控 IP
  final TextEditingController _ipController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 断开原因 → SnackBar 提示（同步服务是全局单例，这里只负责展示）
    SyncService.instance.addListener(_onSyncChanged);
  }

  @override
  void dispose() {
    _ipController.dispose();
    SyncService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    final reason = SyncService.instance.takeDisconnectReason();
    final notice = SyncService.instance.takeNotice();
    if (!mounted) return;
    if (reason != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(_infoBar(reason));
    } else if (notice != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(_infoBar(notice));
    }
    if (_connectingTo != null && SyncService.instance.isSynced) {
      _connectingTo = null;
    }
    setState(() {});
  }

  /// 提示条：白底黑字悬浮条（深色主题下默认黑条看不清内容）
  SnackBar _infoBar(String text) => SnackBar(
    content: Text(
      text,
      style: const TextStyle(color: Colors.black, fontSize: 13),
    ),
    backgroundColor: Colors.white,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 5),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([uiStyle, SyncService.instance]),
      builder: (context, _) {
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
              '多设备同步',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: SafeArea(top: false, child: _buildBody()),
        );
      },
    );
  }

  // ---------- 主体（按角色/状态分发） ----------

  Widget _buildBody() {
    final sync = SyncService.instance;
    // 已同步：任一角色都显示连接状态 + 断开
    if (sync.isSynced) return _buildSyncedView();
    // 连接中
    if (sync.status == SyncStatus.connecting) {
      return _buildConnectingView();
    }
    // 角色选择
    if (sync.role == SyncRole.none) return _buildRolePicker();
    // 主控等待 / 被控扫描
    return sync.role == SyncRole.master
        ? _buildMasterWaiting()
        : _buildFollowerBrowsing();
  }

  /// 角色选择：创建同步（主控）/ 加入同步（被控）
  Widget _buildRolePicker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        _hint(
          '两台设备连同一 Wi-Fi，一台当主控（点歌/切歌/暂停/拖动），'
          '另一台实时跟播同一首歌、同进度。音频仍由各设备自己加载。',
        ),
        const SizedBox(height: 12),
        _buildConnectModeCard(),
        const SizedBox(height: 12),
        _bigCard(
          icon: Icons.phonelink_ring,
          title: '创建同步',
          subtitle: '本机作为主控，控制另一台设备播放',
          onTap: () async {
            if (!await _ensureLocation()) return;
            await SyncService.instance.startHosting();
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 12),
        _bigCard(
          icon: Icons.speaker_group,
          title: '加入同步',
          subtitle: '本机作为被控，跟随主控设备播放',
          onTap: () async {
            if (!await _ensureLocation()) return;
            await SyncService.instance.startBrowsing();
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 20),
        _hint(
          '· 仅支持同一 Wi-Fi（局域网发现）\n'
          '· 一台手机开热点也能用：创建同步后页面会显示本机 IP，'
          '另一台手动输入即可\n'
          '· 两台设备出声约有 200-500ms 差，适合一起听，'
          '不适合严格立体声同步\n'
          '· 后台时间过长可能被系统断开，回到本页重新加入即可',
        ),
      ],
    );
  }

  /// 主控等待页：本机设备名 + 已接入被控 + 附近可邀请被控列表
  /// 一对多：已接入被控置顶显示（可单独断开），下方继续列可邀请设备
  Widget _buildMasterWaiting() {
    final sync = SyncService.instance;
    final followers = sync.followers;
    final guests = sync.guests;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        _hint('本机设备名：${sync.deviceName}　·　正在发现附近设备…'),
        const SizedBox(height: 12),
        _buildLocalIpCard(sync.localIPv4s),
        // 已接入被控置顶（一对多）
        if (guests.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildGuestList(),
        ],
        const SizedBox(height: 12),
        _buildCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                guests.isEmpty ? '附近被控设备' : '可邀请更多被控',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (followers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fgSecondary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请让另一台设备打开「多设备同步 → 加入同步」',
                      style: TextStyle(color: fgTertiary, fontSize: 12),
                    ),
                  ],
                ),
              )
            else
              for (final d in followers)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: Icon(Icons.speaker, color: fgSecondary),
                  title: Text(
                    d.name,
                    style: TextStyle(color: fgPrimary, fontSize: 14),
                  ),
                  subtitle: Text(
                    '${d.host}:${d.port}',
                    style: TextStyle(color: fgTertiary, fontSize: 11),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: fgPrimary.withOpacity(0.6),
                  ),
                  onTap: () => _invite(d),
                ),
          ],
        ),
        const SizedBox(height: 12),
        _stopButton(guests.isEmpty ? '停止同步' : '断开所有被控'),
      ],
    );
  }

  /// 被控浏览页：附近主控列表（点击加入）
  Widget _buildFollowerBrowsing() {
    final sync = SyncService.instance;
    final masters = sync.masters;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        _hint('正在扫描附近的主控设备…'),
        const SizedBox(height: 12),
        _buildConnectModeCard(),
        const SizedBox(height: 12),
        _buildCard(
          children: [
            if (masters.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fgSecondary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请让主控设备打开「多设备同步 → 创建同步」',
                      style: TextStyle(color: fgTertiary, fontSize: 12),
                    ),
                  ],
                ),
              )
            else
              for (final d in masters)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: Icon(Icons.phonelink, color: fgSecondary),
                  title: Text(
                    d.name,
                    style: TextStyle(color: fgPrimary, fontSize: 14),
                  ),
                  subtitle: Text(
                    '${d.host}:${d.port}',
                    style: TextStyle(color: fgTertiary, fontSize: 11),
                  ),
                  trailing: _connectingTo == d.name
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: fgSecondary,
                          ),
                        )
                      : Icon(
                          Icons.chevron_right,
                          color: fgPrimary.withOpacity(0.6),
                        ),
                  onTap: () => _join(d),
                ),
          ],
        ),
        const SizedBox(height: 12),
        _buildManualIpCard(),
        const SizedBox(height: 12),
        _stopButton('退出扫描'),
      ],
    );
  }

  /// 连接中
  Widget _buildConnectingView() {
    final sync = SyncService.instance;
    final autoFallback = sync.connectMode == SyncConnectMode.auto;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: fgSecondary),
          const SizedBox(height: 16),
          Text(
            '正在连接 ${sync.peerName}…',
            style: TextStyle(color: fgPrimary, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            autoFallback
                ? '先尝试 WebRTC 点对点，连不上将自动切换兼容模式'
                : sync.connectMode == SyncConnectMode.httpOnly
                ? 'HTTP 兼容模式直连中…'
                : 'WebRTC 点对点连接中…',
            style: TextStyle(color: fgTertiary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 已同步：通道状态（点按可切通道）+ 断开按钮
  /// 一对多：主控模式列出所有已接入被控，每台可单独断开；被控模式保持原样
  Widget _buildSyncedView() {
    final sync = SyncService.instance;
    final isMaster = sync.role == SyncRole.master;
    // 被控模式：用单值通道徽章
    final isHttp = sync.transport == SyncTransport.http;
    final channelColor = isHttp
        ? const Color(0xFFF5A623)
        : const Color(0xFF1DB954);
    final canSwitch = sync.role == SyncRole.follower;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Column(
            children: [
              Icon(
                isMaster
                    ? Icons.speaker_group
                    : (isHttp ? Icons.autorenew : Icons.link),
                color: channelColor,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                isMaster ? '同步中（主控）' : '同步中：${sync.peerName}',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              if (!isMaster) _channelBadge(isHttp, channelColor, canSwitch),
              if (!isMaster) const SizedBox(height: 10),
              // 设备数徽章：主控显示被控数，被控显示 1
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: channelColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isMaster
                      ? '已连接 ${sync.syncedGuestCount} 台被控'
                      : (sync.isSynced ? '已连接 1 台设备' : '未连接设备'),
                  style: TextStyle(
                    color: channelColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isMaster
                    ? '本机（${sync.deviceName}）为主控，播放操作会实时同步给所有被控'
                    : '本机为主控端（${sync.peerName}）的跟播设备，由对方控制播放',
                textAlign: TextAlign.center,
                style: TextStyle(color: fgTertiary, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        // 主控一对多：列出所有被控，每台可单独断开 + 邀请更多
        if (isMaster) ...[
          const SizedBox(height: 16),
          _buildGuestList(),
          const SizedBox(height: 16),
          _buildInviteMoreCard(),
        ],
        const SizedBox(height: 16),
        _buildDriftThresholdCard(),
        const SizedBox(height: 16),
        _stopButton('断开同步'),
      ],
    );
  }

  /// 主控已同步视图：邀请更多被控（一对多，可继续邀请）
  Widget _buildInviteMoreCard() {
    final sync = SyncService.instance;
    final followers = sync.followers;
    // 过滤掉已接入的被控（按 host 去重）
    final guestHosts = sync.guests.map((g) => g.host).toSet();
    final available = followers
        .where((d) => !guestHosts.contains(d.host))
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              available.isEmpty ? '附近已无可邀请被控' : '邀请更多被控',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (available.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                '让另一台设备打开「多设备同步 → 加入同步」即可加入',
                style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.5),
              ),
            )
          else
            for (final d in available)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(Icons.speaker, color: fgSecondary),
                title: Text(
                  d.name,
                  style: TextStyle(color: fgPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  '${d.host}:${d.port}',
                  style: TextStyle(color: fgTertiary, fontSize: 11),
                ),
                trailing: Icon(Icons.add, color: fgPrimary.withOpacity(0.6)),
                onTap: () => _invite(d),
              ),
        ],
      ),
    );
  }

  /// 主控已同步视图：被控设备列表（每台显示名字 + 通道徽章 + 单独断开按钮）
  Widget _buildGuestList() {
    final sync = SyncService.instance;
    final guests = sync.guests;
    if (guests.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              '已接入被控',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final g in guests)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(Icons.speaker, color: fgSecondary, size: 22),
              title: Text(
                g.deviceName,
                style: TextStyle(color: fgPrimary, fontSize: 14),
              ),
              subtitle: Text(
                '${g.host}:${g.port}'
                '${g.transport == SyncTransport.http ? ' · HTTP' : ' · WebRTC'}',
                style: TextStyle(color: fgTertiary, fontSize: 11),
              ),
              trailing: IconButton(
                tooltip: '断开该被控',
                icon: Icon(Icons.link_off, color: fgSecondary, size: 20),
                onPressed: () async {
                  await sync.disconnectGuest(g);
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 漂移修正阈值调节卡片：滑块 50-500ms，默认 250ms。
  /// 主控端拖动 → 本地立即生效 + 下次心跳自动下发给被控。
  /// 被控端拖动 → 仅本地改（实际阈值由主控心跳覆盖）。
  /// 用 AnimatedBuilder 监听 SyncService，阈值变化时 UI 实时刷新。
  Widget _buildDriftThresholdCard() {
    final sync = SyncService.instance;
    final isMaster = sync.role == SyncRole.master;
    // 已连接的被控：阈值由主控心跳统一下发（WebRTC 5s / HTTP 500ms 同步一次），
    // 本地滑杆锁定，避免"两边各调各的"造成困惑
    final followerLocked =
        !isMaster && sync.role == SyncRole.follower && sync.isSynced;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final ms = sync.driftSeekThresholdMs;
        final isDefault = ms == SyncService.kDefaultDriftThresholdMs;
        final accent = isDefault
            ? const Color(0xFF1DB954)
            : const Color(0xFFF5A623);
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tune, color: fgPrimary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '漂移修正阈值',
                    style: TextStyle(
                      color: fgPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isMaster) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1DB954).withOpacity(0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF1DB954).withOpacity(0.5),
                        ),
                      ),
                      child: const Text(
                        '主控',
                        style: TextStyle(
                          color: Color(0xFF1DB954),
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  if (followerLocked) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5).withOpacity(0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF1E88E5).withOpacity(0.5),
                        ),
                      ),
                      child: const Text(
                        '跟随主控',
                        style: TextStyle(
                          color: Color(0xFF1E88E5),
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: accent.withOpacity(0.5)),
                    ),
                    child: Text(
                      '$ms ms',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                isMaster
                    ? '进度偏差超过此值才 seek 修正。主控调整会通过心跳下发给被控统一生效。'
                          '${isDefault ? "推荐 250ms：听感无差异且不易卡顿。" : "低于 250ms 可能频繁 seek 导致卡顿。"}'
                    : followerLocked
                    ? '当前阈值由主控统一下发（主控端调整后自动同步到本机），被控端不单独调整。'
                    : '进度偏差超过此值才 seek 修正。连接主控后将以主控下发的阈值为准。'
                          '${isDefault ? "推荐 250ms：听感无差异且不易卡顿。" : "低于 250ms 可能频繁 seek 导致卡顿。"}',
                style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.5),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: accent,
                  inactiveTrackColor: fgPrimary.withOpacity(0.1),
                  thumbColor: accent,
                  overlayColor: accent.withOpacity(0.2),
                  trackHeight: 4,
                  showValueIndicator: ShowValueIndicator.always,
                ),
                child: Slider(
                  min: 50,
                  max: 500,
                  divisions: 9, // 50, 100, 150, ..., 500
                  value: ms.toDouble(),
                  label: '$ms ms',
                  // 主控端（或未连接时）可拖动；已连接的被控锁定——
                  // 阈值由主控统一下发，本地调整只会被覆盖，徒增困惑
                  onChanged: followerLocked
                      ? null
                      : (v) async {
                          await sync.setDriftThresholdMs(v.round());
                        },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '50ms',
                    style: TextStyle(color: fgTertiary, fontSize: 10),
                  ),
                  Text(
                    isDefault ? '← 250ms 推荐' : '推荐 250ms',
                    style: TextStyle(
                      color: isDefault ? accent : fgTertiary,
                      fontSize: 10,
                      fontWeight: isDefault ? FontWeight.w600 : null,
                    ),
                  ),
                  Text(
                    '500ms',
                    style: TextStyle(color: fgTertiary, fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// 通道徽章：绿=WebRTC / 黄=HTTP；被控端点按弹切换菜单
  Widget _channelBadge(bool isHttp, Color color, bool canSwitch) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isHttp ? Icons.autorenew : Icons.link, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            isHttp ? 'HTTP 同步中（兼容模式）' : 'WebRTC 同步中',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (canSwitch) ...[
            const SizedBox(width: 4),
            Icon(Icons.swap_horiz, size: 14, color: color),
          ],
        ],
      ),
    );
    if (!canSwitch) return badge;
    return GestureDetector(onTap: _showChannelSwitch, child: badge);
  }

  /// 被控端：选择切换通道
  Future<void> _showChannelSwitch() async {
    final sync = SyncService.instance;
    final isHttp = sync.transport == SyncTransport.http;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              '切换同步通道',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(
                Icons.link,
                color: isHttp ? fgTertiary : const Color(0xFF1DB954),
              ),
              title: Text('WebRTC 点对点', style: TextStyle(color: fgPrimary)),
              subtitle: Text(
                '低延迟，普通 Wi-Fi 推荐',
                style: TextStyle(color: fgTertiary, fontSize: 12),
              ),
              trailing: isHttp
                  ? null
                  : Icon(Icons.check, color: const Color(0xFF1DB954)),
              onTap: () async {
                Navigator.pop(ctx);
                await sync.followerSwitchTransport(SyncTransport.webrtc);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.autorenew,
                color: isHttp ? const Color(0xFFF5A623) : fgTertiary,
              ),
              title: Text('HTTP 长轮询（兼容模式）', style: TextStyle(color: fgPrimary)),
              subtitle: Text(
                '热点 / AP 隔离 / 模拟器连不上 WebRTC 时使用',
                style: TextStyle(color: fgTertiary, fontSize: 12),
              ),
              trailing: isHttp
                  ? const Icon(Icons.check, color: Color(0xFFF5A623))
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                await sync.followerSwitchTransport(SyncTransport.http);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 连接方式选择卡（自动 / WebRTC / HTTP 兼容），持久化即时生效
  Widget _buildConnectModeCard() {
    final sync = SyncService.instance;
    final mode = sync.connectMode;
    const green = Color(0xFF1DB954);
    const yellow = Color(0xFFF5A623);
    final items = <(SyncConnectMode, String, String, Color)>[
      (SyncConnectMode.auto, '自动', '推荐', green),
      (SyncConnectMode.webrtc, 'WebRTC', '点对点', fgSecondary),
      (SyncConnectMode.httpOnly, 'HTTP', '兼容模式', yellow),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 17, color: fgSecondary),
              const SizedBox(width: 8),
              Text(
                '连接方式',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '自动：先试 WebRTC，5 秒连不上自动切 HTTP 兼容模式；'
            '模拟器可直接选 HTTP 并手动输入 IP。',
            style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final it in items) ...[
                Expanded(
                  child: _modeChip(
                    label: it.$2,
                    sub: it.$3,
                    color: it.$4,
                    selected: mode == it.$1,
                    onTap: () => sync.setConnectMode(it.$1),
                  ),
                ),
                if (it != items.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeChip({
    required String label,
    required String sub,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? color.withOpacity(0.16) : fgPrimary.withOpacity(0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : borderColor,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? color : fgPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(sub, style: TextStyle(color: fgTertiary, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 动作 ----------

  /// 运行时申请位置权限：Android 12+ 枚举 Wi-Fi 接口、收集局域网 IPv4
  /// host candidate 必需；未授予时 WebRTC 可能只有 IPv6，同步必失败。
  Future<bool> _ensureLocation() async {
    final status = await Permission.location.request();
    if (status.isGranted) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: fgPrimary.withOpacity(0.15)),
        ),
        title: Text('需要位置权限', style: TextStyle(color: fgPrimary)),
        content: Text(
          '多设备同步需要位置权限来枚举 Wi-Fi 局域网 IPv4 地址'
          '（Android 12+ 系统要求），否则无法与另一台手机建立连接。',
          style: TextStyle(color: fgSecondary, height: 1.6, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: fgSecondary)),
          ),
          if (status.isPermanentlyDenied)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                openAppSettings();
              },
              child: const Text('去系统设置开启'),
            )
          else
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                // 普通拒绝：再次触发系统授权弹窗；成功后用户重新点击按钮即可
                Permission.location.request();
              },
              child: const Text('重新授权'),
            ),
        ],
      ),
    );
    return false;
  }

  Future<void> _invite(NearbyDevice d) async {
    await SyncService.instance.inviteFollower(d);
    if (mounted) setState(() {});
  }

  Future<void> _join(NearbyDevice d) async {
    if (_connectingTo != null) return;
    setState(() => _connectingTo = d.name);
    final ok = await SyncService.instance.connectToMaster(d);
    if (!mounted) return;
    setState(() => _connectingTo = null);
    // 失败的具体原因（超时/ICE 失败/无响应）已由服务监听弹出白底提示条，
    // 这里不再用笼统文案覆盖
    if (!ok) return;
  }

  Future<void> _stop() async {
    await SyncService.instance.leave();
    if (mounted) setState(() {});
  }

  /// 被控：手动输入主控 IP 直连（绕过 mDNS，热点场景用）
  Future<void> _joinIp() async {
    if (_connectingTo != null) return;
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    setState(() => _connectingTo = '__manual__');
    final ok = await SyncService.instance.connectToMasterIp(ip);
    if (!mounted) return;
    setState(() => _connectingTo = null);
    if (ok) _ipController.clear();
  }

  // ---------- 热点场景组件 ----------

  /// 主控等待页：大字列出本机 IPv4，供被控手动输入
  Widget _buildLocalIpCard(List<String> ips) {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lan_outlined, size: 18, color: fgSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '本机 IP（被控可手动输入连接）',
                  style: TextStyle(
                    color: fgPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.refresh, size: 18, color: fgSecondary),
                onPressed: () async {
                  await SyncService.instance.refreshLocalIPv4s();
                },
              ),
            ],
          ),
          if (ips.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                '正在获取本机 IP…',
                style: TextStyle(color: fgTertiary, fontSize: 12),
              ),
            )
          else
            for (final ip in ips)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      ip,
                      style: TextStyle(
                        color: fgPrimary,
                        fontSize: 16,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ipTag(ip),
                  ],
                ),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 0),
            child: Text(
              '本机开热点时，IP 通常是 192.168.43.1；'
              '让另一台手机在下方「手动输入主控 IP」填入即可连接。',
              style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  /// IP 来源小标签：热点网段标绿，其余标局域网
  Widget _ipTag(String ip) {
    final hotspot = ip.startsWith('192.168.43.');
    final color = hotspot ? const Color(0xFF1DB954) : fgSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        hotspot ? '热点' : '局域网',
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }

  /// 被控浏览页：手动输入主控 IP + 连接（mDNS 发现不到/热点时的兜底入口）
  Widget _buildManualIpCard() {
    final busy = _connectingTo != null;
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering, size: 18, color: fgSecondary),
              const SizedBox(width: 8),
              Text(
                '手动输入主控 IP',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '开热点或列表里找不到主控时，输入主控页显示的 IP 直连（不依赖局域网发现）',
            style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _ipController,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(color: fgPrimary, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '例如 192.168.43.1',
                      hintStyle: TextStyle(color: fgTertiary, fontSize: 13),
                      filled: true,
                      fillColor: fgPrimary.withOpacity(0.06),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderColor),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF1DB954)),
                      ),
                    ),
                    onSubmitted: busy ? null : (_) => _joinIp(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 42,
                child: ElevatedButton.icon(
                  onPressed: busy ? null : _joinIp,
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.link, size: 16),
                  label: const Text('连接'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(
                      0xFF1DB954,
                    ).withOpacity(0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 通用组件 ----------

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      text,
      style: TextStyle(color: fgTertiary, fontSize: 12, height: 1.6),
    ),
  );

  Widget _buildCard({required List<Widget> children}) => Container(
    decoration: BoxDecoration(
      color: bgCard,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: borderColor, width: 1),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  Widget _bigCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Material(
    color: bgCard,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fgPrimary.withOpacity(0.12),
                border: Border.all(color: borderColor),
              ),
              child: Icon(icon, color: fgPrimary, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fgPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(color: fgTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: fgPrimary.withOpacity(0.6)),
          ],
        ),
      ),
    ),
  );

  Widget _stopButton(String label) => SizedBox(
    width: double.infinity,
    child: TextButton.icon(
      onPressed: _stop,
      icon: Icon(Icons.link_off, color: fgPrimary, size: 18),
      label: Text(label, style: TextStyle(color: fgPrimary)),
      style: TextButton.styleFrom(
        backgroundColor: fgPrimary.withOpacity(0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: fgPrimary.withOpacity(0.25)),
        ),
      ),
    ),
  );
}
