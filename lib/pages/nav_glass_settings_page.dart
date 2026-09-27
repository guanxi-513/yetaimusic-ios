/// 导航栏液态玻璃参数自定义页
library;

import 'package:flutter/material.dart';
import '../state/ui_settings.dart';

class NavGlassSettingsPage extends StatelessWidget {
  const NavGlassSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgBase,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: fgPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('导航栏玻璃参数', style: TextStyle(color: fgPrimary)),
        actions: [
          TextButton(
            onPressed: () async {
              await resetNavGlassSettings();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已重置')),
                );
              }
            },
            child: const Text('重置'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('轨道玻璃'),
          _slider('厚度', navGlassThickness, 5, 60, 0.1, 'nav_glass_thickness'),
          _slider('模糊', navGlassBlur, 0, 20, 0.5, 'nav_glass_blur'),
          _slider('折射率', navGlassRefractiveIndex, 1.0, 2.5, 0.05, 'nav_glass_ri'),
          _slider('边缘高光', navGlassFresnel, 0, 5, 0.1, 'nav_glass_fresnel'),
          _slider('光强', navGlassLight, 0, 2, 0.1, 'nav_glass_light'),
          _slider('辉光', navGlassGlow, 0, 2, 0.05, 'nav_glass_glow'),
          _slider('背景不透明度', navGlassBgAlpha, 0, 0.5, 0.01, 'nav_glass_bg_alpha'),
          const SizedBox(height: 16),
          _section('选中胶囊'),
          _slider('折射率', navIndicatorRefractiveIndex, 1.0, 2.5, 0.05, 'nav_ind_ri'),
          _slider('边缘高光', navIndicatorFresnel, 0, 5, 0.1, 'nav_ind_fresnel'),
          _slider('光强', navIndicatorLight, 0, 2, 0.1, 'nav_ind_light'),
          _slider('辉光', navIndicatorGlow, 0, 2, 0.05, 'nav_ind_glow'),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Text(title, style: TextStyle(color: fgSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _slider(String label, ValueNotifier<double> notifier, double min, double max, double divisions, String key) {
    return ValueListenableBuilder<double>(
      valueListenable: notifier,
      builder: (_, v, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: TextStyle(color: fgPrimary, fontSize: 14)),
                Text(v.toStringAsFixed(2), style: TextStyle(color: fgSecondary, fontSize: 12)),
              ],
            ),
          ),
          Slider(
            value: v,
            min: min,
            max: max,
            onChanged: (val) {
              notifier.value = val;
              saveNavGlassParam(key, val);
            },
          ),
        ],
      ),
    );
  }
}
