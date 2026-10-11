// Restores original-release track/album/artist names that Spotify 9.1.88 takes
// from relinked IdentityTrait (extension kind 178) metadata, by pairing every
// IdentityTrait track query with a TRACK_V4 (kind 10) query and copying the
// TRACK_V4 names back into the IdentityTrait payload. Alternative releases are
// mapped to their canonical (original) release through Track.canonical_uri, and
// names without CJK text fall back to a zh TRACK_V4 lookup when it has CJK text.
// Original names are written onto the client's own artist URIs, whose pages are
// not region-locked; learned artist names also rename artist entities and
// searchview results.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <zlib.h>

static const uint64_t kKindArtistV4 = 8;
static const uint64_t kKindSimpleCard = 97;
static const uint64_t kKindTrackV4 = 10;
static const uint64_t kKindIdentityTrait = 178;

#pragma mark - Protobuf wire helpers

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
} JPTReader;

typedef struct {
    uint32_t field;
    uint32_t wire;
    uint64_t varint;
    const uint8_t *data;
    size_t len;
    const uint8_t *start;
    const uint8_t *stop;
} JPTField;

static BOOL JPTReadVarint(JPTReader *r, uint64_t *out) {
    uint64_t value = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (r->p >= r->end) return NO;
        uint8_t b = *r->p++;
        value |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) {
            *out = value;
            return YES;
        }
    }
    return NO;
}

static BOOL JPTNext(JPTReader *r, JPTField *f, BOOL *ok) {
    *ok = YES;
    if (r->p >= r->end) return NO;
    f->start = r->p;
    uint64_t tag;
    if (!JPTReadVarint(r, &tag) || (tag >> 3) == 0) goto fail;
    f->field = (uint32_t)(tag >> 3);
    f->wire = (uint32_t)(tag & 7);
    f->data = NULL;
    f->len = 0;
    switch (f->wire) {
        case 0:
            if (!JPTReadVarint(r, &f->varint)) goto fail;
            break;
        case 1:
            if (r->end - r->p < 8) goto fail;
            r->p += 8;
            break;
        case 2: {
            uint64_t len;
            if (!JPTReadVarint(r, &len) || len > (uint64_t)(r->end - r->p)) goto fail;
            f->data = r->p;
            f->len = (size_t)len;
            r->p += len;
            break;
        }
        case 5:
            if (r->end - r->p < 4) goto fail;
            r->p += 4;
            break;
        default:
            goto fail;
    }
    f->stop = r->p;
    return YES;
fail:
    *ok = NO;
    return NO;
}

static JPTReader JPTReaderMake(const uint8_t *p, size_t len) {
    return (JPTReader){p, p + len};
}

static void JPTWriteVarint(NSMutableData *d, uint64_t v) {
    uint8_t buf[10];
    int n = 0;
    do {
        uint8_t b = v & 0x7f;
        v >>= 7;
        buf[n++] = b | (v ? 0x80 : 0);
    } while (v);
    [d appendBytes:buf length:n];
}

static void JPTWriteBytes(NSMutableData *d, uint32_t field, const void *bytes, size_t len) {
    JPTWriteVarint(d, ((uint64_t)field << 3) | 2);
    JPTWriteVarint(d, len);
    if (len) [d appendBytes:bytes length:len];
}

static void JPTWriteData(NSMutableData *d, uint32_t field, NSData *data) {
    JPTWriteBytes(d, field, data.bytes, data.length);
}

static void JPTWriteString(NSMutableData *d, uint32_t field, NSString *s) {
    NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
    JPTWriteBytes(d, field, utf8.bytes, utf8.length);
}

static void JPTWriteRaw(NSMutableData *d, const JPTField *f) {
    [d appendBytes:f->start length:(NSUInteger)(f->stop - f->start)];
}

static NSString *JPTString(const JPTField *f) {
    if (f->wire != 2) return nil;
    return [[NSString alloc] initWithBytes:f->data length:f->len encoding:NSUTF8StringEncoding];
}

static NSString *JPTBase62(const uint8_t *gid, size_t len) {
    static const char alphabet[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    if (len != 16) return nil;
    uint8_t num[16];
    memcpy(num, gid, 16);
    char out[23];
    int pos = 22;
    out[22] = 0;
    // Repeated big-endian division by 62
    while (pos > 0) {
        uint32_t rem = 0;
        for (int i = 0; i < 16; i++) {
            uint32_t acc = (rem << 8) | num[i];
            num[i] = (uint8_t)(acc / 62);
            rem = acc % 62;
        }
        out[--pos] = alphabet[rem];
    }
    return [NSString stringWithUTF8String:out];
}

#pragma mark - Metadata model

@interface JPTTrackInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *originalTitle;
@property (nonatomic, copy) NSString *versionTitle;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, copy) NSString *albumURI;
@property (nonatomic, copy) NSString *canonicalURI;
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *artists;
@end

@implementation JPTTrackInfo
@end

static BOOL JPTParseEntity(const uint8_t *p, size_t len, NSString **name, NSString **uri, NSString *prefix) {
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 1 && f.wire == 2 && f.len == 16) *uri = [prefix stringByAppendingString:JPTBase62(f.data, f.len)];
        else if (f.field == 2) *name = JPTString(&f);
    }
    return ok;
}

// Track: 2 name, 3 album, 4 artists, 27 original_title, 28 version_title, 36 canonical_uri
static JPTTrackInfo *JPTParseTrack(const uint8_t *p, size_t len) {
    JPTTrackInfo *info = [JPTTrackInfo new];
    info.artists = [NSMutableArray array];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.wire != 2) continue;
        if (f.field == 2) {
            info.name = JPTString(&f);
        } else if (f.field == 3) {
            NSString *name = nil, *uri = nil;
            if (JPTParseEntity(f.data, f.len, &name, &uri, @"spotify:album:")) {
                info.albumName = name;
                info.albumURI = uri;
            }
        } else if (f.field == 4) {
            NSString *name = nil, *uri = nil;
            if (JPTParseEntity(f.data, f.len, &name, &uri, @"spotify:artist:") && name && uri) {
                [info.artists addObject:@[name, uri]];
            }
        } else if (f.field == 27) {
            info.originalTitle = JPTString(&f);
        } else if (f.field == 28) {
            info.versionTitle = JPTString(&f);
        } else if (f.field == 36) {
            info.canonicalURI = JPTString(&f);
        }
    }
    return (ok && info.name.length) ? info : nil;
}

