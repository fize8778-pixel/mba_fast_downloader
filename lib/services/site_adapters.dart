import 'dart:convert';
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
      title: 'غیر معاون لنک',
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
    '.flv',
    '.3gp',
    '.mp3',
    '.m4a',
    '.wav',
    '.ogg',
    '.aac',
    '.zip',
    '.rar',
    '.7z',
    '.pdf',
    '.apk',
    '.exe',
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
    final lowerName = probe.fileName.toLowerCase();
    final isAudio = lowerName.endsWith('.mp3') ||
        lowerName.endsWith('.m4a') ||
        lowerName.endsWith('.wav') ||
        lowerName.endsWith('.ogg') ||
        lowerName.endsWith('.aac');
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
    final q = uri.query.toLowerCase();
    return p.endsWith('.m3u8') ||
        p.endsWith('.mpd') ||
        q.contains('.m3u8') ||
        q.contains('.mpd');
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final isDash = uri.path.toLowerCase().endsWith('.mpd') ||
        uri.query.toLowerCase().contains('.mpd');
    final title = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'Live Stream Video';

    return AnalyzedMediaResult(
      originalUrl: uri.toString(),
      title: title,
      sourceType: MediaSourceType.hlsDash,
      qualityOptions: [
        StreamQualityOption(
          id: 'stream_best',
          label: isDash ? 'DASH Stream (MP4)' : 'HLS Stream (MP4)',
          format: 'mp4',
          downloadUrl: uri.toString(),
          isAudioOnly: false,
        ),
        StreamQualityOption(
          id: 'stream_audio',
          label: 'Audio Only (M4A)',
          format: 'm4a',
          downloadUrl: uri.toString(),
          isAudioOnly: true,
        ),
      ],
    );
  }
}

class YouTubeSiteAdapter implements SiteAdapter {
  final Dio _dio;

  YouTubeSiteAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 25),
              ),
            );

  @override
  bool canHandle(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        host.contains('youtube-nocookie.com');
  }

  static String? extractVideoId(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }
    if (uri.queryParameters.containsKey('v')) {
      return uri.queryParameters['v'];
    }
    final segments = uri.pathSegments;
    final shortsIdx = segments.indexOf('shorts');
    if (shortsIdx != -1 && shortsIdx + 1 < segments.length) {
      return segments[shortsIdx + 1];
    }
    final liveIdx = segments.indexOf('live');
    if (liveIdx != -1 && liveIdx + 1 < segments.length) {
      return segments[liveIdx + 1];
    }
    final embedIdx = segments.indexOf('embed');
    if (embedIdx != -1 && embedIdx + 1 < segments.length) {
      return segments[embedIdx + 1];
    }
    return null;
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final videoId = extractVideoId(uri);
    final canonicalUrl = videoId != null
        ? 'https://www.youtube.com/watch?v=$videoId'
        : uri.toString();

    // Strategy 1: YoutubeExplode library
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(canonicalUrl);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      final options = <StreamQualityOption>[];

      for (final stream in manifest.muxed.sortByVideoQuality()) {
        options.add(
          StreamQualityOption(
            id: 'yt_muxed_${stream.tag}',
            label:
                '${stream.qualityLabel} (${stream.container.name.toUpperCase()})',
            format: stream.container.name,
            downloadUrl: stream.url.toString(),
            estimatedSizeBytes: stream.size.totalBytes,
            isAudioOnly: false,
          ),
        );
      }

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

        options.add(
          StreamQualityOption(
            id: 'yt_audio_${bestAudio.tag}',
            label: 'Audio Only (M4A)',
            format: 'm4a',
            downloadUrl: bestAudio.url.toString(),
            estimatedSizeBytes: bestAudio.size.totalBytes,
            isAudioOnly: true,
          ),
        );
      }

      if (options.isNotEmpty) {
        return AnalyzedMediaResult(
          originalUrl: uri.toString(),
          title: video.title,
          thumbnailUrl: video.thumbnails.highResUrl,
          duration: video.duration,
          sourceType: MediaSourceType.youtube,
          qualityOptions: options,
        );
      }
    } catch (_) {
      // Fall through to Strategy 2 (Direct Innertube Player API)
    } finally {
      yt.close();
    }

    // Strategy 2: Direct YouTube Innertube API (ANDROID_VR & IOS clients)
    if (videoId != null && videoId.isNotEmpty) {
      final innertubeResult =
          await _analyzeViaInnertube(videoId, uri.toString());
      if (innertubeResult != null) {
        return innertubeResult;
      }
    }

    return AnalyzedMediaResult.unsupported(
      url: uri.toString(),
      sourceType: MediaSourceType.youtube,
      reason:
          'اس یوٹیوب ویڈیو کے اسٹریم لنکس حاصل نہیں ہو سکے۔ براہِ کرم تصدیق کریں کہ ویڈیو عوامی ہے۔',
    );
  }

  Future<AnalyzedMediaResult?> _analyzeViaInnertube(
      String videoId, String originalUrl) async {
    final clients = [
      {
        'context': {
          'client': {
            'clientName': 'ANDROID_VR',
            'clientVersion': '1.60.19',
            'androidSdkVersion': 34,
            'userAgent':
                'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 14; en_US; Quest 3; Build/UP1A.231005.007.A1; Cronet/132.0.6808.3)',
            'hl': 'en',
            'gl': 'US',
          }
        },
        'ua':
            'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 14; en_US; Quest 3; Build/UP1A.231005.007.A1; Cronet/132.0.6808.3)',
      },
      {
        'context': {
          'client': {
            'clientName': 'IOS',
            'clientVersion': '19.45.4',
            'deviceMake': 'Apple',
            'deviceModel': 'iPhone16,2',
            'osName': 'iPhone',
            'osVersion': '18.1.0.22B83',
            'hl': 'en',
            'gl': 'US',
          }
        },
        'ua':
            'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)',
      },
    ];

    for (final profile in clients) {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
          data: {
            'videoId': videoId,
            'context': profile['context'],
            'contentCheckOk': true,
            'racyCheckOk': true,
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': profile['ua'] as String,
            },
          ),
        );

        final data = response.data;
        if (data == null) continue;

        final videoDetails =
            data['videoDetails'] as Map<String, dynamic>? ?? {};
        final title =
            (videoDetails['title'] as String?) ?? 'YouTube Video $videoId';
        final lengthSec =
            int.tryParse('${videoDetails['lengthSeconds'] ?? '0'}') ?? 0;

        final streamingData =
            data['streamingData'] as Map<String, dynamic>? ?? {};
        final formats =
            (streamingData['formats'] as List<dynamic>?) ?? const [];
        final adaptiveFormats =
            (streamingData['adaptiveFormats'] as List<dynamic>?) ?? const [];

        final options = <StreamQualityOption>[];
        final seenQuality = <String>{};

        for (final item in formats) {
          if (item is! Map<String, dynamic>) continue;
          final url = item['url'] as String?;
          if (url == null || url.isEmpty) continue;
          final qualityLabel =
              (item['qualityLabel'] as String?) ?? 'Standard MP4';
          final contentLen =
              int.tryParse('${item['contentLength'] ?? ''}') ?? 0;
          seenQuality.add(qualityLabel);
          options.add(
            StreamQualityOption(
              id: 'yt_inner_${item['itag'] ?? options.length}',
              label: '$qualityLabel (MP4)',
              format: 'mp4',
              downloadUrl: url,
              estimatedSizeBytes: contentLen > 0 ? contentLen : null,
              isAudioOnly: false,
            ),
          );
        }

        String? bestAudioUrl;
        int bestAudioSize = 0;
        for (final item in adaptiveFormats) {
          if (item is! Map<String, dynamic>) continue;
          final mime = (item['mimeType'] as String?) ?? '';
          final url = item['url'] as String?;
          if (url == null || url.isEmpty) continue;
          if (mime.startsWith('audio/')) {
            bestAudioUrl ??= url;
            bestAudioSize = int.tryParse('${item['contentLength'] ?? ''}') ?? 0;
          }
        }

        for (final item in adaptiveFormats) {
          if (item is! Map<String, dynamic>) continue;
          final mime = (item['mimeType'] as String?) ?? '';
          final url = item['url'] as String?;
          if (url == null || url.isEmpty) continue;
          if (mime.startsWith('video/mp4')) {
            final qualityLabel = item['qualityLabel'] as String?;
            if (qualityLabel != null && !seenQuality.contains(qualityLabel)) {
              seenQuality.add(qualityLabel);
              final contentLen =
                  int.tryParse('${item['contentLength'] ?? ''}') ?? 0;
              options.add(
                StreamQualityOption(
                  id: 'yt_adapt_${item['itag'] ?? options.length}',
                  label: '$qualityLabel HD (MP4)',
                  format: 'mp4',
                  downloadUrl: url,
                  audioTrackUrl: bestAudioUrl,
                  estimatedSizeBytes:
                      contentLen > 0 ? contentLen + bestAudioSize : null,
                  isAudioOnly: false,
                ),
              );
            }
          }
        }

        if (bestAudioUrl != null) {
          options.add(
            StreamQualityOption(
              id: 'yt_inner_audio',
              label: 'Audio Only (M4A)',
              format: 'm4a',
              downloadUrl: bestAudioUrl,
              estimatedSizeBytes: bestAudioSize > 0 ? bestAudioSize : null,
              isAudioOnly: true,
            ),
          );
        }

        if (options.isNotEmpty) {
          return AnalyzedMediaResult(
            originalUrl: originalUrl,
            title: title,
            thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
            duration: lengthSec > 0 ? Duration(seconds: lengthSec) : null,
            sourceType: MediaSourceType.youtube,
            qualityOptions: options,
          );
        }
      } catch (_) {}
    }
    return null;
  }
}

class FacebookSiteAdapter implements SiteAdapter {
  final Dio _dio;

  FacebookSiteAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 25),
                followRedirects: true,
                maxRedirects: 8,
                validateStatus: (status) => status != null && status < 500,
              ),
            );

  @override
  bool canHandle(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.contains('facebook.com') ||
        host.contains('fb.watch') ||
        host.contains('fb.gg') ||
        host.contains('fb.com');
  }

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final originalUrl = uri.toString();
    final foundStreams = <String, String>{};
    String? detectedTitle;
    String? detectedThumb;
    String resolvedUrl = originalUrl;
    String? detectedVideoId = _extractFacebookVideoId(originalUrl);

    // 1. Query Link-Preview Crawler User-Agents FIRST (resolves share/v, share/r, fb.watch without login wall)
    for (final botUa in const [
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
      'TelegramBot (like TwitterBot)',
    ]) {
      try {
        final botResp = await _dio.get<String>(
          resolvedUrl,
          options: Options(
            headers: {
              'User-Agent': botUa,
              'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ),
        );
        final realUriStr = botResp.realUri.toString();
        if (realUriStr.isNotEmpty && !realUriStr.contains('/login')) {
          resolvedUrl = realUriStr;
        } else if (realUriStr.contains('next=')) {
          final nextParam = Uri.tryParse(realUriStr)?.queryParameters['next'];
          if (nextParam != null && nextParam.startsWith('http')) {
            resolvedUrl = nextParam;
          }
        }
        final botHtml = botResp.data ?? '';
        _extractFacebookStreamsFromHtml(botHtml, foundStreams);
        detectedTitle ??= _extractMetaContent(botHtml, 'og:title');
        detectedThumb ??= _extractMetaContent(botHtml, 'og:image');
        final ogUrl = _extractMetaContent(botHtml, 'og:url');
        if (ogUrl != null && ogUrl.startsWith('http')) {
          resolvedUrl = _unescapeUrl(ogUrl);
        }
        detectedVideoId ??= _extractFacebookVideoId(resolvedUrl) ??
            _extractFacebookVideoIdFromHtml(botHtml);
        if (foundStreams.isNotEmpty) break;
      } catch (_) {}
    }

    // 2. Try Desktop Chrome request with full Sec-Fetch navigation headers
    if (foundStreams.isEmpty) {
      try {
        final resp = await _dio.get<String>(
          resolvedUrl,
          options: Options(
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
              'Accept-Language': 'en-US,en;q=0.9',
              'Sec-Fetch-Dest': 'document',
              'Sec-Fetch-Mode': 'navigate',
              'Sec-Fetch-Site': 'none',
              'Sec-Fetch-User': '?1',
              'Upgrade-Insecure-Requests': '1',
            },
          ),
        );
        final realUriStr = resp.realUri.toString();
        if (realUriStr.contains('next=')) {
          final nextParam = Uri.tryParse(realUriStr)?.queryParameters['next'];
          if (nextParam != null && nextParam.startsWith('http')) {
            resolvedUrl = nextParam;
          }
        } else if (realUriStr.isNotEmpty && !realUriStr.contains('/login')) {
          resolvedUrl = realUriStr;
        }
        final html = resp.data ?? '';
        _extractFacebookStreamsFromHtml(html, foundStreams);
        detectedTitle ??= _extractMetaContent(html, 'og:title');
        detectedThumb ??= _extractMetaContent(html, 'og:image');
        detectedVideoId ??= _extractFacebookVideoId(resolvedUrl) ??
            _extractFacebookVideoIdFromHtml(html);
      } catch (_) {}
    }

    // 3. Query Facebook Public Embed Plugin (`plugins/video.php`) using Video/Reel ID or resolved URL
    detectedVideoId ??= _extractFacebookVideoId(resolvedUrl);
    if (foundStreams.isEmpty) {
      final candidateHrefs = <String>[
        if (detectedVideoId != null)
          'https://www.facebook.com/facebook/videos/$detectedVideoId/',
        if (detectedVideoId != null)
          'https://www.facebook.com/watch/?v=$detectedVideoId',
        resolvedUrl,
      ];
      for (final href in candidateHrefs) {
        try {
          final embedTarget = Uri.encodeComponent(href);
          final embedUrl =
              'https://www.facebook.com/plugins/video.php?href=$embedTarget&show_text=0';
          final embedResp = await _dio.get<String>(
            embedUrl,
            options: Options(
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.9',
                'Referer': 'https://www.facebook.com/',
              },
            ),
          );
          final embedHtml = embedResp.data ?? '';
          _extractFacebookStreamsFromHtml(embedHtml, foundStreams);
          detectedTitle ??= _extractMetaContent(embedHtml, 'og:title');
          detectedThumb ??= _extractMetaContent(embedHtml, 'og:image');
          if (foundStreams.isNotEmpty) break;
        } catch (_) {}
      }
    }

    // 4. Try mbasic.facebook.com mobile fallback (extracts /video_redirect/?src=...)
    if (foundStreams.isEmpty) {
      final mbasicTargets = <String>[
        if (detectedVideoId != null)
          'https://mbasic.facebook.com/watch/?v=$detectedVideoId',
        (Uri.tryParse(resolvedUrl) ?? uri)
            .replace(host: 'mbasic.facebook.com')
            .toString(),
      ];
      for (final mbUrl in mbasicTargets) {
        try {
          final mbResp = await _dio.get<String>(
            mbUrl,
            options: Options(
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 13; SM-S908B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml',
              },
            ),
          );
          final mbHtml = mbResp.data ?? '';
          _extractFacebookStreamsFromHtml(mbHtml, foundStreams);
          detectedTitle ??= _extractMetaContent(mbHtml, 'og:title');
          if (foundStreams.isNotEmpty) break;
        } catch (_) {}
      }
    }

    if (foundStreams.isEmpty) {
      return AnalyzedMediaResult.unsupported(
        url: originalUrl,
        sourceType: MediaSourceType.facebook,
        reason:
            'یہ فیس بک ویڈیو نجی ہے یا اس کے لیے لاگ اِن درکار ہے۔ صرف عوامی ویڈیوز ڈاؤن لوڈ کی جا سکتی ہیں۔',
      );
    }

    final options = <StreamQualityOption>[];
    int idx = 1;
    foundStreams.forEach((label, streamUrl) {
      options.add(
        StreamQualityOption(
          id: 'fb_$idx',
          label: label,
          format: 'mp4',
          downloadUrl: streamUrl,
          isAudioOnly: false,
        ),
      );
      idx++;
    });

    options.add(
      StreamQualityOption(
        id: 'fb_audio',
        label: 'Audio Only (M4A)',
        format: 'm4a',
        downloadUrl: options.first.downloadUrl,
        isAudioOnly: true,
      ),
    );

    return AnalyzedMediaResult(
      originalUrl: originalUrl,
      title: _cleanTitle(detectedTitle) ??
          'Facebook Video ${detectedVideoId ?? ""}'.trim(),
      thumbnailUrl: detectedThumb != null ? _unescapeUrl(detectedThumb) : null,
      sourceType: MediaSourceType.facebook,
      qualityOptions: options,
    );
  }

  static String? _extractFacebookVideoId(String url) {
    final decoded = Uri.decodeFull(url);
    for (final pattern in [
      RegExp(r'/videos/(?:[^/]+/)?(\d{7,})'),
      RegExp(r'/reel/(\d{7,})'),
      RegExp(r'/reels/(\d{7,})'),
      RegExp(r'[?&]v=(\d{7,})'),
      RegExp(r'story_fbid=(\d{7,})'),
    ]) {
      final m = pattern.firstMatch(decoded);
      if (m != null && m.group(1) != null) {
        return m.group(1);
      }
    }
    return null;
  }

  static String? _extractFacebookVideoIdFromHtml(String html) {
    if (html.isEmpty) return null;
    for (final pattern in [
      RegExp(r'"video_id"\s*:\s*"?(\d{7,})"?'),
      RegExp(r'"videoID"\s*:\s*"?(\d{7,})"?'),
      RegExp(r'/videos/(\d{7,})'),
      RegExp(r'/reel/(\d{7,})'),
    ]) {
      final m = pattern.firstMatch(html);
      if (m != null && m.group(1) != null) {
        return m.group(1);
      }
    }
    return null;
  }

  static void _extractFacebookStreamsFromHtml(
      String rawHtml, Map<String, String> outStreams) {
    if (rawHtml.isEmpty) return;
    final decoded = _unescapeUrl(rawHtml);

    final hdPatterns = [
      RegExp(r'"browser_native_hd_url"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"playable_url_quality_hd"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"hd_src_no_ratelimit"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"hd_src"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'hd_src\s*:\s*"(https?:[^"]+)"'),
    ];

    for (final p in hdPatterns) {
      final m = p.firstMatch(decoded);
      if (m != null && m.group(1) != null) {
        final clean = _unescapeUrl(m.group(1)!);
        if (_isValidMediaStreamUrl(clean)) {
          outStreams['HD Quality (MP4)'] = clean;
          break;
        }
      }
    }

    final sdPatterns = [
      RegExp(r'"browser_native_sd_url"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"playable_url"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"sd_src_no_ratelimit"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"sd_src"\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'sd_src\s*:\s*"(https?:[^"]+)"'),
      RegExp(r'"progressive_url"\s*:\s*"(https?:[^"]+)"'),
    ];

    for (final p in sdPatterns) {
      final m = p.firstMatch(decoded);
      if (m != null && m.group(1) != null) {
        final clean = _unescapeUrl(m.group(1)!);
        if (_isValidMediaStreamUrl(clean) && !outStreams.containsValue(clean)) {
          outStreams['Standard Quality SD (MP4)'] = clean;
          break;
        }
      }
    }

    // Check /video_redirect/?src=...
    final redirectMatches =
        RegExp(r'video_redirect/\?src=([^"&>\s]+)').allMatches(rawHtml);
    for (final rm in redirectMatches) {
      final rawSrc = rm.group(1);
      if (rawSrc != null) {
        final unescaped = Uri.decodeComponent(
          rawSrc.replaceAll('&amp;', '&'),
        );
        if (_isValidMediaStreamUrl(unescaped) &&
            !outStreams.containsValue(unescaped)) {
          outStreams.putIfAbsent('Direct Video (MP4)', () => unescaped);
        }
      }
    }

    // Check OpenGraph <meta property="og:video...">
    for (final metaProp in ['og:video:secure_url', 'og:video:url', 'og:video']) {
      final ogVideo = _extractMetaContent(rawHtml, metaProp);
      if (ogVideo != null) {
        final clean = _unescapeUrl(ogVideo);
        if (_isValidMediaStreamUrl(clean) && !outStreams.containsValue(clean)) {
          outStreams.putIfAbsent('Public Stream (MP4)', () => clean);
        }
      }
    }

    // Fallback: direct fbcdn.net MP4 links in HTML
    if (outStreams.isEmpty) {
      final cdnMatches = RegExp(
        r'''https://video[^"'\s<>]+\.fbcdn\.net/[^"'\s<>]+\.mp4[^"'\s<>]*''',
      ).allMatches(decoded);
      int count = 1;
      for (final cm in cdnMatches) {
        final url = _unescapeUrl(cm.group(0)!);
        if (_isValidMediaStreamUrl(url) && !outStreams.containsValue(url)) {
          outStreams['Video Stream $count (MP4)'] = url;
          count++;
          if (count > 3) break;
        }
      }
    }
  }
}

