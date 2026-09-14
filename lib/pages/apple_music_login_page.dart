/// Apple Music 登录页（内嵌 WebView）
///
/// 流程：打开 music.apple.com → 用户完成 Apple ID 登录（含 2FA）→
/// 每 1.5s 从 WebView Cookie 中找 media-user-token 自动提交后端验证；
/// 也可点右上角"我已完成登录"手动提交（兜底）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../state/ui_settings.dart';

class AppleMusicLoginPage extends StatefulWidget {
  const AppleMusicLoginPage({super.key});

  @override
  State<AppleMusicLoginPage> createState() => _AppleMusicLoginPageState();
}

class _AppleMusicLoginPageState extends State<AppleMusicLoginPage> {
  static const String _appleUrl = 'https://music.apple.com';

  late final WebViewController _controller;
  late final WebViewCookieManager _cookieManager;
  Timer? _pollTimer;

  /// 是否已在提交（自动/手动互斥，防止重复请求）
  bool _submitting = false;

  /// 是否已成功（成功后停止轮询、拦截后续回调）
  bool _succeeded = false;

  @override
  void initState() {
    super.initState();
    _cookieManager = WebViewCookieManager();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(_appleUrl));
    // 打开页面后每 1.5s 检查一次 media-user-token
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _tryAutoSubmit();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// 自动检测：cookie 中出现非空 media-user-token 即提交
  Future<void> _tryAutoSubmit() async {
    if (_submitting || _succeeded || !mounted) return;
    final r = await _readToken();
    if (r.token != null && r.token!.isNotEmpty) {
      await _submit(r.token!);
    }
  }

  /// 要扫描的 Apple 相关域（登录态可能种在任一域）
  static const List<String> _appleDomains = [
    'https://music.apple.com',
    'https://beta.music.apple.com',
    'https://idmsa.apple.com',
    'https://apple.com',
    'https://auth.itunes.apple.com',
  ];