// EntityExtensionData: 1 header {1 status_code}, 2 entity_uri, 3 extension_data (Any: 1 type_url, 2 value)
static BOOL JPTParseEntry(const JPTField *entry, NSString **uri, uint64_t *status, JPTField *anyValue) {
    JPTReader r = JPTReaderMake(entry->data, entry->len);
    JPTField f;
    BOOL ok;
    BOOL hasValue = NO;
    *status = 0;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 1 && f.wire == 2) {
            JPTReader hr = JPTReaderMake(f.data, f.len);
            JPTField hf;
            BOOL hok;
            while (JPTNext(&hr, &hf, &hok)) {
                if (hf.field == 1 && hf.wire == 0) *status = hf.varint;
            }
        } else if (f.field == 2) {
            *uri = JPTString(&f);
        } else if (f.field == 3 && f.wire == 2) {
            JPTReader ar = JPTReaderMake(f.data, f.len);
            JPTField af;
            BOOL aok;
            while (JPTNext(&ar, &af, &aok)) {
                if (af.field == 2 && af.wire == 2) {
                    *anyValue = af;
                    hasValue = YES;
                }
            }
        }
    }
    return ok && hasValue;
}

static uint64_t JPTArrayKind(const JPTField *array) {
    JPTReader r = JPTReaderMake(array->data, array->len);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2 && f.wire == 0) return f.varint;
    }
    return 0;
}

NSData *JPTGunzip(NSData *data) {
    if (!data.length) return nil;
    z_stream zs = {0};
    zs.next_in = (Bytef *)data.bytes;
    zs.avail_in = (uInt)data.length;
    // 15 + 32: accept gzip or zlib headers
    if (inflateInit2(&zs, 15 + 32) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:data.length * 4 + 256];
    int status;
    do {
        if (zs.total_out >= out.length) out.length += data.length * 2 + 256;
        zs.next_out = (Bytef *)out.mutableBytes + zs.total_out;
        zs.avail_out = (uInt)(out.length - zs.total_out);
        status = inflate(&zs, Z_NO_FLUSH);
    } while (status == Z_OK);
    inflateEnd(&zs);
    if (status != Z_STREAM_END) return nil;
    out.length = zs.total_out;
    return out;
}

#pragma mark - Request augmentation

// BatchedEntityRequest: 1 header, 2 EntityRequest {1 entity_uri, 2 ExtensionQuery {1 extension_kind, 2 etag}}
// Returns nil when nothing was added; traitTracks receives tracks requesting IdentityTrait or TRACK_V4,
// artistURIs every artist entity that asks for ARTIST_V4 or IdentityTrait
NSData *JPTAugmentRequest(NSData *body, NSMutableSet<NSString *> *added, NSMutableSet<NSString *> *traitTracks,
                          NSMutableSet<NSString *> *artistURIs, NSMutableDictionary<NSNumber *, NSNumber *> *kindCounts) {
    NSMutableData *out = [NSMutableData dataWithCapacity:body.length + 64];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSString *uri = nil;
        BOOL hasTrait = NO, hasTrack = NO, hasArtist = NO;
        JPTReader er = JPTReaderMake(f.data, f.len);
        JPTField ef;
        BOOL eok;
        while (JPTNext(&er, &ef, &eok)) {
            if (ef.field == 1) {
                uri = JPTString(&ef);
            } else if (ef.field == 2 && ef.wire == 2) {
                JPTReader qr = JPTReaderMake(ef.data, ef.len);
                JPTField qf;
                BOOL qok;
                while (JPTNext(&qr, &qf, &qok)) {
                    if (qf.field == 1 && qf.wire == 0) {
                        if (qf.varint == kKindIdentityTrait) hasTrait = YES;
                        if (qf.varint == kKindTrackV4) hasTrack = YES;
                        if (qf.varint == kKindArtistV4 || qf.varint == kKindSimpleCard) hasArtist = YES;
                        if (kindCounts) kindCounts[@(qf.varint)] = @(kindCounts[@(qf.varint)].unsignedIntegerValue + 1);
                    }
                }
            }
        }
        if (eok && (hasTrait || hasTrack) && [uri hasPrefix:@"spotify:track:"]) [traitTracks addObject:uri];
        if (eok && (hasTrait || hasArtist) && [uri hasPrefix:@"spotify:artist:"]) [artistURIs addObject:uri];
        if (!eok || !hasTrait || hasTrack || ![uri hasPrefix:@"spotify:track:"]) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSMutableData *entity = [NSMutableData dataWithBytes:f.data length:f.len];
        NSMutableData *query = [NSMutableData data];
        JPTWriteVarint(query, (1 << 3) | 0);
        JPTWriteVarint(query, kKindTrackV4);
        JPTWriteData(entity, 2, query);
        JPTWriteData(out, 2, entity);
        [added addObject:uri];
    }
    if (!ok || added.count == 0) return nil;
    return out;
}

// Builds a TRACK_V4-only request reusing the header (field 1) of an existing request body
NSData *JPTTrackRequest(NSData *templateBody, NSSet<NSString *> *uris) {
    NSMutableData *out = [NSMutableData data];
    JPTReader r = JPTReaderMake(templateBody.bytes, templateBody.length);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 1) JPTWriteRaw(out, &f);
    }
    for (NSString *uri in uris) {
        NSMutableData *query = [NSMutableData data];
        JPTWriteVarint(query, (1 << 3) | 0);
        JPTWriteVarint(query, kKindTrackV4);
        NSMutableData *entity = [NSMutableData data];
        JPTWriteString(entity, 1, uri);
        JPTWriteData(entity, 2, query);
        JPTWriteData(out, 2, entity);
    }
    return out;
}

#pragma mark - Response rewrite

// Collects successful TRACK_V4 payloads keyed by entity URI
NSDictionary<NSString *, JPTTrackInfo *> *JPTCollectTracks(NSData *body) {
    NSMutableDictionary<NSString *, JPTTrackInfo *> *tracks = [NSMutableDictionary dictionary];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2 || JPTArrayKind(&f) != kKindTrackV4) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len);
        JPTField af;
        BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil;
            uint64_t status;
            JPTField value;
            if (!JPTParseEntry(&af, &uri, &status, &value) || status != 200 || !uri) continue;
            JPTTrackInfo *info = JPTParseTrack(value.data, value.len);
            if (info) tracks[uri] = info;
        }
    }
    return ok ? tracks : nil;
}

// Kana, CJK ideographs and Hangul; romanized releases contain none of these
static BOOL JPTHasCJK(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x1100 && c <= 0x11FF) || (c >= 0x3040 && c <= 0x30FF) || (c >= 0x3130 && c <= 0x318F)
            || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF)
            || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF66 && c <= 0xFF9F)) {
            return YES;
        }
    }
    return NO;
}

static NSString *JPTRomanizedCanonical(NSString *uri, JPTTrackInfo *own) {
    NSString *canonical = own.canonicalURI;
    if (![canonical hasPrefix:@"spotify:track:"] || [canonical isEqualToString:uri] || JPTHasCJK(own.name)) return nil;
    return canonical;
}

