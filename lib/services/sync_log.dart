/// 多设备同步日志全局缓冲（屏幕内实时查看 [SYNC] 日志，排查建连问题用）
library;

import 'package:flutter/foundation.dart';

class SyncLog extends ChangeNotifier {
  SyncLog._();
  static final SyncLog instance = SyncLog._();

  static const int maxLines = 500;

  final List<String> lines = [];

  void log(String msg) {
    final t = DateTime.now().toString().substring(11, 19); // HH:mm:ss
    lines.add('$t $msg');
    if (lines.length > maxLines) lines.removeRange(0, lines.length - maxLines);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  /// 错误行：异常/失败关键字（含中文「失败/错误」），日志页据此标红
  static bool isErrorLine(String line) {
    final lower = line.toLowerCase();
    return lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('exception') ||
        line.contains('失败') ||
        line.contains('错误');
  }
}
