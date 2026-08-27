import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/platform/mpris.dart';

/// The bus itself is not exercised here — no session bus in CI — but the mapping
/// is, and that is where MPRIS goes wrong: microseconds mistaken for
/// milliseconds, a track id that is not a valid object path, an artist that a
/// client expects as an array and gets as a string.

Song _song({
  String id = '/music/track.mp3',
  String title = 'Al Sudeste',
  String artist = 'Moneda Dura',
  List<ArtistRef> artists = const [],
  String album = 'Sin Blasfemias',
  String? albumArtist,
  String? albumArtPath,
  String? genre,
  int duration = 249000,
  int trackNumber = 0,
  String? path,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  artistId: 1,
  artists: artists,
  album: album,
  albumId: 1,
  albumArtist: albumArtist,
  albumArtPath: albumArtPath,
  genre: genre,
  path: path ?? id,
  duration: duration,
  trackNumber: trackNumber,
);

void main() {
  group('playback status', () {
    test('only the three legal values are produced', () {
      expect(mprisPlaybackStatus(playing: true, hasTrack: true), 'Playing');
      expect(mprisPlaybackStatus(playing: false, hasTrack: true), 'Paused');
      expect(mprisPlaybackStatus(playing: false, hasTrack: false), 'Stopped');
    });

    test('nothing loaded is Stopped even if the player thinks it is playing', () {
      // A client shown "Playing" with no metadata renders an empty widget.
      expect(mprisPlaybackStatus(playing: true, hasTrack: false), 'Stopped');
    });
  });

  group('track id', () {
    test('it is a valid object path, not the song id', () {
      // Song ids are file paths or `drive:account:file`, neither of which is a
      // legal object path — D-Bus would reject the whole message.
      final id = mprisTrackId(3);
      expect(id.value, '/org/mpris/MediaPlayer2/pixelplayer/track/3');
      expect(() => DBusObjectPath(id.value), returnsNormally);
    });

    test('different positions get different ids', () {
      expect(mprisTrackId(0), isNot(mprisTrackId(1)));
    });
  });

  group('metadata', () {
    test('length is in microseconds', () {
      // The commonest MPRIS bug: a progress bar a thousand times too short.
      final metadata = mprisMetadata(_song(duration: 249000));
      expect(metadata['mpris:length'], const DBusUint64(249000000));
    });

    test('a track of unknown length omits the length entirely', () {
      // A Drive track has no duration until it plays; zero would read as an
      // empty track rather than an unknown one.
      final metadata = mprisMetadata(_song(duration: 0));
      expect(metadata.containsKey('mpris:length'), isFalse);
    });

    test('artist is an array, as the spec requires', () {
      final metadata = mprisMetadata(_song());
      expect(metadata['xesam:artist'], isA<DBusArray>());
      expect(
        (metadata['xesam:artist']! as DBusArray).children
            .map((v) => v.asString()),
        ['Moneda Dura'],
      );
    });

    test('every credited artist is listed when the track has them', () {
      final metadata = mprisMetadata(
        _song(
          artists: const [
            ArtistRef(id: 1, name: 'Moneda Dura', isPrimary: true),
            ArtistRef(id: 2, name: 'Guest', isPrimary: false),
          ],
        ),
      );
      expect(
        (metadata['xesam:artist']! as DBusArray).children
            .map((v) => v.asString()),
        ['Moneda Dura', 'Guest'],
      );
    });

    test('an empty artist name is dropped rather than shown as a blank', () {
      final metadata = mprisMetadata(_song(artist: ''));
      expect((metadata['xesam:artist']! as DBusArray).children, isEmpty);
    });

    test('optional fields appear only when there is something to say', () {
      final bare = mprisMetadata(_song());
      expect(bare.containsKey('xesam:albumArtist'), isFalse);
      expect(bare.containsKey('xesam:trackNumber'), isFalse);
      expect(bare.containsKey('xesam:genre'), isFalse);
      expect(bare.containsKey('mpris:artUrl'), isFalse);

      final full = mprisMetadata(
        _song(
          albumArtist: 'Moneda Dura',
          trackNumber: 4,
          genre: 'Rock',
          albumArtPath: '/cache/art.jpg',
        ),
      );
      expect(full['xesam:trackNumber'], const DBusInt32(4));
      expect(full.containsKey('xesam:albumArtist'), isTrue);
      expect(full.containsKey('xesam:genre'), isTrue);
      expect(full.containsKey('mpris:artUrl'), isTrue);
    });

    test('no song still yields a usable map with a track id', () {
      // Clients key on trackid; omitting it confuses them more than an empty
      // map would.
      final metadata = mprisMetadata(null);
      expect(metadata['mpris:trackid'], isA<DBusObjectPath>());
      expect(metadata.containsKey('xesam:title'), isFalse);
    });

    test('the track id follows the queue position', () {
      expect(mprisMetadata(_song(), index: 7)['mpris:trackid'],
          mprisTrackId(7));
    });

    test('the whole map survives being packed for the bus', () {
      // A wrong value type here fails at send time, far from the cause.
      final metadata = mprisMetadata(
        _song(albumArtPath: '/cache/art.jpg', trackNumber: 2, genre: 'Rock'),
      );
      expect(
        () => DBusDict.stringVariant(metadata),
        returnsNormally,
      );
    });
  });

  group('URIs', () {
    test('a path on disk becomes a file URI', () {
      expect(mprisArtUrl('/cache/art.jpg'), 'file:///cache/art.jpg');
      expect(mprisTrackUrl('/music/track.mp3'), 'file:///music/track.mp3');
    });

    test('a remote URL is already a URI and is left alone', () {
      expect(
        mprisArtUrl('https://server/art.jpg'),
        'https://server/art.jpg',
      );
      expect(
        mprisTrackUrl('https://server/stream?id=1'),
        'https://server/stream?id=1',
      );
    });

    test('a path with spaces is escaped', () {
      // An unescaped space makes the URI invalid and the art silently missing.
      expect(mprisArtUrl('/cache/my art.jpg'), 'file:///cache/my%20art.jpg');
    });

    test('nothing to point at yields nothing', () {
      expect(mprisArtUrl(null), isNull);
      expect(mprisArtUrl(''), isNull);
      expect(mprisTrackUrl(''), isEmpty);
    });
  });

  group('names', () {
    test('the bus name and path are the ones the spec fixes', () {
      // Any deviation and no client finds the player at all.
      expect(mprisBusName, startsWith('org.mpris.MediaPlayer2.'));
      expect(mprisObjectPath, '/org/mpris/MediaPlayer2');
      expect(mprisRootInterface, 'org.mpris.MediaPlayer2');
      expect(mprisPlayerInterface, 'org.mpris.MediaPlayer2.Player');
    });

    test('the bus name is a legal one', () {
      // Dots separate elements, and no element may start with a digit.
      for (final element in mprisBusName.split('.')) {
        expect(element, isNotEmpty);
        expect(RegExp(r'^[A-Za-z_-]').hasMatch(element), isTrue);
      }
    });
  });
}