// TRACK_V4 URIs still needed in the original-name language: the tracks themselves when the client
// language differs (needOriginal), and the canonical releases of romanized tracks
NSSet<NSString *> *JPTMissingOriginals(NSDictionary<NSString *, JPTTrackInfo *> *tracks, NSSet<NSString *> *uris,
                                      NSDictionary<NSString *, JPTTrackInfo *> *originals, BOOL needOriginal) {
    NSMutableSet<NSString *> *missing = [NSMutableSet set];
    for (NSString *uri in uris) {
        if (needOriginal && tracks[uri] && !originals[uri]) [missing addObject:uri];
        NSString *canonical = JPTRomanizedCanonical(uri, tracks[uri]);
        if (canonical && !originals[canonical]) [missing addObject:canonical];
    }
    return missing;
}

// Client-language value unless only the original-name language has CJK text
static NSString *JPTPick(NSString *client, NSString *original) {
    return (!JPTHasCJK(client) && JPTHasCJK(original)) ? original : client;
}

static JPTTrackInfo *JPTMergeInfo(JPTTrackInfo *client, JPTTrackInfo *original) {
    if (!client) return original;
    if (!original || original == client) return client;
    JPTTrackInfo *info = [JPTTrackInfo new];
    info.name = JPTPick(client.name, original.name);
    info.originalTitle = JPTPick(client.originalTitle, original.originalTitle);
    info.versionTitle = JPTPick(client.versionTitle, original.versionTitle);
    info.albumName = JPTPick(client.albumName, original.albumName);
    info.albumURI = client.albumURI ?: original.albumURI;
    info.canonicalURI = client.canonicalURI;
    info.artists = [NSMutableArray array];
    for (NSArray<NSString *> *artist in client.artists) {
        NSArray<NSString *> *match = nil;
        for (NSArray<NSString *> *candidate in original.artists) {
            if ([candidate[1] isEqualToString:artist[1]]) {
                match = candidate;
                break;
            }
        }
        [info.artists addObject:match ? @[JPTPick(artist[0], match[0]), artist[1]] : artist];
    }
    return info;
}

// Original names on the client's own artist URIs. Artists of a region-locked original release are separate
// entities with empty pages; the romanized release lists the same artists in the same order.
static JPTTrackInfo *JPTAdoptOriginal(JPTTrackInfo *own, JPTTrackInfo *original) {
    NSUInteger count = own.artists.count;
    if (count != original.artists.count) return original;
    for (NSUInteger i = 0; i < count; i++) {
        for (NSUInteger j = 0; j < count; j++) {
            // A shared artist at another position means the order differs
            if (i != j && [own.artists[i][1] isEqualToString:original.artists[j][1]]) return original;
        }
    }
    JPTTrackInfo *info = [JPTTrackInfo new];
    info.name = original.name;
    info.originalTitle = original.originalTitle;
    info.versionTitle = original.versionTitle;
    info.albumName = original.albumName;
    info.albumURI = original.albumURI;
    info.canonicalURI = original.canonicalURI;
    info.artists = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [info.artists addObject:@[original.artists[i][0], own.artists[i][1]]];
    return info;
}

static JPTTrackInfo *JPTPreferredInfo(NSString *uri, NSDictionary<NSString *, JPTTrackInfo *> *tracks,
                                      NSDictionary<NSString *, JPTTrackInfo *> *originals) {
    JPTTrackInfo *own = tracks[uri];
    if (!own) return nil;
    JPTTrackInfo *info = JPTMergeInfo(own, originals[uri]);
    // Only undo romanization; remasters and same-named singles keep their own metadata
    NSString *canonical = JPTRomanizedCanonical(uri, info);
    JPTTrackInfo *original = canonical ? JPTMergeInfo(tracks[canonical], originals[canonical]) : nil;
    return (original && JPTHasCJK(original.name)) ? JPTAdoptOriginal(info, original) : info;
}

// Records artist URI -> original name pairs where the preferred info renamed one of the track's own artists
static void JPTLearnArtists(JPTTrackInfo *own, JPTTrackInfo *preferred, NSMutableDictionary<NSString *, NSString *> *names) {
    if (!names) return;
    for (NSArray<NSString *> *artist in preferred.artists) {
        if (!JPTHasCJK(artist[0])) continue;
        for (NSArray<NSString *> *mine in own.artists) {
            if ([mine[1] isEqualToString:artist[1]] && !JPTHasCJK(mine[0])) names[artist[1]] = artist[0];
        }
    }
}

// Copies a message, replacing the string at `field` (or appending it when absent)
static NSData *JPTReplaceString(const uint8_t *p, size_t len, uint32_t field, NSString *value, NSString **old) {
    NSMutableData *out = [NSMutableData dataWithCapacity:len + 32];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok, written = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == field && f.wire == 2 && !written) {
            if (old) *old = JPTString(&f);
            JPTWriteString(out, field, value);
            written = YES;
        } else {
            JPTWriteRaw(out, &f);
        }
    }
    if (!ok) return nil;
    if (!written) JPTWriteString(out, field, value);
    return out;
}

static NSString *JPTSummary(NSString *name, NSArray<NSString *> *artists) {
    return [NSString stringWithFormat:@"%@ | %@", name, [artists componentsJoinedByString:@", "]];
}

static NSData *JPTRewriteIdentity(const JPTField *value, JPTTrackInfo *track, NSString **oldSummary) {
    NSMutableData *out = [NSMutableData dataWithCapacity:value->len + 32];
    JPTReader r = JPTReaderMake(value->data, value->len);
    JPTField f;
    BOOL ok;
    BOOL hadParent = NO;
    NSMutableData *keptParent = [NSMutableData data];
    NSMutableData *keptContributors = [NSMutableData data];
    NSString *oldName = nil;
    NSMutableArray<NSString *> *oldArtists = [NSMutableArray array];
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2) {
            oldName = JPTString(&f);
            continue;
        }
        if (f.field == 4) {
            hadParent = YES;
            JPTWriteRaw(keptParent, &f);
            continue;
        }
        if (f.field == 5) {
            JPTWriteRaw(keptContributors, &f);
            JPTReader cr = JPTReaderMake(f.data, f.len);
            JPTField cf;
            BOOL cok;
            while (JPTNext(&cr, &cf, &cok)) {
                if (cf.field == 1) [oldArtists addObject:JPTString(&cf) ?: @""];
            }
            continue;
        }
        JPTWriteRaw(out, &f);
    }
    if (!ok) return nil;
    *oldSummary = JPTSummary(oldName, oldArtists);
    JPTWriteString(out, 2, track.name);
    if (hadParent && track.albumName.length && track.albumURI.length) {
        NSMutableData *parent = [NSMutableData data];
        JPTWriteString(parent, 1, track.albumName);
        JPTWriteString(parent, 2, track.albumURI);
        JPTWriteData(out, 4, parent);
    } else {
        [out appendData:keptParent];
    }
    if (track.artists.count) {
        for (NSArray<NSString *> *artist in track.artists) {
            NSMutableData *contributor = [NSMutableData data];
            JPTWriteString(contributor, 1, artist[0]);
            JPTWriteString(contributor, 2, artist[1]);
            JPTWriteData(out, 5, contributor);
        }
    } else {
        [out appendData:keptContributors];
    }
    return out;
}

