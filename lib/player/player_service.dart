import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../data/db/database.dart';
import '../data/models/models.dart' show Song;
import '../data/models/transition.dart';
import '../data/prefs/settings.dart';

enum RepeatMode { off, all, one }

/// Replaces `data/service/MusicService` (Media3 `MediaSessionService`).
/// mpv owns the playlist so gapless and the queue-advance logic stay native;
/// this class keeps the Dart-side view of it and persists the snapshot.
class PlayerService extends ChangeNotifier {
  PlayerService(this._db, this._settings) {
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'PixelPlayer',
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _wire();
  }

  final MusicDatabase _db;
  final Settings _settings;
  late final Player _player;

  final _subs = <StreamSubscription<Object?>>[];

  List<Song> _queue = const [];
  int _index = 0;
  bool _playing = false;
  Duration _position = Duration.zero;

  /// Position updates arrive many times a second. Routing them through
  /// `notifyListeners()` rebuilt every widget watching this service — including
  /// every row of the library list — so they get their own listenable and only
  /// the seek bar and time labels subscribe.
  final positionListenable = ValueNotifier<Duration>(Duration.zero);
  Duration _duration = Duration.zero;
  bool _buffering = false;
  String? _lastRecordedSongId;

  /// Volume actually sent to mpv is `_settings.volume * _fadeFactor`, so track
  /// transitions and the sleep timer can duck the output without clobbering the
  /// user's volume setting.
  double _fadeFactor = 1;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndsAt;
  bool _sleepAtEndOfTrack = false;

  /// "Stop after N songs" from the timer sheet; 0 means inactive.
  int _sleepAfterTracks = 0;

  List<Song> get queue => _queue;
  int get index => _index;
  Song? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  bool get playing => _playing;
  bool get buffering => _buffering;
  Duration get position => _position;
  Duration get duration =>
      _duration != Duration.zero ? _duration : (current?.durationValue ?? Duration.zero);
  bool get hasQueue => _queue.isNotEmpty;

  bool get shuffle => _settings.shuffle;
  RepeatMode get repeatMode => RepeatMode.values[_settings.repeatMode];
  double get volume => _settings.volume;

  TransitionSettings get transition => _settings.transition;

  /// Non-null while a sleep timer is counting down.
  Duration? get sleepTimerRemaining {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) return null;
    final left = endsAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get sleepAtEndOfTrack => _sleepAtEndOfTrack;
  int get sleepAfterTracks => _sleepAfterTracks;
  bool get sleepTimerActive =>
      _sleepTimerEndsAt != null || _sleepAtEndOfTrack || _sleepAfterTracks > 0;

  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  void _wire() {
    _subs.addAll([
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
      }),
      _player.stream.position.listen((value) {
        _position = value;
        positionListenable.value = value;
        _updateTransitionFade();
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      _player.stream.buffering.listen((value) {
        _buffering = value;
        notifyListeners();
      }),
      // mpv advances the playlist itself; mirror its index so the UI and the
      // "now playing" row stay in sync with what is actually decoding.
      _player.stream.playlist.listen((value) {
        if (value.index != _index && value.index < _queue.length) {
          if (_sleepAtEndOfTrack) {
            _sleepAtEndOfTrack = false;
            _player.pause();
          } else if (_sleepAfterTracks > 0) {
            _sleepAfterTracks--;
            if (_sleepAfterTracks == 0) _player.pause();
          }
          _index = value.index;
          _onTrackChanged();
        }
        notifyListeners();
      }),
    ]);

    _player.setVolume(_settings.volume);
    _player.setShuffle(_settings.shuffle);
    _applyRepeatMode();
  }

  /// Restores the last queue so relaunching lands where the user left off.
  Future<void> restoreQueue() async {
    final ids = _settings.lastQueue;
    if (ids.isEmpty) return;
    final songs = _db.songsByIds(ids);
    if (songs.isEmpty) return;
    _queue = songs;
    _index = _settings.lastQueueIndex.clamp(0, songs.length - 1);
    try {
      await _player.open(_playlist(), play: false);
      final resume = Duration(milliseconds: _settings.lastPositionMs);
      if (resume > Duration.zero) await _player.seek(resume);
    } finally {
      notifyListeners();
    }
  }

