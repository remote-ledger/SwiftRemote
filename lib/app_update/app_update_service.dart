import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The repository releases are pulled from.
///
/// This is deliberately the fork's own repository rather than anything the
/// user can point at: an updater that installs arbitrary APKs is a way to
/// get a malicious package onto the device, so the source is fixed at build
/// time and every download is signed with the key that built this app.
const String kUpdateRepoOwner = 'remote-ledger';
const String kUpdateRepoName = 'SwiftRemote';

/// Preference key for the startup check.
const String kUpdateAutoCheckPref = 'update_check_on_startup';

/// Preference key for when the startup check last went out to GitHub, held
/// as milliseconds since the epoch.
const String kUpdateLastAutoCheckPref = 'update_last_auto_check';

/// How long a startup check stands before another one is allowed.
///
/// Unauthenticated GitHub allows 60 requests an hour per IP address, and a
/// carrier-grade NAT puts a great many devices behind a single address, so a
/// request nobody asked for is worth making rarely. A day is far longer than
/// releases arrive, and the check is only ever a courtesy: the button on the
/// update screen is what a user reaches for when they actually want to know.
const Duration kUpdateAutoCheckInterval = Duration(hours: 24);

/// Why an update check or download could not finish.
enum UpdateErrorKind { network, rateLimited, noRelease, noAsset, install }

class UpdateException implements Exception {
  const UpdateException(this.kind, [this.detail]);

  final UpdateErrorKind kind;
  final String? detail;

  @override
  String toString() => 'UpdateException($kind, $detail)';
}

/// A published release that carries an installable APK.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
  });

  /// Comparable version, e.g. `3.4.2`, with any leading `v` removed.
  final String version;

  /// The tag as published, e.g. `v3.4.2`.
  final String tag;

  /// Release body, rendered as plain text.
  final String notes;

  final String apkUrl;
  final String apkName;

  /// Size in bytes as GitHub reports it; 0 when unknown.
  final int apkSize;
}

/// Outcome of a check: the installed version, plus a release when a newer
/// one exists.
class UpdateCheck {
  const UpdateCheck({required this.currentVersion, this.release});

  final String currentVersion;
  final AppRelease? release;

  bool get hasUpdate => release != null;
}

/// Strips a leading `v` and any pre-release or build suffix, so `v3.4.2-rc.1`
/// and `3.4.2+45` both compare as `3.4.2`.
String normaliseVersion(String raw) {
  var v = raw.trim();
  if (v.startsWith('v') || v.startsWith('V')) {
    v = v.substring(1);
  }
  for (final separator in const ['-', '+', ' ']) {
    final cut = v.indexOf(separator);
    if (cut > 0) {
      v = v.substring(0, cut);
    }
  }
  return v;
}

