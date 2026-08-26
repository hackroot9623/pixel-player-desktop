import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import 'album_art.dart';

/// The artist picture, with the lookup happening behind it.
///
/// Watching this is what starts the fetch, so simply opening the artist screen
/// is enough — there is no button to press. A failed lookup shows here, on the
/// avatar, with a tap to try again; a "no such artist" result just leaves the
/// placeholder, because that is not something retrying will fix.
class ArtistAvatar extends ConsumerWidget {
  const ArtistAvatar({super.key, required this.artist, this.size = 200});

  final Artist artist;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(artistImageProvider(artist.id));
    // Fall back to the row we already have while the lookup is in flight, so a
    // cached picture never blinks out.
    final resolved = async.valueOrNull ?? artist;
    final loading = async.isLoading;
    final failed = resolved.imageStatus.isFailure || async.hasError;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipOval(
            child: AlbumArt(
              path: resolved.effectiveImageUrl,
              size: size,
              radius: size,
              icon: Icons.person_rounded,
            ),
          ),
          if (loading)
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                // Only the ring, so any cached picture stays visible under it.
                color: scheme.primary.withValues(alpha: 0.8),
              ),
            ),
          if (failed && !loading)
            _RetryOverlay(
              size: size,
              message: resolved.imageError ?? 'Could not load the picture',
              onRetry: () => retryArtistImage(ref, resolved),
            ),
        ],
      ),
    );
  }
}

class _RetryOverlay extends StatelessWidget {
  const _RetryOverlay({
    required this.size,
    required this.message,
    required this.onRetry,
  });

  final double size;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$message — click to try again',
      child: Material(
        color: scheme.errorContainer.withValues(alpha: 0.88),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onRetry,
          child: SizedBox(
            width: size,
            height: size,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.refresh_rounded,
                  size: size * 0.28,
                  color: scheme.onErrorContainer,
                ),
                SizedBox(height: size * 0.04),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: size * 0.12),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
