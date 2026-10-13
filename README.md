# spotify-JPOriginalTitles

On Spotify iOS 9.1.88, some Japanese tracks show English or romanized titles, while the Mac desktop app and 9.1.28 show the originals. This plugin restores the original names.

This repository contains the prebuilt plugins and this document.

| Version | File | Scope |
| --- | --- | --- |
| v6.1.1 | [JPOriginalTitles.dylib](jp-original-titles/dist/v6.1.1/JPOriginalTitles.dylib) | v6.1, plus uncompressed metadata requests and a refresh of old missed responses |
| v6.1 | [JPOriginalTitles.dylib](jp-original-titles/dist/v6.1/JPOriginalTitles.dylib) | v6, client TRACK_V4 names and structured titles, a cache refresh and English maintenance controls |
| v6 | `jp-original-titles/dist/v6/JPOriginalTitles.dylib` | v5, plus search results and working artist links |
| v5 | `jp-original-titles/dist/JPOriginalTitles.dylib` | Playlists, album pages, player bar and queue |

## Screenshots

Mac desktop app compared with patched Spotify on an iOS 18.6.2 virtual machine.

Playlist:

![Playlist: Mac desktop and patched iOS](screenshots/playlist.jpeg)

Album page:

![v6 artist page: original Japanese names and working artist links on patched iOS](screenshots/album.jpeg)

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
- The cache version is now `6`, so the metadata cache is cleared once more after upgrading from v5.

### v6.1: cache repair and maintenance

- **Display names.** Client-requested TRACK_V4 names, album/artist names and structured title fields are rewritten alongside IdentityTrait. Name queries omit old etags; missing own-track data can be recovered before the canonical lookup.
- **Cache repair.** Old playback restoration can bring English metadata back after primary.ldb is cleared. Metadata and playback resume state have separate reset checkboxes. Select both to clear the reported stale-title case; playback state is deleted directly without creating a backup.
- **Maintenance page.** Open Settings and privacy, then tap **Original Titles** directly below **Eevee Settings**. The page shows plugin/Spotify versions, network hook status, cache counts and the last reset result. It adds persistent diagnostic logging, export through the system share sheet, log clearing, and three cache reset options.

### v6.1.1: Japanese titles changing back to English

Some tracks briefly showed their Japanese title, then switched to English in the player while the menu or album page stayed Japanese. The request hook treated an absent `Content-Encoding` header as gzip: Objective-C messaging to `nil` returns zero, which equals `NSOrderedSame`. Decompressing the plain protobuf body failed, so those metadata requests bypassed both rewriting and etag removal.

v6.1.1 only decompresses requests with an explicit gzip header. Its cache version is also 6.1.1: upgrading refreshes the old metadata/library index once, because repairing the hook alone leaves previously cached English IdentityTrait data available. Playback resume state is preserved. The three reset options keep their v6.1 behavior.

## Usage

Requirements: Spotify iOS 9.1.88 and an app that already loads `Frameworks/*.dylib` through a plugin manager (it was tested with a build that ships LoadControl).

1. Download v6.1.1 from the table above and put `JPOriginalTitles.dylib` into `Payload/Spotify.app/Frameworks/` (mode 755), then repackage and install. Use one version only; all versions have the same filename. Physical LiveContainer validation is pending.
2. On the first launch after upgrading from a cache version other than 6.1.1, the plugin removes `Library/Application Support/PersistentCache/Users/*/primary.ldb` once. This automatic migration leaves playback resume state untouched.
3. Open **Settings and privacy → Original Titles**, directly below **Eevee Settings**. The page is in English.
4. Select the reset options below, then tap **Apply**. Apply saves the selection and immediately closes Spotify. Reopen Spotify to run only the selected resets.

| Reset checkbox | Effect |
| --- | --- |
| **Reset Plugin Name Cache** | Clear original-track lookups and learned artist names. |
| **Reset Spotify Metadata and Library Index** | Clear `PersistentCache/Users/*/primary.ldb` and the plugin name cache. Online library resync is required; playback resume state is kept. |
| **Reset Playback Resume State** | Delete `PersistentCache/Users/*/context_player_state_restore` directly, without creating a backup. The saved playback queue and position are cleared; metadata and plugin caches are kept when this is the only selected option. |

To fix the reported English ray cache, select **both metadata and playback resume resets** before Apply.
Login, preferences, Keychain and audio files are kept.

## Known limitations

- A separate international release whose `canonical_uri` points to itself cannot be mapped to a Japanese release from the available metadata. For example, the English-search ILLIT track `6VedlO2MtaEjAITax6vQyg` stays English; the tested Japanese track is `7LFuSAGcZKLP2EVO4iSzkz`. The plugin does not guess a replacement by title alone.
- Original-name lookups require the server to return the corresponding metadata. Offline or failed lookups keep the available client values.
- The large name at the top of an artist page stays in the client language (for example "Yachiyo Runami(cv.Saori Hayami)"), even after a fresh install. Its popular tracks and the artist list in the player are shown in the original language. The menu opened from "More" also stays in English.
- Search results appear slightly later when the plugin has to fetch metadata for new tracks first (one or two extra requests). Only results of a submitted search were checked; live suggestions while typing were not checked separately.
- Region-locked original artists themselves remain empty; v6 avoids opening them instead of unlocking them.
- Offline playback of downloaded songs after a cache clear is unverified (inference: the first playback may need a connection).
- It depends on internal Spotify class names (such as `SPTCoreURLSessionDataDelegate`) and protocol fields, so a Spotify update may break it.

## Checksum

Paths below are relative to the repository root.

```
sha256  ba538fe23846e6ef874df935b1e4bab64ced43dacd380edbb67dc55d8a4f3d1f  jp-original-titles/dist/v6.1.1/JPOriginalTitles.dylib
sha256  d61e9933fd65de8bceb05217f8be260678b67fcffc5ffb250d1fa1b1ef36526c  jp-original-titles/dist/v6.1/JPOriginalTitles.dylib
sha256  e74886344b11261db0e26025001de286fa1475dd941394f4bb7850932cf72c9f  jp-original-titles/dist/v6/JPOriginalTitles.dylib
sha256  5af4f822301436b4e391d477165d83f8623fe9e31bdc0e70ab496466acbf703d  jp-original-titles/dist/JPOriginalTitles.dylib
```

All plugins are arm64, minimum iOS 14.0, ad-hoc signed.

## Disclaimer

Not affiliated with Spotify. For personal learning and research only. Follow your local laws and Spotify's terms of service.
