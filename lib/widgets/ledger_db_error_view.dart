import 'package:flutter/material.dart';
import 'package:swiftremote/l10n/l10n.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';

/// What to tell someone when the IR code database could not be read.
///
/// The database is downloaded from the Remote Ledger the first time a brand
/// is opened and kept on the device, so most failures mean the same thing:
/// there is no connection and nothing saved to fall back on. A manifest this
/// build cannot read is different, and retrying will not help.
///
/// [fallback] is used for an error that is not the database's own.
String ledgerDbErrorText(
  BuildContext context,
  Object? error, {
  String? fallback,
}) {
  if (error is LedgerDbUnavailable) {
    return error.reason == LedgerDbFailure.unsupportedVersion
        ? context.l10n.irDbNeedsUpdate
        : context.l10n.irDbNeedsNetwork;
  }
  if (error is LedgerSignalUnavailable) {
    return context.l10n.irDbSignalUnavailable;
  }
  return fallback ?? context.l10n.irFinderDatabaseInitFailed;
}

/// Whether trying again could help with [error].
bool ledgerDbErrorIsRetryable(Object? error) =>
    error is! LedgerDbUnavailable || error.retryable;

/// A snack bar for a database failure, with a Retry action where one helps.
void showLedgerDbErrorSnack(
  BuildContext context,
  Object error, {
  VoidCallback? onRetry,
  String? fallback,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(ledgerDbErrorText(context, error, fallback: fallback)),
      duration: const Duration(seconds: 8),
      action: (onRetry != null && ledgerDbErrorIsRetryable(error))
          ? SnackBarAction(label: context.l10n.retry, onPressed: onRetry)
          : null,
    ),
  );
}

/// The message and a Retry button, for a list that could not be loaded.
class LedgerDbErrorView extends StatelessWidget {
  const LedgerDbErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.fallback,
  });

  final Object error;
  final VoidCallback onRetry;
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_rounded, color: theme.colorScheme.error),
            const SizedBox(height: 10),
            Text(
              ledgerDbErrorText(context, error, fallback: fallback),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (ledgerDbErrorIsRetryable(error)) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: onRetry,
                child: Text(context.l10n.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