class GenericWebSiteAdapter implements SiteAdapter {
  final Dio _dio;

  GenericWebSiteAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 25),
                followRedirects: true,
                maxRedirects: 8,
                validateStatus: (status) => status != null && status < 500,
                headers: const {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                },
              ),
            );

  @override
  bool canHandle(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

  @override
  Future<AnalyzedMediaResult> analyze(Uri uri) async {
    final host = uri.host.toLowerCase();
    final urlStr = uri.toString();

    // 1. Fail-Fast on known subscription DRM platforms
    if (host.contains('netflix.com') ||
        host.contains('primevideo.com') ||
        host.contains('disneyplus.com') ||
        host.contains('spotify.com') ||
        host.contains('hulu.com')) {
      return AnalyzedMediaResult.unsupported(
        url: urlStr,
        reason:
            'یہ ویب سائٹ DRM کاپی رائٹ سیکیورٹی استعمال کرتی ہے۔ قانونی اور تکنیکی طور پر اسے ڈاؤن لوڈ نہیں کیا جا سکتا۔',
      );
    }

    // 2. TikTok specialized extractor (tikwm API + HTML fallback)
    if (host.contains('tiktok.com')) {
      final tikResult = await _analyzeTikTok(urlStr);
      if (tikResult != null) return tikResult;
    }

    // 3. Instagram specialized extractor (embed/captioned + ddinstagram + OpenGraph)
    if (host.contains('instagram.com') || host.contains('instagr.am')) {
      final igResult = await _analyzeInstagram(uri);
      if (igResult != null) return igResult;
    }

    // 4. Twitter / X specialized extractor (vxtwitter API)
    if (host.contains('twitter.com') ||
        host.contains('x.com') ||
        host.contains('t.co')) {
      final xResult = await _analyzeTwitterX(uri);
      if (xResult != null) return xResult;
    }

    // 5. Vimeo / Dailymotion / Reddit specialized extractors
    if (host.contains('vimeo.com')) {
      final vimeoResult = await _analyzeVimeo(uri);
      if (vimeoResult != null) return vimeoResult;
    }
    if (host.contains('dailymotion.com') || host.contains('dai.ly')) {
      final dmResult = await _analyzeDailymotion(uri);
      if (dmResult != null) return dmResult;
    }
    if (host.contains('reddit.com') || host.contains('redd.it')) {
      final redditResult = await _analyzeReddit(uri);
      if (redditResult != null) return redditResult;
    }

    // 6. Universal webpage & direct Content-Type inspection
    try {
      final response = await _dio.get<String>(
        urlStr,
        options: Options(
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        ),
      );

      final contentType =
          response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ?? '';
      if (contentType.startsWith('video/') ||
          contentType.startsWith('audio/') ||
          contentType.contains('application/octet-stream')) {
        final isAudio = contentType.startsWith('audio/');
        final ext = isAudio ? 'mp3' : 'mp4';
        final contentLen = int.tryParse(
                response.headers.value(Headers.contentLengthHeader) ?? '') ??
            0;
        return AnalyzedMediaResult(
          originalUrl: urlStr,
          title: uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : 'Direct Media Stream',
          sourceType: MediaSourceType.directFile,
          qualityOptions: [
            StreamQualityOption(
              id: 'direct_ct',
              label: isAudio
                  ? 'Direct Audio (${ext.toUpperCase()})'
                  : 'Direct Video (${ext.toUpperCase()})',
              format: ext,
              downloadUrl: response.realUri.toString().isNotEmpty
                  ? response.realUri.toString()
                  : urlStr,
              estimatedSizeBytes: contentLen > 0 ? contentLen : null,
              isAudioOnly: isAudio,
            ),
          ],
        );
      }

      final html = response.data ?? '';
      if (html.contains('"drmConfig"') || html.contains('widevine')) {
        return AnalyzedMediaResult.unsupported(
          url: urlStr,
          reason: 'یہ ویڈیو DRM سے محفوظ ہے اور ڈاؤن لوڈ کے لیے دستیاب نہیں ہے۔',
        );
      }

      final streams = <String>{};
      _extractGenericWebStreams(html, uri, streams);

      String? title = _extractMetaContent(html, 'og:title') ??
          _extractHtmlTitle(html);
      String? thumb = _extractMetaContent(html, 'og:image');

      // Fallback: Try TelegramBot User-Agent for OpenGraph video tags
      if (streams.isEmpty) {
        final botResp = await _dio.get<String>(
          urlStr,
          options: Options(
            headers: const {
              'User-Agent': 'TelegramBot (like TwitterBot)',
            },
          ),
        );
        final botHtml = botResp.data ?? '';
        _extractGenericWebStreams(botHtml, uri, streams);
        title ??= _extractMetaContent(botHtml, 'og:title');
        thumb ??= _extractMetaContent(botHtml, 'og:image');
      }

      if (streams.isEmpty) {
        return AnalyzedMediaResult.unsupported(
          url: urlStr,
          sourceType: MediaSourceType.genericWeb,
          reason:
              'اس ویب صفحے پر کوئی براہِ راست عوامی ویڈیو لنک نہیں ملا۔',
        );
      }

      final options = <StreamQualityOption>[];
      int idx = 1;
      for (final sUrl in streams) {
        final lower = sUrl.toLowerCase();
        final isM3u8 = lower.contains('.m3u8');
        final isAudio = lower.endsWith('.mp3') || lower.endsWith('.m4a');
        options.add(
          StreamQualityOption(
            id: 'web_$idx',
            label: isAudio
                ? 'Audio Stream $idx (MP3/M4A)'
                : (isM3u8
                    ? 'HLS Video Stream $idx (MP4)'
                    : (idx == 1 ? 'HD Video (MP4)' : 'Video Quality $idx (MP4)')),
            format: isAudio ? 'mp3' : 'mp4',
            downloadUrl: sUrl,
            isAudioOnly: isAudio,
          ),
        );
        idx++;
      }

      return AnalyzedMediaResult(
        originalUrl: urlStr,
        title: _cleanTitle(title) ?? 'Web Video',
        thumbnailUrl: thumb != null ? _unescapeUrl(thumb) : null,
        sourceType: MediaSourceType.genericWeb,
        qualityOptions: options,
      );
    } catch (_) {
      return AnalyzedMediaResult.unsupported(
        url: urlStr,
        reason:
            'ویب سائٹ سے معلومات حاصل کرنے میں رکاوٹ پیش آئی یا لنک درست نہیں ہے۔',
      );
    }
  }

  Future<AnalyzedMediaResult?> _analyzeTikTok(String url) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        'https://www.tikwm.com/api/',
        queryParameters: {'url': url, 'hd': 1},
      );
      final data = resp.data?['data'] as Map<String, dynamic>?;
      if (data != null) {
        final title = (data['title'] as String?) ?? 'TikTok Video';
        final cover = data['cover'] as String?;
        final durationSec = data['duration'] as int? ?? 0;
        final hdPlay = data['hdplay'] as String?;
        final play = data['play'] as String?;
        final music = data['music'] as String?;

        final options = <StreamQualityOption>[];
        if (hdPlay != null && hdPlay.isNotEmpty) {
          options.add(
            StreamQualityOption(
              id: 'tt_hd',
              label: 'HD No Watermark (MP4)',
              format: 'mp4',
              downloadUrl: hdPlay.startsWith('http')
                  ? hdPlay
                  : 'https://www.tikwm.com$hdPlay',
              estimatedSizeBytes: data['hd_size'] as int?,
            ),
          );
        }
        if (play != null && play.isNotEmpty) {
          options.add(
            StreamQualityOption(
              id: 'tt_sd',
              label: 'Standard No Watermark (MP4)',
              format: 'mp4',
              downloadUrl: play.startsWith('http')
                  ? play
                  : 'https://www.tikwm.com$play',
              estimatedSizeBytes: data['size'] as int?,
            ),
          );
        }
        if (music != null && music.isNotEmpty) {
          options.add(
            StreamQualityOption(
              id: 'tt_audio',
              label: 'Audio Only (MP3)',
              format: 'mp3',
              downloadUrl: music.startsWith('http')
                  ? music
                  : 'https://www.tikwm.com$music',
              isAudioOnly: true,
            ),
          );
        }
        if (options.isNotEmpty) {
          return AnalyzedMediaResult(
            originalUrl: url,
            title: title.trim().isEmpty ? 'TikTok Video' : title,
            thumbnailUrl: cover,
            duration: durationSec > 0 ? Duration(seconds: durationSec) : null,
            sourceType: MediaSourceType.genericWeb,
            qualityOptions: options,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<AnalyzedMediaResult?> _analyzeInstagram(Uri uri) async {
    final segments = uri.pathSegments;
    String? shortcode;
    for (int i = 0; i < segments.length - 1; i++) {
      final seg = segments[i].toLowerCase();
      if (seg == 'reel' || seg == 'reels' || seg == 'p' || seg == 'tv') {
        shortcode = segments[i + 1];
        break;
      }
    }

    final streams = <String>{};
    String? title;
    String? thumb;

    if (shortcode != null && shortcode.isNotEmpty) {
      try {
        final embedResp = await _dio.get<String>(
          'https://www.instagram.com/p/$shortcode/embed/captioned/',
          options: Options(
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Accept': 'text/html,application/xhtml+xml',
            },
          ),
        );
        final html = embedResp.data ?? '';
        final decoded = _unescapeUrl(html);
        for (final m in RegExp(r'"video_url"\s*:\s*"(https?:[^"]+)"')
            .allMatches(decoded)) {
          final vUrl = _unescapeUrl(m.group(1)!);
          if (_isValidMediaStreamUrl(vUrl)) streams.add(vUrl);
        }
        title ??= _extractMetaContent(html, 'og:title');
        thumb ??= _extractMetaContent(html, 'og:image');
      } catch (_) {}

      if (streams.isEmpty) {
        try {
          final ddResp = await _dio.get<String>(
            'https://d.ddinstagram.com/reel/$shortcode/',
            options: Options(
              headers: const {'User-Agent': 'TelegramBot (like TwitterBot)'},
            ),
          );
          final ddHtml = ddResp.data ?? '';
          final ogVid = _extractMetaContent(ddHtml, 'og:video') ??
              _extractMetaContent(ddHtml, 'og:video:secure_url');
          if (ogVid != null && ogVid.startsWith('http')) {
            streams.add(_unescapeUrl(ogVid));
          }
          title ??= _extractMetaContent(ddHtml, 'og:title');
          thumb ??= _extractMetaContent(ddHtml, 'og:image');
        } catch (_) {}
      }
    }

    if (streams.isNotEmpty) {
      return AnalyzedMediaResult(
        originalUrl: uri.toString(),
        title: _cleanTitle(title) ?? 'Instagram Video ${shortcode ?? ""}'.trim(),
        thumbnailUrl: thumb != null ? _unescapeUrl(thumb) : null,
        sourceType: MediaSourceType.genericWeb,
        qualityOptions: [
          for (int i = 0; i < streams.length; i++)
            StreamQualityOption(
              id: 'ig_${i + 1}',
              label: i == 0
                  ? 'HD Quality (MP4)'
                  : 'Standard Quality ${i + 1} (MP4)',
              format: 'mp4',
              downloadUrl: streams.elementAt(i),
            ),
        ],
      );
    }
    return null;
  }

  Future<AnalyzedMediaResult?> _analyzeTwitterX(Uri uri) async {
    try {
      final apiUri = Uri.https('api.vxtwitter.com', uri.path);
      final resp = await _dio.get<Map<String, dynamic>>(apiUri.toString());
      final data = resp.data;
      if (data != null && data['media_extended'] is List) {
        final mediaList = data['media_extended'] as List<dynamic>;
        final options = <StreamQualityOption>[];
        String? thumb;
        int idx = 1;
        for (final m in mediaList) {
          if (m is Map<String, dynamic>) {
            final type = m['type'] as String? ?? '';
            final url = m['url'] as String?;
            thumb ??= m['thumbnail_url'] as String?;
            if (url != null &&
                url.startsWith('http') &&
                (type == 'video' || type == 'gif' || url.contains('.mp4'))) {
              options.add(
                StreamQualityOption(
                  id: 'x_$idx',
                  label: 'HD Video $idx (MP4)',
                  format: 'mp4',
                  downloadUrl: url,
                ),
              );
              idx++;
            }
          }
        }
        if (options.isNotEmpty) {
          final text = (data['text'] as String?) ?? 'X / Twitter Video';
          return AnalyzedMediaResult(
            originalUrl: uri.toString(),
            title: text.length > 65 ? '${text.substring(0, 65)}...' : text,
            thumbnailUrl: thumb,
            sourceType: MediaSourceType.genericWeb,
            qualityOptions: options,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<AnalyzedMediaResult?> _analyzeVimeo(Uri uri) async {
    final idMatch = RegExp(r'(\d{6,})').firstMatch(uri.path);
    if (idMatch == null) return null;
    final videoId = idMatch.group(1)!;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        'https://player.vimeo.com/video/$videoId/config',
      );
      final data = resp.data;
      if (data == null) return null;
      final videoMeta = data['video'] as Map<String, dynamic>? ?? {};
      final title = (videoMeta['title'] as String?) ?? 'Vimeo Video $videoId';
      final progressive =
          data['request']?['files']?['progressive'] as List<dynamic>? ??
              const [];
      final options = <StreamQualityOption>[];
      for (final p in progressive) {
        if (p is Map<String, dynamic> && p['url'] is String) {
          final q = p['quality'] as String? ?? 'HD';
          options.add(
            StreamQualityOption(
              id: 'vimeo_$q',
              label: '$q (MP4)',
              format: 'mp4',
              downloadUrl: p['url'] as String,
            ),
          );
        }
      }
      if (options.isNotEmpty) {
        return AnalyzedMediaResult(
          originalUrl: uri.toString(),
          title: title,
          sourceType: MediaSourceType.genericWeb,
          qualityOptions: options,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<AnalyzedMediaResult?> _analyzeDailymotion(Uri uri) async {
    String? videoId;
    if (uri.host.contains('dai.ly') && uri.pathSegments.isNotEmpty) {
      videoId = uri.pathSegments.first;
    } else {
      final m = RegExp(r'/video/([a-zA-Z0-9]+)').firstMatch(uri.path);
      videoId = m?.group(1);
    }
    if (videoId == null) return null;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        'https://www.dailymotion.com/player/metadata/video/$videoId',
      );
      final data = resp.data;
      if (data == null) return null;
      final title = (data['title'] as String?) ?? 'Dailymotion Video';
      final qualities = data['qualities'] as Map<String, dynamic>? ?? {};
      final options = <StreamQualityOption>[];
      qualities.forEach((key, value) {
        if (value is List) {
          for (final item in value) {
            if (item is Map<String, dynamic> && item['url'] is String) {
              final u = item['url'] as String;
              final type = (item['type'] as String?) ?? '';
              final isMp4 = type.contains('mp4') || u.contains('.mp4');
              options.add(
                StreamQualityOption(
                  id: 'dm_${key}_${options.length}',
                  label: isMp4 ? '${key}p (MP4)' : '$key Stream (HLS/MP4)',
                  format: 'mp4',
                  downloadUrl: u,
                ),
              );
            }
          }
        }
      });
      if (options.isNotEmpty) {
        return AnalyzedMediaResult(
          originalUrl: uri.toString(),
          title: title,
          sourceType: MediaSourceType.genericWeb,
          qualityOptions: options,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<AnalyzedMediaResult?> _analyzeReddit(Uri uri) async {
    try {
      final cleanPath = uri.path.endsWith('/')
          ? uri.path.substring(0, uri.path.length - 1)
          : uri.path;
      final jsonUrl = 'https://www.reddit.com$cleanPath.json';
      final resp = await _dio.get<List<dynamic>>(
        jsonUrl,
        options: Options(
          headers: const {
            'User-Agent': 'Mozilla/5.0 MBAFastDownloader/1.0',
          },
        ),
      );
      final raw = jsonEncode(resp.data);
      final m =
          RegExp(r'"fallback_url"\s*:\s*"(https?:[^"]+)"').firstMatch(raw);
      if (m != null && m.group(1) != null) {
        final videoUrl = _unescapeUrl(m.group(1)!);
        final titleMatch = RegExp(r'"title"\s*:\s*"([^"]+)"').firstMatch(raw);
        return AnalyzedMediaResult(
          originalUrl: uri.toString(),
          title: titleMatch?.group(1) ?? 'Reddit Video',
          sourceType: MediaSourceType.genericWeb,
          qualityOptions: [
            StreamQualityOption(
              id: 'reddit_hd',
              label: 'HD Video (MP4)',
              format: 'mp4',
              downloadUrl: videoUrl,
            ),
          ],
        );
      }
    } catch (_) {}
    return null;
  }

  static void _extractGenericWebStreams(
      String html, Uri baseUri, Set<String> outStreams) {
    if (html.isEmpty) return;
    final decoded = _unescapeUrl(html);

    for (final prop in [
      'og:video:secure_url',
      'og:video:url',
      'og:video',
      'twitter:player:stream',
    ]) {
      final val = _extractMetaContent(html, prop);
      if (val != null) {
        final clean = _resolveRelativeUrl(_unescapeUrl(val), baseUri);
        if (_isValidMediaStreamUrl(clean)) {
          outStreams.add(clean);
        }
      }
    }

    final patterns = [
      RegExp(r'"contentUrl"\s*:\s*"(https?:[^"]+\.(?:mp4|webm|m3u8)[^"]*)"',
          caseSensitive: false),
      RegExp(r'"video_url"\s*:\s*"(https?:[^"]+)"', caseSensitive: false),
      RegExp(r'"playAddr"\s*:\s*"(https?:[^"]+)"', caseSensitive: false),
      RegExp(
          r'''(?:src|data-src|file)\s*=\s*["'](https?:[^"']+\.(?:mp4|webm|m3u8|mp3|m4a)[^"']*)["']''',
          caseSensitive: false),
      RegExp(
          r'''https?://[^"'\s<>\\]+\.(?:mp4|webm|m3u8)(?:\?[^"'\s<>\\]*)?''',
          caseSensitive: false),
    ];

    for (final p in patterns) {
      for (final m in p.allMatches(decoded)) {
        final raw = m.groupCount >= 1 ? m.group(1) : m.group(0);
        if (raw != null) {
          final clean = _resolveRelativeUrl(_unescapeUrl(raw), baseUri);
          if (_isValidMediaStreamUrl(clean)) {
            outStreams.add(clean);
          }
        }
      }
    }
  }
}

String _unescapeUrl(String input) {
  return input
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u0025', '%')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\u002F', '/')
      .replaceAll(r'\u002f', '/')
      .replaceAll(r'\u003D', '=')
      .replaceAll(r'\u003d', '=')
      .replaceAll(r'\u003F', '?')
      .replaceAll(r'\u003f', '?')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .trim();
}

bool _isValidMediaStreamUrl(String url) {
  if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
  final lower = url.toLowerCase();
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.css') ||
      lower.endsWith('.js')) {
    return false;
  }
  return true;
}

String _resolveRelativeUrl(String url, Uri baseUri) {
  if (url.startsWith('//')) {
    return '${baseUri.scheme}:$url';
  }
  if (url.startsWith('/')) {
    return '${baseUri.scheme}://${baseUri.host}$url';
  }
  return url;
}

String? _extractMetaContent(String html, String propertyOrName) {
  final escapedProp = RegExp.escape(propertyOrName);
  final patterns = [
    RegExp(
      '<meta[^>]+(?:property|name)=["\']$escapedProp["\'][^>]+content=["\']([^"\']+)["\']',
      caseSensitive: false,
    ),
    RegExp(
      '<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']$escapedProp["\']',
      caseSensitive: false,
    ),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(html);
    if (m != null && m.group(1) != null && m.group(1)!.trim().isNotEmpty) {
      return m.group(1)!.trim();
    }
  }
  return null;
}

String? _extractHtmlTitle(String html) {
  final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
      .firstMatch(html);
  return m?.group(1)?.trim();
}

String? _cleanTitle(String? raw) {
  if (raw == null) return null;
  final cleaned = raw
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? null : cleaned;
}

class SmartLinkAnalyzer {
  final List<SiteAdapter> _adapters;

  SmartLinkAnalyzer({ChunkedRangeDownloader? downloader})
      : _adapters = [
          DirectUrlAdapter(downloader ?? ChunkedRangeDownloader()),
          HlsDashStreamAdapter(),
          YouTubeSiteAdapter(),
          FacebookSiteAdapter(),
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
    if (host.contains('facebook.com') ||
        host.contains('fb.watch') ||
        host.contains('fb.com')) {
      return MediaSourceType.facebook;
    }
    return MediaSourceType.genericWeb;
  }

  Future<AnalyzedMediaResult> analyzeUrl(String rawUrl) async {
    var trimmed = rawUrl.trim();
    final urlMatch = RegExp(r'https?://[^\s"]+').firstMatch(trimmed);
    if (urlMatch != null) {
      trimmed = urlMatch.group(0)!;
    } else if (!trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://') &&
        trimmed.contains('.')) {
      trimmed = 'https://$trimmed';
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return AnalyzedMediaResult.unsupported(
        url: rawUrl,
        reason: 'براہِ کرم ایک درست ویب لنک درج کریں۔',
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
