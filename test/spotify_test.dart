import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/remote/spotify/spotify_api.dart';
import 'package:pixelplay_desktop/data/remote/spotify/spotify_auth.dart';
import 'package:pixelplay_desktop/data/remote/spotify/spotify_match.dart';

/// The matcher is the part that decides whether the importer is useful at all,
/// and it is pure — so it is tested against the cases that actually appear:
/// remasters, features, accents, covers and different edits.

Song _song({
  String title = 'Al Sudeste',
  String artist = 'Moneda Dura',
  String album = 'Sin Blasfemias',
  int duration = 249000,
  String? albumArtist,
  List<ArtistRef> artists = const [],
  String id = '/music/a.mp3',
}) => Song(
  id: id,
  title: title,
  artist: artist,
  artistId: artist.hashCode.abs(),
  artists: artists,
  album: album,
  albumId: album.hashCode.abs(),
  albumArtist: albumArtist,
  path: id,
  duration: duration,
);

SpotifyTrack _track({
  String title = 'Al Sudeste',
  List<String> artists = const ['Moneda Dura'],
  String? album = 'Sin Blasfemias',
  int? durationMs = 249000,
  String? isrc,
}) => SpotifyTrack(
  id: 'sp1',
  title: title,
  artists: artists,
  album: album,
  durationMs: durationMs,
  isrc: isrc,
);