static NSData *JPTRewriteEntry(const JPTField *entry, NSData *newValue) {
    NSMutableData *out = [NSMutableData dataWithCapacity:entry->len + 32];
    JPTReader r = JPTReaderMake(entry->data, entry->len);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 3 || f.wire != 2) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSMutableData *any = [NSMutableData data];
        JPTReader ar = JPTReaderMake(f.data, f.len);
        JPTField af;
        BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field == 2 && af.wire == 2) JPTWriteData(any, 2, newValue);
            else JPTWriteRaw(any, &af);
        }
        if (!aok) return nil;
        JPTWriteData(out, 3, any);
    }
    return ok ? out : nil;
}

// Change display names only. Playback IDs, restrictions and unknown fields stay byte-for-byte intact.
static NSData *JPTRewriteTrack(const JPTField *value, JPTTrackInfo *preferred) {
    if (!preferred) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:value->len];
    JPTReader r = JPTReaderMake(value->data, value->len);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2 && f.wire == 2 && preferred.name.length
            && ![JPTString(&f) isEqualToString:preferred.name]) {
            JPTWriteString(out, 2, preferred.name); changed = YES;
        } else if ((f.field == 27 || f.field == 28) && f.wire == 2 && preferred.originalTitle.length) {
            // The client can reconstruct display names from these instead of field 2.
            NSString *text = f.field == 27 ? preferred.originalTitle : preferred.versionTitle ?: @"";
            if (![JPTString(&f) isEqualToString:text]) { JPTWriteString(out, f.field, text); changed = YES; }
            else JPTWriteRaw(out, &f);
        } else if ((f.field == 3 || f.field == 4 || f.field == 32) && f.wire == 2) {
            NSString *oldName = nil, *uri = nil;
            BOOL parsed = JPTParseEntity(f.data, f.len, &oldName, &uri,
                                        f.field == 3 ? @"spotify:album:" : @"spotify:artist:");
            NSString *name = f.field == 3 ? preferred.albumName : nil;
            if (f.field != 3) {
                for (NSArray<NSString *> *artist in preferred.artists) {
                    if ([artist[1] isEqualToString:uri]) { name = artist[0]; break; }
                }
            }
            NSData *entity = (parsed && name.length && ![oldName isEqualToString:name])
                ? JPTReplaceString(f.data, f.len, 2, name, NULL) : nil;
            if (entity) { JPTWriteData(out, f.field, entity); changed = YES; }
            else JPTWriteRaw(out, &f);
        } else JPTWriteRaw(out, &f);
    }
    return ok && changed ? out : nil;
}

// BatchedExtensionResponse: 1 header, 2 EntityExtensionDataArray {1 header, 2 extension_kind, 3 EntityExtensionData}
// originals: TRACK_V4 fetched in the original-name language (may be the client's own response)
// artistNames: known artist URI -> original name; renames artist entities and receives newly learned pairs
NSData *JPTRewriteResponse(NSData *body, NSSet<NSString *> *added, NSDictionary<NSString *, JPTTrackInfo *> *originals,
                           NSMutableDictionary<NSString *, NSString *> *artistNames, NSMutableArray<NSString *> *changes) {
    NSDictionary<NSString *, JPTTrackInfo *> *tracks = JPTCollectTracks(body);
    if (!tracks) return nil;

    NSMutableData *out = [NSMutableData dataWithCapacity:body.length];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        uint64_t kind = (f.field == 2 && f.wire == 2) ? JPTArrayKind(&f) : 0;
        if (kind != kKindTrackV4 && kind != kKindIdentityTrait && kind != kKindArtistV4 && kind != kKindSimpleCard) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSMutableData *array = [NSMutableData dataWithCapacity:f.len];
        NSUInteger kept = 0;
        JPTReader ar = JPTReaderMake(f.data, f.len);
        JPTField af;
        BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) {
                JPTWriteRaw(array, &af);
                continue;
            }
            NSString *uri = nil;
            uint64_t status;
            JPTField value;
            BOOL parsed = JPTParseEntry(&af, &uri, &status, &value);
            if (kind == kKindTrackV4) {
                // Drop TRACK_V4 entries that the client never asked for
                if (uri && [added containsObject:uri]) continue;
                JPTTrackInfo *preferred = parsed && status == 200 ? JPTPreferredInfo(uri, tracks, originals) : nil;
                NSData *track = preferred ? JPTRewriteTrack(&value, preferred) : nil;
                NSData *entry = track ? JPTRewriteEntry(&af, track) : nil;
                if (entry) {
                    JPTWriteData(array, 3, entry);
                    JPTLearnArtists(tracks[uri], preferred, artistNames);
                    [changes addObject:[NSString stringWithFormat:@"TRACK_V4 %@: %@ -> %@ / %@",
                                        uri, tracks[uri].name, preferred.name, preferred.albumName]];
                } else JPTWriteRaw(array, &af);
                kept++;
                continue;
            }
            kept++;
            if ([uri hasPrefix:@"spotify:artist:"]) {
                // ARTIST_V4, IdentityTrait and SimpleCardTrait (artist page header) keep the name in field 2
                NSString *name = artistNames[uri], *oldName = nil;
                NSData *value2 = (parsed && status == 200 && name) ? JPTReplaceString(value.data, value.len, 2, name, &oldName) : nil;
                if (value2 && kind == kKindSimpleCard) {
                    // SimpleCardTrait repeats the title in field 6
                    NSString *oldTitle = nil;
                    NSData *value6 = JPTReplaceString(value2.bytes, value2.length, 6, name, &oldTitle);
                    if (value6 && [oldTitle isEqualToString:oldName]) value2 = value6;
                }
                NSData *entry = value2 ? JPTRewriteEntry(&af, value2) : nil;
                if (entry) {
                    JPTWriteData(array, 3, entry);
                    if (![oldName isEqualToString:name]) [changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@", uri, oldName, name]];
                } else {
                    JPTWriteRaw(array, &af);
                }
                continue;
            }
            JPTTrackInfo *track = (uri && kind == kKindIdentityTrait) ? JPTPreferredInfo(uri, tracks, originals) : nil;
            NSString *oldSummary = nil;
            NSData *identity = (parsed && status == 200 && track) ? JPTRewriteIdentity(&value, track, &oldSummary) : nil;
            NSData *entry = identity ? JPTRewriteEntry(&af, identity) : nil;
            if (entry) {
                JPTWriteData(array, 3, entry);
                JPTLearnArtists(tracks[uri], track, artistNames);
                NSMutableArray<NSString *> *artists = [NSMutableArray array];
                for (NSArray<NSString *> *artist in track.artists) [artists addObject:artist[0]];
                NSString *newSummary = JPTSummary(track.name, artists);
                if (![oldSummary isEqualToString:newSummary]) {
                    [changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@ / %@", uri, oldSummary, newSummary, track.albumName]];
                }
            } else {
                JPTWriteRaw(array, &af);
            }
        }
        if (!aok) return nil;
        if (kind == kKindTrackV4 && kept == 0) continue;
        JPTWriteData(out, 2, array);
    }
    return ok ? out : nil;
}

