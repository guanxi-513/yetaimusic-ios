/// UI 高度自定义（三级页）：主题预设 + 独立开关，自由组合视觉风格
/// 与 [TransitionSettingsPage] 同级，从设置抽屉「自定义界面」分区 push 进入。
/// 设计原则：不新增预设枚举，复用现有 UiStyle 四档；独立开关复用 songCardBlur/
/// transitionHero/transitionPage，仅新增 globalBlur/secondaryTransparent/pageBlur/closeAnimation。
library;

import 'package:flutter/material.dart';

import '../state/ui_settings.dart';

class UiCustomizePage extends StatelessWidget {
  const UiCustomizePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: uiStyle,
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
              'UI 高度自定义',
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Text(
                    '先选主题预设作为基底，再用下方独立开关自由组合。预设不会覆盖你已手动调整的开关，仅作为快速起点。',
                    style: TextStyle(
                      color: fgTertiary,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // ---- 主题预设 ----
                _SectionLabel('主题预设'),
                const SizedBox(height: 6),
                ValueListenableBuilder<UiStyle>(
                  valueListenable: uiStyle,
                  builder: (_, style, __) => _buildCard(
                    children: [
                      _PresetOption(
                        title: '液态玻璃',
                        desc: '封面模糊 + 实时毛玻璃 + 青绿光效',
                        selected: style == UiStyle.glass,
                        onTap: () => setUiStyle(UiStyle.glass),
                      ),
                      Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                      _PresetOption(
                        title: '极简暗色',
                        desc: '纯黑背景 + 扁平卡片，无模糊无光效',
                        selected: style == UiStyle.plain,
                        onTap: () => setUiStyle(UiStyle.plain),
                      ),
                      Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                      _PresetOption(
                        title: '暗色透明',
                        desc: '封面模糊 + 详情页透明透出下层',
                        selected: style == UiStyle.transparent,
                        onTap: () => setUiStyle(UiStyle.transparent),
                      ),
                      Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                      _PresetOption(
                        title: '极简白色',
                        desc: '暖白背景 + 黑字，无玻璃无模糊',
                        selected: style == UiStyle.white,
                        onTap: () => setUiStyle(UiStyle.white),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // ---- 背景设置 ----
                _SectionLabel('背景设置'),
                const SizedBox(height: 6),
                _buildCard(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: globalBlur,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '全局背景模糊',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '底部播放栏毛玻璃层；关闭后播放栏为实色',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setGlobalBlur,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: secondaryTransparent,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '二级页面背景透明',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '打开后歌单详情页透出下层（任何主题预设生效）；关闭后按预设铺实色背景',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setSecondaryTransparent,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: songCardBlur,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '歌单列表卡片背景模糊',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '开启后歌曲卡片带背景模糊；关闭可提升列表滚动性能',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setSongCardBlur,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: pageBlur,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '播放页背景模糊',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '播放页封面高斯模糊层；关闭后为清晰封面',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setPageBlur,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // ---- 播放页背景色（独立于主题预设，强制覆盖） ----
                _SectionLabel('播放页背景色'),
                const SizedBox(height: 6),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    playerBgStyle,
                    customPlayerBgColor,
                  ]),
                  builder: (_, __) {
                    final bg = playerBgStyle.value;
                    return _buildCard(
                      children: [
                        _BgStyleOption(
                          title: '跟随预设（封面）',
                          desc: '玻璃档封面模糊，极简档纯色',
                          selected: bg == PlayerBgStyle.cover,
                          onTap: () => setPlayerBgStyle(PlayerBgStyle.cover),
                        ),
                        Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                        _BgStyleOption(
                          title: '暖白',
                          desc: '纯色暖白背景',
                          swatch: const Color(0xFFF9FAF4),
                          selected: bg == PlayerBgStyle.white,
                          onTap: () => setPlayerBgStyle(PlayerBgStyle.white),
                        ),
                        Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                        _BgStyleOption(
                          title: '纯黑',
                          desc: '纯色纯黑背景',
                          swatch: const Color(0xFF000000),
                          selected: bg == PlayerBgStyle.black,
                          onTap: () => setPlayerBgStyle(PlayerBgStyle.black),
                        ),
                        Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                        _BgStyleOption(
                          title: '透明',
                          desc: '播放页透出下层首页',
                          selected: bg == PlayerBgStyle.transparent,
                          onTap: () =>
                              setPlayerBgStyle(PlayerBgStyle.transparent),
                        ),
                        Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                        _BgStyleOption(
                          title: '自定义颜色',
                          desc: '从下方选色器挑选',
                          swatch: Color(customPlayerBgColor.value),
                          selected: bg == PlayerBgStyle.custom,
                          onTap: () => setPlayerBgStyle(PlayerBgStyle.custom),
                        ),
                      ],
                    );
                  },
                ),
                // 自定义颜色选色器（选「自定义颜色」时展开）
                ValueListenableBuilder<PlayerBgStyle>(
                  valueListenable: playerBgStyle,
                  builder: (_, bg, __) => AnimatedCrossFade(
                    firstChild: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _buildColorPicker(),
                    ),
                    secondChild: const SizedBox.shrink(),
                    crossFadeState: bg == PlayerBgStyle.custom
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    duration: const Duration(milliseconds: 220),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Text(
                    '该选项独立于主题预设；透明播放页会透出首页内容，自定义颜色建议选深色以保证歌词可读。',
                    style: TextStyle(
                      color: fgTertiary,
                      fontSize: 11,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // ---- 动画设置 ----
                _SectionLabel('动画设置'),
                const SizedBox(height: 6),
                _buildCard(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: transitionHero,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '歌单打开动画',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '点开歌单时，封面从列表飞入详情页头部',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setTransitionHero,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: transitionPage,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '模糊过渡动画',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '打开详情页整页上滑淡入，背景模糊渐显',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setTransitionPage,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: closeAnimation,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '关闭动画丝滑过渡',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '返回时的过渡动画；关闭后立即切回（预留接线位）',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setCloseAnimation,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  /// 内置选色器：预设色板 + RGB 三通道滑杆（无第三方依赖）
  Widget _buildColorPicker() {
    const swatches = <int>[
      0xFF000000,
      0xFF1A1C20,
      0xFF2D2D30,
      0xFF1DB954,
      0xFF1E88E5,
      0xFF8E24AA,
      0xFFE53935,
      0xFFFB8C00,
      0xFFEC407A,
      0xFFF5F5F0,
      0xFFFFFFFF,
    ];
    return _buildCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<int>(
            valueListenable: customPlayerBgColor,
            builder: (_, value, __) {
              final c = Color(value);
              void update({int? r, int? g, int? b}) {
                setCustomPlayerBgColor(
                  Color.fromARGB(
                    255,
                    r ?? c.red,
                    g ?? c.green,
                    b ?? c.blue,
                  ).value,
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final s in swatches)
                        GestureDetector(
                          onTap: () => setCustomPlayerBgColor(s),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Color(s),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: value == s
                                    ? const Color(0xFF1DB954)
                                    : fgPrimary.withOpacity(0.3),
                                width: value == s ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _channelSlider(
                    label: 'R',
                    value: c.red,
                    channelColor: const Color(0xFFE53935),
                    onChanged: (v) => update(r: v),
                  ),
                  _channelSlider(
                    label: 'G',
                    value: c.green,
                    channelColor: const Color(0xFF43A047),
                    onChanged: (v) => update(g: v),
                  ),
                  _channelSlider(
                    label: 'B',
                    value: c.blue,
                    channelColor: const Color(0xFF1E88E5),
                    onChanged: (v) => update(b: v),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _channelSlider({
    required String label,
    required int value,
    required Color channelColor,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Text(
            label,
            style: TextStyle(color: channelColor, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 255,
              divisions: 255,
              activeColor: channelColor,
              inactiveColor: fgPrimary.withOpacity(0.12),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(
          width: 30,
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: TextStyle(color: fgTertiary, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

/// 播放页背景风格选项行：选中圆点 + 标题 + 描述（可选色板预览）
class _BgStyleOption extends StatelessWidget {
  const _BgStyleOption({
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
    this.swatch,
  });

  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? const Color(0xFF1DB954) : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF1DB954)
                      : fgPrimary.withOpacity(0.35),
                  width: 1.5,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fgPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      color: fgTertiary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            if (swatch != null) ...[
              const SizedBox(width: 10),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: fgPrimary.withOpacity(0.3),
                    width: 1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分区小标题
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: TextStyle(
          color: fgSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 主题预设选项行（单选样式：选中圆点 + 标题 + 描述）
class _PresetOption extends StatelessWidget {
  const _PresetOption({
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 选中圆点
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? const Color(0xFF1DB954) : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF1DB954)
                      : fgPrimary.withOpacity(0.35),
                  width: 1.5,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fgPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      color: fgTertiary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
