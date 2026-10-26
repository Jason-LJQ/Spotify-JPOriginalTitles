# spotify-JPOriginalTitles

An iOS plugin that restores original track, album and artist names in Spotify 9.1.88.

This repository contains prebuilt dylibs and installation instructions.

| Version               | Download | Features |
|-----------------------| --- | --- |
| v7.x, current release | [JPOriginalTitles.dylib](https://github.com/Jason-LJQ/Spotify-JPOriginalTitles/releases/download/v7.1.1/JPOriginalTitles.dylib) | Original names, original metadata in Credits, SQLite storage and optional metadata refresh on upgrade |
| v6.3.3                | JPOriginalTitles.dylib] | Original names, artist links, search, associated-album matching and maintenance controls |
| v5                    | JPOriginalTitles.dylib | Original names in playlists, album pages, the player bar and queue |

## Screenshots

Playlist:

![Playlist](screenshots/playlist.jpeg)

Artist page:

![Artist page](screenshots/album.jpeg)

## How it works

The plugin rewrites metadata in Spotify's networking layer without changing the Spotify main binary.

- Shows names received before rewriting under **Original Metadata** in Credits. **Title**, **Artist** and **Album** appear only when a nonempty prior value was actually replaced. Equal values can share one native row with multiple labels. Ordinary track titles are not expanded.
- Shows changed song titles as **Original title｜Previous title** by default, joined by U+FF5C without spaces. Album and artist names show only the original name. The option can be turned off on the management page.
- Restores track, album and artist names in IdentityTrait and client-requested TRACK_V4 metadata, including structured title fields.
- Replaces a delivered name only when a name without CJK text gains CJK text. Chinese, Latin-only and case-only differences from another release keep Spotify's values. Each artist is checked separately.
- Uses a track's canonical release when it supplies an original CJK name. Otherwise, it can follow a server-provided album association, an observed reverse canonical link or a sibling track’s canonical release. Indirect track matches require a unique ISRC with identical duration, disc and track number; reverse and sibling matches require a canonical link to the requested track or to its resolved, non-CJK canonical target. Sibling-release discovery runs only when the observed performance language is Japanese, undetermined, non-linguistic, or absent.
- Looks up artist names independently. Chinese-language CJK names take priority; Japanese fallback names must contain kanji or hiragana. Pure katakana fallback names are rejected.
- Resolves names on original-release artist entities before retaining the client's artist links, and applies learned names to artist entities, track contributors and search results. Playlist names remain user content.
- Handles plain and gzip metadata requests and removes old name-query etags so refreshed metadata can be rewritten.
- Processes large original-name lookups in batches with limited concurrency. Request failures can retry in smaller batches, and incomplete responses retry only the affected entities. By default, verified changes are retained, while unresolved names and unparseable entries keep Spotify’s values. Failed items remain retryable; diagnostics record warnings when enabled.

Completed lookups without an unambiguous original name keep the available client value. The plugin does not guess replacements by title, change the app language or unlock region-restricted content. Korean and song-title multilingual fallback are not enabled.

## Installation

Requires Spotify iOS 9.1.88 with a plugin loader that loads `Frameworks/*.dylib`.

1. Download the latest release.
2. Put `JPOriginalTitles.dylib` into `Payload/Spotify.app/Frameworks/` with mode 755, then repackage and install. Keep only one version of the plugin.
3. Open **Settings and privacy → Original Titles**, directly below **Eevee Settings**.

On first installation and once for each plugin version, a short prompt offers to clear cached data. Spotify metadata, playback resume state, login, preferences, Keychain and audio files are retained unless their reset is selected.

All dylibs are arm64, require iOS 14.0 or later, and are ad-hoc signed.

## Maintenance

The English management page includes versions, hook status, database row counts and file size, the title display switch, diagnostic logging, strict mode, log export and log clearing.  

**Show Original and Previous Song Titles** is on by default. New responses follow the switch immediately. Switching it selects **Reset Spotify Metadata and Library Index** and shows a notice; titles already cached by Spotify keep their previous display until that reset is applied. The reset is not forced: tap **Apply** to run it, or deselect it.

**Strict Mode** is off by default and takes effect immediately. When enabled, a failed original-name lookup or an unparseable client response fails the request instead of delivering names without enhancement. This can cause pages or search results to fail to load. Search can still use cached names before a metadata request template is available.

Select the required reset checkboxes, then tap **Apply**. Spotify closes immediately; reopen it to run the selected resets.

| Reset checkbox | Effect |
| --- | --- |
| **Reset Plugin Cache** | Clear original-name lookups, learned artist names and previous-metadata records. |
| **Reset Spotify Metadata and Library Index** | Clear `PersistentCache/Users/*/primary.ldb`. The library resyncs online; plugin data and playback resume state are retained unless selected separately. |
| **Reset Playback Resume State** | Delete `PersistentCache/Users/*/context_player_state_restore` directly, without a backup. Clear the saved playback queue and position. |

Spotify metadata and playback resets are optional maintenance actions and run only when explicitly selected. Login, preferences, Keychain and audio files are retained.

## Limitations

- Original metadata is collected from fresh responses after installation; names already rewritten in Spotify’s cache cannot be recovered retrospectively. Existing Credits cache entries appear as stored until they refresh. The optional startup cleanup or the metadata reset control can fetch fresh data.
- Original-name lookup depends on server metadata and connectivity. Extra lookups can delay pages or search results. Unresolved names delivered after a failed lookup can remain in Spotify’s metadata cache until it refreshes. Strict mode does not repair already cached names; use the metadata reset option to fetch them again.
- Releases without a usable canonical link or unambiguous album match remain unchanged. Standalone album-page titles follow only server-provided album associations. Some native album-navigation actions retain the client’s original album ID.
- Pure-katakana Japanese artist names may remain romanized, and some other locale-dependent text may retain the client name.
- Region-restricted original artist pages remain restricted; the plugin keeps the client's artist links.
- Spotify updates can change the internal classes and protocol fields used by the plugin.

## Disclaimer

Not affiliated with Spotify. For personal learning and research only. Follow your local laws and Spotify's terms of service.
