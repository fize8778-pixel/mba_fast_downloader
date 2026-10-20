import 'dart:io';
import 'package:flutter/services.dart';

class FfmpegHelperService {
  /// Checks if local FFmpeg CLI is available (on Windows / Linux) for stream merging.
  Future<bool> isFfmpegAvailable() async {
    try {
      final result = await Process.run('ffmpeg', ['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Merges separate video and audio files into a single MP4 container.
  Future<bool> mergeVideoAndAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    try {
      final available = await isFfmpegAvailable();
      if (!available) return false;

      final result = await Process.run('ffmpeg', [
        '-y',
        '-i',
        videoPath,
        '-i',
        audioPath,
        '-c',
        'copy',
        outputPath,
      ]);
      if (result.exitCode == 0) {
        final vFile = File(videoPath);
        final aFile = File(audioPath);
        if (await vFile.exists()) await vFile.delete();
        if (await aFile.exists()) await aFile.delete();
        return true;
      }
    } catch (_) {}
    return false;
  }
}

/// Native Android Share-to-Downloader Channel (Zero external plugin conflicts!)
class ShareIntentService {
  static const MethodChannel _channel =
      MethodChannel('mba_fast_downloader/share');

  static Future<String?> getInitialSharedUrl() async {
    if (!Platform.isAndroid) return null;
    try {
      final sharedText = await _channel.invokeMethod<String>('getInitialSharedText');
      return _extractFirstUrl(sharedText);
    } catch (_) {
      return null;
    }
  }

  static void listenForSharedUrls(void Function(String url) onSharedUrl) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedText') {
        final text = call.arguments as String?;
        final url = _extractFirstUrl(text);
        if (url != null) {
          onSharedUrl(url);
        }
      }
    });
  }

  static String? _extractFirstUrl(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final match = RegExp(r'https?://[^\s"]+').firstMatch(text);
    return match?.group(0);
  }
}
