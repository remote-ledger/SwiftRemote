import 'package:flutter/material.dart';
import 'package:swiftremote/l10n/l10n.dart';

enum AddButtonSheetAction {
  addButton,
  browseRemoteLedger,
}

class AddButtonSheet extends StatelessWidget {
  const AddButtonSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(AddButtonSheetAction.addButton),
            icon: const Icon(Icons.add_circle_outline_rounded),
            label: Text(l10n.addButton),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              Icons.storefront_rounded,
              color: cs.onSurfaceVariant,
            ),
            title: Text(
              l10n.importARemote,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            onTap: () =>
                Navigator.of(context).pop(AddButtonSheetAction.browseRemoteLedger),
          ),
        ],
      ),
    );
  }
}
