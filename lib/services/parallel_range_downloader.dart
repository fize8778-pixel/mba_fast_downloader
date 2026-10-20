import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../models/download_item.dart';

class ByteChunkRange {
  final int index;
  final int startByte;
  final int endByte;
  int downloadedBytes;

  ByteChunkRange({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
  });

  int get totalChunkBytes => (endByte - startByte) + 1;
  bool get isComplete => downloadedBytes >= totalChunkBytes;
  int get currentOffset => startByte + downloadedBytes;

  Map<String, dynamic> toJson() => {
        'index': index,
        'startByte': startByte,
        'endByte': endByte,
        'downloadedBytes': downloadedBytes,
      };

  factory ByteChunkRange.fromJson(Map<String, dynamic> json) => ByteChunkRange(
        index: json['index'] as int,
        startByte: json['startByte'] as int,
        endByte: json['endByte'] as int,
        downloadedBytes: json['downloadedBytes'] as int? ?? 0,
      );
}

class ChunkedRangeDownloader {
  final Dio _dio;
  final Map<String, List<CancelToken>> _taskTokens = {};

  ChunkedRangeDownloader({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 25),
                receiveTimeout: const Duration(minutes: 45),
                followRedirects: true,
                maxRedirects: 8,
                headers: const {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                  'Accept': '*/*',
                },
              ),
            );

  static List<ByteChunkRange> calculateByteRanges(
      int totalBytes, int requestedChunks) {
    if (totalBytes <= 0 ||
        requestedChunks <= 1 ||
        totalBytes < 2 * 1024 * 1024) {
      return [
        ByteChunkRange(
          index: 0,
          startByte: 0,
          endByte: totalBytes > 0 ? totalBytes - 1 : 0,
        ),
      ];
    }

    final chunkCount = requestedChunks.clamp(1, 16);
    final chunkSize = totalBytes ~/ chunkCount;
    final ranges = <ByteChunkRange>[];

    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end =
          (i == chunkCount - 1) ? (totalBytes - 1) : ((i + 1) * chunkSize - 1);
      ranges.add(ByteChunkRange(index: i, startByte: start, endByte: end));
    }
    return ranges;
  }

  Future<({String fileName, int totalBytes, bool supportsRange})> probeUrl(
      String url,
      {String? preferredFileName}) async {
    String fileName = preferredFileName != null && preferredFileName.isNotEmpty
        ? _sanitizeFileName(preferredFileName)
        : _extractFileNameFromUrl(url);
    int totalBytes = 0;
    bool supportsRange = false;

    try {
      final response = await _dio.head(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final headers = response.headers;
      final contentRange = headers.value('content-range')?.toLowerCase() ?? '';
      final acceptRanges = headers.value('accept-ranges')?.toLowerCase() ?? '';

      if (contentRange.contains('/')) {
        final totalPart = contentRange.split('/').last.trim();
        totalBytes = int.tryParse(totalPart) ?? 0;
      }
      if (totalBytes <= 0) {
        final contentLen = headers.value(Headers.contentLengthHeader);
        totalBytes = int.tryParse(contentLen ?? '') ?? 0;
      }

      supportsRange = response.statusCode == 206 ||
          acceptRanges.contains('bytes') ||
          contentRange.contains('bytes');

      if (preferredFileName == null || preferredFileName.isEmpty) {
        final contentDisp = headers.value('content-disposition');
        if (contentDisp != null && contentDisp.contains('filename=')) {
          final match =
              RegExp(r'filename="?([^";]+)"?').firstMatch(contentDisp);
          if (match != null && match.group(1) != null) {
            fileName = _sanitizeFileName(match.group(1)!);
          }
        }
      }
    } catch (_) {}

    return (
      fileName: fileName,
      totalBytes: totalBytes,
      supportsRange: supportsRange,
    );
  }

  Future<void> startOrResumeDownload({
    required DownloadTaskItem task,
    required int maxParallelChunks,
    required void Function(
            int downloaded, int total, double speedBps, int etaSec)
        onProgress,
    required void Function(String finalFilePath) onCompleted,
    required void Function(String errorMessage) onError,
  }) async {
    final saveDir = Directory(task.savePath);
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final finalFile = File(p.join(task.savePath, task.fileName));
    final lowerHost = Uri.tryParse(task.downloadUrl)?.host.toLowerCase() ?? '';
    final isSignedSocialCdn = lowerHost.contains('fbcdn.net') ||
        lowerHost.contains('tiktok') ||
        lowerHost.contains('cdninstagram.com');

    final useParallel = !isSignedSocialCdn &&
        task.supportsRangeResume &&
        task.totalBytes >= 2 * 1024 * 1024 &&
        maxParallelChunks > 1;

    if (!useParallel) {
      await _downloadSingleStream(
        task: task,
        targetFile: finalFile,
        onProgress: onProgress,
        onCompleted: onCompleted,
        onError: onError,
      );
      return;
    }

    final metaFile = File('${finalFile.path}.mba.meta.json');
    List<ByteChunkRange> chunks;

    if (await metaFile.exists()) {
      try {
        final raw = jsonDecode(await metaFile.readAsString()) as List<dynamic>;
        chunks = raw
            .map((e) => ByteChunkRange.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        chunks = calculateByteRanges(task.totalBytes, maxParallelChunks);
      }
    } else {
      chunks = calculateByteRanges(task.totalBytes, maxParallelChunks);
    }

    for (final chunk in chunks) {
      final partFile = File('${finalFile.path}.part${chunk.index}');
      if (await partFile.exists()) {
        final diskLen = await partFile.length();
        chunk.downloadedBytes = diskLen.clamp(0, chunk.totalChunkBytes);
      } else {
        chunk.downloadedBytes = 0;
      }
    }

    final tokens = <CancelToken>[];
    _taskTokens[task.id] = tokens;

    DateTime lastTickTime = DateTime.now();
    int lastTickBytes = chunks.fold(0, (sum, c) => sum + c.downloadedBytes);
    double smoothedSpeed = 0.0;

    void reportAggregatedProgress() {
      final now = DateTime.now();
      final elapsedMs = now.difference(lastTickTime).inMilliseconds;
      if (elapsedMs < 300) return;

      final totalDownloaded =
          chunks.fold(0, (sum, c) => sum + c.downloadedBytes);
      final delta = totalDownloaded - lastTickBytes;
      final instantSpeed = elapsedMs > 0 ? (delta * 1000.0) / elapsedMs : 0.0;
      smoothedSpeed = smoothedSpeed == 0.0
          ? instantSpeed
          : (smoothedSpeed * 0.65) + (instantSpeed * 0.35);

      final remaining =
          (task.totalBytes - totalDownloaded).clamp(0, task.totalBytes);
      final etaSec = smoothedSpeed > 1 ? (remaining / smoothedSpeed).round() : 0;

      onProgress(totalDownloaded, task.totalBytes, smoothedSpeed, etaSec);
      lastTickTime = now;
      lastTickBytes = totalDownloaded;
    }

    try {
      await Future.wait(
        chunks.map((chunk) async {
          if (chunk.isComplete) return;
          final token = CancelToken();
          tokens.add(token);

          final partFile = File('${finalFile.path}.part${chunk.index}');
          final startOffset = chunk.currentOffset;
          final rangeHeader = 'bytes=$startOffset-${chunk.endByte}';

          final response = await _dio.get<ResponseBody>(
            task.downloadUrl,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Range': rangeHeader},
            ),
            cancelToken: token,
          );

          final raf = await partFile.open(
            mode: chunk.downloadedBytes > 0 ? FileMode.append : FileMode.write,
          );

          try {
            await for (final data in response.data!.stream) {
              if (token.isCancelled) {
                await raf.close();
                return;
              }
              await raf.writeFrom(data);
              chunk.downloadedBytes += data.length;
              reportAggregatedProgress();
            }
          } finally {
            await raf.flush();
            await raf.close();
          }
        }),
      );

      if (tokens.any((t) => t.isCancelled)) {
        await metaFile.writeAsString(
          jsonEncode(chunks.map((c) => c.toJson()).toList()),
        );
        return;
      }

      if (chunks.every((c) => c.isComplete)) {
        final outSink = finalFile.openWrite(mode: FileMode.writeOnly);
        for (final chunk in chunks) {
          final partFile = File('${finalFile.path}.part${chunk.index}');
          if (await partFile.exists()) {
            await outSink.addStream(partFile.openRead());
          }
        }
        await outSink.flush();
        await outSink.close();

        for (final chunk in chunks) {
          final partFile = File('${finalFile.path}.part${chunk.index}');
          if (await partFile.exists()) {
            await partFile.delete();
          }
        }
        if (await metaFile.exists()) {
          await metaFile.delete();
        }

        _taskTokens.remove(task.id);
        onCompleted(finalFile.path);
      }
    } on DioException catch (e) {
      _taskTokens.remove(task.id);
      if (CancelToken.isCancel(e)) {
        await metaFile.writeAsString(
          jsonEncode(chunks.map((c) => c.toJson()).toList()),
        );
        return;
      }
      await _downloadSingleStream(
        task: task,
        targetFile: finalFile,
        onProgress: onProgress,
        onCompleted: onCompleted,
        onError: onError,
      );
    } catch (e) {
      _taskTokens.remove(task.id);
      onError(e.toString());
    }
  }

  Future<void> _downloadSingleStream({
    required DownloadTaskItem task,
    required File targetFile,
    required void Function(
            int downloaded, int total, double speedBps, int etaSec)
        onProgress,
    required void Function(String finalFilePath) onCompleted,
    required void Function(String errorMessage) onError,
  }) async {
    final token = CancelToken();
    _taskTokens[task.id] = [token];

    int existingBytes = 0;
    if (await targetFile.exists() && task.supportsRangeResume) {
      existingBytes = await targetFile.length();
    }

    DateTime lastTickTime = DateTime.now();
    int lastTickBytes = existingBytes;
    double smoothedSpeed = 0.0;

    try {
      final response = await _dio.get<ResponseBody>(
        task.downloadUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers:
              existingBytes > 0 ? {'Range': 'bytes=$existingBytes-'} : null,
        ),
        cancelToken: token,
      );

      final isResumed = response.statusCode == 206 && existingBytes > 0;
      final contentLen = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      final totalBytes = isResumed
          ? existingBytes + contentLen
          : (contentLen > 0 ? contentLen : task.totalBytes);

      final raf = await targetFile.open(
        mode: isResumed ? FileMode.append : FileMode.write,
      );

      int currentBytes = isResumed ? existingBytes : 0;

      await for (final chunk in response.data!.stream) {
        if (token.isCancelled) {
          await raf.close();
          return;
        }
        await raf.writeFrom(chunk);
        currentBytes += chunk.length;

        final now = DateTime.now();
        final elapsedMs = now.difference(lastTickTime).inMilliseconds;
        if (elapsedMs >= 300) {
          final delta = currentBytes - lastTickBytes;
          final instantSpeed = (delta * 1000.0) / elapsedMs;
          smoothedSpeed = smoothedSpeed == 0.0
              ? instantSpeed
              : (smoothedSpeed * 0.65) + (instantSpeed * 0.35);
          final remaining =
              totalBytes > currentBytes ? totalBytes - currentBytes : 0;
          final etaSec =
              smoothedSpeed > 1 ? (remaining / smoothedSpeed).round() : 0;

          onProgress(currentBytes, totalBytes, smoothedSpeed, etaSec);
          lastTickTime = now;
          lastTickBytes = currentBytes;
        }
      }

      await raf.flush();
      await raf.close();
      _taskTokens.remove(task.id);
      onCompleted(targetFile.path);
    } on DioException catch (e) {
      _taskTokens.remove(task.id);
      if (CancelToken.isCancel(e)) return;
      onError(e.message ?? 'ڈاؤن لوڈ میں رکاوٹ پیش آئی۔');
    } catch (e) {
      _taskTokens.remove(task.id);
      onError(e.toString());
    }
  }

  void pauseOrCancel(String taskId) {
    final tokens = _taskTokens.remove(taskId);
    if (tokens != null) {
      for (final t in tokens) {
        if (!t.isCancelled) {
          t.cancel('Paused by user');
        }
      }
    }
  }

  static String _extractFileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last.trim();
      if (last.isNotEmpty && last.contains('.')) {
        return _sanitizeFileName(last);
      }
    }
    return 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  static String _sanitizeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    return cleaned.isEmpty ? 'download_file.mp4' : cleaned;
  }
}