#pragma mark - Search rewrite

// searchview Entity: 1 uri, 2 name, 3 image, 4 artist, 5 track {3 album {1 uri, 2 name}, 4 artist {1 uri, 2 name}},
// 6 album {1 subtitle, 7 artist {1 uri, 2 name}}, 14 section holding nested entities
static NSString *JPTEntityURI(const uint8_t *p, size_t len) {
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok;
    if (!JPTNext(&r, &f, &ok) || f.field != 1 || f.wire != 2) return nil;
    NSString *uri = JPTString(&f);
    if (![uri hasPrefix:@"spotify:"]) return nil;
    while (JPTNext(&r, &f, &ok)) {}
    return ok ? uri : nil;
}

static BOOL JPTIsMessage(const uint8_t *p, size_t len) {
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok = YES;
    while (JPTNext(&r, &f, &ok)) {}
    return ok;
}

typedef NSData *(^JPTEntityRewriter)(NSString *uri, const uint8_t *p, size_t len);

// Rebuilds only the messages that contain a rewritten track/album/artist entity; nil when nothing changed
static NSData *JPTWalkSearch(const uint8_t *p, size_t len, int depth, JPTEntityRewriter rewrite) {
    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        NSData *replacement = nil;
        if (f.wire == 2 && f.len && depth < 8) {
            NSString *uri = JPTEntityURI(f.data, f.len);
            if ([uri hasPrefix:@"spotify:track:"] || [uri hasPrefix:@"spotify:album:"] || [uri hasPrefix:@"spotify:artist:"]) {
                replacement = rewrite(uri, f.data, f.len);
            } else if (uri || JPTIsMessage(f.data, f.len)) {
                replacement = JPTWalkSearch(f.data, f.len, depth + 1, rewrite);
            }
        }
        if (replacement) {
            JPTWriteData(out, f.field, replacement);
            changed = YES;
        } else {
            JPTWriteRaw(out, &f);
        }
    }
    return (ok && changed) ? out : nil;
}

NSSet<NSString *> *JPTSearchTracks(NSData *body) {
    NSMutableSet<NSString *> *uris = [NSMutableSet set];
    JPTWalkSearch(body.bytes, body.length, 0, ^NSData *(NSString *uri, const uint8_t *p, size_t len) {
        if ([uri hasPrefix:@"spotify:track:"]) [uris addObject:uri];
        return nil;
    });
    return uris;
}

static NSString *JPTSubString(const JPTField *f, uint32_t field) {
    JPTReader r = JPTReaderMake(f->data, f->len);
    JPTField rf;
    BOOL ok;
    while (JPTNext(&r, &rf, &ok)) {
        if (rf.field == field && rf.wire == 2) return JPTString(&rf);
    }
    return nil;
}

// Renames a {1 uri, 2 name} reference or entity; nil when unchanged
static NSData *JPTRenameReference(const JPTField *f, NSString *name) {
    NSString *old = JPTSubString(f, 2);
    NSString *picked = JPTPick(old, name);
    if (!picked.length || [picked isEqualToString:old]) return nil;
    return JPTReplaceString(f->data, f->len, 2, picked, nil);
}

static NSData *JPTRewriteSearchTrack(const uint8_t *p, size_t len, JPTTrackInfo *info, NSString **oldName) {
    NSMutableData *out = [NSMutableData dataWithCapacity:len + 64];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2 && f.wire == 2) {
            *oldName = JPTString(&f);
            NSString *name = JPTPick(*oldName, info.name);
            JPTWriteString(out, 2, name ?: @"");
            changed |= ![name isEqualToString:*oldName];
        } else if (f.field == 5 && f.wire == 2) {
            NSMutableData *track = [NSMutableData dataWithCapacity:f.len + 64];
            JPTReader tr = JPTReaderMake(f.data, f.len);
            JPTField tf;
            BOOL tok;
            while (JPTNext(&tr, &tf, &tok)) {
                NSData *replacement = nil;
                if (tf.field == 3 && tf.wire == 2) {
                    replacement = JPTRenameReference(&tf, info.albumName);
                    // The original album page lists the original names; its URI follows the name
                    if (replacement && info.albumURI) replacement = JPTReplaceString(replacement.bytes, replacement.length, 1, info.albumURI, nil);
                } else if (tf.field == 4 && tf.wire == 2) {
                    NSString *uri = JPTSubString(&tf, 1);
                    for (NSArray<NSString *> *artist in info.artists) {
                        if ([artist[1] isEqualToString:uri]) replacement = JPTRenameReference(&tf, artist[0]);
                    }
                }
                if (replacement) {
                    JPTWriteData(track, tf.field, replacement);
                    changed = YES;
                } else {
                    JPTWriteRaw(track, &tf);
                }
            }
            if (!tok) return nil;
            JPTWriteData(out, 5, track);
        } else {
            JPTWriteRaw(out, &f);
        }
    }
    return (ok && changed) ? out : nil;
}