void main() {
  group('normalising', () {
    test('remaster and edition noise is stripped', () {
      expect(
        normaliseTitle('Al Sudeste - Remastered 2011'),
        normaliseTitle('Al Sudeste'),
      );
      expect(
        normaliseTitle('Thriller (Deluxe Edition)'),
        normaliseTitle('Thriller'),
      );
    });

    test('featured artists in the title are dropped', () {
      expect(
        normaliseTitle('Song (feat. Someone Else)'),
        normaliseTitle('Song'),
      );
      expect(normaliseTitle('Song ft. Someone'), normaliseTitle('Song'));
    });

    test('accents and punctuation stop mattering', () {
      expect(normaliseTitle('Mágico'), normaliseTitle('Magico'));
      expect(normaliseTitle("Don't Stop"), normaliseTitle('Dont Stop'));
      expect(normaliseTitle('¿Y Qué?'), normaliseTitle('Y Que'));
    });

    test('a meaningful dash clause survives', () {
      // "- Remastered" is noise; "- Part Two" is the title.
      expect(normaliseTitle('Song - Part Two'), isNot(normaliseTitle('Song')));
      expect(normaliseTitle('Song - Remastered'), normaliseTitle('Song'));
    });

    test('artist lists are split so orderings agree', () {
      expect(
        normaliseArtists(['Calle 13 & Rubén Blades']),
        normaliseArtists(['Ruben Blades, Calle 13']),
      );
      expect(normaliseArtists(['A feat. B']), containsAll(['a', 'b']));
    });
  });

  group('matching', () {
    test('an exact track matches strongly', () {
      final match = matchTrack(_track(), [_song()]);
      expect(match.matched, isTrue);
      expect(match.confidence, MatchConfidence.strong);
      expect(match.score, greaterThanOrEqualTo(85));
    });

    test('a remaster matches the plain local file', () {
      final match = matchTrack(
        _track(title: 'Al Sudeste - Remastered 2011'),
        [_song()],
      );
      expect(match.matched, isTrue);
    });

    test('an accented local tag still matches', () {
      final match = matchTrack(
        _track(title: 'Como Fue', artists: ['Benny More']),
        [_song(title: 'Cómo Fué', artist: 'Benny Moré', album: 'Mágico')],
      );
      expect(match.matched, isTrue);
    });

    test('a cover by another artist is not the same recording', () {
      // Same title, different artist: the commonest false positive.
      final match = matchTrack(
        _track(),
        [_song(artist: 'Someone Else Entirely')],
      );
      expect(match.matched, isFalse);
    });

    test('a different edit matches, but only loosely', () {
      // Four minutes against six is a different version, and the import should
      // say so rather than pretend.
      final match = matchTrack(
        _track(durationMs: 240000),
        [_song(duration: 380000)],
      );
      expect(match.matched, isTrue);
      expect(match.confidence, MatchConfidence.loose);
    });

    test('the best of several candidates wins', () {
      final match = matchTrack(_track(), [
        _song(title: 'Al Sudeste (Live)', duration: 300000, id: '/live.mp3'),
        _song(id: '/studio.mp3'),
      ]);
      expect(match.song!.id, '/studio.mp3');
    });

    test('an unrelated library yields no match, not a bad one', () {
      final match = matchTrack(_track(), [
        _song(title: 'Something Completely Different', artist: 'Nobody'),
      ]);
      expect(match.matched, isFalse);
      expect(match.song, isNull);
      expect(match.confidence, MatchConfidence.none);
    });

    test('an empty library matches nothing without throwing', () {
      expect(matchTrack(_track(), const []).matched, isFalse);
      expect(matchTracks([_track()], const []), hasLength(1));
    });

    test('a secondary artist tag is enough to match', () {
      // Spotify lists every credited artist; the local file often names one.
      final match = matchTrack(
        _track(artists: ['Someone Else', 'Moneda Dura']),
        [_song(artists: const [
          ArtistRef(id: 1, name: 'Moneda Dura', isPrimary: true),
        ])],
      );
      expect(match.matched, isTrue);
    });

    test('order is preserved across a playlist', () {
      final matches = matchTracks(
        [_track(title: 'One'), _track(title: 'Al Sudeste')],
        [_song()],
      );
      expect(matches, hasLength(2));
      expect(matches.first.matched, isFalse);
      expect(matches.last.matched, isTrue);
    });

    test('a search query for a miss carries artist and title', () {
      final query = searchQueryFor(
        _track(title: 'Al Sudeste - Remastered', artists: ['Moneda Dura']),
      );
      expect(query, contains('moneda dura'));
      expect(query, contains('al sudeste'));
      expect(query, isNot(contains('remastered')));
    });
  });

  group('PKCE', () {
    test('the verifier is long enough and uses only unreserved characters', () {
      // RFC 7636 wants 43–128 characters from an unreserved set.
      final verifier = SpotifyAuth.createVerifier();
      expect(verifier.length, inInclusiveRange(43, 128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    });

    test('two verifiers differ', () {
      expect(
        SpotifyAuth.createVerifier(),
        isNot(SpotifyAuth.createVerifier()),
      );
    });

    test('the challenge is unpadded base64url of the SHA-256', () {
      const verifier = 'abc123';
      final expected = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      expect(SpotifyAuth.challengeFor(verifier), expected);
      expect(SpotifyAuth.challengeFor(verifier), isNot(contains('=')));
    });
  });

  group('authorize URL', () {
    const auth = SpotifyAuth(clientId: 'client-123');

    test('it carries the code challenge, never the verifier', () {
      // Sending the verifier would defeat the entire point of PKCE.
      final verifier = SpotifyAuth.createVerifier();
      final url = auth.authorizeUrl(verifier: verifier, state: 'st');

      expect(url.host, 'accounts.spotify.com');
      expect(url.queryParameters['client_id'], 'client-123');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        SpotifyAuth.challengeFor(verifier),
      );
      expect(url.toString(), isNot(contains(verifier)));
    });

    test('the redirect is loopback only', () {
      expect(auth.redirectUri, 'http://127.0.0.1:8888/callback');
      expect(
        auth.authorizeUrl(verifier: 'v', state: 's').queryParameters['redirect_uri'],
        auth.redirectUri,
      );
    });

    test('the scopes are read-only, with nothing about playback', () {
      // Asking for playback scopes would imply this can play Spotify audio.
      expect(spotifyScopes, contains('playlist-read-private'));
      expect(spotifyScopes, contains('user-library-read'));
      expect(
        spotifyScopes.any((scope) => scope.contains('modify')),
        isFalse,
      );
      expect(
        spotifyScopes.any((scope) => scope.contains('streaming')),
        isFalse,
      );
    });

    test('connecting without a client ID fails before opening a browser', () {
      expect(
        const SpotifyAuth(clientId: '  ').authorize(),
        throwsA(
          isA<SpotifyAuthException>().having(
            (e) => e.message,
            'message',
            contains('client ID'),
          ),
        ),
      );
    });
  });

  group('parsing tracks', () {
    test('a full track object is read', () {
      final track = SpotifyApi.parseTrack({
        'id': 'abc',
        'name': 'Al Sudeste',
        'duration_ms': 249000,
        'artists': [
          {'name': 'Moneda Dura'},
          {'name': 'Guest'},
        ],
        'album': {'name': 'Sin Blasfemias'},
        'external_ids': {'isrc': 'CUA010100001'},
      });

      expect(track, isNotNull);
      expect(track!.title, 'Al Sudeste');
      expect(track.artists, ['Moneda Dura', 'Guest']);
      expect(track.album, 'Sin Blasfemias');
      expect(track.durationMs, 249000);
      expect(track.isrc, 'CUA010100001');
      expect(track.primaryArtist, 'Moneda Dura');
    });

    test('a local file or podcast episode in a playlist is skipped', () {
      // Spotify returns these with a null id, and nothing can be done with one.
      expect(SpotifyApi.parseTrack({'name': 'Local file'}), isNull);
      expect(SpotifyApi.parseTrack({'id': 'x'}), isNull);
      expect(SpotifyApi.parseTrack(null), isNull);
      expect(SpotifyApi.parseTrack('not an object'), isNull);
    });

    test('a track with no album or duration still parses', () {
      final track = SpotifyApi.parseTrack({'id': 'a', 'name': 'T'});
      expect(track, isNotNull);
      expect(track!.album, isNull);
      expect(track.durationMs, isNull);
      expect(track.artists, isEmpty);
    });
  });

  group('tokens', () {
    test('a token near its expiry counts as expired', () {
      // A minute of slack, so a long request does not start on a dying token.
      final almost = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(almost.isExpired, isTrue);

      final fresh = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      );
      expect(fresh.isExpired, isFalse);
    });
  });
}
