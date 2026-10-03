/// Why the IR code database could not be read.
enum LedgerDbFailure {
  /// The network failed (no connection, a timeout, a refused handshake) and
  /// nothing usable is cached.
  offline,

  /// The server answered, but not with the file: an error status, or a file
  /// whose content does not match the hash its brand's index gives.
  server,

  /// The manifest's schema version is one this build does not know how to
  /// read; the app has to be updated.
  unsupportedVersion,

  /// A file arrived (or was cached) and cannot be parsed.
  corrupt,
}

/// The IR code database is read from the Remote Ledger over the network and
/// kept on the device. This is thrown when a file it needs is neither on the
/// device nor reachable: the first use of a brand while offline, a server
/// error, a manifest from the future.
///
/// Anything that is cached is used when the network fails, so this means there
/// is nothing to fall back to. It never means the answer is "no codes".
class LedgerDbUnavailable implements Exception {
  const LedgerDbUnavailable(this.reason, this.message, {this.cause});

  final LedgerDbFailure reason;
  final String message;
  final Object? cause;

  /// Whether trying again later can help (every reason but a schema this
  /// build cannot read).
  bool get retryable => reason != LedgerDbFailure.unsupportedVersion;

  @override
  String toString() => 'LedgerDbUnavailable(${reason.name}): $message';
}

/// A code of a protocol the app reads from the ledger's compiled signal could
/// not be turned into a signal because the signal is not available (offline,
/// and not cached yet).
///
/// The app's own decoder is deliberately not tried instead: for these
/// protocols it reads the database's hex codes differently from the wire, so a
/// send it made would be a different code from the one the database lists.
class LedgerSignalUnavailable implements Exception {
  const LedgerSignalUnavailable(this.protocol, [this.cause]);

  /// The database protocol name, e.g. `SONY12`.
  final String protocol;
  final Object? cause;

  @override
  String toString() =>
      'The signal for $protocol codes is not available (needs a network '
      'connection the first time).';
}
