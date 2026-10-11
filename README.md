# spotify-JPOriginalTitles

On Spotify iOS 9.1.88, some Japanese tracks show English or romanized titles, while the Mac desktop app and 9.1.28 show the originals. This plugin restores the original names.

This repository contains only the prebuilt plugin and this document.

| Version | File | Scope |
| --- | --- | --- |
| v6 (recommended) | `jp-original-titles/dist/v6/JPOriginalTitles.dylib` | v5, plus search results and working artist links |
| v5 | `jp-original-titles/dist/JPOriginalTitles.dylib` | Playlists, album pages, player bar and queue |

## Screenshots

Mac desktop app (left) next to the patched Spotify on an iOS 18.6.2 virtual machine (right). Titles and artists match the originals on both sides.

Playlist:

![Playlist: Mac desktop and patched iOS](screenshots/playlist.jpeg)

Album page:

![Album: Mac desktop and patched iOS](screenshots/album.jpeg)

## Symptom and cause

- The client fetches metadata with `POST https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata`.
- The server replaces the `IdentityTrait` (extension kind 178) of Japanese originals with a romanized international sibling. 9.1.88 uses this field for the player bar, queue and playlists; 9.1.28 and the Mac app use `TRACK_V4` (kind 10).
- Playlists reference the romanized URI, but its `canonical_uri` points to the Japanese original.
- Artist names are localized by the `Accept-Language` header: `en`, `ko` or no header returns English names, `zh-Hans` / `zh-Hant` return the original names, and `ja` turns some Chinese artists into katakana.

These are results observed on one account (one set of tracks, playlists and languages). Other accounts and regions may differ.

## How it works

The plugin hooks the app's networking layer and does not modify the Spotify main binary:

1. It intercepts extended-metadata requests. If a batch asks for kind 178 without `TRACK_V4`, it adds `TRACK_V4` (request bodies may be gzip and are decompressed first).
2. When the response arrives, it rewrites the track name, album name and artist names inside `IdentityTrait`.
3. Per field, it uses the original value when the client value has no CJK characters and the original does; otherwise it keeps the client value.
4. If a romanized track has a canonical original and its own name has no CJK characters, it is mapped to the original. English songs are untouched (for example, "Never Gonna Give You Up" is not swapped for its Remaster).
5. If the client request language is not Chinese, it queries `TRACK_V4` again with `Accept-Language: zh-Hans` as the source of originals. If the client is already Chinese, it only fetches the canonical originals. If that fetch fails, the client values are kept.

### v6: artists and search

- **Artist links.** In v5, tapping an artist of a mapped track opened the original artist, which is region-locked here and shows an empty page. v6 keeps the client's own (international) artist URIs and only replaces their names with the originals. Artists are matched by position, and only when both tracks list the same number of artists; otherwise the v5 behavior is kept.
- **Learned artist names.** Each such pair (international artist URI -> original name) is stored in `NSUserDefaults` (`JPOriginalTitlesArtistNames`, cleared after 5000 entries). It is used to rename those artists wherever they appear as entities in extended-metadata. A name is only known after the plugin has seen one of the artist's tracks.
- **Search.** Search uses `GET …/searchview/v3/search`, which returns protobuf (`MainViewResponse`) through `HttpClientURLSession`. v6 holds the response, fetches `TRACK_V4` (`zh-Hans`) and the canonical originals for tracks it has not cached yet, and rewrites track rows (name, album, artists), album rows (name, artists, and the album link to the original album) and artist rows. Playlist names are user content and stay as they are.
- The cache version is now `6`, so the metadata cache is cleared once more after upgrading from v5.

## Usage

Requirements: Spotify iOS 9.1.88 and an app that already loads `Frameworks/*.dylib` through a plugin manager (it was tested with a build that ships LoadControl).

1. Put `JPOriginalTitles.dylib` (v6 recommended) into `Payload/Spotify.app/Frameworks/` (mode 755), then repackage and install. Use one version only; both files have the same name.
2. On first launch the plugin deletes `Library/Application Support/PersistentCache/Users/*/primary.ldb` once (the metadata cache) so stale romanized entries are fetched again. Login and settings are kept. The Bluetooth permission intro may appear once more, and your library and playlists resync.
3. v6 writes no log and deletes the `Documents/JPOriginalTitles.log` left by v5. v5 recreates that log on every launch; lines such as `hooked delegate ...` and `purge ...: removed` mean it is active.

To force a cache clear later, quit Spotify and delete that `primary.ldb` directory manually.

## Known limitations

- Only `IdentityTrait` is rewritten; `TRACK_V4` entries requested by the client keep the client language. With a non-Chinese client, screens that read `TRACK_V4` may still show localized artist names.
- The large name at the top of an artist page stays in the client language (for example "Yachiyo Runami(cv.Saori Hayami)"), even after a fresh install. Its popular tracks and the artist list in the player are shown in the original language. The menu opened from "More" also stays in English.
- Search results appear slightly later when the plugin has to fetch metadata for new tracks first (one or two extra requests). Only results of a submitted search were checked; live suggestions while typing were not checked separately.
- Region-locked original artists themselves remain empty; v6 avoids opening them instead of unlocking them.
- Offline playback of downloaded songs after a cache clear is unverified (inference: the first playback may need a connection).
- Verified on an iOS 18.6.2 virtual machine (vphone). Not retested on a physical device with LiveContainer.
- It depends on internal Spotify class names (such as `SPTCoreURLSessionDataDelegate`) and protocol fields, so a Spotify update may break it.

## Checksum

```
sha256  e74886344b11261db0e26025001de286fa1475dd941394f4bb7850932cf72c9f  dist/v6/JPOriginalTitles.dylib
sha256  5af4f822301436b4e391d477165d83f8623fe9e31bdc0e70ab496466acbf703d  dist/JPOriginalTitles.dylib (v5)
```

Both are arm64, minimum iOS 14.0, ad-hoc signed.

## Disclaimer

Not affiliated with Spotify. For personal learning and research only. Follow your local laws and Spotify's terms of service.
