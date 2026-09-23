/// 锁屏歌词日志全局缓冲（排查锁屏不显示问题用，模式同 SyncLog）
library;

import 'package:flutter/foundation.dart';

class LockLog extends ChangeNotifier {
  LockLog._();
  static final LockLog instance = LockLog._();

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

  /// 错误行：异常/失败关键字，日志页据此标红
  static bool isErrorLine(String line) {
    final lower = line.toLowerCase();
    return lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('exception') ||
        line.contains('失败') ||
        line.contains('错误');
  }
}
