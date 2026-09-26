import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

/// 竖屏 9:16 裁剪页（自定义播放页背景用）。
/// 返回裁剪后的图片字节；取消返回 null。
class PlayerBgCropPage extends StatefulWidget {
  final Uint8List imageBytes;
  const PlayerBgCropPage({super.key, required this.imageBytes});

  @override
  State<PlayerBgCropPage> createState() => _PlayerBgCropPageState();
}

class _PlayerBgCropPageState extends State<PlayerBgCropPage> {
  final CropController _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('裁剪播放背景（9:16）', style: TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _cropping
                ? null
                : () {
                    setState(() => _cropping = true);
                    _controller.crop();
                  },
            child: Text(
              '确定',
              style: TextStyle(
                color: _cropping ? Colors.white38 : const Color(0xFF1DB954),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Crop(
            image: widget.imageBytes,
            controller: _controller,
            aspectRatio: 9 / 16,
            baseColor: Colors.black,
            maskColor: Colors.black.withValues(alpha: 0.55),
            onCropped: (result) {
              switch (result) {
                case CropSuccess(:final croppedImage):
                  if (!mounted) return;
                  Navigator.of(context).pop(croppedImage);
                case CropFailure(:final cause):
                  if (!mounted) return;
                  setState(() => _cropping = false);
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(content: Text('裁剪失败：$cause')),
                    );
              }
            },
          ),
          if (_cropping)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
