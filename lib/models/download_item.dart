enum DownloadStatus {
  queued,
  analyzing,
  downloading,
  paused,
  merging,
  completed,
  failed,
  canceled,
}

enum MediaSourceType {
  directFile,
  youtube,
  facebook,
  hlsDash,
  genericWeb,
  unsupportedDrm,
}

class StreamQualityOption {
  final String id;
  final String label; // e.g., "1080p MP4", "720p MP4", "Audio Only (M4A)"
  final String format; // mp4, webm, m4a, mp3
  final String downloadUrl;
  final String? audioTrackUrl; // Used when video and audio streams are separate
  final int? estimatedSizeBytes;
  final bool isAudioOnly;

  const StreamQualityOption({
    required this.id,
    required this.label,
    required this.format,
    required this.downloadUrl,
    this.audioTrackUrl,
    this.estimatedSizeBytes,
    this.isAudioOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'format': format,
        'downloadUrl': downloadUrl,
        'audioTrackUrl': audioTrackUrl,
        'estimatedSizeBytes': estimatedSizeBytes,
        'isAudioOnly': isAudioOnly,
      };

  factory StreamQualityOption.fromJson(Map<String, dynamic> json) =>
      StreamQualityOption(
        id: json['id'] as String,
        label: json['label'] as String,
        format: json['format'] as String,
        downloadUrl: json['downloadUrl'] as String,
        audioTrackUrl: json['audioTrackUrl'] as String?,
        estimatedSizeBytes: json['estimatedSizeBytes'] as int?,
        isAudioOnly: json['isAudioOnly'] as bool? ?? false,
      );
}

class DownloadTaskItem {
  final String id;
  final String originalUrl;
  final String downloadUrl;
  final String title;
  final String fileName;
  final String savePath;
  final String? thumbnailUrl;
  final Duration? duration;
  final String qualityLabel;
  final bool isAudioOnly;
  final MediaSourceType sourceType;
  final DownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final int etaSeconds;
  final bool supportsRangeResume;
  final int parallelChunks;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? completedAt;

  const DownloadTaskItem({
    required this.id,
    required this.originalUrl,
    required this.downloadUrl,
    required this.title,
    required this.fileName,
    required this.savePath,
    this.thumbnailUrl,
    this.duration,
    required this.qualityLabel,
    this.isAudioOnly = false,
    required this.sourceType,
    this.status = DownloadStatus.queued,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0.0,
    this.etaSeconds = 0,
    this.supportsRangeResume = false,
    this.parallelChunks = 1,
    this.errorMessage,
    required this.createdAt,
    this.completedAt,
  });

  double get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  String get formattedProgressPercent =>
      '${(progress * 100).toStringAsFixed(1)}%';

  String get formattedSpeed {
    if (speedBytesPerSec <= 0) return '0 KB/s';
    final mbps = speedBytesPerSec / (1024 * 1024);
    if (mbps >= 1.0) {
      return '${mbps.toStringAsFixed(2)} MB/s';
    }
    final kbps = speedBytesPerSec / 1024;
    return '${kbps.toStringAsFixed(1)} KB/s';
  }

  String get formattedSize {
    String fmt(int b) {
      if (b <= 0) return 'Unknown';
      final mb = b / (1024 * 1024);
      if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
      if (mb >= 1.0) return '${mb.toStringAsFixed(2)} MB';
      return '${(b / 1024).toStringAsFixed(1)} KB';
    }

    if (totalBytes <= 0) return fmt(downloadedBytes);
    return '${fmt(downloadedBytes)} / ${fmt(totalBytes)}';
  }

  String get formattedEta {
    if (status != DownloadStatus.downloading || etaSeconds <= 0) return '--:--';
    final mins = etaSeconds ~/ 60;
    final secs = etaSeconds % 60;
    if (mins >= 60) {
      final hrs = mins ~/ 60;
      final remMins = mins % 60;
      return '${hrs}h ${remMins}m';
    }
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  DownloadTaskItem copyWith({
    String? downloadUrl,
    String? title,
    String? fileName,
    String? savePath,
    String? thumbnailUrl,
    Duration? duration,
    String? qualityLabel,
    bool? isAudioOnly,
    MediaSourceType? sourceType,
    DownloadStatus? status,
    int? downloadedBytes,
    int? totalBytes,
    double? speedBytesPerSec,
    int? etaSeconds,
    bool? supportsRangeResume,
    int? parallelChunks,
    String? errorMessage,
    DateTime? completedAt,
  }) {
    return DownloadTaskItem(
      id: id,
      originalUrl: originalUrl,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      title: title ?? this.title,
      fileName: fileName ?? this.fileName,
      savePath: savePath ?? this.savePath,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
      sourceType: sourceType ?? this.sourceType,
      status: status ?? this.status,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      supportsRangeResume: supportsRangeResume ?? this.supportsRangeResume,
      parallelChunks: parallelChunks ?? this.parallelChunks,
      errorMessage: errorMessage,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'originalUrl': originalUrl,
        'downloadUrl': downloadUrl,
        'title': title,
        'fileName': fileName,
        'savePath': savePath,
        'thumbnailUrl': thumbnailUrl,
        'durationSeconds': duration?.inSeconds,
        'qualityLabel': qualityLabel,
        'isAudioOnly': isAudioOnly,
        'sourceType': sourceType.name,
        'status': status.name,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'supportsRangeResume': supportsRangeResume,
        'parallelChunks': parallelChunks,
        'errorMessage': errorMessage,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
      };

  factory DownloadTaskItem.fromJson(Map<String, dynamic> json) {
    return DownloadTaskItem(
      id: json['id'] as String,
      originalUrl: json['originalUrl'] as String,
      downloadUrl: json['downloadUrl'] as String,
      title: json['title'] as String,
      fileName: json['fileName'] as String,
      savePath: json['savePath'] as String,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      duration: json['durationSeconds'] != null
          ? Duration(seconds: json['durationSeconds'] as int)
          : null,
      qualityLabel: json['qualityLabel'] as String? ?? 'Standard',
      isAudioOnly: json['isAudioOnly'] as bool? ?? false,
      sourceType: MediaSourceType.values.firstWhere(
        (e) => e.name == json['sourceType'],
        orElse: () => MediaSourceType.directFile,
      ),
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.paused,
      ),
      downloadedBytes: json['downloadedBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
      supportsRangeResume: json['supportsRangeResume'] as bool? ?? false,
      parallelChunks: json['parallelChunks'] as int? ?? 1,
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'] as String)
          : null,
    );
  }
}
