import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/download_item.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../services/ffmpeg_and_share_service.dart';
import '../services/site_adapters.dart';

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
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('براہِ کرم پہلے ویڈیو یا فائل کا لنک پیسٹ کریں۔'),
        ),
      );
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analyzedMedia = null;
    });

    final analyzer = ref.read(smartLinkAnalyzerProvider);
    final result = await analyzer.analyzeUrl(url);

    if (!mounted) return;
    setState(() {
      _isAnalyzing = false;
      _analyzedMedia = result;
    });

    if (result.isSupported && result.qualityOptions.isNotEmpty) {
      _showQualitySelectionSheet(result);
    }
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
                              'دورانیہ: ${_formatDuration(media.duration!)} • ${media.sourceType.name.toUpperCase()}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                const Text(
                  'معیار اور فارمیٹ منتخب کریں (Select Quality / Audio Only):',
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
                          subtitle: Text('سائز: $sizeLabel • فارمیٹ: ${opt.format.toUpperCase()}'),
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
                                    'ڈاؤن لوڈ قطار میں شامل کر دیا گیا: ${media.title}',
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
            Icon(Icons.bolt_rounded, color: Colors.amber),
            SizedBox(width: 8),
            Text(
              'MBA Fast Downloader',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          const Chip(
            avatar: Icon(Icons.shield_outlined, size: 16),
            label: Text('100% Ad-Free'),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            hintText:
                                'لنک پیسٹ کریں (YouTube, Facebook, Direct MP4/WebM, HLS)...',
                            prefixIcon: const Icon(Icons.link_rounded),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            suffixIcon: IconButton(
                              tooltip: 'Paste from Clipboard',
                              icon: const Icon(Icons.content_paste_rounded),
                              onPressed: _pasteFromClipboard,
                            ),
                          ),
                          onSubmitted: (_) => _analyzeLink(),
                        ),
                      ),
                      const SizedBox(width: 12),
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
                            : const Icon(Icons.search_rounded),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            _isAnalyzing ? 'پہچان جاری...' : 'لنک چیک کریں',
                          ),
                        ),
                      ),
                    ],
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
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.12),
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
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.folder_open_rounded, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'محفوظ فولڈر: ${settings.saveDirectory.isEmpty ? "Default Downloads" : settings.saveDirectory}',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => ref
                            .read(appSettingsProvider.notifier)
                            .pickSaveDirectory(),
                        icon: const Icon(Icons.edit_folder_upload_rounded,
                            size: 18),
                        label: const Text('فولڈر بدلیں'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ڈاؤن لوڈ قطار اور جاری فائلیں (${activeTasks.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              Text(
                'متوازی کنکشنز: ${settings.maxParallelChunksPerFile}x • بیک وقت فائلیں: ${settings.maxConcurrentDownloads}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: activeTasks.isEmpty
                ? const Center(
                    child: Text(
                      'ابھی کوئی ڈاؤن لوڈ جاری نہیں ہے۔ اوپر لنک پیسٹ کر کے آغاز کریں۔',
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
                        '${task.qualityLabel} • ${task.formattedSize} • ${task.supportsRangeResume ? "${task.parallelChunks}x Fast Range" : "Single Stream"}',
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
                Text(
                  task.status == DownloadStatus.failed
                      ? 'خرابی: ${task.errorMessage ?? "Download failed"}'
                      : '${task.status.name.toUpperCase()} • ${task.formattedProgressPercent}',
                  style: TextStyle(
                    fontSize: 12,
                    color: task.status == DownloadStatus.failed
                        ? Colors.redAccent
                        : null,
                  ),
                ),
                Text(
                  'رفتار: ${task.formattedSpeed} • باقی وقت: ${task.formattedEta}',
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
        child: Text('ابھی تک کوئی فائل مکمل نہیں ہوئی۔'),
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
          title: const Text('ڈارک موڈ (Dark Mode)'),
          subtitle: const Text('سادہ، اشتہارات سے پاک اور آنکھوں کے لیے آرام دہ ڈیزائن'),
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
        const Divider(),
        ListTile(
          leading: const Icon(Icons.speed_rounded),
          title: Text(
            'متوازی ڈاؤن لوڈ حصے (Parallel Chunks per File): ${settings.maxParallelChunksPerFile}',
          ),
          subtitle: Slider(
            value: settings.maxParallelChunksPerFile.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: '${settings.maxParallelChunksPerFile} Chunks',
            onChanged: (val) => notifier.updateMaxParallelChunks(val.round()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.queue_play_next_rounded),
          title: Text(
            'بیک وقت ڈاؤن لوڈز کی تعداد (Max Concurrent Files): ${settings.maxConcurrentDownloads}',
          ),
          subtitle: Slider(
            value: settings.maxConcurrentDownloads.toDouble(),
            min: 1,
            max: 6,
            divisions: 5,
            label: '${settings.maxConcurrentDownloads} Files',
            onChanged: (val) => notifier.updateMaxConcurrent(val.round()),
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
