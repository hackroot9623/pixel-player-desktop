import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/shapes.dart';

/// Port of `presentation/components/SmartImage` + `OptimizedAlbumArt`:
/// artwork with a themed placeholder, rounded to the app's shape scale.
/// Whether an artwork path is a URL to fetch rather than a file to open.
bool isNetworkArtwork(String path) =>
    path.startsWith('http://') || path.startsWith('https://');

class AlbumArt extends StatelessWidget {
  const AlbumArt({
    super.key,
    required this.path,
    this.size,
    this.radius = shapeMedium,
    this.icon = Icons.music_note_rounded,
    this.heroTag,
  });

  final String? path;
  final double? size;
  final double radius;
  final IconData icon;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // No existsSync() here: this widget renders once per visible row, and a
    // stat syscall inside build showed up as list-scrolling jank. A missing
    // file falls through to errorBuilder instead.
    // A remote source hands back an http(s) cover URL rather than a file, so the
    // path decides which loader to use. Without this every server's artwork
    // silently fell through to the placeholder.
    final child = switch (path) {
      null => _placeholder(scheme),
      final value when isNetworkArtwork(value) => Image.network(
        value,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: size == null ? 512 : (size! * 2).round(),
        errorBuilder: (_, _, _) => _placeholder(scheme),
        // A blank box while it downloads reads as broken; the placeholder is
        // the same shape and colour as the final image's backdrop.
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : _placeholder(scheme),
      ),
      final value => Image.file(
        File(value),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: size == null ? 512 : (size! * 2).round(),
        errorBuilder: (_, _, _) => _placeholder(scheme),
      ),
    };
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
    return heroTag == null
        ? clipped
        : Hero(tag: heroTag!, child: clipped);
  }

  Widget _placeholder(ColorScheme scheme) => Container(
    width: size,
    height: size,
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(
      icon,
      size: size == null ? 28 : (size! * 0.42).clamp(14, 96),
      color: scheme.onSurfaceVariant,
    ),
  );
}

/// Port of `AlbumArtCollage` — the 2x2 mosaic used for mixes and playlists
/// without their own cover.
class AlbumArtCollage extends StatelessWidget {
  const AlbumArtCollage({
    super.key,
    required this.paths,
    this.size = 96,
    this.radius = shapeMedium,
  });

  final List<String?> paths;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final available = paths.where((path) => path != null).take(4).toList();
    if (available.length < 2) {
      return AlbumArt(
        path: available.firstOrNull,
        size: size,
        radius: radius,
      );
    }
    final tile = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < 4; i++)
              AlbumArt(
                path: available[i % available.length],
                size: tile,
                radius: 0,
              ),
          ],
        ),
      ),
    );
  }
}