/// Compares dotted numeric versions. Returns <0, 0 or >0 like [Comparable].
int compareVersions(String a, String b) {
  List<int> parts(String value) => value
      .split('.')
      .map((part) {
        final match = RegExp(r'^\d+').firstMatch(part.trim());
        return match == null ? 0 : int.parse(match.group(0)!);
      })
      .toList(growable: false);

  final left = parts(a);
  final right = parts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const MethodChannel _channel =
      MethodChannel('com.github.shanjian.swiftremote/app_update');

  /// Asks GitHub for the newest published release.
  ///
  /// `/releases/latest` skips drafts and pre-releases, so superseded builds
  /// marked pre-release are never offered.
  Future<UpdateCheck> check() async {
    final info = await PackageInfo.fromPlatform();
    final current = normaliseVersion(info.version);

    final uri = Uri.https(
      'api.github.com',
      '/repos/$kUpdateRepoOwner/$kUpdateRepoName/releases/latest',
    );

    final http.Response response;
    try {
      response = await _client.get(uri, headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      }).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const UpdateException(UpdateErrorKind.network, 'timed out');
    } catch (e) {
      throw UpdateException(UpdateErrorKind.network, e.toString());
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateException(UpdateErrorKind.rateLimited);
    }
    if (response.statusCode == 404) {
      throw const UpdateException(UpdateErrorKind.noRelease);
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        UpdateErrorKind.network,
        'HTTP ${response.statusCode}',
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw UpdateException(UpdateErrorKind.network, 'bad JSON');
    }

    final tag = (body['tag_name'] ?? '').toString();
    if (tag.isEmpty) {
      throw const UpdateException(UpdateErrorKind.noRelease);
    }
    final version = normaliseVersion(tag);

    if (compareVersions(version, current) <= 0) {
      return UpdateCheck(currentVersion: current);
    }

    Map<String, dynamic>? apk;
    final assets = body['assets'];
    if (assets is List) {
      for (final entry in assets) {
        if (entry is! Map) continue;
        final asset = entry.cast<String, dynamic>();
        final name = (asset['name'] ?? '').toString();
        if (name.toLowerCase().endsWith('.apk')) {
          apk = asset;
          break;
        }
      }
    }
    if (apk == null) {
      throw const UpdateException(UpdateErrorKind.noAsset);
    }

    final url = (apk['browser_download_url'] ?? '').toString();
    if (url.isEmpty) {
      throw const UpdateException(UpdateErrorKind.noAsset);
    }

    return UpdateCheck(
      currentVersion: current,
      release: AppRelease(
        version: version,
        tag: tag,
        notes: (body['body'] ?? '').toString().trim(),
        apkUrl: url,
        apkName: (apk['name'] ?? 'update.apk').toString(),
        apkSize: apk['size'] is int ? apk['size'] as int : 0,
      ),
    );
  }

  /// Downloads [release] into the cache directory, reporting progress.
  ///
  /// Anything left from an earlier attempt is removed first so a partial
  /// file can never be handed to the installer.
  Future<File> download(
    AppRelease release, {
    void Function(int received, int total)? onProgress,
    CancellationToken? cancel,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${release.apkName}');
    if (await file.exists()) {
      await file.delete();
    }

    final request = http.Request('GET', Uri.parse(release.apkUrl));
    final http.StreamedResponse response;
    try {
      // The APK runs to tens of megabytes and a slow but healthy connection
      // can legitimately spend minutes on it, so the transfer as a whole is
      // deliberately left without a deadline. What is bounded is the wait
      // for the response, which is the part that hangs when the connection
      // is dead rather than merely slow, and 20 seconds for a set of headers
      // is the same allowance [check] makes.
      response =
          await _client.send(request).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const UpdateException(UpdateErrorKind.network, 'timed out');
    } catch (e) {
      throw UpdateException(UpdateErrorKind.network, e.toString());
    }

    if (response.statusCode != 200) {
      throw UpdateException(
        UpdateErrorKind.network,
        'HTTP ${response.statusCode}',
      );
    }

    final total = response.contentLength ?? release.apkSize;
    var received = 0;
    final sink = file.openWrite();
    try {
      // Headers arriving is no promise that the body will. A connection that
      // dies mid-transfer often leaves the socket open, and without this the
      // screen sits on "Downloading..." until the user gives up. The gap
      // measured is the one between chunks, not the length of the download,
      // so every byte that arrives resets the clock and a transfer that is
      // only slow is never cut off. A minute is generous on purpose: a phone
      // moving between cells can go quiet for a while and still recover.
      final stream = response.stream.timeout(const Duration(seconds: 60));
      await for (final chunk in stream) {
        if (cancel != null && cancel.isCancelled) {
          await sink.close();
          if (await file.exists()) await file.delete();
          throw const UpdateException(UpdateErrorKind.network, 'cancelled');
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await file.exists()) {
        await file.delete();
      }
      if (e is UpdateException) rethrow;
      if (e is TimeoutException) {
        throw const UpdateException(UpdateErrorKind.network, 'stalled');
      }
      throw UpdateException(UpdateErrorKind.network, e.toString());
    }

    return file;
  }

  /// Whether Android will let this app launch the package installer.
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system page where "install unknown apps" is granted.
  ///
  /// Reaching that page is not a certainty: some OEM builds ship without the
  /// activity the intent names, and the native side reports the resulting
  /// failure as a platform error. Converting it the way [install] does lets
  /// the screen say something went wrong, rather than leaving the user
  /// tapping a button that appears to do nothing at all.
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on PlatformException catch (e) {
      throw UpdateException(UpdateErrorKind.install, e.message);
    }
  }

  /// Hands [apk] to the system installer. The user confirms from there.
  Future<void> install(File apk) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apk.path});
    } on PlatformException catch (e) {
      throw UpdateException(UpdateErrorKind.install, e.message);
    }
  }

  static Future<bool> autoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kUpdateAutoCheckPref) ?? true;
  }

  static Future<void> setAutoCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kUpdateAutoCheckPref, value);
  }

  /// Whether the startup check is due again, per [kUpdateAutoCheckInterval].
  ///
  /// Only the unattended check consults this. A check the user asked for is
  /// answering a question they just put to the app, so it always goes out.
  static Future<bool> autoCheckDue() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(kUpdateLastAutoCheckPref);
    if (last == null) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    // A stamp in the future means the clock has moved backwards, which is
    // ordinary on a device that only learns the real time once it is online.
    // Treating that as due avoids parking the check until the clock catches
    // up with a stamp that was never meant to be that far ahead.
    return elapsed < 0 || elapsed >= kUpdateAutoCheckInterval.inMilliseconds;
  }

  /// Records that the startup check has just gone out to GitHub.
  static Future<void> markAutoChecked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kUpdateLastAutoCheckPref,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// Minimal cooperative cancellation for an in-flight download.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
