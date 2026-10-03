import 'dart:io';
import 'dart:typed_data';

/// The IR code database's files on the device.
///
/// They live in the application support directory, not the OS-purgeable cache
/// directory: a user who opened a brand once expects it to work on a train.
/// Every write goes to a staging file first and is then renamed into place, so
/// a process killed or a disk filled half way never leaves a truncated file
/// that looks present (the pattern the old bundled database used for its
/// copy). When the files outgrow [maxBytes] the brands used longest ago go
/// first; the manifest, the brand list and the power list are never evicted.
class LedgerCache {
  LedgerCache(
    this.root, {
    this.maxBytes = 40 * 1024 * 1024,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Directory root;

  /// The ceiling for brand and signal files together.
  final int maxBytes;
  final DateTime Function() _now;

  static final RegExp _safePath = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.\-]*'
      r'(/[A-Za-z0-9_][A-Za-z0-9_.\-]*)*$');

  /// Files that are kept however long ago they were used.
  static const Set<String> _pinned = <String>{
    'manifest.json',
    'brands.json',
    'power.json',
    'meta.json',
  };

  int? _bytes;

  File _file(String relative) {
    if (!_safePath.hasMatch(relative) || relative.contains('..')) {
      throw ArgumentError.value(relative, 'relative', 'Not a cache path');
    }
    return File('${root.path}/$relative');
  }

  /// The file's bytes, or null when it is not cached. Reading counts as using
  /// it: a read file is the last to be evicted.
  Future<Uint8List?> read(String relative) async {
    try {
      final File f = _file(relative);
      if (!await f.exists()) return null;
      final Uint8List bytes = await f.readAsBytes();
      await _touch(f);
      return bytes;
    } on ArgumentError {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Stores [bytes] atomically. Failure to write is not an error for the
  /// caller: a cache that cannot be written costs a download next time,
  /// nothing more. Returns whether it was written.
  Future<bool> write(String relative, Uint8List bytes) async {
    final File target = _file(relative);
    final File staging = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      final int previous = await _sizeOf(target);
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(target.path);
      final int? total = _bytes;
      if (total != null && _isEvictable(relative)) {
        _bytes = total - previous + bytes.length;
      }
    } catch (_) {
      await _deleteQuietly(staging);
      return false;
    }
    if (_isEvictable(relative)) {
      await _trimIfNeeded(keep: relative);
    }
    return true;
  }

  Future<void> delete(String relative) async {
    final File f = _file(relative);
    final int size = await _sizeOf(f);
    await _deleteQuietly(f);
    final int? total = _bytes;
    if (total != null && _isEvictable(relative)) _bytes = total - size;
  }

  bool _isEvictable(String relative) => !_pinned.contains(relative);

  /// Removes staging files an interrupted write left behind.
  Future<void> removeStaging() async {
    try {
      if (!await root.exists()) return;
      await for (final FileSystemEntity e in root.list(recursive: true)) {
        if (e is File && e.path.endsWith('.tmp')) {
          await _deleteQuietly(e);
        }
      }
    } catch (_) {
      // Housekeeping only.
    }
  }

  /// The bytes held by brand and signal files.
  Future<int> evictableBytes() async {
    int total = 0;
    for (final _Entry e in await _entries()) {
      total += e.size;
    }
    return total;
  }

  Future<void> _trimIfNeeded({required String keep}) async {
    int? total = _bytes;
    if (total == null) {
      total = await evictableBytes();
      _bytes = total;
    }
    if (total <= maxBytes) return;

    final List<_Entry> entries = await _entries();
    // Brand files go as a pair (`b/<key>.m.json` with its `.k.json`), by the
    // later of the two's last use.
    final Map<String, _Group> groups = <String, _Group>{};
    for (final _Entry e in entries) {
      final String id = e.relative.replaceFirst(RegExp(r'\.[mk]\.json$'), '');
      groups.putIfAbsent(id, () => _Group()).add(e);
    }
    final String keepId = keep.replaceFirst(RegExp(r'\.[mk]\.json$'), '');
    final List<_Group> byAge = groups.entries
        .where((MapEntry<String, _Group> g) => g.key != keepId)
        .map((MapEntry<String, _Group> g) => g.value)
        .toList()
      ..sort((_Group a, _Group b) => a.usedAt.compareTo(b.usedAt));

    int size = entries.fold(0, (int sum, _Entry e) => sum + e.size);
    for (final _Group g in byAge) {
      if (size <= maxBytes) break;
      for (final _Entry e in g.entries) {
        await _deleteQuietly(e.file);
        size -= e.size;
      }
    }
    _bytes = size;
  }

  Future<List<_Entry>> _entries() async {
    final List<_Entry> out = <_Entry>[];
    try {
      if (!await root.exists()) return out;
      await for (final FileSystemEntity e in root.list(recursive: true)) {
        if (e is! File) continue;
        final String relative = e.path.substring(root.path.length + 1);
        if (_pinned.contains(relative) || relative.endsWith('.tmp')) continue;
        final FileStat stat = await e.stat();
        out.add(_Entry(e, relative, stat.size, stat.modified));
      }
    } catch (_) {
      // A listing that fails evicts nothing.
    }
    return out;
  }

  Future<int> _sizeOf(File f) async {
    try {
      if (await f.exists()) return await f.length();
    } catch (_) {}
    return 0;
  }

  Future<void> _touch(File f) async {
    try {
      await f.setLastModified(_now());
    } catch (_) {
      // Eviction order is a nicety.
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Housekeeping only.
    }
  }
}

class _Entry {
  _Entry(this.file, this.relative, this.size, this.modified);
  final File file;
  final String relative;
  final int size;
  final DateTime modified;
}

class _Group {
  final List<_Entry> entries = <_Entry>[];
  DateTime usedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void add(_Entry e) {
    entries.add(e);
    if (e.modified.isAfter(usedAt)) usedAt = e.modified;
  }
}
