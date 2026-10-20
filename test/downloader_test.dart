import 'package:flutter_test/flutter_test.dart';
import 'package:mba_fast_downloader/models/download_item.dart';
import 'package:mba_fast_downloader/services/parallel_range_downloader.dart';
import 'package:mba_fast_downloader/services/site_adapters.dart';

void main() {
  group('MBA Fast Downloader — Automated QA Verification Suite', () {
    test('1. Parallel Chunk Range Calculation splits bytes accurately', () {
      const totalBytes = 10 * 1024 * 1024; // 10 MB
      final chunks = ChunkedRangeDownloader.calculateByteRanges(totalBytes, 4);

      expect(chunks.length, 4);
      expect(chunks.first.startByte, 0);
      expect(chunks.last.endByte, totalBytes - 1);

      final sumBytes =
          chunks.fold<int>(0, (sum, item) => sum + item.totalChunkBytes);
      expect(sumBytes, totalBytes);
    });

    test('2. Small files (< 2 MB) use a single range stream cleanly', () {
      const smallBytes = 500 * 1024; // 500 KB
      final chunks = ChunkedRangeDownloader.calculateByteRanges(smallBytes, 6);
      expect(chunks.length, 1);
      expect(chunks.first.totalChunkBytes, smallBytes);
    });

    test('3. SmartLinkAnalyzer classifies Direct, YouTube, HLS, Facebook & DRM URLs', () {
      expect(
        SmartLinkAnalyzer.classifyUrl('https://cdn.example.com/movie.mp4'),
        MediaSourceType.directFile,
      );
      expect(
        SmartLinkAnalyzer.classifyUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        MediaSourceType.youtube,
      );
      expect(
        SmartLinkAnalyzer.classifyUrl('https://live.example.com/stream.m3u8'),
        MediaSourceType.hlsDash,
      );
      expect(
        SmartLinkAnalyzer.classifyUrl('https://www.facebook.com/watch/?v=123456'),
        MediaSourceType.facebook,
      );
      expect(
        SmartLinkAnalyzer.classifyUrl('https://www.netflix.com/watch/80057281'),
        MediaSourceType.unsupportedDrm,
      );
    });

    test('4. DownloadTaskItem serializes & restores Pause/Resume state accurately', () {
      final original = DownloadTaskItem(
        id: 'task-101',
        originalUrl: 'https://example.com/video.mp4',
        downloadUrl: 'https://example.com/video.mp4',
        title: 'Sample 1080p Video',
        fileName: 'Sample_1080p_Video.mp4',
        savePath: '/downloads',
        qualityLabel: '1080p MP4',
        sourceType: MediaSourceType.directFile,
        status: DownloadStatus.paused,
        downloadedBytes: 5242880,
        totalBytes: 10485760,
        speedBytesPerSec: 2097152, // 2 MB/s
        etaSeconds: 65,
        supportsRangeResume: true,
        parallelChunks: 4,
        createdAt: DateTime.utc(2026, 10, 20),
      );

      expect(original.formattedProgressPercent, '50.0%');
      expect(original.formattedSpeed, '2.00 MB/s');

      final json = original.toJson();
      final restored = DownloadTaskItem.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.downloadedBytes, 5242880);
      expect(restored.totalBytes, 10485760);
      expect(restored.supportsRangeResume, isTrue);
      expect(restored.parallelChunks, 4);
    });
  });
}