// original: @[original album URI, original album name] or nil
static NSData *JPTRewriteSearchAlbum(const uint8_t *p, size_t len, NSArray<NSString *> *original,
                                     NSDictionary<NSString *, NSString *> *artistNames) {
    NSMutableData *out = [NSMutableData dataWithCapacity:len + 64];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 1 && original) {
            JPTWriteString(out, 1, original[0]);
            changed = YES;
        } else if (f.field == 2 && f.wire == 2 && original) {
            NSString *old = JPTString(&f), *name = JPTPick(old, original[1]);
            JPTWriteString(out, 2, name ?: @"");
            changed |= ![name isEqualToString:old];
        } else if (f.field == 6 && f.wire == 2) {
            // Artist renames, also applied to the subtitle that joins the artist names
            NSMutableDictionary<NSString *, NSString *> *renames = [NSMutableDictionary dictionary];
            JPTReader ar = JPTReaderMake(f.data, f.len);
            JPTField af;
            BOOL aok;
            while (JPTNext(&ar, &af, &aok)) {
                if (af.field != 7 || af.wire != 2) continue;
                NSString *uri = JPTSubString(&af, 1), *name = JPTSubString(&af, 2);
                NSData *renamed = artistNames[uri] ? JPTRenameReference(&af, artistNames[uri]) : nil;
                if (renamed && name.length) renames[name] = JPTPick(name, artistNames[uri]);
            }
            if (!aok) return nil;
            if (!renames.count) {
                JPTWriteRaw(out, &f);
                continue;
            }
            NSMutableData *album = [NSMutableData dataWithCapacity:f.len + 64];
            ar = JPTReaderMake(f.data, f.len);
            while (JPTNext(&ar, &af, &aok)) {
                if (af.field == 1 && af.wire == 2) {
                    NSMutableString *subtitle = [JPTString(&af) mutableCopy] ?: [NSMutableString string];
                    for (NSString *name in renames) [subtitle replaceOccurrencesOfString:name withString:renames[name] options:0 range:NSMakeRange(0, subtitle.length)];
                    JPTWriteString(album, 1, subtitle);
                } else if (af.field == 7 && af.wire == 2) {
                    NSString *uri = JPTSubString(&af, 1);
                    NSData *renamed = artistNames[uri] ? JPTRenameReference(&af, artistNames[uri]) : nil;
                    if (renamed) JPTWriteData(album, 7, renamed);
                    else JPTWriteRaw(album, &af);
                } else {
                    JPTWriteRaw(album, &af);
                }
            }
            JPTWriteData(out, 6, album);
            changed = YES;
        } else {
            JPTWriteRaw(out, &f);
        }
    }
    return (ok && changed) ? out : nil;
}

// originals: TRACK_V4 in the original-name language for the search tracks and their canonical releases
NSData *JPTRewriteSearch(NSData *body, NSDictionary<NSString *, JPTTrackInfo *> *originals,
                         NSMutableDictionary<NSString *, NSString *> *artistNames, NSMutableArray<NSString *> *changes) {
    NSMutableDictionary<NSString *, JPTTrackInfo *> *preferred = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *albums = [NSMutableDictionary dictionary];
    for (NSString *uri in JPTSearchTracks(body)) {
        JPTTrackInfo *own = originals[uri];
        JPTTrackInfo *info = JPTPreferredInfo(uri, originals, originals);
        if (!info) continue;
        preferred[uri] = info;
        JPTLearnArtists(own, info, artistNames);
        if (own.albumURI && info.albumURI && ![own.albumURI isEqualToString:info.albumURI] && info.albumName
            && JPTHasCJK(info.albumName) && !JPTHasCJK(own.albumName)) {
            albums[own.albumURI] = @[info.albumURI, info.albumName];
        }
    }
    return JPTWalkSearch(body.bytes, body.length, 0, ^NSData *(NSString *uri, const uint8_t *p, size_t len) {
        NSData *rewritten = nil;
        NSString *old = nil, *now = nil;
        if ([uri hasPrefix:@"spotify:track:"]) {
            JPTTrackInfo *info = preferred[uri];
            rewritten = info ? JPTRewriteSearchTrack(p, len, info, &old) : nil;
            now = info.name;
        } else if ([uri hasPrefix:@"spotify:album:"]) {
            rewritten = JPTRewriteSearchAlbum(p, len, albums[uri], artistNames);
            now = albums[uri][1];
        } else if (artistNames[uri]) {
            JPTField f = {0};
            f.data = p;
            f.len = len;
            rewritten = JPTRenameReference(&f, artistNames[uri]);
            now = artistNames[uri];
        }
        if (rewritten) [changes addObject:[NSString stringWithFormat:@"search %@: %@ -> %@", uri, old ?: @"", now ?: @"(artists)"]];
        return rewritten;
    });
}

#ifndef JPT_TEST

#pragma mark - Logging

static void JPTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#pragma mark - Original-name metadata cache

// Artist names are localized by Accept-Language; zh returns the original names (ja katakanizes Chinese artists)
static NSString *const kJPTOriginalLanguage = @"zh-Hans";

static NSMutableDictionary<NSString *, JPTTrackInfo *> *gOriginalCache;

static NSDictionary<NSString *, JPTTrackInfo *> *JPTOriginalSnapshot(void) {
    @synchronized (gOriginalCache) {
        return [gOriginalCache copy];
    }
}

static void JPTFetchOriginals(NSURLRequest *template, NSData *templateBody, NSSet<NSString *> *uris, void (^done)(void)) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 8;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    NSMutableURLRequest *request = [template mutableCopy];
    NSData *body = JPTTrackRequest(templateBody, uris);
    request.HTTPBody = body;
    [request setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    [request setValue:kJPTOriginalLanguage forHTTPHeaderField:@"Accept-Language"];
    if ([request valueForHTTPHeaderField:@"Content-Length"]) {
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)body.length] forHTTPHeaderField:@"Content-Length"];
    }
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary<NSString *, JPTTrackInfo *> *tracks = (!error && code == 200) ? JPTCollectTracks(data) : nil;
        if (tracks.count) {
            @synchronized (gOriginalCache) {
                [gOriginalCache addEntriesFromDictionary:tracks];
            }
        }
        JPTLog(@"original fetch %lu uris: status %ld, got %lu%@", (unsigned long)uris.count, (long)code,
               (unsigned long)tracks.count, error ? [NSString stringWithFormat:@", error %@/%ld", error.domain, (long)error.code] : @"");
        done();
    }] resume];
}

#pragma mark - Learned artist names and request template

static NSString *const kJPTArtistNamesKey = @"JPOriginalTitlesArtistNames";
static NSMutableDictionary<NSString *, NSString *> *gArtistNames;

static NSMutableDictionary<NSString *, NSString *> *JPTArtistNamesSnapshot(void) {
    @synchronized (gArtistNames) {
        return [gArtistNames mutableCopy];
    }
}

// Keeps pairs learned from track rewrites so artist pages opened later (or after relaunch) are renamed too
static void JPTMergeArtistNames(NSDictionary<NSString *, NSString *> *names) {
    NSDictionary *copy = nil;
    @synchronized (gArtistNames) {
        NSUInteger before = gArtistNames.count;
        BOOL changed = NO;
        for (NSString *uri in names) {
            if (![gArtistNames[uri] isEqualToString:names[uri]]) {
                gArtistNames[uri] = names[uri];
                changed = YES;
            }
        }
        if (!changed) return;
        if (gArtistNames.count > 5000) [gArtistNames removeAllObjects];
        copy = [gArtistNames copy];
        JPTLog(@"artist names %lu -> %lu", (unsigned long)before, (unsigned long)copy.count);
    }
    [[NSUserDefaults standardUserDefaults] setObject:copy forKey:kJPTArtistNamesKey];
}

static BOOL JPTKnowsAnyArtist(NSSet<NSString *> *uris) {
    @synchronized (gArtistNames) {
        for (NSString *uri in uris) {
            if (gArtistNames[uri]) return YES;
        }
    }
    return NO;
}

