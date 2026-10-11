# spotify-JPOriginalTitles

On Spotify iOS 9.1.88, some Japanese tracks show English or romanized titles, while the Mac desktop app and 9.1.28 show the originals. This plugin restores the original names.

This repository contains only the prebuilt `JPOriginalTitles.dylib` and this document.

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

## Usage

Requirements: Spotify iOS 9.1.88 and an app that already loads `Frameworks/*.dylib` through a plugin manager (it was tested with a build that ships LoadControl).

1. Put `JPOriginalTitles.dylib` into `Payload/Spotify.app/Frameworks/` (mode 755), then repackage and install.
2. On first launch the plugin deletes `Library/Application Support/PersistentCache/Users/*/primary.ldb` once (the metadata cache) so stale romanized entries are fetched again. Login and settings are kept. The Bluetooth permission intro may appear once more, and your library and playlists resync.
3. The log is written to `Documents/JPOriginalTitles.log` and recreated on every launch. Lines such as `hooked delegate ...` and `purge ...: removed` mean it is active.

To force a cache clear later, quit Spotify and delete that `primary.ldb` directory manually.

## Known limitations

- Only `IdentityTrait` is rewritten; `TRACK_V4` entries requested by the client keep the client language. With a non-Chinese client, screens that read `TRACK_V4` may still show localized artist names.
- Screens that may use other endpoints (such as search) were not checked separately.
- Offline playback of downloaded songs after a cache clear is unverified (inference: the first playback may need a connection).
- Verified on an iOS 18.6.2 virtual machine (vphone). Not retested on a physical device with LiveContainer.
- It depends on internal Spotify class names (such as `SPTCoreURLSessionDataDelegate`) and protocol fields, so a Spotify update may break it.

## Checksum

```
sha256  5af4f822301436b4e391d477165d83f8623fe9e31bdc0e70ab496466acbf703d  JPOriginalTitles.dylib
```

arm64, minimum iOS 14.0, ad-hoc signed.

## Disclaimer

Not affiliated with Spotify. For personal learning and research only. Follow your local laws and Spotify's terms of service.