  /// 读取 media-user-token
  /// 方案1（主）：JS 注入读 document.cookie（实测有效，getCookies 在部分设备读不到）
  /// 方案2（兜底）：原生 getCookies 多域扫描
  Future<({List<String> names, String? token, String? mutDetail})>
  _readToken() async {
    // ---- 方案1：JS 注入 ----
    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (function() {
          var ck = '';
          try { ck = document.cookie; } catch(e) { return JSON.stringify({ok:false, err:String(e)}); }
          var parts = ck.split('; ');
          var found = null;
          var names = [];
          for (var i = 0; i < parts.length; i++) {
            var idx = parts[i].indexOf('=');
            if (idx < 0) continue;
            var n = parts[i].substring(0, idx).trim();
            names.push(n);
            if (n === 'media-user-token') {
              found = parts[i].substring(idx + 1).trim();
            }
          }
          // 关键：找到 media-user-token 就提交【完整 cookie 串】，Apple 需要完整上下文（gamdl 式）
          return JSON.stringify({ok:true, cookie:ck, names:names, token: found ? ck : null, len: ck.length});
        })()
      ''');
      final raw = result.toString();
      final outer = jsonDecode(raw);
      if (outer is String) {
        final map = jsonDecode(outer) as Map<String, dynamic>;
        if (map['ok'] == true) {
          final token = (map['token'] as String?)?.trim() ?? '';
          final names = (map['names'] as List)
              .map((e) => e.toString())
              .toList();
          return (
            names: ['[JS document.cookie] ${names.join(', ')}'],
            token: token.isEmpty ? null : token,
            mutDetail: token.isEmpty
                ? 'JS 读到 document.cookie 但 media-user-token 为空'
                : '【JS 读取成功】完整cookie串 len=${token.length} 含 media-user-token',
          );
        }
      }
    } catch (e) {
      // JS 失败继续走方案2
    }

    // ---- 方案2：原生 getCookies 多域扫描（兜底 + 诊断）----
    try {
      final all = <String>[];
      String? token;
      String? mutDetail;
      for (final url in _appleDomains) {
        try {
          final cookies = await _cookieManager.getCookies(
            domain: Uri.parse(url),
          );
          if (cookies.isEmpty) {
            all.add('[$url] （无 cookie）');
            continue;
          }
          for (final c in cookies) {
            final len = c.value.length;
            all.add('[$url] ${c.name} (len=$len)');
            if (c.name == 'media-user-token') {
              mutDetail =
                  '域=$url name="${c.name}" len=${c.value.length} '
                  '前20="${c.value.length > 20 ? c.value.substring(0, 20) : c.value}"';
              if (c.value.isNotEmpty) token = c.value;
            }
          }
        } catch (e) {
          all.add('[$url] 读取异常: $e');
        }
      }
      return (names: all, token: token, mutDetail: mutDetail);
    } catch (e) {
      return (names: ['<读取异常: $e>'], token: null, mutDetail: null);
    }
  }

  /// 手动点击"我已完成登录"
  Future<void> _onManualSubmit() async {
    if (_submitting || _succeeded) return;
    final r = await _readToken();
    final jsProbe = await _jsProbe();
    if (r.token == null || r.token!.isEmpty) {
      // 调试框：关键信息放最顶部，一次截全
      _showDebugDialog(
        '未检测到 media-user-token',
        '【media-user-token 详情（5域）】\n'
            '${r.mutDetail ?? "（5 个域都没找到该名字）"}\n\n'
            '【JS 注入探测 document.cookie + localStorage】\n'
            '$jsProbe\n\n'
            '【多域扫描明细（${r.names.length} 条）】\n'
            '${r.names.isEmpty ? "（全部为空）" : r.names.join("\n")}',
      );
      return;
    }
    await _submit(r.token!);
  }

  /// 注入 JS：读 document.cookie + localStorage（token 若存在 Web Storage 能直接看到）
  Future<String> _jsProbe() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (function() {
          var ls = {};
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              var v = localStorage.getItem(k) || '';
              ls[k] = v.length > 40 ? v.substring(0, 40) + '...(len=' + v.length + ')' : v;
            }
          } catch(e) { ls['<error>'] = String(e); }
          var ck = '';
          try { ck = document.cookie; } catch(e) { ck = '<error:' + e + '>'; }
          return JSON.stringify({cookie: ck, localStorage: ls});
        })()
      ''');
      final s = result.toString();
      return s.length > 600 ? s.substring(0, 600) : s;
    } catch (e) {
      return '<JS 注入失败: $e>';
    }
  }

  /// 调试对话框（白底黑字，确保可读，替代被主题吞色的 SnackBar）
  void _showDebugDialog(String title, String body) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SingleChildScrollView(
          child: Text(
            body,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭', style: TextStyle(color: Colors.black54)),
          ),
        ],
      ),
    );
  }

  /// 提交 token 给后端验证并落盘
  Future<void> _submit(String token) async {
    setState(() => _submitting = true);
    try {
      // GET /apple/login/token?token=（query 传参）；
      // 401 → NotLoggedInException（过期/无订阅）
      final profile = await ApiService.appleLoginVerify(token);
      await ApiService.setAppleToken(token);
      await ApiService.setAppleProfile(jsonEncode(profile));
      if (!mounted) return;
      _succeeded = true;
      _pollTimer?.cancel();
      await context.read<AuthState>().onAppleLoginSuccess(profile);
      _toast('Apple Music 登录成功');
      Navigator.of(context).pop(true);
    } on NotLoggedInException {
      // 401：token 过期/无效 → 停止自动轮询（否则无限弹窗），引导重新登录
      _pollTimer?.cancel();
      if (mounted) {
        setState(() => _submitting = false);
        _showDebugDialog(
          '登录已过期',
          '后端验证失败：这个登录凭证已过期或无效，需要重新登录。\n\n'
              '请按顺序操作：\n'
              '1. 关闭本弹窗\n'
              '2. 在网页里点右上角头像（红色圆圈图标）\n'
              '3. 进入账户设置，滑到底部点「退出登录」\n'
              '4. 重新登录（Apple ID 邮箱 + 密码 + 验证码）\n'
              '5. 登录成功后，点右上角「我已完成登录」',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _showDebugDialog('提交失败', '请求后端失败：$e\n请检查音源服务地址和网络后重试');
      }
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

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
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              '登录 Apple Music',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            actions: [
              TextButton(
                onPressed: _submitting ? null : _onManualSubmit,
                child: Text(
                  '我已完成登录',
                  style: TextStyle(
                    color: const Color(0xFFFA57C1),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                // 提交中遮罩：禁止用户继续操作 WebView
                if (_submitting)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(strokeWidth: 2.5),
                          const SizedBox(height: 14),
                          Text(
                            '正在验证登录…',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
