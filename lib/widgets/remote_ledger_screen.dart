import 'package:flutter/material.dart';
import 'package:swiftremote/github_store/github_store_service.dart';
import 'package:swiftremote/github_store/models.dart';
import 'package:swiftremote/github_store/remote_ledger_index.dart';
import 'package:swiftremote/l10n/l10n.dart';
import 'package:swiftremote/state/remotes_state.dart';
import 'package:swiftremote/utils/remote.dart';
import 'package:swiftremote/utils/remotes_io.dart';
import 'package:swiftremote/widgets/remote_view.dart';

String _describeStoreError(Object error) {
  if (error is GitHubRateLimitException) {
    final resetAt = error.resetAt;
    if (resetAt == null) {
      return 'GitHub API rate limit reached. Try again later.';
    }
    final local = resetAt.toLocal();
    final hh = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final mm = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour >= 12 ? 'PM' : 'AM';
    final month = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ][local.month - 1];
    final when = '$month ${local.day}, $hh:$mm $ampm';
    return 'GitHub API rate limit reached. Try again after $when.';
  }
  return error.toString().replaceFirst('Exception: ', '');
}

/// Remote Ledger, the only place the app takes remotes from. Search its index
/// by device, model or maker, or browse its compiled remotes by folder, then
/// preview a remote and import it. There is no way to point it elsewhere: the
/// repository is fixed in [GitHubStoreService].
class RemoteLedgerScreen extends StatefulWidget {
  const RemoteLedgerScreen({super.key, this.ledgerService, this.storeService});

  /// Where searches get the index. Null uses the network, as the app does;
  /// tests hand in one that serves a fixture.
  final RemoteLedgerIndexService? ledgerService;

  /// Where the folder browser and the import preview read files. Null uses
  /// GitHub, as the app does; tests hand in one backed by a fixture client.
  final GitHubStoreService? storeService;

  @override
  State<RemoteLedgerScreen> createState() => _RemoteLedgerScreenState();
}

