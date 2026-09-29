/// 榜单页：紧凑列表，左侧小方图 + 榜单名 + 描述，点击进歌单详情
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../state/ui_settings.dart';
import '../config.dart';
import 'playlist_detail_page.dart';

class ChartsPage extends StatefulWidget {
  ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 80, 20, 4),
            child: Text(
              '排行榜',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '云音乐官方榜单，每日更新',
              style: TextStyle(
                color: fgPrimary.withOpacity(0.45),
                fontSize: 12,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final chart = AppConfig.kCharts[i];
                return _ChartRow(chart: chart);
              },
              childCount: AppConfig.kCharts.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChartRow extends StatelessWidget {
  final BoardChart chart;
  const _ChartRow({required this.chart});

  @override
  Widget build(BuildContext context) {
    final colors = _chartColors(chart.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.of(context).push(
              PageRouteBuilder(
                opaque: false,
                transitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, anim, __) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                  child: PlaylistDetailPage(
                    id: chart.id,
                    title: chart.name,
                  ),
                ),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Row(
              children: [
                // 小方图：渐变色 + 首字（缩小版，不再是大字）
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      chart.name.characters.first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chart.name,
                        style: TextStyle(
                          color: fgPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${chart.name} · 每日更新',
                        style: TextStyle(
                          color: fgPrimary.withOpacity(0.45),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: fgPrimary.withOpacity(0.4), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 每个榜单一个渐变色（从原代码提取）
List<Color> _chartColors(String name) {
  if (name.contains('热歌')) return [const Color(0xFF4A90D9), const Color(0xFF6BB6E8)];
  if (name.contains('飙升')) return [const Color(0xFF3B5BDB), const Color(0xFF4C6EF5)];
  if (name.contains('新歌')) return [const Color(0xFFD48806), const Color(0xFFF59F00)];
  if (name.contains('原创')) return [const Color(0xFFC92A2A), const Color(0xFFE03131)];
  if (name.contains('说唱')) return [const Color(0xFF7048E8), const Color(0xFF845EF7)];
  if (name.contains('电音')) return [const Color(0xFF1971C2), const Color(0xFF1C7ED6)];
  if (name.contains('抖音')) return [const Color(0xFFE64980), const Color(0xFFF06595)];
  if (name.contains('民谣')) return [const Color(0xFF2F9E44), const Color(0xFF40C057)];
  return [const Color(0xFF495057), const Color(0xFF868E96)];
}
