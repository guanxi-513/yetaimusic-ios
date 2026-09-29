/// 主题皮肤分享服务
///
/// 上传：收集所有页面背景配置 + UI 参数 + 用户自定义图片，POST 到 /theme/share，返回分享码
/// 导入：GET /theme/shared/:code，下载图片到本地，替换路径，应用配置
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../state/theme_state.dart';
import '../state/ui_settings.dart';
import '../config.dart';

class ThemeShareService {
  /// 上传当前主题，返回 6 位分享码
  static Future<String> share({
    void Function(double progress)? onProgress,
  }) async {
    // 1. 收集所有页面的原始配置（深拷贝成可修改 JSON）
    final bgsJson = <String, dynamic>{};
    // 自定义本地图片去重：原始路径 -> slot 编号
    final localImages = <String>[];
    String? slotForPath(String p) {
      if (p.startsWith('assets/')) return null; // 内置图不用传
      var idx = localImages.indexOf(p);
      if (idx < 0) {
        idx = localImages.length;
        localImages.add(p);
      }
      return '__SHARE_IMG_${idx}__';
    }

    for (final pageId in BgPages.all) {
      final bg = themeState.rawBg(pageId);
      final json = bg.toJson();
      if (bg.type == BgType.image && bg.imagePath != null) {
        final slot = slotForPath(bg.imagePath!);
        // PageBg.toJson() 用短键 'i' 存图片路径，必须替换 'i'
        // （此前误写成 'imagePath'，导致分享者本机绝对路径被原样上传）
        if (slot != null) json['i'] = slot;
      }
      bgsJson[pageId] = json;
    }

    // 2. UI 参数（播放页自定义背景图也要收集上传，否则接收方拿到无效路径）
    final uiJson = exportUiSettings();
    final playerBgImg = customPlayerBgImage.value;
    if (playerBgImg.isNotEmpty) {
      final slot = slotForPath(playerBgImg);
      if (slot != null) uiJson['customPlayerBgImage'] = slot;
    }

    final config = jsonEncode({'bgs': bgsJson, 'ui': uiJson});

    // 3. multipart 上传（去掉 baseUrl 末尾斜杠，避免拼出 //theme/share）
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/theme/share');
    final request = _ProgressMultipartRequest('POST', uri);
    request.fields['config'] = config;

    for (var i = 0; i < localImages.length; i++) {
      final file = File(localImages[i]);
      if (!file.existsSync()) continue;
      final ext = _extOf(file.path);
      final multipart = await http.MultipartFile.fromPath(
        'images',
        file.path,
        filename: 'slot_$i$ext',
      );
      request.files.add(multipart);
    }

    // 上传字节进度（图片越大越慢，这里让调用方能看到百分比）
    request.onSendProgress = (sent, total) {
      if (total <= 0) return;
      onProgress?.call((sent / total).clamp(0.0, 1.0));
    };
    onProgress?.call(0);

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('上传失败(${streamed.statusCode}): $body');
    }
    final resp = jsonDecode(body) as Map<String, dynamic>;
    final code = resp['shareCode'] as String?;
    if (code == null) throw Exception('服务器未返回分享码');
    return code;
  }

  /// 输入分享码导入主题，返回 true 成功
  static Future<void> import(String code) async {
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/theme/shared/$code');
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      String msg = '分享码不存在';
      try {
        msg = jsonDecode(resp.body)['message'] ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }

    final record =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final files = (record['files'] as List?)?.cast<String>() ?? [];

    // 下载图片到本地目录
    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory('${dir.path}/shared_themes/$code');
    if (!imgDir.existsSync()) imgDir.createSync(recursive: true);

    // 按文件名里的 slot 编号建立映射（上传端跳过的文件不会造成下标错位）
    final slotFiles = <int, String>{};
    for (var i = 0; i < files.length; i++) {
      final name = files[i];
      final file = File('${imgDir.path}/$name');
      if (!file.existsSync()) {
        final imgResp = await http.get(
          Uri.parse('$base/theme/shared/$code/img/$name'),
        );
        if (imgResp.statusCode == 200) {
          await file.writeAsBytes(imgResp.bodyBytes);
        }
      }
      final m = RegExp(r'img_slot_(\d+)').firstMatch(name);
      slotFiles[m != null ? int.parse(m.group(1)!) : i] = file.path;
    }

    // 把 __SHARE_IMG_n__ 解析成本机实际路径；解析不到返回 null（图缺失）
    String? resolveSlot(String p) {
      final m = RegExp(r'^__SHARE_IMG_(\d+)__$').firstMatch(p);
      if (m == null) return null;
      return slotFiles[int.parse(m.group(1)!)];
    }

    // 应用背景配置：把 __SHARE_IMG_n__ 替换成本地路径
    final bgsJson = (record['bgs'] as Map?) ?? {};
    for (final entry in bgsJson.entries) {
      final pageId = entry.key as String;
      final json = Map<String, dynamic>.from(entry.value as Map);
      // 图片路径在短键 'i'；兼容旧分享码里误写的 'imagePath' 键
      if (json['i'] is String) {
        final local = resolveSlot(json['i'] as String);
        if (local != null) json['i'] = local;
      }
      if (json['imagePath'] is String) {
        final local = resolveSlot(json['imagePath'] as String);
        if (local != null) json['i'] = local;
      }
      json.remove('imagePath');
      try {
        final bg = PageBg.fromJson(json);
        await themeState.setBg(pageId, bg);
      } catch (_) {
        // 单页配置解析失败跳过
      }
    }

    // 应用 UI 参数（播放页自定义背景图占位符替换成本机路径）
    final uiJson = record['ui'] is Map
        ? Map<String, dynamic>.from(record['ui'] as Map)
        : null;
    if (uiJson != null) {
      final img = uiJson['customPlayerBgImage'];
      if (img is String && img.isNotEmpty) {
        // 解析失败（图缺失/被清理）则清空，避免残留无效路径
        uiJson['customPlayerBgImage'] = resolveSlot(img) ?? '';
      }
      await importUiSettings(uiJson);
    }
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '.jpg';
    var ext = path.substring(i).toLowerCase();
    if (ext.length > 5) ext = '.jpg';
    return ext;
  }
}

/// 带发送进度的 MultipartRequest。
///
/// `http` 包原生没有上传进度回调，这里在 [finalize] 返回的字节流上打点，
/// 统计「已交给 socket 的字节数 / 请求体总字节数」（contentLength 由
/// MultipartRequest 精确计算，含 boundary 与各段 header）。
/// 注意：反映的是**本地发送进度**，不代表服务器已接收完毕。
class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(super.method, super.url);

  /// (已发送字节, 请求体总字节)
  void Function(int sent, int total)? onSendProgress;

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    final progress = onSendProgress;
    final source = super.finalize();
    if (progress == null) return source;

    var sent = 0;
    return http.ByteStream(
      source.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            progress(sent, total);
            sink.add(chunk);
          },
        ),
      ),
    );
  }
}