  Playlist _playlist() => Playlist(
    [for (final song in _queue) Media('file://${Uri.encodeFull(song.path)}')],
    index: _index,
  );

  /// Plays [songs] starting at [startIndex] — the single entry point used by
  /// every "play" affordance in the UI.
  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _queue = List.unmodifiable(songs);
    _index = startIndex.clamp(0, songs.length - 1);
    // Notify even when the load fails — a missing or unreadable file must not
    // leave the UI showing the previous track.
    try {
      await _player.open(_playlist());
    } finally {
      _onTrackChanged();
      notifyListeners();
    }
  }

  Future<void> playSong(Song song) => playQueue([song]);

  Future<void> toggle() async {
    if (!hasQueue) return;
    await _player.playOrPause();
  }

  Future<void> next() async {
    if (!hasQueue) return;
    await _player.next();
  }

  Future<void> previous() async {
    if (!hasQueue) return;
    // Match the Android behaviour: restart the track if we are past 3s.
    if (_position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    await _player.previous();
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _player.jump(index);
  }

  Future<void> seek(Duration position) {
    // Move the thumb immediately; mpv confirms a frame or two later.
    _position = position;
    positionListenable.value = position;
    return _player.seek(position);
  }

  Future<void> seekFraction(double fraction) =>
      seek(Duration(milliseconds: (duration.inMilliseconds * fraction).round()));

  Future<void> setVolume(double value) async {
    _settings.volume = value;
    await _applyVolume();
    notifyListeners();
  }

  Future<void> _applyVolume() =>
      _player.setVolume((_settings.volume * _fadeFactor).clamp(0, 100));

  /// Ported from the `TransitionSettings` handling in the Android player.
  ///
  /// ponytail: single-decoder fade only — mpv owns one playlist, so the head
  /// and tail of adjacent tracks cannot literally overlap. OVERLAP and SMOOTH
  /// therefore render as a fade-out/fade-in pair over the same duration; true
  /// overlap needs the second player planned for phase 7.
  void _updateTransitionFade() {
    final settings = _settings.transition;
    if (!settings.enabled || !_playing) {
      if (_fadeFactor != 1) {
        _fadeFactor = 1;
        _applyVolume();
      }
      return;
    }
    final total = duration.inMilliseconds;
    if (total <= 0) return;
    final fade = settings.durationMs.clamp(1, total ~/ 2);
    final elapsed = _position.inMilliseconds;
    final remaining = total - elapsed;

    var factor = 1.0;
    if (elapsed < fade && _index > 0) {
      // Only fade in when we arrived from another track, not on a fresh start.
      factor = settings.curveIn.apply(elapsed / fade);
    } else if (remaining < fade && _index < _queue.length - 1) {
      factor = settings.curveOut.apply(remaining / fade);
    }
    if ((factor - _fadeFactor).abs() < 0.01) return;
    _fadeFactor = factor;
    _applyVolume();
  }

  // ------------------------------------------------------------ sleep timer

  /// Ported from `TimerOptionsBottomSheet`.
  void setSleepTimer(Duration duration) {
    cancelSleepTimer();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, _onSleepTimerFired);
    notifyListeners();
  }

  void setSleepTimerAtEndOfTrack() {
    cancelSleepTimer();
    _sleepAtEndOfTrack = true;
    notifyListeners();
  }

  /// Stop once [count] more tracks have finished.
  void setSleepTimerAfterTracks(int count) {
    cancelSleepTimer();
    if (count <= 0) return;
    _sleepAfterTracks = count;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
    _sleepAtEndOfTrack = false;
    _sleepAfterTracks = 0;
    if (_fadeFactor != 1) {
      _fadeFactor = 1;
      _applyVolume();
    }
    notifyListeners();
  }

  Future<void> _onSleepTimerFired() async {
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
    // Ease out over 5s rather than cutting the audio dead.
    const steps = 25;
    for (var i = steps; i >= 0; i--) {
      _fadeFactor = i / steps;
      await _applyVolume();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _player.pause();
    _fadeFactor = 1;
    await _applyVolume();
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _settings.shuffle = !_settings.shuffle;
    await _player.setShuffle(_settings.shuffle);
    notifyListeners();
  }

  Future<void> cycleRepeatMode() async {
    _settings.repeatMode = (_settings.repeatMode + 1) % 3;
    await _applyRepeatMode();
    notifyListeners();
  }

  Future<void> _applyRepeatMode() => _player.setPlaylistMode(
    switch (repeatMode) {
      RepeatMode.off => PlaylistMode.none,
      RepeatMode.all => PlaylistMode.loop,
      RepeatMode.one => PlaylistMode.single,
    },
  );

  // ------------------------------------------------------------- queue edits

  Future<void> addToQueue(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (!hasQueue) return playQueue(songs);
    _queue = [..._queue, ...songs];
    for (final song in songs) {
      await _player.add(Media('file://${Uri.encodeFull(song.path)}'));
    }
    notifyListeners();
  }

  /// "Play next" — insert directly after the current track.
  Future<void> playNext(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (!hasQueue) return playQueue(songs);
    final updated = [..._queue];
    updated.insertAll(_index + 1, songs);
    await _rebuildPreservingPlayback(updated, _index);
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    if (_queue.length == 1) return clear();
    final updated = [..._queue]..removeAt(index);
    final newIndex = index < _index ? _index - 1 : _index.clamp(0, updated.length - 1);
    if (index == _index) {
      await _rebuildPreservingPlayback(updated, newIndex, resume: false);
    } else {
      _queue = updated;
      _index = newIndex;
      await _player.remove(index);
      notifyListeners();
    }
  }

  Future<void> move(int from, int to) async {
    if (from == to) return;
    final updated = [..._queue];
    final song = updated.removeAt(from);
    updated.insert(to, song);
    final playingSong = current;
    _queue = updated;
    _index = playingSong == null ? 0 : updated.indexOf(playingSong);
    await _player.move(from, to);
    notifyListeners();
  }

  Future<void> clear() async {
    _queue = const [];
    _index = 0;
    await _player.stop();
    _settings.saveQueueSnapshot(const [], 0, 0);
    notifyListeners();
  }

  /// Reopens the mpv playlist while keeping the current track playing from the
  /// same position — needed because mpv has no "insert at index" primitive.
  Future<void> _rebuildPreservingPlayback(
    List<Song> songs,
    int index, {
    bool resume = true,
  }) async {
    final at = _position;
    final wasPlaying = _playing;
    _queue = List.unmodifiable(songs);
    _index = index.clamp(0, songs.length - 1);
    try {
      await _player.open(_playlist(), play: wasPlaying);
      if (resume && at > Duration.zero) await _player.seek(at);
    } finally {
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- favourites

  bool toggleFavorite(Song song) {
    final next = !_db.isFavorite(song.id);
    _db.setFavorite(song.id, next);
    _queue = [
      for (final s in _queue)
        s.id == song.id ? s.copyWith(isFavorite: next) : s,
    ];
    notifyListeners();
    return next;
  }

  void _onTrackChanged() {
    final song = current;
    if (song == null) return;
    if (_lastRecordedSongId != song.id) {
      _lastRecordedSongId = song.id;
      _db.recordPlayback(song.id, msPlayed: 0);
    }
    _settings.saveQueueSnapshot(
      [for (final s in _queue) s.id],
      _index,
      _position.inMilliseconds,
    );
  }

  @override
  void dispose() {
    _settings.saveQueueSnapshot(
      [for (final s in _queue) s.id],
      _index,
      _position.inMilliseconds,
    );
    _sleepTimer?.cancel();
    positionListenable.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
