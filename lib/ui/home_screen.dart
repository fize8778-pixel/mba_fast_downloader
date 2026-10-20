import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/download_item.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../services/ffmpeg_and_share_service.dart';
import '../services/site_adapters.dart';

/// Professional custom vector-style App Icon widget matching MBA Fast Downloader's launcher icon:
/// Deep emerald-teal & navy squircle with glowing cyan rim, download arrow, play triangle & golden bolt.
class MbaBrandLogoIcon extends StatelessWidget {
  final double size;
  const MbaBrandLogoIcon({super.key, this.size = 38});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF00695C),
            Color(0xFF00363A),
            Color(0xFF06162E),
          ],
        ),
        border: Border.all(
          color: const Color(0xFF00E5FF),
          width: (size * 0.045).clamp(1.2, 2.5),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4000E5FF),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.download_rounded,
            color: const Color(0xFF00E5FF),
            size: size * 0.68,
          ),
          Positioned(
            top: size * 0.14,
            child: Icon(
              Icons.play_arrow_rounded,
              color: const Color(0xFFFFD54F),
              size: size * 0.30,
            ),
          ),
          Positioned(
            right: size * 0.08,
            bottom: size * 0.10,
            child: Icon(
              Icons.bolt_rounded,
              color: const Color(0xFFFFC107),
              size: size * 0.42,
            ),
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  int _selectedIndex = 0;
  String? _clipboardSuggestion;
  bool _isAnalyzing = false;
  AnalyzedMediaResult? _analyzedMedia;

  static const String developerName = 'Muhammad Bin Amjad';
  static const String brandName = 'Digital RAZ';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboard();
      _initAndroidShareReceiver();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  Future<void> _initAndroidShareReceiver() async {
    final initialUrl = await ShareIntentService.getInitialSharedUrl();
    if (initialUrl != null && mounted) {
      _urlController.text = initialUrl;
      _analyzeLink();
    }
    ShareIntentService.listenForSharedUrls((sharedUrl) {
      if (!mounted) return;
      setState(() {
        _selectedIndex = 0;
        _urlController.text = sharedUrl;
      });
      _analyzeLink();
    });
  }

  Future<void> _checkClipboard() async {
    final detected = await ref
        .read(appSettingsProvider.notifier)
        .checkClipboardForMediaUrl();
    if (detected != null && mounted && _urlController.text.isEmpty) {
      setState(() {
        _clipboardSuggestion = detected;
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _urlController.text = data.text!.trim();
        _clipboardSuggestion = null;
      });
      _analyzeLink();
    }
  }

  Future<void> _analyzeLink() async {
    final rawText = _urlController.text.trim();
    if (rawText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'براہِ کرم پہلے ویڈیو یا فائل کا لنک پیسٹ کریں۔',
            textDirection: TextDirection.rtl,
          ),
        ),
      );
      return;
    }

    // Check if user pasted multiple URLs at once for simultaneous batch downloading
    final allUrls = RegExp(r'https?://[^\s"]+')
        .allMatches(rawText)
        .map((m) => m.group(0)!)
        .toList();

    if (allUrls.length > 1) {
      setState(() {
        _isAnalyzing = true;
        _analyzedMedia = null;
      });
      final added = await ref
          .read(downloadQueueProvider.notifier)
          .enqueueBatchUrls(allUrls);
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
      });
      if (added > 0) {
        _urlController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'ایک ساتھ $added ویڈیوز کی ڈاؤن لوڈنگ شروع کر دی گئی ہے!',
              textDirection: TextDirection.rtl,
            ),
          ),
        );
      }
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analyzedMedia = null;
    });

    final analyzer = ref.read(smartLinkAnalyzerProvider);
    final result = await analyzer.analyzeUrl(rawText);

    if (!mounted) return;
    setState(() {
      _isAnalyzing = false;
      _analyzedMedia = result;
    });

    if (result.isSupported && result.qualityOptions.isNotEmpty) {
      _showQualitySelectionSheet(result);
    }
  }

  void _showAboutDeveloperDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Row(
            children: [
              MbaBrandLogoIcon(size: 40),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'MBA Fast Downloader',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'تیز رفتار، اشتہارات سے پاک اور لا محدود بیک وقت ڈاؤن لوڈنگ کی سہولت کے ساتھ ملٹی پلیٹ فارم ویڈیو اور فائل ڈاؤن لوڈر۔',
                textDirection: TextDirection.rtl,
              ),
              SizedBox(height: 16),
              Divider(),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.person_rounded, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Developer: Muhammad Bin Amjad',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.verified_rounded, size: 20, color: Colors.teal),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Brand: Digital RAZ',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.all_inclusive_rounded, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Mode: Unlimited Simultaneous Downloads'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('ٹھیک ہے'),
            ),
          ],
        );
      },
    );
  }

  void _showQualitySelectionSheet(AnalyzedMediaResult media) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      _iconForSource(media.sourceType),
                      size: 28,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            media.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (media.duration != null)
                            Text(
                              'Duration: ${_formatDuration(media.duration!)} • ${media.sourceType.name.toUpperCase()}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                const Text(
                  'معیار اور فارمیٹ منتخب کریں:',
                  textDirection: TextDirection.rtl,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: media.qualityOptions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final opt = media.qualityOptions[idx];
                      final sizeLabel = opt.estimatedSizeBytes != null &&
                              opt.estimatedSizeBytes! > 0
                          ? '${(opt.estimatedSizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB'
                          : 'Auto Size';
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: Icon(
                            opt.isAudioOnly
                                ? Icons.audiotrack_rounded
                                : Icons.hd_rounded,
                            color: opt.isAudioOnly
                                ? Colors.orange
                                : Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(
                            opt.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'Size: $sizeLabel • Format: ${opt.format.toUpperCase()}',
                          ),
                          trailing: FilledButton.icon(
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: const Text('ڈاؤن لوڈ'),
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              ref
                                  .read(downloadQueueProvider.notifier)
                                  .enqueueDownload(
                                    media: media,
                                    selectedQuality: opt,
                                  );
                              _urlController.clear();
                              setState(() {
                                _analyzedMedia = null;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'ڈاؤن لوڈ فوری شروع ہو گیا: ${media.title}',
                                    textDirection: TextDirection.rtl,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final downloads = ref.watch(downloadQueueProvider);
    final isWideScreen = MediaQuery.of(context).size.width >= 720;

    final activeTasks = downloads
        .where((d) => d.status != DownloadStatus.completed)
        .toList();
    final completedTasks = downloads
        .where((d) => d.status == DownloadStatus.completed)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            MbaBrandLogoIcon(size: 36),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'MBA Fast Downloader',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Digital RAZ • Muhammad Bin Amjad',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (isWideScreen)
            const Chip(
              avatar: Icon(Icons.all_inclusive_rounded, size: 16),
              label: Text('Unlimited • 100% Ad-Free'),
              visualDensity: VisualDensity.compact,
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'About Developer ($developerName - $brandName)',
            onPressed: _showAboutDeveloperDialog,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          IconButton(
            tooltip: 'Toggle Dark / Light Mode',
            onPressed: () =>
                ref.read(appSettingsProvider.notifier).toggleThemeMode(),
            icon: Icon(
              settings.themeMode == ThemeMode.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          if (isWideScreen)
            NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (idx) =>
                  setState(() => _selectedIndex = idx),
              labelType: NavigationRailLabelType.all,
              destinations: [
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: activeTasks.isNotEmpty,
                    label: Text('${activeTasks.length}'),
                    child: const Icon(Icons.downloading_rounded),
                  ),
                  label: const Text('ڈاؤن لوڈز'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: completedTasks.isNotEmpty,
                    label: Text('${completedTasks.length}'),
                    child: const Icon(Icons.history_rounded),
                  ),
                  label: const Text('ہسٹری'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.settings_rounded),
                  label: Text('سیٹنگز'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildActiveDownloadsTab(settings, activeTasks),
                _buildHistoryTab(completedTasks),
                _buildSettingsTab(settings),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: isWideScreen
          ? null
          : NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (idx) =>
                  setState(() => _selectedIndex = idx),
              destinations: [
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: activeTasks.isNotEmpty,
                    label: Text('${activeTasks.length}'),
                    child: const Icon(Icons.downloading_rounded),
                  ),
                  label: 'ڈاؤن لوڈز',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: completedTasks.isNotEmpty,
                    label: Text('${completedTasks.length}'),
                    child: const Icon(Icons.history_rounded),
                  ),
                  label: 'ہسٹری',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_rounded),
                  label: 'سیٹنگز',
                ),
              ],
            ),
    );
  }

  Widget _buildActiveDownloadsTab(
      AppSettingsState settings, List<DownloadTaskItem> activeTasks) {
    final queueLabel = settings.unlimitedConcurrentDownloads
        ? 'Unlimited (لا محدود)'
        : 'Max ${settings.maxConcurrentDownloads}';

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(14.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _urlController,
                    textDirection: TextDirection.ltr,
                    maxLines: 2,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText:
                          'Paste 1 or multiple video links (YouTube, FB, TikTok, Instagram, X, MP4)...',
                      prefixIcon: const Icon(Icons.link_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_urlController.text.isNotEmpty)
                            IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () => setState(() {
                                _urlController.clear();
                                _analyzedMedia = null;
                              }),
                            ),
                          IconButton(
                            tooltip: 'Paste from Clipboard',
                            icon: const Icon(Icons.content_paste_rounded),
                            onPressed: _pasteFromClipboard,
                          ),
                        ],
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _analyzeLink(),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _isAnalyzing ? null : _analyzeLink,
                    icon: _isAnalyzing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.bolt_rounded),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _isAnalyzing
                            ? 'ویڈیو لنک چیک ہو رہا ہے...'
                            : 'لنک چیک کریں اور ڈاؤن لوڈ کریں',
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  if (_clipboardSuggestion != null) ...[
                    const SizedBox(height: 10),
                    MaterialBanner(
                      content: Text(
                        'کلپ بورڈ میں نیا لنک ملا ہے: $_clipboardSuggestion',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      leading: const Icon(Icons.paste_rounded),
                      actions: [
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _urlController.text = _clipboardSuggestion!;
                              _clipboardSuggestion = null;
                            });
                            _analyzeLink();
                          },
                          child: const Text('پیسٹ اور چیک کریں'),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _clipboardSuggestion = null),
                          child: const Text('نظر انداز'),
                        ),
                      ],
                    ),
                  ],
                  if (_analyzedMedia != null && !_analyzedMedia!.isSupported) ...[
                    const SizedBox(height: 12),
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x1FFF5252),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.redAccent),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                color: Colors.redAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _analyzedMedia!.unsupportedReason ??
                                    'یہ لنک ڈاؤن لوڈ کے لیے معاون نہیں ہے۔',
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.folder_open_rounded, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Save Folder: ${settings.saveDirectory.isEmpty ? "Default Downloads" : settings.saveDirectory}',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => ref
                            .read(appSettingsProvider.notifier)
                            .pickSaveDirectory(),
                        icon: const Icon(Icons.create_new_folder_rounded,
                            size: 18),
                        label: const Text('فولڈر بدلیں'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                'جاری ڈاؤن لوڈز (${activeTasks.length})',
                textDirection: TextDirection.rtl,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (activeTasks.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: () => ref
                          .read(downloadQueueProvider.notifier)
                          .resumeAllDownloads(),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('سب چلائیں'),
                    ),
                    TextButton.icon(
                      onPressed: () => ref
                          .read(downloadQueueProvider.notifier)
                          .pauseAllDownloads(),
                      icon: const Icon(Icons.pause_rounded, size: 18),
                      label: const Text('سب روکیں'),
                    ),
                  ],
                  Text(
                    'Speed: ${settings.maxParallelChunksPerFile}x • Mode: $queueLabel',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: activeTasks.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MbaBrandLogoIcon(size: 56),
                        SizedBox(height: 12),
                        Text(
                          'ابھی کوئی ڈاؤن لوڈ جاری نہیں ہے۔ ایک یا بیک وقت جتنے چاہیں لنکس پیسٹ کر کے ڈاؤن لوڈ کریں۔',
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: activeTasks.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final task = activeTasks[index];
                      return _buildTaskCard(task);
                    },
                  ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Powered by Digital RAZ • Developed by Muhammad Bin Amjad',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(DownloadTaskItem task) {
    final notifier = ref.read(downloadQueueProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  task.isAudioOnly
                      ? Icons.audiotrack_rounded
                      : _iconForSource(task.sourceType),
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${task.qualityLabel} • ${task.formattedSize} • ${task.supportsRangeResume ? "${task.parallelChunks}x Fast Range" : "Direct Stream"}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (task.status == DownloadStatus.downloading)
                  IconButton(
                    tooltip: 'Pause (روکیں)',
                    icon: const Icon(Icons.pause_circle_filled_rounded),
                    onPressed: () => notifier.pauseDownload(task.id),
                  )
                else if (task.status == DownloadStatus.paused ||
                    task.status == DownloadStatus.failed)
                  IconButton(
                    tooltip: 'Resume / Retry (دوبارہ شروع کریں)',
                    icon: const Icon(Icons.play_circle_fill_rounded),
                    onPressed: () => notifier.resumeDownload(task.id),
                  ),
                IconButton(
                  tooltip: 'Cancel & Remove (ختم کریں)',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => notifier.removeTask(task.id),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: task.status == DownloadStatus.analyzing
                  ? null
                  : task.progress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(6),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    task.status == DownloadStatus.failed
                        ? 'Error: ${task.errorMessage ?? "Download failed"}'
                        : '${task.status.name.toUpperCase()} • ${task.formattedProgressPercent}',
                    style: TextStyle(
                      fontSize: 12,
                      color: task.status == DownloadStatus.failed
                          ? Colors.redAccent
                          : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${task.formattedSpeed} • ETA: ${task.formattedEta}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTab(List<DownloadTaskItem> completedTasks) {
    final notifier = ref.read(downloadQueueProvider.notifier);
    if (completedTasks.isEmpty) {
      return const Center(
        child: Text(
          'ابھی تک کوئی فائل مکمل نہیں ہوئی۔',
          textDirection: TextDirection.rtl,
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'مکمل شدہ ڈاؤن لوڈ ہسٹری (${completedTasks.length})',
                textDirection: TextDirection.rtl,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextButton.icon(
                onPressed: () => notifier.clearCompletedHistory(),
                icon: const Icon(Icons.clear_all_rounded),
                label: const Text('ہسٹری صاف کریں'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: completedTasks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = completedTasks[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_rounded,
                      color: Colors.green),
                  title: Text(item.title),
                  subtitle: Text(
                    '${item.qualityLabel} • ${item.formattedSize}\n${item.savePath}/${item.fileName}',
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Open Folder',
                        icon: const Icon(Icons.folder_open_rounded),
                        onPressed: () => notifier.openSavedFolder(item),
                      ),
                      IconButton(
                        tooltip: 'Remove from History',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => notifier.removeTask(item.id),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab(AppSettingsState settings) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.all_inclusive_rounded),
          title: const Text(
            'ان لمیٹڈ بیک وقت ڈاؤن لوڈز (Unlimited Simultaneous Downloads)',
          ),
          subtitle: const Text(
            'فعال ہونے پر جتنی بھی ویڈیوز لگائیں گے وہ سب ایک ہی وقت میں بغیر انتظار کے ڈاؤن لوڈ ہوں گی',
          ),
          value: settings.unlimitedConcurrentDownloads,
          onChanged: (v) => notifier.setUnlimitedConcurrentDownloads(v),
        ),
        const Divider(),
        if (!settings.unlimitedConcurrentDownloads) ...[
          ListTile(
            leading: const Icon(Icons.queue_play_next_rounded),
            title: Text(
              'بیک وقت ڈاؤن لوڈز کی زیادہ سے زیادہ تعداد: ${settings.maxConcurrentDownloads} فائلیں',
            ),
            subtitle: Slider(
              value: settings.maxConcurrentDownloads.toDouble(),
              min: 1,
              max: 50,
              divisions: 49,
              label: '${settings.maxConcurrentDownloads} Files',
              onChanged: (val) => notifier.updateMaxConcurrent(val.round()),
            ),
          ),
          const Divider(),
        ],
        ListTile(
          leading: const Icon(Icons.speed_rounded),
          title: Text(
            'فی فائل متوازی رفتار کنکشنز (Parallel Speed Chunks): ${settings.maxParallelChunksPerFile}x',
          ),
          subtitle: Slider(
            value: settings.maxParallelChunksPerFile.toDouble(),
            min: 1,
            max: 16,
            divisions: 15,
            label: '${settings.maxParallelChunksPerFile}x Chunks',
            onChanged: (val) => notifier.updateMaxParallelChunks(val.round()),
          ),
        ),
        const Divider(),
        SwitchListTile(
          title: const Text('ڈارک موڈ (Dark Mode)'),
          subtitle: const Text(
              'سادہ، اشتہارات سے پاک اور آنکھوں کے لیے آرام دہ ڈیزائن'),
          value: settings.themeMode == ThemeMode.dark,
          onChanged: (_) => notifier.toggleThemeMode(),
        ),
        const Divider(),
        SwitchListTile(
          title: const Text('خودکار کلپ بورڈ شناخت (Clipboard Detection)'),
          subtitle: const Text('لنک کاپی کرنے پر خودکار پہچاننے کی سہولت'),
          value: settings.autoDetectClipboard,
          onChanged: (v) => notifier.setAutoDetectClipboard(v),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.folder_rounded),
          title: const Text('ڈاؤن لوڈ محفوظ کرنے کا فولڈر (Save Folder)'),
          subtitle: Text(settings.saveDirectory),
          trailing: OutlinedButton(
            onPressed: () => notifier.pickSaveDirectory(),
            child: const Text('فولڈر بدلیں'),
          ),
        ),
        const Divider(height: 32),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    MbaBrandLogoIcon(size: 32),
                    SizedBox(width: 10),
                    Text(
                      'ڈویلپر اور برانڈ (Developer & Brand)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Text(
                  'Creator: Muhammad Bin Amjad',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  'Brand: Digital RAZ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  'Edition: MBA Fast Downloader v1.2.0 (Unlimited Edition • 100% Ad-Free)',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static IconData _iconForSource(MediaSourceType type) {
    switch (type) {
      case MediaSourceType.youtube:
        return Icons.ondemand_video_rounded;
      case MediaSourceType.facebook:
        return Icons.public_rounded;
      case MediaSourceType.hlsDash:
        return Icons.stream_rounded;
      case MediaSourceType.directFile:
        return Icons.video_file_rounded;
      case MediaSourceType.genericWeb:
        return Icons.language_rounded;
      case MediaSourceType.unsupportedDrm:
        return Icons.lock_outline_rounded;
    }
  }

  static String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
