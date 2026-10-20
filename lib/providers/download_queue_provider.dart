import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../models/download_item.dart';
import '../services/ffmpeg_and_share_service.dart';
import '../services/parallel_range_downloader.dart';
import '../services/site_adapters.dart';
import 'settings_provider.dart';

final rangeDownloaderProvider = Provider<ChunkedRangeDownloader>((ref) {
  return ChunkedRangeDownloader();
});

final smartLinkAnalyzerProvider = Provider<SmartLinkAnalyzer>((ref) {
  return SmartLinkAnalyzer(downloader: ref.watch(rangeDownloaderProvider));
});

final ffmpegHelperProvider = Provider<FfmpegHelperService>((ref) {
  return FfmpegHelperService();
});

class DownloadQueueNotifier extends StateNotifier<List<DownloadTaskItem>> {
  final Ref ref;
  static const _storageKey = 'mba_download_tasks_v1';

  DownloadQueueNotifier(this.ref) : super(const []) {
    _loadSavedTasks();
  }

  Future<void> _loadSavedTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final loaded = decoded
            .map((e) => DownloadTaskItem.fromJson(e as Map<String, dynamic>))
            .map((task) {
          // Any task that was downloading when app closed becomes paused so user can resume
          if (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.analyzing) {
            return task.copyWith(
              status: DownloadStatus.paused,
              speedBytesPerSec: 0,
              etaSeconds: 0,
            );
          }
          return task;
        }).toList();
        state = loaded;
      }
    } catch (_) {}
  }

  Future<void> _persistTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(state.map((t) => t.toJson()).toList());
      await prefs.setString(_storageKey, encoded);
    } catch (_) {}
  }

  /// Enqueues a user-selected quality option from SmartLinkAnalyzer and triggers queue scheduler.
  Future<void> enqueueDownload({
    required AnalyzedMediaResult media,
    required StreamQualityOption selectedQuality,
  }) async {
    final settings = ref.read(appSettingsProvider);
    final downloader = ref.read(rangeDownloaderProvider);
    final id = const Uuid().v4();

    final cleanTitle = media.title
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .trim();
    final safeBaseName = cleanTitle.isEmpty ? 'video_$id' : cleanTitle;
    final fileName = '$safeBaseName.${selectedQuality.format}';

    final probe = await downloader.probeUrl(
      selectedQuality.downloadUrl,
      preferredFileName: fileName,
    );

    final totalBytes = probe.totalBytes > 0
        ? probe.totalBytes
        : (selectedQuality.estimatedSizeBytes ?? 0);

    final newTask = DownloadTaskItem(
      id: id,
      originalUrl: media.originalUrl,
      downloadUrl: selectedQuality.downloadUrl,
      title: media.title,
      fileName: fileName,
      savePath: settings.saveDirectory,
      thumbnailUrl: media.thumbnailUrl,
      duration: media.duration,
      qualityLabel: selectedQuality.label,
      isAudioOnly: selectedQuality.isAudioOnly,
      sourceType: media.sourceType,
      status: DownloadStatus.queued,
      totalBytes: totalBytes,
      supportsRangeResume: probe.supportsRange,
      parallelChunks:
          probe.supportsRange ? settings.maxParallelChunksPerFile : 1,
      createdAt: DateTime.now(),
    );

    state = [newTask, ...state];
    await _persistTasks();
    _scheduleQueue();
  }

  void _scheduleQueue() {
    final settings = ref.read(appSettingsProvider);
    final activeCount = state
        .where((t) => t.status == DownloadStatus.downloading)
        .length;

    if (activeCount >= settings.maxConcurrentDownloads) return;

    final slotsAvailable = settings.maxConcurrentDownloads - activeCount;
    final queuedTasks = state
        .where((t) => t.status == DownloadStatus.queued)
        .take(slotsAvailable)
        .toList();

    for (final task in queuedTasks) {
      _runTask(task.id);
    }
  }

  Future<void> _runTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    final settings = ref.read(appSettingsProvider);
    final downloader = ref.read(rangeDownloaderProvider);

    final activeTask = task.copyWith(
      status: DownloadStatus.downloading,
      errorMessage: null,
    );
    _replaceTask(activeTask);
    await _persistTasks();

    await downloader.startOrResumeDownload(
      task: activeTask,
      maxParallelChunks: settings.maxParallelChunksPerFile,
      onProgress: (downloaded, total, speedBps, etaSec) {
        final current = _findTask(id);
        if (current == null || current.status == DownloadStatus.paused) return;
        _replaceTask(
          current.copyWith(
            downloadedBytes: downloaded,
            totalBytes: total > 0 ? total : current.totalBytes,
            speedBytesPerSec: speedBps,
            etaSeconds: etaSec,
            status: DownloadStatus.downloading,
          ),
        );
      },
      onCompleted: (savedPath) async {
        final current = _findTask(id);
        if (current == null) return;
        _replaceTask(
          current.copyWith(
            downloadedBytes: current.totalBytes > 0
                ? current.totalBytes
                : current.downloadedBytes,
            speedBytesPerSec: 0,
            etaSeconds: 0,
            status: DownloadStatus.completed,
            completedAt: DateTime.now(),
          ),
        );
        await _persistTasks();
        _scheduleQueue();
      },
      onError: (errorMsg) async {
        final current = _findTask(id);
        if (current == null) return;
        _replaceTask(
          current.copyWith(
            status: DownloadStatus.failed,
            speedBytesPerSec: 0,
            etaSeconds: 0,
            errorMessage: errorMsg,
          ),
        );
        await _persistTasks();
        _scheduleQueue();
      },
    );
  }

  Future<void> pauseDownload(String id) async {
    final current = _findTask(id);
    if (current == null) return;
    ref.read(rangeDownloaderProvider).pauseOrCancel(id);
    _replaceTask(
      current.copyWith(
        status: DownloadStatus.paused,
        speedBytesPerSec: 0,
        etaSeconds: 0,
      ),
    );
    await _persistTasks();
    _scheduleQueue();
  }

  Future<void> resumeDownload(String id) async {
    final current = _findTask(id);
    if (current == null) return;
    _replaceTask(
      current.copyWith(
        status: DownloadStatus.queued,
        errorMessage: null,
      ),
    );
    await _persistTasks();
    _scheduleQueue();
  }

  Future<void> removeTask(String id, {bool deleteFileOnDisk = false}) async {
    final current = _findTask(id);
    ref.read(rangeDownloaderProvider).pauseOrCancel(id);
    if (deleteFileOnDisk && current != null) {
      try {
        final f = File(p.join(current.savePath, current.fileName));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    state = state.where((t) => t.id != id).toList();
    await _persistTasks();
    _scheduleQueue();
  }

  Future<void> clearCompletedHistory() async {
    state = state
        .where((t) => t.status != DownloadStatus.completed)
        .toList();
    await _persistTasks();
  }

  Future<void> openSavedFolder(DownloadTaskItem item) async {
    final uri = Uri.directory(item.savePath);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  DownloadTaskItem? _findTask(String id) {
    for (final item in state) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _replaceTask(DownloadTaskItem updated) {
    state = [
      for (final item in state)
        if (item.id == updated.id) updated else item
    ];
  }
}

final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, List<DownloadTaskItem>>(
  (ref) => DownloadQueueNotifier(ref),
);
