import 'package:dio/dio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/download_item.dart';
import 'parallel_range_downloader.dart';

class AnalyzedMediaResult {
  final String originalUrl;
  final String title;
  final String? thumbnailUrl;
  final Duration? duration;
  final MediaSourceType sourceType;
  final List<StreamQualityOption> qualityOptions;
  final bool isSupported;
  final String? unsupportedReason;

  const AnalyzedMediaResult({
    required this.originalUrl,
    required this.title,
    this.thumbnailUrl,
    this.duration,
    required this.sourceType,
    required this.qualityOptions,
    this.isSupported = true,
    this.unsupportedReason,
  });

  factory AnalyzedMediaResult.unsupported({
    required String url,
    required String reason,
    MediaSourceType sourceType = MediaSourceType.unsupportedDrm,
  }) {
    return AnalyzedMediaResult(
      originalUrl: url,
      title: 'غیر معاون لنک (Unsupported Link)',
      sourceType: sourceType,
      qualityOptions: const [],
      isSupported: false,
      unsupportedReason: reason,
    );
  }
}

abstract class SiteAdapter {
  bool canHandle(Uri uri);
  Future<AnalyzedMediaResult> analyze(Uri uri);
}

class DirectUrlAdapter implements SiteAdapter {
  final ChunkedRangeDownloader _downloader;
  DirectUrlAdapter(this._downloader);

  static const _directExtensions = {
    '.mp4',
    '.webm',
    '.mkv',
    '.mov',
    '.avi',
    '.mp3',
    '.m4a',
    '.wav',
    '.zip',
    '.pdf',
  };

  @override
  bool canHandle(Uri uri) {
    final pathLower = uri.path.toLowerCase();
    return _directExtensions.any((ext) => pathLower.endsWith(ext));
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final url = uri.toString();
    final probe = await _downloader.probeUrl(url);
    final isAudio = probe.fileName.endsWith('.mp3') ||
        probe.fileName.endsWith('.m4a') ||
        probe.fileName.endsWith('.wav');
    final ext = probe.fileName.contains('.')
        ? probe.fileName.split('.').last.toLowerCase()
        : 'mp4';

    return AnalyzedMediaResult(
      originalUrl: url,
      title: probe.fileName,
      sourceType: MediaSourceType.directFile,
      qualityOptions: [
        StreamQualityOption(
          id: 'direct_original',
          label: isAudio
              ? 'Original Audio (${ext.toUpperCase()})'
              : 'Original Direct Quality (${ext.toUpperCase()})',
          format: ext,
          downloadUrl: url,
          estimatedSizeBytes: probe.totalBytes > 0 ? probe.totalBytes : null,
          isAudioOnly: isAudio,
        ),
      ],
    );
  }
}

class HlsDashStreamAdapter implements SiteAdapter {
  @override
  bool canHandle(Uri uri) {
    final p = uri.path.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.mpd');
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final isDash = uri.path.toLowerCase().endsWith('.mpd');
    final title = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'Live/Stream Video';

    return AnalyzedMediaResult(
      originalUrl: uri.toString(),
      title: title,
      sourceType: MediaSourceType.hlsDash,
      qualityOptions: [
        StreamQualityOption(
          id: 'stream_best',
          label: isDash ? 'DASH Stream (MP4 via FFmpeg)' : 'HLS Stream (MP4 via FFmpeg)',
          format: 'mp4',
          downloadUrl: uri.toString(),
          isAudioOnly: false,
        ),
        StreamQualityOption(
          id: 'stream_audio',
          label: 'صرف آڈیو (Audio Only - M4A)',
          format: 'm4a',
          downloadUrl: uri.toString(),
          isAudioOnly: true,
        ),
      ],
    );
  }
}

