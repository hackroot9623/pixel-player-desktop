import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/remote_account.dart';
import '../../state/providers.dart';
import '../navigation.dart';

/// Switches the whole app between the local library and a configured server.
///
/// There is no Android counterpart: the phone app reaches a server through its
/// own dashboard screen. On a desktop the library, search and detail screens are
/// the natural way to browse anything, so the source is a mode the app is in
/// rather than a place inside it.
class SourceSelector extends ConsumerWidget {
  const SourceSelector({super.key, this.compact = false});

  /// Icon only, for the navigation rail.
  final bool compact;

  IconData _iconFor(RemoteKind kind) => switch (kind) {
    RemoteKind.jellyfin => Icons.movie_filter_rounded,
    RemoteKind.navidrome => Icons.dns_rounded,
    RemoteKind.telegram => Icons.send_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(remoteAccountsProvider);
    final activeId = ref.watch(activeSourceProvider);
    final active = ref.watch(activeAccountProvider);
    final theme = Theme.of(context);

    // With nothing configured there is nothing to switch between, and a menu
    // holding one disabled item is worse than no menu.
    if (accounts.isEmpty) return const SizedBox.shrink();

    final label = active?.title ?? 'This computer';
    final icon = active == null
        ? Icons.folder_outlined
        : _iconFor(active.kind);

    return MenuAnchor(
      builder: (context, controller, _) => compact
          ? IconButton(
              tooltip: 'Source · $label',
              icon: Icon(icon),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            )
          : Tooltip(
              message: 'Switch source',
              child: TextButton.icon(
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: Icon(icon, size: 18),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
            ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_outlined),
          trailingIcon: activeId == null
              ? const Icon(Icons.check_rounded, size: 18)
              : null,
          onPressed: () =>
              ref.read(settingsProvider).activeSourceId = null,
          child: const Text('This computer'),
        ),
        for (final account in accounts)
          MenuItemButton(
            leadingIcon: Icon(_iconFor(account.kind)),
            trailingIcon: activeId == account.id
                ? const Icon(Icons.check_rounded, size: 18)
                : null,
            onPressed: () =>
                ref.read(settingsProvider).activeSourceId = account.id,
            child: Text(account.title),
          ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_rounded),
          onPressed: () => openAccounts(context),
          child: Text(
            'Manage accounts',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// Shown while a server's catalogue is loading or after it failed, so a remote
/// source never looks like an empty library.
class SourceStatusBanner extends ConsumerWidget {
  const SourceStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(activeAccountProvider);
    if (account == null) return const SizedBox.shrink();
    final library = ref.watch(activeLibraryProvider);
    final theme = Theme.of(context);

    if (library.error != null) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: ListTile(
          leading: Icon(
            Icons.cloud_off_rounded,
            color: theme.colorScheme.onErrorContainer,
          ),
          title: Text(
            library.error!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          subtitle: Text(
            account.title,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          trailing: TextButton(
            onPressed: () =>
                ref.invalidate(remoteSongsProvider(account.id)),
            child: const Text('Retry'),
          ),
        ),
      );
    }

    if (library.scanning && library.songs.isEmpty) {
      return Card(
        child: ListTile(
          leading: const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Loading ${account.title}…'),
          subtitle: const Text('Fetching the catalogue from the server'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