// The latest client extended-metadata request; search rewrites reuse its URL, headers and body header
static NSURLRequest *gTemplateRequest;
static NSData *gTemplateBody;

static void JPTSetTemplate(NSURLRequest *request, NSData *body) {
    @synchronized ([JPTTrackInfo class]) {
        gTemplateRequest = request;
        gTemplateBody = body;
    }
}

static BOOL JPTTemplate(NSURLRequest *auth, NSURLRequest **request, NSData **body) {
    @synchronized ([JPTTrackInfo class]) {
        if (!gTemplateRequest) return NO;
        NSMutableURLRequest *copy = [gTemplateRequest mutableCopy];
        // The search request carries the freshest credentials
        for (NSString *header in @[@"Authorization", @"client-token"]) {
            NSString *value = [auth valueForHTTPHeaderField:header];
            if (value) [copy setValue:value forHTTPHeaderField:header];
        }
        *request = copy;
        *body = gTemplateBody;
        return YES;
    }
}

#pragma mark - Hooks

@interface JPTTaskState : NSObject
@property (nonatomic, strong) NSSet<NSString *> *added;
@property (nonatomic, strong) NSSet<NSString *> *traitTracks;
@property (nonatomic) BOOL search;
@property (nonatomic) BOOL clientIsOriginalLanguage;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic) BOOL done;
@end

@implementation JPTTaskState
@end

static char kJPTStateKey;
static NSMutableArray<Class> *gDelegateClasses;

static BOOL JPTIsHookedDelegate(id delegate) {
    for (Class cls in gDelegateClasses) {
        if ([delegate isKindOfClass:cls]) return YES;
    }
    return NO;
}

static BOOL JPTIsExtendedMetadata(NSURLRequest *request) {
    return [request.HTTPMethod isEqualToString:@"POST"]
        && [request.URL.path hasSuffix:@"/extended-metadata/v0/extended-metadata"];
}

static NSString *JPTKindSummary(NSDictionary<NSNumber *, NSNumber *> *counts) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *kind in [counts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [parts addObject:[NSString stringWithFormat:@"%@x%@", kind, counts[kind]]];
    }
    return [parts componentsJoinedByString:@","];
}

// Whether the client's own response already carries original-language names
static BOOL JPTIsOriginalLanguage(NSString *acceptLanguage) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    NSString *value = acceptLanguage ?: @"(none)";
    BOOL first;
    @synchronized (seen) {
        first = ![seen containsObject:value];
        [seen addObject:value];
    }
    BOOL original = [[value lowercaseString] hasPrefix:@"zh"];
    if (first) JPTLog(@"client accept-language %@ (original language: %d)", value, original);
    return original;
}

static BOOL JPTIsSearch(NSURLRequest *request) {
    return [request.HTTPMethod isEqualToString:@"GET"] && [request.URL.path hasSuffix:@"/searchview/v3/search"];
}

