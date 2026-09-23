/// 锁屏歌词日志页：实时显示 LockLog 缓冲的全部日志（模式同同步日志页）
///
/// 深色终端风格，最新日志在最上面；含 error/failed/失败/错误 的行标红。
library;

import 'package:flutter/material.dart';

import '../services/lock_log.dart';

class LockLogPage extends StatefulWidget {
  const LockLogPage({super.key});

  @override
  State<LockLogPage> createState() => _LockLogPageState();
}

class _LockLogPageState extends State<LockLogPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF11111B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11111B),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Color(0xFFBAC2DE), size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          '锁屏歌词日志',
          style: TextStyle(
            color: Color(0xFFBAC2DE),
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: LockLog.instance.clear,
            icon: const Icon(Icons.delete_outline,
                color: Color(0xFFBAC2DE), size: 18),
            label: const Text(
              '清空',
              style: TextStyle(color: Color(0xFFBAC2DE), fontSize: 13),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: LockLog.instance,
          builder: (context, _) {
            final lines = LockLog.instance.lines;
            if (lines.isEmpty) {
              return const Center(
                child: Text(
                  '暂无日志\n锁屏点亮屏幕或点击「立即测试」后这里会实时滚动',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF585B70),
                    fontSize: 12,
                    height: 1.8,
                  ),
                ),
              );
            }
            // 倒序：最新在最上面
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final line = lines[lines.length - 1 - i];
                final isError = LockLog.isErrorLine(line);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.4,
                      color: isError
                          ? const Color(0xFFF38BA8)
                          : const Color(0xFFBAC2DE),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