class _RemoteLedgerScreenState extends State<RemoteLedgerScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  late final GitHubStoreService _service =
      widget.storeService ?? GitHubStoreService();

  String _currentPath = kRemoteLedgerBrowseRoot;
  List<RepoItem> _items = const <RepoItem>[];
  bool _loading = false;
  String? _error;
  bool _hasLoadedDirectory = false;
  bool _hasAttemptedLoad = false;

  /// Remote Ledger's own index, which the search box searches.
  late final RemoteLedgerIndexService _ledgerService =
      widget.ledgerService ?? RemoteLedgerIndexService();
  RemoteLedgerIndex? _ledger;
  bool _ledgerLoading = false;
  String? _ledgerError;

  /// How many matching remotes one search lists, as the ledger's site does.
  static const int _ledgerResultsShown = 50;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _canNavigateUp =>
      _currentPath.length > kRemoteLedgerBrowseRoot.length;

  Future<void> _loadDirectory({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _hasAttemptedLoad = true;
    });
    try {
      final items = await _service.listDirectory(
        _currentPath,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _hasLoadedDirectory = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeStoreError(e);
        _hasLoadedDirectory = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _navigateUp() async {
    if (!_canNavigateUp) return;
    setState(() {
      _currentPath = _currentPath.substring(0, _currentPath.lastIndexOf('/'));
      _searchCtrl.clear();
    });
    await _loadDirectory();
  }

  Future<void> _openItem(RepoItem item) async {
    if (item.type == RepoItemType.dir) {
      setState(() {
        _currentPath = item.path;
        _searchCtrl.clear();
      });
      await _loadDirectory();
      return;
    }
    if (!isSupportedImportFilename(item.name)) {
      _showSnack('This file type is not supported for import.');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RemoteFileImportScreen(
          item: item,
          service: _service,
        ),
      ),
    );
  }

  void _onSearchChanged(String value) {
    setState(() {});
    if (value.trim().isNotEmpty && _ledger == null && !_ledgerLoading) {
      _loadLedgerIndex();
    }
  }

  Future<void> _loadLedgerIndex({bool forceRefresh = false}) async {
    setState(() {
      _ledgerLoading = true;
      _ledgerError = null;
    });
    try {
      final index = await _ledgerService.load(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() => _ledger = index);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ledgerError = 'Could not load the Remote Ledger index. Check the '
            'connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _ledgerLoading = false);
    }
  }

  Future<void> _openLedgerRemote(RemoteLedgerEntry entry) {
    return _openItem(
      RepoItem(
        type: RepoItemType.file,
        name: entry.fileName,
        path: entry.artifact,
      ),
    );
  }

  Widget _ledgerSearchResults(ThemeData theme, String query) {
    final ledger = _ledger;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (ledger == null) {
      if (_ledgerError != null) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _ledgerError!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _ledgerLoading ? null : _loadLedgerIndex,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final result = ledger.search(query);
    if (result.remotes.isEmpty && result.unresolved.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            // The ledger's third state: not "no remote exists" but "nobody
            // has looked", which is worth saying so it is not mistaken for
            // the other.
            'Nothing in Remote Ledger matches "$query", and nobody has '
            'recorded looking for it either.',
            style: muted,
          ),
        ),
      );
    }

    final shown = result.remotes.take(_ledgerResultsShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            result.remotes.length > shown.length
                ? 'Showing ${shown.length} of ${result.remotes.length} '
                    'remotes. Refine the search to see the rest.'
                : '${result.remotes.length} '
                    '${result.remotes.length == 1 ? 'remote' : 'remotes'} '
                    'in Remote Ledger',
            style: muted,
          ),
        ),
        if (shown.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  ListTile(
                    leading: Icon(
                      shown[i].importedFrom == null
                          ? Icons.verified_outlined
                          : Icons.settings_remote_outlined,
                    ),
                    title: Text(shown[i].title),
                    subtitle: Text(
                      _ledgerEntryDetail(shown[i]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _openLedgerRemote(shown[i]),
                  ),
                  if (i != shown.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        for (final device in result.unresolved)
          Card(
            child: ListTile(
              leading: const Icon(Icons.help_outline_rounded),
              title: Text(device.device),
              subtitle: Text(
                device.checked == null
                    ? 'Checked, and no known remote found.'
                    : 'Checked ${device.checked}, and no known remote found.',
              ),
            ),
          ),
      ],
    );
  }

  static String _ledgerEntryDetail(RemoteLedgerEntry entry) {
    final parts = <String>[
      if (entry.controls.isNotEmpty) 'Controls ${entry.controls.join(', ')}',
      '${entry.keyCount} ${entry.keyCount == 1 ? 'key' : 'keys'}',
      if (entry.protocol != null) entry.protocol!,
      entry.importedFrom == null ? 'authored' : 'imported',
    ];
    return parts.join(' · ');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchCtrl.text.trim();

    return PopScope(
      canPop: !_canNavigateUp,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_canNavigateUp) {
          await _navigateUp();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Remote Ledger'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading || !_hasLoadedDirectory
                  ? null
                  : () => _loadDirectory(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            if (_hasLoadedDirectory) {
              await _loadDirectory(forceRefresh: true);
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$kRemoteLedgerOwner/$kRemoteLedgerRepo',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _canNavigateUp ? _navigateUp : null,
                            icon: const Icon(Icons.arrow_upward_rounded),
                            label: const Text('Up'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '/$_currentPath',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _searchCtrl,
                        onChanged: _onSearchChanged,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText:
                              'Search a device, model or maker, e.g. BDP-S185',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (query.isNotEmpty)
                _ledgerSearchResults(theme, query)
              else if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (!_hasAttemptedLoad)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Remote Ledger',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'IR codes by manufacturer and remote model. Each key carries its most trusted code and cites where it came from. Search above by device, model or maker, or load the repository to browse it by folder.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _loading ? null : _loadDirectory,
                          icon: const Icon(Icons.cloud_download_rounded),
                          label: const Text('Load Remote Ledger'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_error != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                )
              else if (_items.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'There are no files or folders here.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < _items.length; i++) ...[
                        ListTile(
                          leading: Icon(
                            _items[i].type == RepoItemType.dir
                                ? Icons.folder_open_rounded
                                : Icons.description_outlined,
                          ),
                          title: Text(_items[i].name),
                          subtitle: Text(
                            _items[i].path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _items[i].type == RepoItemType.dir
                              ? const Icon(Icons.chevron_right_rounded)
                              : _FileSupportChip(fileName: _items[i].name),
                          onTap: () => _openItem(_items[i]),
                        ),
                        if (i != _items.length - 1) const Divider(height: 1),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileSupportChip extends StatelessWidget {
  const _FileSupportChip({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final supported = isSupportedImportFilename(fileName);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: supported ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        supported ? 'Import' : 'Unsupported',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: supported ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _RemoteFileImportScreen extends StatefulWidget {
  const _RemoteFileImportScreen({
    required this.item,
    required this.service,
  });

  final RepoItem item;
  final GitHubStoreService service;

  @override
  State<_RemoteFileImportScreen> createState() =>
      _RemoteFileImportScreenState();
}

class _RemoteFileImportScreenState extends State<_RemoteFileImportScreen> {
  Future<_ParsedRemoteImport>? _future;
  bool _saving = false;
  bool _wrap = true;

  Future<void> _showImportSuccessSheet({
    required String title,
    required String message,
    Remote? remoteToOpen,
  }) async {
    final action = await showModalBottomSheet<_ImportSuccessAction>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final cs = theme.colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (remoteToOpen != null) ...[
                FilledButton.icon(
                  onPressed: () => Navigator.of(sheetContext).pop(
                    _ImportSuccessAction.openRemote,
                  ),
                  icon: const Icon(Icons.settings_remote_rounded),
                  label: const Text('Open remote'),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop(
                  _ImportSuccessAction.browseAgain,
                ),
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('Browse again'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (action == _ImportSuccessAction.openRemote && remoteToOpen != null) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RemoteView(remote: remoteToOpen),
        ),
      );
      return;
    }

    if (action == _ImportSuccessAction.browseAgain || action == null) {
      Navigator.of(context).pop();
    }
  }

  Future<_ParsedRemoteImport> _load(BuildContext context) async {
    final fallbackRemoteName = context.l10n.importedRemoteDefaultName;
    final fallbackButtonLabel = context.l10n.buttonFallbackTitle;
    final payload = await widget.service.fetchFileText(widget.item.path);
    final preview = analyzeImportedText(
      payload.text,
      filename: widget.item.name,
      fallbackRemoteName: fallbackRemoteName,
      fallbackButtonLabel: fallbackButtonLabel,
    );
    return _ParsedRemoteImport(
      payload: payload,
      preview: preview,
    );
  }

  Future<void> _saveAsNew(_ParsedRemoteImport parsed) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (remotes.isEmpty) {
        remotes = await readRemotes();
      }
      final importedRemotes = cloneRemotesForImport(parsed.preview.remotes);
      final importedIds = importedRemotes.map((remote) => remote.id).toSet();
      final next = <Remote>[
        ...remotes,
        ...importedRemotes,
      ];
      await writeRemotelist(next);
      remotes = await readRemotes();
      notifyRemotesChanged();
      if (!mounted) return;
      final savedRemotes = remotes
          .where((remote) => importedIds.contains(remote.id))
          .toList(growable: false);
      final importedCount = savedRemotes.length;
      await _showImportSuccessSheet(
        title: importedCount == 1 ? 'Remote imported' : 'Remotes imported',
        message: importedCount == 1
            ? 'The remote is ready. You can keep browsing Remote Ledger or open it now.'
            : 'Imported $importedCount remotes. You can go back to Remote Ledger and continue browsing.',
        remoteToOpen: importedCount == 1 ? savedRemotes.first : null,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _saveIntoExisting(_ParsedRemoteImport parsed) async {
    if (_saving) return;
    if (remotes.isEmpty) {
      remotes = await readRemotes();
    }
    if (!mounted) return;
    if (remotes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noRemotesAvailable)),
      );
      return;
    }

    final target = await showModalBottomSheet<Remote>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: remotes.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final remote = remotes[index];
            return ListTile(
              leading: const Icon(Icons.settings_remote_outlined),
              title: Text(
                remote.name.isEmpty
                    ? context.l10n.remoteNumber(remote.id)
                    : remote.name,
              ),
              subtitle: Text(
                context.l10n.remoteButtonCountLabel(remote.buttons.length),
              ),
              onTap: () => Navigator.of(sheetContext).pop(remote),
            );
          },
        ),
      ),
    );
    if (target == null) return;

    setState(() => _saving = true);
    try {
      final idx = remotes.indexWhere((remote) => remote.id == target.id);
      if (idx < 0) {
        throw StateError('Target remote not found.');
      }

      final existingKeys = remotes[idx]
          .buttons
          .map((button) => normalizeButtonKey(button.image))
          .toSet();
      final incoming = cloneButtonsForImport(
        parsed.preview.remotes.expand((remote) => remote.buttons),
      );

      final toAdd = <IRButton>[];
      var skipped = 0;
      for (final button in incoming) {
        final key = normalizeButtonKey(button.image);
        if (key.isNotEmpty && existingKeys.contains(key)) {
          skipped++;
          continue;
        }
        existingKeys.add(key);
        toAdd.add(button);
      }

      if (toAdd.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.importedButtonsSkippedDuplicates(0, skipped),
            ),
          ),
        );
        return;
      }

      remotes[idx].buttons.addAll(toAdd);
      await writeRemotelist(remotes);
      remotes = await readRemotes();
      notifyRemotesChanged();

      if (!mounted) return;
      final updatedRemote =
          remotes.where((remote) => remote.id == target.id).firstOrNull;
      final remoteLabel = updatedRemote?.name.isNotEmpty == true
          ? updatedRemote!.name
          : context.l10n.remoteNumber(target.id);
      final message = skipped > 0
          ? context.l10n.importedButtonsSkippedDuplicates(toAdd.length, skipped)
          : context.l10n.importedButtonCount(toAdd.length);
      final successMessage = updatedRemote == null
          ? '$remoteLabel: $message'
          : '$remoteLabel: $message You can keep browsing Remote Ledger or open this remote now.';
      await _showImportSuccessSheet(
        title: 'Import complete',
        message: successMessage,
        remoteToOpen: updatedRemote,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _future ??= _load(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.name),
      ),
      body: FutureBuilder<_ParsedRemoteImport>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _describeStoreError(
                    snapshot.error ?? Exception('Unknown error'),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final parsed = snapshot.data!;
          final preview = parsed.preview;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        parsed.payload.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: preview.isSupported
                                  ? theme.colorScheme.primaryContainer
                                  : theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              preview.isSupported
                                  ? 'Compatible'
                                  : 'Not compatible',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: preview.isSupported
                                    ? theme.colorScheme.onPrimaryContainer
                                    : theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preview.formatLabel,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        preview.supportReason,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Parsed ${preview.remotes.length} remote${preview.remotes.length == 1 ? '' : 's'} and ${preview.totalButtons} button${preview.totalButtons == 1 ? '' : 's'}.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final remote in preview.remotes.take(8))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.settings_remote_outlined,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${remote.name.isEmpty ? context.l10n.unnamedRemote : remote.name} (${remote.buttons.length})',
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (preview.remotes.length > 8)
                        Text(
                          '+${preview.remotes.length - 8} more',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (preview.issues.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Validation',
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        for (final issue in preview.issues.take(6))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 16,
                                  color: theme.colorScheme.tertiary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    issue,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'File preview',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: _wrap ? 'Disable wrap' : 'Enable wrap',
                            onPressed: () => setState(() => _wrap = !_wrap),
                            icon: Icon(
                              _wrap
                                  ? Icons.wrap_text_rounded
                                  : Icons.swap_horiz_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 360),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _codeView(context, parsed.payload.text, _wrap),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving || !preview.isSupported
                    ? null
                    : () => _saveAsNew(parsed),
                icon: const Icon(Icons.add_box_outlined),
                label: Text(
                  preview.remotes.length == 1
                      ? 'Create new remote'
                      : 'Create new remotes',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving || !preview.isSupported
                    ? null
                    : () => _saveIntoExisting(parsed),
                icon: const Icon(Icons.playlist_add_rounded),
                label: const Text('Add buttons to existing remote'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _codeView(BuildContext context, String text, bool wrap) {
    final mono = const TextStyle(fontFamily: 'monospace');

    if (wrap) {
      return SingleChildScrollView(
        child: SelectableText(text, style: mono),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(minWidth: MediaQuery.of(context).size.width),
        child: SingleChildScrollView(
          child: SelectableText(text, style: mono),
        ),
      ),
    );
  }
}

enum _ImportSuccessAction {
  browseAgain,
  openRemote,
}

class _ParsedRemoteImport {
  const _ParsedRemoteImport({
    required this.payload,
    required this.preview,
  });

  final GitHubFilePayload payload;
  final ImportPreviewResult preview;
}