static NSURLRequest *JPTPrepareRequest(NSURLSession *session, NSURLRequest *request, JPTTaskState **stateOut) {
    *stateOut = nil;
    if (gDelegateClasses.count && JPTIsSearch(request) && JPTIsHookedDelegate(session.delegate)) {
        JPTTaskState *state = [JPTTaskState new];
        state.search = YES;
        state.buffer = [NSMutableData data];
        *stateOut = state;
        return request;
    }
    if (!gDelegateClasses.count || !JPTIsExtendedMetadata(request)) return request;
    NSData *body = request.HTTPBody;
    NSString *delegateName = session.delegate ? NSStringFromClass([session.delegate class]) : @"nil";
    NSString *encoding = [request valueForHTTPHeaderField:@"Content-Encoding"];
    BOOL gzip = [encoding caseInsensitiveCompare:@"gzip"] == NSOrderedSame;
    if (gzip) body = JPTGunzip(body);
    if (!JPTIsHookedDelegate(session.delegate) || !body.length || (encoding.length && !gzip)) {
        JPTLog(@"skip request: delegate=%@ body=%lu stream=%d encoding=%@", delegateName, (unsigned long)body.length,
               request.HTTPBodyStream != nil, encoding);
        return request;
    }
    JPTSetTemplate(request, body);
    NSMutableSet<NSString *> *uris = [NSMutableSet set];
    NSMutableSet<NSString *> *traitTracks = [NSMutableSet set];
    NSMutableSet<NSString *> *artists = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSData *augmented = JPTAugmentRequest(body, uris, traitTracks, artists, counts);
    BOOL knownArtists = JPTKnowsAnyArtist(artists);
    JPTLog(@"request %@%@ kinds %@, traits %lu, added %lu%@", delegateName, gzip ? @" gzip" : @"", JPTKindSummary(counts),
           (unsigned long)traitTracks.count, (unsigned long)uris.count, knownArtists ? @", known artists" : @"");
    if (!traitTracks.count && !knownArtists) return request;
    JPTTaskState *state = [JPTTaskState new];
    state.added = uris;
    state.traitTracks = traitTracks;
    state.clientIsOriginalLanguage = JPTIsOriginalLanguage([request valueForHTTPHeaderField:@"Accept-Language"]);
    state.body = augmented ?: body;
    state.buffer = [NSMutableData data];
    *stateOut = state;
    if (!augmented) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.HTTPBody = augmented;
    // The augmented body is sent uncompressed
    if (gzip) [copy setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    if ([copy valueForHTTPHeaderField:@"Content-Length"]) {
        [copy setValue:[NSString stringWithFormat:@"%lu", (unsigned long)augmented.length] forHTTPHeaderField:@"Content-Length"];
    }
    return copy;
}

// Fetches TRACK_V4 for the search tracks, then for the canonical releases of romanized ones, then rewrites
static void JPTFinishSearch(NSURLSession *session, NSURLRequest *searchRequest, NSData *payload, void (^deliver)(NSData *)) {
    NSSet<NSString *> *uris = JPTSearchTracks(payload);
    NSURLRequest *template = nil;
    NSData *templateBody = nil;
    if (!uris.count || !JPTTemplate(searchRequest, &template, &templateBody)) {
        JPTLog(@"search %lu bytes, tracks %lu%@", (unsigned long)payload.length, (unsigned long)uris.count,
               template ? @"" : @", no metadata template yet");
        deliver(payload);
        return;
    }
    NSOperationQueue *queue = session.delegateQueue;
    void (^finish)(void) = ^{
        NSMutableDictionary<NSString *, NSString *> *names = JPTArtistNamesSnapshot();
        NSMutableArray<NSString *> *changes = [NSMutableArray array];
        NSData *patched = JPTRewriteSearch(payload, JPTOriginalSnapshot(), names, changes);
        JPTMergeArtistNames(names);
        JPTLog(@"search %lu bytes, tracks %lu, changed %lu", (unsigned long)payload.length, (unsigned long)uris.count,
               (unsigned long)changes.count);
        for (NSString *change in changes) JPTLog(@"  %@", change);
        deliver(patched ?: payload);
    };
    void (^onQueue)(void) = ^{
        if (queue) [queue addOperationWithBlock:finish];
        else finish();
    };
    void (^canonicals)(void) = ^{
        NSDictionary<NSString *, JPTTrackInfo *> *snapshot = JPTOriginalSnapshot();
        NSSet<NSString *> *missing = JPTMissingOriginals(snapshot, uris, snapshot, NO);
        if (missing.count) JPTFetchOriginals(template, templateBody, missing, onQueue);
        else onQueue();
    };
    NSDictionary<NSString *, JPTTrackInfo *> *snapshot = JPTOriginalSnapshot();
    NSMutableSet<NSString *> *own = [NSMutableSet set];
    for (NSString *uri in uris) {
        if (!snapshot[uri]) [own addObject:uri];
    }
    if (own.count) JPTFetchOriginals(template, templateBody, own, canonicals);
    else canonicals();
}

static Method JPTOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static void JPTHookDataTask(Class cls) {
    SEL sel = @selector(dataTaskWithRequest:);
    // Subclasses that only inherit the method are covered by the NSURLSession hook
    Method method = JPTOwnMethod(cls, sel);
    if (!method) return;
    typedef NSURLSessionDataTask *(*Fn)(id, SEL, NSURLRequest *);
    Fn original = (Fn)method_getImplementation(method);
    id block = ^NSURLSessionDataTask *(NSURLSession *self, NSURLRequest *request) {
        JPTTaskState *state = nil;
        NSURLRequest *prepared = JPTPrepareRequest(self, request, &state);
        NSURLSessionDataTask *task = original(self, sel, prepared);
        if (task && state) objc_setAssociatedObject(task, &kJPTStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return task;
    };
    method_setImplementation(method, imp_implementationWithBlock(block));
    JPTLog(@"hooked %s dataTaskWithRequest:", class_getName(cls));
}

static void JPTHookDelegate(NSString *name) {
    Class cls = NSClassFromString(name);
    SEL receiveSel = @selector(URLSession:dataTask:didReceiveData:);
    SEL completeSel = @selector(URLSession:task:didCompleteWithError:);
    Method receive = cls ? JPTOwnMethod(cls, receiveSel) : NULL;
    Method complete = cls ? JPTOwnMethod(cls, completeSel) : NULL;
    if (!receive || !complete) {
        JPTLog(@"delegate %@ unavailable (class %d)", name, cls != nil);
        return;
    }
    [gDelegateClasses addObject:cls];
    JPTLog(@"hooked delegate %@", name);
    typedef void (*ReceiveFn)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
    typedef void (*CompleteFn)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
    ReceiveFn origReceive = (ReceiveFn)method_getImplementation(receive);
    CompleteFn origComplete = (CompleteFn)method_getImplementation(complete);

    method_setImplementation(receive, imp_implementationWithBlock(^(id self, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
        JPTTaskState *state = objc_getAssociatedObject(task, &kJPTStateKey);
        if (state && !state.done) {
            [state.buffer appendData:data];
            return;
        }
        origReceive(self, receiveSel, session, task, data);
    }));

    method_setImplementation(complete, imp_implementationWithBlock(^(id self, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        JPTTaskState *state = objc_getAssociatedObject(task, &kJPTStateKey);
        if (!state || state.done) {
            origComplete(self, completeSel, session, task, error);
            return;
        }
        state.done = YES;
        NSData *payload = state.buffer;
        NSInteger statusCode = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
        void (^deliver)(NSData *) = ^(NSData *data) {
            if (data.length) origReceive(self, receiveSel, session, (NSURLSessionDataTask *)task, data);
            origComplete(self, completeSel, session, task, error);
        };
        if (error || statusCode != 200 || !payload.length) {
            deliver(payload);
            return;
        }
        if (state.search) {
            JPTFinishSearch(session, task.currentRequest ?: task.originalRequest, payload, deliver);
            return;
        }
        NSDictionary<NSString *, JPTTrackInfo *> *tracks = JPTCollectTracks(payload);
        BOOL clientOriginal = state.clientIsOriginalLanguage;
        NSDictionary<NSString *, JPTTrackInfo *> *(^originals)(void) = ^NSDictionary<NSString *, JPTTrackInfo *> *{
            NSMutableDictionary<NSString *, JPTTrackInfo *> *all = [JPTOriginalSnapshot() mutableCopy];
            if (clientOriginal && tracks) [all addEntriesFromDictionary:tracks];
            return all;
        };
        void (^finish)(void) = ^{
            NSMutableArray<NSString *> *changes = [NSMutableArray array];
            NSMutableDictionary<NSString *, NSString *> *names = JPTArtistNamesSnapshot();
            NSData *patched = JPTRewriteResponse(payload, state.added, originals(), names, changes);
            JPTMergeArtistNames(names);
            JPTLog(@"response %lu bytes, traits %lu, added %lu, changed %lu%@", (unsigned long)payload.length,
                   (unsigned long)state.traitTracks.count, (unsigned long)state.added.count, (unsigned long)changes.count,
                   patched ? @"" : @", parse failed");
            for (NSString *change in changes) JPTLog(@"  %@", change);
            deliver(patched ?: payload);
        };
        NSSet<NSString *> *missing = tracks ? JPTMissingOriginals(tracks, state.traitTracks, originals(), !clientOriginal) : nil;
        if (!missing.count) {
            finish();
            return;
        }
        // Deliver later on the delegate queue once original-name metadata is fetched
        NSOperationQueue *queue = session.delegateQueue;
        JPTFetchOriginals(task.currentRequest ?: task.originalRequest, state.body, missing, ^{
            if (queue) [queue addOperationWithBlock:finish];
            else finish();
        });
    }));
}

static void JPTInitializeNetwork(void) {
    @autoreleasepool {
        gOriginalCache = [NSMutableDictionary dictionary];
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTArtistNamesKey];
        gArtistNames = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
        gDelegateClasses = [NSMutableArray array];
        // Native core requests use SPTCoreURLSessionDataDelegate; Swift clients use HttpClientURLSession
        JPTHookDelegate(@"SPTCoreURLSessionDataDelegate");
        JPTHookDelegate(@"Connectivity_HttpClientKit.HttpClientURLSession");
        if (!gDelegateClasses.count) {
            JPTLog(@"no delegate class found, disabled");
            return;
        }
        JPTHookDataTask([NSURLSession class]);
        Class local = NSClassFromString(@"__NSURLSessionLocal");
        if (local) JPTHookDataTask(local);
        JPTLog(@"loaded");
    }
}

#include "JPTManagement.m"

#endif
