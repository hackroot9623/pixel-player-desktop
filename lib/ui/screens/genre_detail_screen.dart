import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/detail_header.dart';

/// Port of `presentation/screens/GenreDetailScreen`.
class GenreDetailScreen extends ConsumerWidget {
  const GenreDetailScreen({super.key, required this.genre});

  final Genre genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) => DetailScaffold(
    title: genre.name,
    artIcon: Icons.graphic_eq_rounded,
    songs: ref.watch(songsForGenreProvider(genre.id)),
    numbered: false,
  );
}
