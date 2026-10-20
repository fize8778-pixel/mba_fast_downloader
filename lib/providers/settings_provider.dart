import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsState {
  final ThemeMode themeMode;
  final String saveDirectory;
  final bool unlimitedConcurrentDownloads;
  final int maxConcurrentDownloads;
  final int maxParallelChunksPerFile;
  final bool autoDetectClipboard;
  final String? lastDetectedClipboardUrl;

  const AppSettingsState({
    this.themeMode = ThemeMode.dark,
    this.saveDirectory = '',
    this.unlimitedConcurrentDownloads = true,
    this.maxConcurrentDownloads = 16,
    this.maxParallelChunksPerFile = 8,
    this.autoDetectClipboard = true,
    this.lastDetectedClipboardUrl,
  });

  AppSettingsState copyWith({
    ThemeMode? themeMode,
    String? saveDirectory,
    bool? unlimitedConcurrentDownloads,
    int? maxConcurrentDownloads,
    int? maxParallelChunksPerFile,
    bool? autoDetectClipboard,
    String? lastDetectedClipboardUrl,
  }) {
    return AppSettingsState(
      themeMode: themeMode ?? this.themeMode,
      saveDirectory: saveDirectory ?? this.saveDirectory,
      unlimitedConcurrentDownloads:
          unlimitedConcurrentDownloads ?? this.unlimitedConcurrentDownloads,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      maxParallelChunksPerFile:
          maxParallelChunksPerFile ?? this.maxParallelChunksPerFile,
      autoDetectClipboard: autoDetectClipboard ?? this.autoDetectClipboard,
      lastDetectedClipboardUrl:
          lastDetectedClipboardUrl ?? this.lastDetectedClipboardUrl,
    );
  }
}

class AppSettingsNotifier extends StateNotifier<AppSettingsState> {
  AppSettingsNotifier() : super(const AppSettingsState()) {
    _initSettings();
  }

  Future<void> _initSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode') ?? true;
    final savedDir = prefs.getString('save_directory');
    final unlimitedConc =
        prefs.getBool('unlimited_concurrent_downloads') ?? true;
    final maxConc = prefs.getInt('max_concurrent_downloads') ?? 16;
    final maxChunks = prefs.getInt('max_parallel_chunks') ?? 8;
    final autoClip = prefs.getBool('auto_detect_clipboard') ?? true;

    String defaultDir = savedDir ?? '';
    if (defaultDir.isEmpty) {
      defaultDir = await _resolveDefaultDownloadDirectory();
    }

    state = state.copyWith(
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      saveDirectory: defaultDir,
      unlimitedConcurrentDownloads: unlimitedConc,
      maxConcurrentDownloads: maxConc.clamp(1, 50),
      maxParallelChunksPerFile: maxChunks.clamp(1, 16),
      autoDetectClipboard: autoClip,
    );
  }

  Future<String> _resolveDefaultDownloadDirectory() async {
    try {
      if (Platform.isWindows) {
        final dir = await getDownloadsDirectory();
        if (dir != null) {
          final mbaDir = Directory('${dir.path}\\MBA_Downloads');
          if (!await mbaDir.exists()) {
            await mbaDir.create(recursive: true);
          }
          return mbaDir.path;
        }
      } else if (Platform.isAndroid) {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final mbaDir = Directory('${extDir.path}/MBA_Downloads');
          if (!await mbaDir.exists()) {
            await mbaDir.create(recursive: true);
          }
          return mbaDir.path;
        }
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<void> toggleThemeMode() async {
    final nextMode =
        state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    state = state.copyWith(themeMode: nextMode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', nextMode == ThemeMode.dark);
  }

  Future<String?> pickSaveDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Download Save Folder',
    );
    if (selected != null && selected.isNotEmpty) {
      state = state.copyWith(saveDirectory: selected);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('save_directory', selected);
      return selected;
    }
    return null;
  }

  Future<void> setUnlimitedConcurrentDownloads(bool unlimited) async {
    state = state.copyWith(unlimitedConcurrentDownloads: unlimited);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('unlimited_concurrent_downloads', unlimited);
  }

  Future<void> updateMaxConcurrent(int count) async {
    final clamped = count.clamp(1, 50);
    state = state.copyWith(maxConcurrentDownloads: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('max_concurrent_downloads', clamped);
  }

  Future<void> updateMaxParallelChunks(int chunks) async {
    final clamped = chunks.clamp(1, 16);
    state = state.copyWith(maxParallelChunksPerFile: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('max_parallel_chunks', clamped);
  }

  Future<void> setAutoDetectClipboard(bool enabled) async {
    state = state.copyWith(autoDetectClipboard: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_detect_clipboard', enabled);
  }

  Future<String?> checkClipboardForMediaUrl() async {
    if (!state.autoDetectClipboard) return null;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (_isValidHttpUrl(text) && text != state.lastDetectedClipboardUrl) {
        state = state.copyWith(lastDetectedClipboardUrl: text);
        return text;
      }
    } catch (_) {}
    return null;
  }

  static bool _isValidHttpUrl(String input) {
    final uri = Uri.tryParse(input);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettingsState>(
  (ref) => AppSettingsNotifier(),
);