class YouTubeSiteAdapter implements SiteAdapter {
  @override
  bool canHandle(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.contains('youtube.com') || host.contains('youtu.be');
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(uri.toString());
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      final options = <StreamQualityOption>[];

      // 1. Add Muxed Streams (Video + Audio combined, fast & direct)
      for (final stream in manifest.muxed.sortByVideoQuality()) {
        options.add(
          StreamQualityOption(
            id: 'yt_muxed_${stream.tag}',
            label: '${stream.qualityLabel} (${stream.container.name.toUpperCase()})',
            format: stream.container.name,
            downloadUrl: stream.url.toString(),
            estimatedSizeBytes: stream.size.totalBytes,
            isAudioOnly: false,
          ),
        );
      }

      // 2. Add 1080p / High-Res Video-Only Streams paired with best Audio stream
      final bestAudio = manifest.audioOnly.isNotEmpty
          ? manifest.audioOnly.withHighestBitrate()
          : null;
      if (bestAudio != null) {
        final seenLabels = options.map((o) => o.label.split(' ').first).toSet();
        for (final vStream in manifest.videoOnly) {
          if (vStream.container.name == 'mp4' &&
              !seenLabels.contains(vStream.qualityLabel)) {
            seenLabels.add(vStream.qualityLabel);
            options.add(
              StreamQualityOption(
                id: 'yt_hd_${vStream.tag}',
                label: '${vStream.qualityLabel} HD (MP4)',
                format: 'mp4',
                downloadUrl: vStream.url.toString(),
                audioTrackUrl: bestAudio.url.toString(),
                estimatedSizeBytes:
                    vStream.size.totalBytes + bestAudio.size.totalBytes,
                isAudioOnly: false,
              ),
            );
          }
        }

        // 3. Add Audio-Only option
        options.add(
          StreamQualityOption(
            id: 'yt_audio_${bestAudio.tag}',
            label: 'صرف آڈیو (Audio Only - M4A)',
            format: 'm4a',
            downloadUrl: bestAudio.url.toString(),
            estimatedSizeBytes: bestAudio.size.totalBytes,
            isAudioOnly: true,
          ),
        );
      }

      if (options.isEmpty) {
        return AnalyzedMediaResult.unsupported(
          url: uri.toString(),
          reason:
              'اس ویڈیو پر خصوصی پابندیاں یا DRM موجود ہے جس کی وجہ سے ڈاؤن لوڈ دستیاب نہیں۔',
        );
      }

      return AnalyzedMediaResult(
        originalUrl: uri.toString(),
        title: video.title,
        thumbnailUrl: video.thumbnails.highResUrl,
        duration: video.duration,
        sourceType: MediaSourceType.youtube,
        qualityOptions: options,
      );
    } catch (e) {
      return AnalyzedMediaResult.unsupported(
        url: uri.toString(),
        reason:
            'یہ ویڈیو نجی (Private)، لاگ اِن کے پیچھے، یا پلیٹ فارم کی شرائط کی وجہ سے قابلِ رسائی نہیں ہے۔',
      );
    } finally {
      yt.close();
    }
  }
}

