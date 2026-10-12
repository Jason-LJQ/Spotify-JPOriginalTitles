# spotify-JPOriginalTitles

On Spotify iOS 9.1.88, some Japanese tracks show English or romanized titles, while the Mac desktop app and 9.1.28 show the originals. This plugin restores the original names.

This repository contains the prebuilt plugins and this document.

| Version | File | Scope |
| --- | --- | --- |
| v6.1 r3 (candidate) | [JPOriginalTitles.dylib](jp-original-titles/dist/v6.1/r3/JPOriginalTitles.dylib) | v6, client TRACK_V4 names and structured titles, a cache refresh and English maintenance controls |
| v6 | `jp-original-titles/dist/v6/JPOriginalTitles.dylib` | v5, plus search results and working artist links |
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
5. Missing track data is fetched with `Accept-Language: zh-Hans`, followed by a canonical lookup when needed. Non-Chinese clients also use this lookup for original-language names. Failed lookups keep the available client values.

### v6: artists and search

- **Artist links.** In v5, tapping an artist of a mapped track opened the original artist, which is region-locked here and shows an empty page. v6 keeps the client's own (international) artist URIs and only replaces their names with the originals. Artists are matched by position, and only when both tracks list the same number of artists; otherwise the v5 behavior is kept.
- **Learned artist names.** Each such pair (international artist URI -> original name) is stored in `NSUserDefaults` (`JPOriginalTitlesArtistNames`, cleared after 5000 entries). It is used to rename those artists wherever they appear as entities in extended-metadata. A name is only known after the plugin has seen one of the artist's tracks.
- **Search.** Search uses `GET …/searchview/v3/search`, which returns protobuf (`MainViewResponse`) through `HttpClientURLSession`. v6 holds the response, fetches `TRACK_V4` (`zh-Hans`) and the canonical originals for tracks it has not cached yet, and rewrites track rows (name, album, artists), album rows (name, artists, and the album link to the original album) and artist rows. Playlist names are user content and stay as they are.
- The cache version stays `6`. Upgrading from v5 clears the metadata cache once; replacing an existing v6 does not automatically clear it.

### v6.1 r3: cache repair and maintenance

- **Display names.** Client-requested TRACK_V4 names, album/artist names and structured title fields are rewritten alongside IdentityTrait. Name queries omit old etags; missing own-track data can be recovered before the canonical lookup.
- **Cache repair.** Old playback restoration can bring English metadata back after primary.ldb is cleared. Metadata reset backs up and moves aside the playback restoration file before clearing the database.
- **Maintenance page.** Open Settings and privacy, then tap **Original Titles** directly below **Eevee Settings**. The page shows plugin/Spotify versions, network hook status, cache counts and the last reset result. It adds persistent diagnostic logging, export through the system share sheet, log clearing, and two cache reset scopes.

## Usage

Requirements: Spotify iOS 9.1.88 and an app that already loads `Frameworks/*.dylib` through a plugin manager (it was tested with a build that ships LoadControl).

1. Download v6.1 r3 from the table above and put `JPOriginalTitles.dylib` into `Payload/Spotify.app/Frameworks/` (mode 755), then repackage and install. Use one version only; all versions have the same filename. v6.1 r3 passed the vphone tests below; physical LiveContainer validation is pending.
2. On the first launch after upgrading from a cache version other than 6.1, the plugin backs up and moves aside the playback restoration file and removes `Library/Application Support/PersistentCache/Users/*/primary.ldb` once to fetch stale names again. Login and settings are kept. The Bluetooth intro may reappear, and your library and playlists resync. If a database is already open or deletion fails, the page reports the failure and offers an explicit retry.
3. Open **Settings and privacy → Original Titles**, directly below the Eevee Settings row. The maintenance page is in English. Diagnostic logging is off by default. Enable it before reproducing an issue, then use **Export Diagnostics** to save or share status and logs. **Clear Logs** removes the retained log files. Logs may contain track names and URIs; the current and previous files are limited to 1 MB each.
4. Select **Reset Plugin Name Cache** or **Reset Spotify Metadata and Library Index**, then tap **Apply**. Apply saves the request and immediately closes Spotify. Reopen Spotify to perform the reset. Metadata reset includes the plugin cache, backs up and moves aside `PersistentCache/Users/*/context_player_state_restore`, then removes `primary.ldb`; it requires online resync. The current playback queue and position reset; previous playback-state bytes remain in a `.jpt-resume-backup-<UUID>` file in the same user directory. Login, preferences, Keychain and audio files are kept. Unsynced offline library changes and downloaded playback after reset remain unverified.

