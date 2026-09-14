import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:irblaster_controller/app_update/app_update_service.dart';
import 'package:irblaster_controller/l10n/l10n.dart';

/// What the screen is doing right now.
enum _Phase { idle, checking, upToDate, available, downloading, ready, failed }

String _formatBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key, this.autoStart = true});

  /// Start checking as soon as the screen opens.
  final bool autoStart;

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  final AppUpdateService _service = AppUpdateService();

  _Phase _phase = _Phase.idle;
  UpdateCheck? _check;
  UpdateException? _error;
  File? _downloaded;
  CancellationToken? _cancel;
  int _received = 0;
  int _total = 0;
  bool _autoCheck = true;

  @override
  void initState() {
    super.initState();
    AppUpdateService.autoCheckEnabled().then((value) {
      if (mounted) setState(() => _autoCheck = value);
    });
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runCheck());
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _runCheck() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _downloaded = null;
    });
    try {
      final result = await _service.check();
      if (!mounted) return;
      setState(() {
        _check = result;
        _phase = result.hasUpdate ? _Phase.available : _Phase.upToDate;
      });
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.failed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = UpdateException(UpdateErrorKind.network, e.toString());
        _phase = _Phase.failed;
      });
    }
  }

  Future<void> _runDownload() async {
    final release = _check?.release;
    if (release == null) return;

    final token = CancellationToken();
    setState(() {
      _phase = _Phase.downloading;
      _cancel = token;
      _received = 0;
      _total = release.apkSize;
      _error = null;
    });

    try {
      final file = await _service.download(
        release,
        cancel: token,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloaded = file;
        _phase = _Phase.ready;
      });
      await _runInstall();
    } on UpdateException catch (e) {
      if (!mounted) return;
      if (token.isCancelled) {
        setState(() => _phase = _Phase.available);
        return;
      }
      setState(() {
        _error = e;
        _phase = _Phase.failed;
      });
    }
  }

  Future<void> _runInstall() async {
    final file = _downloaded;
    if (file == null) return;

    if (!await _service.canInstall()) {
      if (!mounted) return;
      final granted = await _promptForInstallPermission();
      if (!granted) return;
    }

    try {
      await _service.install(file);
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.failed;
      });
    }
  }

  /// Explains why Android is blocking the install and offers to open the
  /// settings page. Returns true if the user came back with the grant.
  Future<bool> _promptForInstallPermission() async {
    final l10n = context.l10n;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.updatesPermissionTitle),
        content: Text(l10n.updatesPermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.updatesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.updatesOpenSettings),
          ),
        ],
      ),
    );
    if (open != true) return false;
    await _service.openInstallSettings();
    // The grant happens in another app, so re-check rather than assume.
    return _service.canInstall();
  }

  String _errorText(BuildContext context) {
    final l10n = context.l10n;
    return switch (_error?.kind) {
      UpdateErrorKind.rateLimited => l10n.updatesRateLimited,
      UpdateErrorKind.noRelease => l10n.updatesNoRelease,
      UpdateErrorKind.noAsset => l10n.updatesNoAsset,
      UpdateErrorKind.install => l10n.updatesInstallFailed,
      UpdateErrorKind.network => l10n.updatesCheckFailed,
      null => l10n.updatesCheckFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final release = _check?.release;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.updatesTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        switch (_phase) {
                          _Phase.upToDate => Icons.check_circle_outline,
                          _Phase.failed => Icons.error_outline,
                          _Phase.available ||
                          _Phase.downloading ||
                          _Phase.ready =>
                            Icons.system_update,
                          _ => Icons.sync,
                        },
                        color: _phase == _Phase.failed ? cs.error : cs.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          switch (_phase) {
                            _Phase.checking => l10n.updatesChecking,
                            _Phase.upToDate => l10n.updatesUpToDate,
                            _Phase.available => l10n.updatesAvailable,
                            _Phase.downloading => l10n.updatesDownloading,
                            _Phase.ready => l10n.updatesReadyToInstall,
                            _Phase.failed => _errorText(context),
                            _Phase.idle => l10n.updatesCheckNow,
                          },
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  if (_check != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${l10n.updatesInstalledVersion}: ${_check!.currentVersion}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (release != null)
                      Text(
                        '${l10n.updatesNewVersion}: ${release.version}'
                        '${release.apkSize > 0 ? '  ·  ${_formatBytes(release.apkSize)}' : ''}',
                        style: theme.textTheme.bodyMedium,
                      ),
                  ],
                  if (_phase == _Phase.failed && _error?.detail != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!.detail!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  if (_phase == _Phase.downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _total > 0 ? _received / _total : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _total > 0
                          ? '${_formatBytes(_received)} / ${_formatBytes(_total)}'
                          : _formatBytes(_received),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_phase == _Phase.available)
                        FilledButton.icon(
                          onPressed: _runDownload,
                          icon: const Icon(Icons.download),
                          label: Text(l10n.updatesDownloadInstall),
                        ),
                      if (_phase == _Phase.ready)
                        FilledButton.icon(
                          onPressed: _runInstall,
                          icon: const Icon(Icons.install_mobile),
                          label: Text(l10n.updatesInstall),
                        ),
                      if (_phase == _Phase.downloading)
                        OutlinedButton(
                          onPressed: () {
                            _cancel?.cancel();
                          },
                          child: Text(l10n.updatesCancel),
                        ),
                      if (_phase == _Phase.upToDate ||
                          _phase == _Phase.failed ||
                          _phase == _Phase.idle)
                        OutlinedButton.icon(
                          onPressed: _runCheck,
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.updatesCheckNow),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (release != null && release.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.updatesReleaseNotes,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      release.notes,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              value: _autoCheck,
              title: Text(l10n.updatesAutoCheck),
              subtitle: Text(l10n.updatesAutoCheckSubtitle),
              onChanged: (value) async {
                setState(() => _autoCheck = value);
                await AppUpdateService.setAutoCheckEnabled(value);
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l10n.updatesSourceNote,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps the app so a startup check can surface an update without blocking
/// anything. It only ever shows a snack bar; installing stays explicit.
class UpdateWatcher extends StatefulWidget {
  const UpdateWatcher({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends State<UpdateWatcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheck());
  }

  Future<void> _maybeCheck() async {
    if (!await AppUpdateService.autoCheckEnabled()) return;
    UpdateCheck result;
    try {
      result = await AppUpdateService().check();
    } catch (_) {
      // A background check must never interrupt startup.
      return;
    }
    if (!mounted || !result.hasUpdate) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = context.l10n;
    messenger.showSnackBar(
      SnackBar(
        content: Text('${l10n.updatesAvailable}  ${result.release!.version}'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: l10n.updatesView,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AppUpdateScreen(),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