class GenericWebSiteAdapter implements SiteAdapter {
  final Dio _dio;
  GenericWebSiteAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: const {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
              ),
            );

  @override
  bool canHandle(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final host = uri.host.toLowerCase();
    final isFacebook =
        host.contains('facebook.com') || host.contains('fb.watch');

    // Check for known DRM-only streaming platforms immediately (Fail-Fast)
    if (host.contains('netflix.com') ||
        host.contains('primevideo.com') ||
        host.contains('disneyplus.com') ||
        host.contains('spotify.com')) {
      return AnalyzedMediaResult.unsupported(
        url: uri.toString(),
        reason:
            'یہ ویب سائٹ DRM کاپی رائٹ سیکیورٹی استعمال کرتی ہے۔ قانونی اور تکنیکی طور پر اسے ڈاؤن لوڈ نہیں کیا جا سکتا۔',
      );
    }

    try {
      final response = await _dio.get<String>(uri.toString());
      final html = response.data ?? '';

      if (html.contains('drmConfig') || html.contains('widevine')) {
        return AnalyzedMediaResult.unsupported(
          url: uri.toString(),
          reason: 'یہ ویڈیو DRM سے محفوظ ہے اور ڈاؤن لوڈ کے لیے دستیاب نہیں ہے۔',
        );
      }

      final titleMatch = RegExp(
        r'<meta\s+property="og:title"\s+content="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(html);
      final thumbMatch = RegExp(
        r'<meta\s+property="og:image"\s+content="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(html);

      final videoUrlMatches = <String>{};
      for (final pattern in [
        RegExp(r'<meta\s+property="og:video(?::secure_url|:url)?"\s+content="([^"]+)"',
            caseSensitive: false),
        RegExp(r'"playable_url_quality_hd":"([^"]+)"'),
        RegExp(r'"playable_url":"([^"]+)"'),
        RegExp(r'src="([^"]+\.(?:mp4|webm|m3u8)[^"]*)"', caseSensitive: false),
      ]) {
        for (final m in pattern.allMatches(html)) {
          final raw = m.group(1)?.replaceAll(r'\/', '/').replaceAll('&amp;', '&');
          if (raw != null && raw.startsWith('http')) {
            videoUrlMatches.add(raw);
          }
        }
      }

      if (videoUrlMatches.isEmpty) {
        return AnalyzedMediaResult.unsupported(
          url: uri.toString(),
          sourceType:
              isFacebook ? MediaSourceType.facebook : MediaSourceType.genericWeb,
          reason: isFacebook
              ? 'یہ فیس بک ویڈیو نجی (Private) ہے یا لاگ اِن کی ضرورت ہے۔ صرف عوامی (Public) ویڈیوز ڈاؤن لوڈ کی جا سکتی ہیں۔'
              : 'اس ویب صفحے پر کوئی براہِ راست عوامی ویڈیو لنک نہیں ملا۔',
        );
      }

      final title = titleMatch?.group(1) ??
          (isFacebook ? 'Facebook Public Video' : 'Web Video');
      final thumb = thumbMatch?.group(1);

      final options = <StreamQualityOption>[];
      int idx = 1;
      for (final vUrl in videoUrlMatches) {
        final isHd = vUrl.contains('hd') || idx == 1;
        options.add(
          StreamQualityOption(
            id: 'web_$idx',
            label: isHd ? 'HD Quality (MP4)' : 'Standard Quality $idx (MP4)',
            format: 'mp4',
            downloadUrl: vUrl,
            isAudioOnly: false,
          ),
        );
        idx++;
      }

      return AnalyzedMediaResult(
        originalUrl: uri.toString(),
        title: title,
        thumbnailUrl: thumb,
        sourceType:
            isFacebook ? MediaSourceType.facebook : MediaSourceType.genericWeb,
        qualityOptions: options,
      );
    } catch (e) {
      return AnalyzedMediaResult.unsupported(
        url: uri.toString(),
        reason: 'ویب سائٹ سے معلومات حاصل کرنے میں رکاوٹ پیش آئی یا لنک درست نہیں ہے۔',
      );
    }
  }
}

class SmartLinkAnalyzer {
  final List<SiteAdapter> _adapters;

  SmartLinkAnalyzer({ChunkedRangeDownloader? downloader})
      : _adapters = [
          DirectUrlAdapter(downloader ?? ChunkedRangeDownloader()),
          HlsDashStreamAdapter(),
          YouTubeSiteAdapter(),
          GenericWebSiteAdapter(),
        ];

  /// Identifies URL category without making network calls (used for badges & tests).
  static MediaSourceType classifyUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return MediaSourceType.unsupportedDrm;
    }
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    if (host.contains('netflix.com') ||
        host.contains('primevideo.com') ||
        host.contains('disneyplus.com')) {
      return MediaSourceType.unsupportedDrm;
    }
    if (path.endsWith('.mp4') ||
        path.endsWith('.webm') ||
        path.endsWith('.mkv') ||
        path.endsWith('.mp3') ||
        path.endsWith('.m4a') ||
        path.endsWith('.zip')) {
      return MediaSourceType.directFile;
    }
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
      return MediaSourceType.hlsDash;
    }
    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      return MediaSourceType.youtube;
    }
    if (host.contains('facebook.com') || host.contains('fb.watch')) {
      return MediaSourceType.facebook;
    }
    return MediaSourceType.genericWeb;
  }

  Future<AnalyzedMediaResult> analyzeUrl(String rawUrl) async {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return AnalyzedMediaResult.unsupported(
        url: trimmed,
        reason: 'براہِ کرم ایک درست ویب لنک (http:// یا https://) درج کریں۔',
      );
    }

    for (final adapter in _adapters) {
      if (adapter.canHandle(uri)) {
        return adapter.analyze(uri);
      }
    }

    return AnalyzedMediaResult.unsupported(
      url: trimmed,
      reason: 'یہ لنک معاون نہیں ہے۔',
    );
  }
}