## Cache repair and validation

Spotify caches TRACK_V4 and IdentityTrait independently. An old English IdentityTrait can remain visible even when a network TRACK_V4 response is Japanese. Clearing primary.ldb alone was insufficient for the reproduced ray case: restoring the old `context_player_state_restore` with an empty primary database brought English back; moving aside that file with an empty primary restored Japanese. Public/event caches were kept throughout this comparison.

v6.1 r3 passed two vphone tests with the plugin disabled to generate English cache, then reenabled before a metadata reset. One test also generated a new English playback restoration file by playing and pausing ray. After Apply and reopening, the popular list and active player showed `ray - 超かぐや姫！ Version`; the old playback state remained byte-for-byte intact in a backup. An app restart and a VM restart preserved the tested Japanese ray display without repeating the reset.

20 management checks and 32 metadata checks passed. The arm64 dylib's ad-hoc signature was verified. Runtime validation used the plugin in an existing Spotify 9.1.88 bundle on iOS 18.6.2. Physical LiveContainer and whole-IPA installation remain unverified. Earlier r1 failed on LiveContainer; r2 failed the subsequent cache reproduction, so these results apply specifically to r3.

**Upgrading an existing v6.1:** cache version remains `6.1`, so replacing r1 or r2 does not automatically reset it again. Select **Reset Spotify Metadata and Library Index**, tap **Apply**, and reopen Spotify once.

## Known limitations

- Automatic Spotify Connect/playback restoration can still show an English title or artist names for a different restored track. That path is not fully covered by the ray cache tests.
- Original-name lookups require the server to return the corresponding metadata. Offline or failed lookups keep the available client values.
- The large name at the top of an artist page stays in the client language (for example "Yachiyo Runami(cv.Saori Hayami)"), even after a fresh install. Its popular tracks and the artist list in the player are shown in the original language. The menu opened from "More" also stays in English.
- Search results appear slightly later when the plugin has to fetch metadata for new tracks first (one or two extra requests). Only results of a submitted search were checked; live suggestions while typing were not checked separately.
- Region-locked original artists themselves remain empty; v6 avoids opening them instead of unlocking them.
- Offline playback of downloaded songs after a cache clear is unverified (inference: the first playback may need a connection).
- Verified on an iOS 18.6.2 virtual machine (vphone). Not retested on a physical device with LiveContainer. The new page was tested while logged in; its logged-out entry and iPad popover have not been tested.
- It depends on internal Spotify class names (such as `SPTCoreURLSessionDataDelegate`) and protocol fields, so a Spotify update may break it.

## Checksum

Paths below are relative to the repository root.

```
sha256  6ca554ab047ed49beb2ae9e6ee9024d29366c3978e7ff200f35701bc62ac17ed  jp-original-titles/dist/v6.1/r3/JPOriginalTitles.dylib
sha256  e74886344b11261db0e26025001de286fa1475dd941394f4bb7850932cf72c9f  jp-original-titles/dist/v6/JPOriginalTitles.dylib
sha256  5af4f822301436b4e391d477165d83f8623fe9e31bdc0e70ab496466acbf703d  jp-original-titles/dist/JPOriginalTitles.dylib
```

All plugins are arm64, minimum iOS 14.0, ad-hoc signed.

## Disclaimer

Not affiliated with Spotify. For personal learning and research only. Follow your local laws and Spotify's terms of service.
