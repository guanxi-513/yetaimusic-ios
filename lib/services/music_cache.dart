/// 音频缓存：播放即缓存，LRU 只保留最近播放的 N 首
///
/// - 缓存目录：应用支持目录/music_cache
/// - 缓存文件：`{songId}_{source}.{m4a|mp3}`（下载完成前为 .part，避免读到半成品）
/// - LRU 元数据：cache_meta.json，记录每首的最近播放时间
/// - 修剪：播放时登记并按最近播放时间排序，删除超出 keep 数量的最旧缓存
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';

class MusicCache {
  MusicCache._();

  static Directory? _dir;
  static File? _metaFile;
  static const int _downloadTimeoutSec = 90;

  // ---------------- 目录与文件 ----------------

  static Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    _dir = Directory(p.join(base.path, 'music_cache'));
    await _dir!.create(recursive: true);
    return _dir!;
  }

  /// 缓存文件名：`{songId}_{source}_{指纹}.{m4a|mp3}`
  /// 指纹 = 歌名+歌手 哈希——同一 QQ 歌（同 mid）不同版本（原版/翻唱/错误匹配）
  /// 缓存文件互相隔离，避免"换后端后旧错误缓存直接命中播放"的问题
  static String _fileName(Song song) {
    final ext = song.isBilibili ? 'm4a' : 'mp3';
    final fp =
        (('${song.name}|${song.artists.join('/')}').hashCode & 0x7fffffff)
            .toRadixString(16);
    return '${song.id}_${song.source}_$fp.$ext';
  }

  static Future<File> _meta() async {
    if (_metaFile != null) return _metaFile!;
    final dir = await _cacheDir();
    _metaFile = File(p.join(dir.path, 'cache_meta.json'));
    return _metaFile!;
  }

  // ---------------- LRU 元数据 ----------------

  static Future<List<Map<String, dynamic>>> _readMeta() async {
    final f = await _meta();
    if (!await f.exists()) return [];
    try {
      final data = jsonDecode(await f.readAsString());
      return (data as List?)?.cast<Map<String, dynamic>>() ?? [];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeMeta(List<Map<String, dynamic>> list) async {
    final f = await _meta();
    await f.writeAsString(jsonEncode(list), flush: true);
  }

  // ---------------- 对外 API ----------------

  /// 本地缓存文件路径（未缓存返回 null）
  static Future<String?> cachedPath(Song song) async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, _fileName(song)));
    if (await f.exists()) return f.path;
    return null;
  }

  /// 播放后调用：登记最近播放 + 修剪只保留最近 [keep] 首
  static Future<void> registerPlayedAndPrune(Song song, {int keep = 30}) async {
    final dir = await _cacheDir();
    final fileName = _fileName(song);
    final meta = await _readMeta();

    // 更新或新增该曲目播放记录（同名文件即视为同一首）
    meta.removeWhere((m) => m['file'] == fileName);
    meta.add({
      'file': fileName,
      'lastPlayed': DateTime.now().millisecondsSinceEpoch,
    });

    // 按最近播放倒序，只保留最近 keep 条
    meta.sort((a, b) =>
        (b['lastPlayed'] as num).compareTo(a['lastPlayed'] as num));
    final kept = meta.take(keep).toList();
    final keptFiles = kept.map((m) => m['file'] as String).toSet();

    // 删除超出 keep 的缓存文件
    for (final m in meta) {
      final f = m['file'] as String;
      if (!keptFiles.contains(f)) {
        final file = File(p.join(dir.path, f));
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    await _writeMeta(kept);
  }

  /// 后台下载缓存（.part 写完后再改名，保证 cachedPath 读到的一定是完整文件）
  static Future<void> cacheFromUrl(Song song, String url) async {
    final dir = await _cacheDir();
    final dest = File(p.join(dir.path, _fileName(song)));
    if (await dest.exists()) return; // 已有缓存，跳过
    final tmp = File('${dest.path}.part');
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: _downloadTimeoutSec));
      if (resp.statusCode != 200) return;
      await tmp.writeAsBytes(resp.bodyBytes, flush: true);
      if (await tmp.exists()) await tmp.rename(dest.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 删除单曲缓存文件（含 meta 记录）——缓存被判定为无效（如 30 秒试听片段）时用
  static Future<void> removeFile(Song song) async {
    final dir = await _cacheDir();
    final fileName = _fileName(song);
    final f = File(p.join(dir.path, fileName));
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      final meta = await _readMeta();
      final before = meta.length;
      meta.removeWhere((m) => m['file'] == fileName);
      if (meta.length != before) await _writeMeta(meta);
    } catch (_) {}
  }

  /// 当前缓存总大小（MB），供设置/缓存管理页展示
  static Future<double> totalSizeMb() async {
    final dir = await _cacheDir();
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total / 1024 / 1024;
  }

  /// 缓存文件数量（含元数据文件），供设置/缓存管理页展示
  static Future<int> countFiles() async {
    final dir = await _cacheDir();
    var n = 0;
    try {
      await for (final e in dir.list()) {
        if (e is File) n++;
      }
    } catch (_) {}
    return n;
  }

  /// 清理上次中断的 .part 残留文件（App 启动时调用）
  static Future<void> cleanupPartFiles() async {
    final dir = await _cacheDir();
    try {
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.part')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 清空全部缓存（含元数据），可选功能
  static Future<void> clearAll() async {
    final dir = await _cacheDir();
    try {
      await for (final f in dir.list()) {
        try {
          if (f is File) await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final meta = await _meta();
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }
}
