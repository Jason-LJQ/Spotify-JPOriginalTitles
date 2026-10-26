// Restores original-release track/album/artist names that Spotify 9.1.88 takes
// from relinked IdentityTrait (extension kind 178) metadata, by pairing every
// IdentityTrait track query with a TRACK_V4 (kind 10) query and copying the
// TRACK_V4 names back into the IdentityTrait payload. Alternative releases are
// mapped through Track.canonical_uri or a verified recording match in an associated album, and
// names without CJK text fall back to a zh TRACK_V4 lookup when it has CJK text.
// Original names are written onto the client's own artist URIs, whose pages are
// not region-locked; learned artist names also rename artist entities and
// searchview results.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <zlib.h>

static const uint64_t kKindArtistV4 = 8;
static const uint64_t kKindAlbumV4 = 9;
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
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, copy) NSArray<NSString *> *performanceLanguages;
@property (nonatomic) uint64_t duration;
@property (nonatomic) uint64_t number;
@property (nonatomic) uint64_t disc;
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

@interface JPTAlbumInfo : JPTTrackInfo
@property (nonatomic, copy) NSSet<NSString *> *trackURIs;
@end
@implementation JPTAlbumInfo
@end

// Album field 35 is an observed release association; its schema name is unknown.
static JPTAlbumInfo *JPTParseAlbum(const uint8_t *p, size_t len) {
    JPTAlbumInfo *info = [JPTAlbumInfo new];
    NSMutableSet *tracks = [NSMutableSet set];
    JPTReader r = JPTReaderMake(p, len); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2) info.name = JPTString(&f);
        else if (f.field == 18) info.originalTitle = JPTString(&f);
        else if (f.field == 35) {
            NSString *uri = JPTString(&f);
            if ([uri hasPrefix:@"spotify:album:"] && uri.length == 36) info.canonicalURI = uri;
        } else if (f.field == 11 && f.wire == 2) {
            JPTReader dr = JPTReaderMake(f.data, f.len); JPTField df; BOOL dok;
            while (JPTNext(&dr, &df, &dok)) {
                if (df.field != 3 || df.wire != 2) continue;
                NSString *name = nil, *uri = nil;
                if (!JPTParseEntity(df.data, df.len, &name, &uri, @"spotify:track:")) return nil;
                if (uri) [tracks addObject:uri];
            }
            if (!dok) return nil;
        }
    }
    info.trackURIs = tracks;
    return ok ? info : nil;
}

// Track: 2 name, 3 album, 4 artists, 27 original_title, 28 version_title, 36 canonical_uri
static JPTTrackInfo *JPTParseTrack(const uint8_t *p, size_t len) {
    JPTTrackInfo *info = [JPTTrackInfo new];
    info.artists = [NSMutableArray array];
    NSMutableArray *languages = [NSMutableArray array];
    JPTReader r = JPTReaderMake(p, len);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.wire == 0) {
            if (f.field == 5) info.number = f.varint;
            else if (f.field == 6) info.disc = f.varint;
            else if (f.field == 7) info.duration = f.varint;
            continue;
        }
        if (f.wire != 2) continue;
        if (f.field == 10) {
            NSString *type = nil, *value = nil;
            JPTReader er = JPTReaderMake(f.data, f.len); JPTField ef; BOOL eok;
            while (JPTNext(&er, &ef, &eok)) {
                if (ef.field == 1) type = JPTString(&ef);
                else if (ef.field == 2) value = JPTString(&ef);
            }
            if (!eok) return nil;
            if ([type isEqualToString:@"isrc"]) info.isrc = value;
        } else if (f.field == 2) {
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
        } else if (f.field == 22) {
            NSString *language = JPTString(&f);
            if (language.length) [languages addObject:language];
        } else if (f.field == 27) {
            info.originalTitle = JPTString(&f);
        } else if (f.field == 28) {
            info.versionTitle = JPTString(&f);
        } else if (f.field == 36) {
            info.canonicalURI = JPTString(&f);
        }
    }
    info.performanceLanguages = languages;
    return ok ? info : nil;
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

static NSString *JPTEntryStatusSummary(NSData *body) {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        uint64_t kind = JPTArrayKind(&f);
        if (kind != kKindTrackV4 && kind != kKindIdentityTrait) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len);
        JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
            JPTParseEntry(&af, &uri, &status, &value);
            NSString *key = [NSString stringWithFormat:@"%llu/%llu", kind, status];
            counts[key] = @(counts[key].unsignedIntegerValue + 1);
        }
    }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in [[counts allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@x%@", key, counts[key]]];
    return [parts componentsJoinedByString:@","];
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
// Returns nil when unchanged; name-bearing track queries omit etags to receive rewritable payloads.
// traitTracks receives tracks requesting IdentityTrait or TRACK_V4,
// artistURIs every artist entity that asks for ARTIST_V4 or IdentityTrait
NSData *JPTAugmentRequest(NSData *body, NSMutableSet<NSString *> *added, NSMutableSet<NSString *> *traitTracks,
                          NSMutableSet<NSString *> *artistURIs, NSMutableDictionary<NSNumber *, NSNumber *> *kindCounts) {
    NSMutableData *out = [NSMutableData dataWithCapacity:body.length + 64];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSString *uri = nil;
        BOOL hasTrait = NO, hasTrack = NO, hasArtist = NO, hasAlbum = NO;
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
                        if (qf.varint == kKindAlbumV4) hasAlbum = YES;
                        if (qf.varint == kKindArtistV4 || qf.varint == kKindSimpleCard) hasArtist = YES;
                        if (kindCounts) kindCounts[@(qf.varint)] = @(kindCounts[@(qf.varint)].unsignedIntegerValue + 1);
                    }
                }
            }
        }
        if (eok && (hasTrait || hasTrack) && [uri hasPrefix:@"spotify:track:"]) [traitTracks addObject:uri];
        if (eok && (hasTrait || hasArtist) && [uri hasPrefix:@"spotify:artist:"]) [artistURIs addObject:uri];
        BOOL album = [uri hasPrefix:@"spotify:album:"];
        BOOL artist = [uri hasPrefix:@"spotify:artist:"] && (hasTrait || hasArtist);
        if (eok && album && (hasTrait || hasAlbum)) [traitTracks addObject:uri];
        if (!eok || (!((hasTrait || hasTrack) && [uri hasPrefix:@"spotify:track:"]) && !(album && (hasTrait || hasAlbum)) && !artist)) {
            JPTWriteRaw(out, &f);
            continue;
        }
        NSMutableData *entity = [NSMutableData data];
        er = JPTReaderMake(f.data, f.len);
        while (JPTNext(&er, &ef, &eok)) {
            if (ef.field != 2 || ef.wire != 2) { JPTWriteRaw(entity, &ef); continue; }
            uint64_t kind = 0;
            JPTReader qr = JPTReaderMake(ef.data, ef.len);
            JPTField qf;
            BOOL qok;
            while (JPTNext(&qr, &qf, &qok)) if (qf.field == 1 && qf.wire == 0) kind = qf.varint;
            if (!qok) return nil;
            if (kind != (album ? kKindAlbumV4 : kKindTrackV4) && kind != kKindIdentityTrait && !(artist && (kind == kKindArtistV4 || kind == kKindSimpleCard))) { JPTWriteRaw(entity, &ef); continue; }
            NSMutableData *query = [NSMutableData data];
            qr = JPTReaderMake(ef.data, ef.len);
            while (JPTNext(&qr, &qf, &qok)) {
                if (qf.field == 2 && qf.wire == 2) changed = YES;
                else JPTWriteRaw(query, &qf);
            }
            if (!qok) return nil;
            JPTWriteData(entity, 2, query);
        }
        if (!eok) return nil;
        if (!artist && hasTrait && !(album ? hasAlbum : hasTrack)) {
            NSMutableData *query = [NSMutableData data];
            JPTWriteVarint(query, (1 << 3) | 0);
            JPTWriteVarint(query, album ? kKindAlbumV4 : kKindTrackV4);
            JPTWriteData(entity, 2, query);
            [added addObject:uri];
            changed = YES;
        }
        JPTWriteData(out, 2, entity);
    }
    if (!ok || !changed) return nil;
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
        JPTWriteVarint(query, [uri hasPrefix:@"spotify:album:"] ? kKindAlbumV4 :
                              [uri hasPrefix:@"spotify:artist:"] ? kKindArtistV4 : kKindTrackV4);
        NSMutableData *entity = [NSMutableData data];
        JPTWriteString(entity, 1, uri);
        JPTWriteData(entity, 2, query);
        JPTWriteData(out, 2, entity);
    }
    return out;
}

#pragma mark - Response rewrite

static void JPTIndexOriginals(NSDictionary<NSString *, JPTTrackInfo *> *tracks);

// Collects successful TRACK_V4 payloads keyed by entity URI
static NSDictionary<NSString *, JPTTrackInfo *> *JPTCollectTracksMode(NSData *body, BOOL index) {
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
    if (ok && index) JPTIndexOriginals(tracks);
    return ok ? tracks : nil;
}

NSDictionary<NSString *, JPTTrackInfo *> *JPTCollectTracks(NSData *body) {
    return JPTCollectTracksMode(body, YES);
}
static NSDictionary<NSString *, JPTTrackInfo *> *JPTCollectMetadataMode(NSData *body, BOOL index) {
    NSMutableDictionary *all = [JPTCollectTracksMode(body, index) mutableCopy];
    if (!all) return nil;
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2 || JPTArrayKind(&f) != kKindAlbumV4) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status; JPTField value;
            if (!JPTParseEntry(&af, &uri, &status, &value) || status != 200 || !uri) continue;
            JPTAlbumInfo *info = JPTParseAlbum(value.data, value.len);
            if (info) all[uri] = info;
        }
        if (!aok) return nil;
    }
    return ok ? all : nil;
}

static NSDictionary<NSString *, JPTTrackInfo *> *JPTCollectMetadata(NSData *body) {
    return JPTCollectMetadataMode(body, YES);
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

// Process-only reverse links are candidates; recording checks below remain mandatory.
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *gReverseOriginals;
static void JPTIndexOriginals(NSDictionary<NSString *, JPTTrackInfo *> *tracks) {
    @synchronized ([JPTTrackInfo class]) {
        if (!gReverseOriginals) gReverseOriginals = [NSMutableDictionary dictionary];
        for (NSString *uri in tracks) {
            JPTTrackInfo *info = tracks[uri];
            NSString *target = info.canonicalURI;
            if (![uri hasPrefix:@"spotify:track:"] || !JPTHasCJK(info.name)
                || ![target hasPrefix:@"spotify:track:"] || [target isEqualToString:uri]) continue;
            if (!gReverseOriginals[target]) gReverseOriginals[target] = [NSMutableSet set];
            [gReverseOriginals[target] addObject:uri];
        }
    }
}
static NSSet<NSString *> *JPTReverseCandidates(NSString *uri) {
    @synchronized ([JPTTrackInfo class]) { return [gReverseOriginals[uri] copy] ?: [NSSet set]; }
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
        if ((needOriginal || !tracks[uri]) && !originals[uri]) [missing addObject:uri];
        NSString *canonical = JPTRomanizedCanonical(uri, tracks[uri] ?: originals[uri]);
        if (canonical && !originals[canonical]) [missing addObject:canonical];
    }
    return missing;
}

// Client-language value unless only the original-name language has CJK text
static NSString *JPTPick(NSString *client, NSString *original) {
    return (!JPTHasCJK(client) && JPTHasCJK(original)) ? original : client;
}

// Delivered names change only when a name without CJK text gains CJK text.
static BOOL JPTUpgradesName(NSString *old, NSString *name) {
    return name.length && !JPTHasCJK(old) && JPTHasCJK(name);
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
    info.performanceLanguages = client.performanceLanguages;
    info.isrc = client.isrc; info.duration = client.duration; info.number = client.number; info.disc = client.disc;
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
    info.performanceLanguages = original.performanceLanguages;
    info.artists = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [info.artists addObject:@[original.artists[i][0], own.artists[i][1]]];
    return info;
}

// Pure katakana may be a Japanese transcription of a Western artist.
static BOOL JPTJapaneseNameCandidate(NSString *name) {
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 0x3040 && c <= 0x309F) || (c >= 0x3400 && c <= 0x4DBF)
            || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) return YES;
    }
    return NO;
}

static NSDictionary<NSString *, NSString *> *JPTCollectArtistNames(NSData *body) {
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2 || JPTArrayKind(&f) != kKindArtistV4) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil, *name = nil, *gidURI = nil; uint64_t status; JPTField value;
            if (!JPTParseEntry(&af, &uri, &status, &value) || status != 200
                || ![uri hasPrefix:@"spotify:artist:"]) continue;
            if (JPTParseEntity(value.data, value.len, &name, &gidURI, @"spotify:artist:")) names[uri] = name ?: @"";
        }
        if (!aok) return nil;
    }
    return ok ? names : nil;
}

static NSSet<NSString *> *JPTTrackArtists(NSDictionary<NSString *, JPTTrackInfo *> *tracks, NSSet<NSString *> *uris) {
    NSMutableSet *artists = [NSMutableSet set];
    for (NSString *uri in uris) for (NSArray *artist in [tracks[uri] artists])
        if (!JPTHasCJK(artist[0])) [artists addObject:artist[1]];
    return artists;
}

static JPTTrackInfo *JPTNamedArtists(JPTTrackInfo *info, NSDictionary<NSString *, NSString *> *names) {
    if (!info) return nil;
    JPTTrackInfo *copy = [JPTTrackInfo new];
    copy.name = info.name; copy.originalTitle = info.originalTitle; copy.versionTitle = info.versionTitle;
    copy.albumName = info.albumName; copy.albumURI = info.albumURI; copy.canonicalURI = info.canonicalURI;
    copy.artists = [NSMutableArray array];
    copy.performanceLanguages = info.performanceLanguages;
    copy.isrc = info.isrc; copy.duration = info.duration; copy.number = info.number; copy.disc = info.disc;
    for (NSArray *artist in info.artists) [copy.artists addObject:@[JPTPick(artist[0], names[artist[1]]) ?: artist[0], artist[1]]];
    return copy;
}

static JPTAlbumInfo *JPTPreferredAlbum(NSString *uri, NSDictionary<NSString *, JPTTrackInfo *> *all) {
    if (!uri.length) return nil;
    JPTTrackInfo *own = all[uri];
    if (![own isKindOfClass:[JPTAlbumInfo class]]) return nil;
    if (!own.canonicalURI.length || [own.canonicalURI isEqualToString:uri] || JPTHasCJK(own.name))
        return (JPTAlbumInfo *)own;
    JPTTrackInfo *linked = all[own.canonicalURI];
    if (![own.canonicalURI isEqualToString:uri] && [linked isKindOfClass:[JPTAlbumInfo class]]
        && !JPTHasCJK(own.name)) return (JPTAlbumInfo *)linked;
    return (JPTAlbumInfo *)own;
}

static JPTTrackInfo *JPTAlbumOriginal(JPTTrackInfo *own, NSDictionary<NSString *, JPTTrackInfo *> *all) {
    if (JPTHasCJK(own.name) || !own.isrc.length || !own.duration || !own.number || !own.disc) return nil;
    JPTAlbumInfo *album = JPTPreferredAlbum(own.albumURI, all);
    if (!album || !album.trackURIs.count) return nil;
    for (NSString *uri in album.trackURIs) if (!all[uri]) return nil;
    JPTTrackInfo *match = nil;
    for (NSString *uri in album.trackURIs) {
        JPTTrackInfo *candidate = all[uri];
        if (![candidate.isrc isEqualToString:own.isrc]) continue;
        // Duplicate recordings are ambiguous, even when only one has a matching position.
        if (match) return nil;
        match = candidate;
    }
    return match && JPTHasCJK(match.name) && match.duration == own.duration
        && match.number == own.number && match.disc == own.disc ? match : nil;
}

// A resolved non-CJK canonical still leaves the track to the indirect paths.
static BOOL JPTDirectCompatible(JPTTrackInfo *own, JPTTrackInfo *target) {
    return !(own.isrc.length && target.isrc.length && ![own.isrc isEqualToString:target.isrc]
        && own.duration && target.duration && own.duration != target.duration);
}

static BOOL JPTCanonicalUnresolved(NSString *uri, JPTTrackInfo *own, NSDictionary *all) {
    if (!own.canonicalURI.length || [own.canonicalURI isEqualToString:uri]) return YES;
    JPTTrackInfo *target = all[own.canonicalURI];
    return target && (!JPTHasCJK(target.name) || !JPTDirectCompatible(own, target));
}


static JPTTrackInfo *JPTIndirectOriginal(NSString *uri, JPTTrackInfo *own, NSDictionary *all) {
    if (JPTHasCJK(own.name) || !own.isrc.length || !own.duration || !own.number || !own.disc
        || !JPTCanonicalUnresolved(uri, own, all)) return nil;
    // Candidates link to the source itself, or to the canonical they share with it.
    NSString *link = own.canonicalURI.length ? own.canonicalURI : uri;
    NSMutableSet *albums = [NSMutableSet set];
    for (NSString *candidateURI in JPTReverseCandidates(uri)) {
        JPTTrackInfo *candidate = all[candidateURI];
        if (candidate.albumURI) [albums addObject:candidate.albumURI];
    }
    JPTAlbumInfo *album = all[own.albumURI];
    BOOL siblingPath = [album isKindOfClass:[JPTAlbumInfo class]]
        && (!album.canonicalURI.length || [album.canonicalURI isEqualToString:own.albumURI]);
    if (siblingPath) for (NSString *siblingURI in album.trackURIs) {
        JPTTrackInfo *sibling = all[siblingURI], *linked = all[sibling.canonicalURI];
        if (linked.albumURI && ![linked.albumURI isEqualToString:own.albumURI]) [albums addObject:linked.albumURI];
    }
    JPTTrackInfo *match = nil;
    for (NSString *albumURI in albums) {
        JPTAlbumInfo *candidateAlbum = all[albumURI];
        if (![candidateAlbum isKindOfClass:[JPTAlbumInfo class]] || !candidateAlbum.trackURIs.count) continue;
        BOOL complete = YES;
        for (NSString *trackURI in candidateAlbum.trackURIs) if (!all[trackURI]) complete = NO;
        if (!complete) continue;
        JPTTrackInfo *candidate = nil; NSUInteger count = 0;
        for (NSString *trackURI in candidateAlbum.trackURIs) {
            JPTTrackInfo *track = all[trackURI];
            if ([track.isrc isEqualToString:own.isrc]) { count++; candidate = track; }
        }
        if (count != 1 || !JPTHasCJK(candidate.name) || candidate.duration != own.duration
            || candidate.disc != own.disc || candidate.number != own.number
            || ![candidate.canonicalURI isEqualToString:link]) continue;
        if (match && match != candidate) return nil;
        match = candidate;
    }
    return match;
}
static JPTTrackInfo *JPTSelectedOriginal(NSString *uri, JPTTrackInfo *info, NSDictionary *tracks, NSDictionary *originals) {
    if (!info || !info.name.length) return nil;
    NSString *canonical = JPTRomanizedCanonical(uri, info);
    JPTTrackInfo *original = canonical ? JPTMergeInfo(tracks[canonical], originals[canonical]) : nil;
    if (original && JPTHasCJK(original.name) && JPTDirectCompatible(info, original)) return original;
    return JPTAlbumOriginal(info, originals) ?: JPTIndirectOriginal(uri, info, originals);
}
static JPTTrackInfo *JPTPreferredInfoWithArtists(NSString *uri, NSDictionary *tracks, NSDictionary *originals, NSDictionary *names) {
    JPTTrackInfo *own = tracks[uri] ?: originals[uri];
    if (!own || !own.name.length) return nil;
    JPTTrackInfo *info = JPTMergeInfo(own, originals[uri]);
    JPTTrackInfo *original = JPTSelectedOriginal(uri, info, tracks, originals);
    return original ? JPTAdoptOriginal(info, JPTNamedArtists(original, names)) : info;
}
static JPTTrackInfo *JPTPreferredInfo(NSString *uri, NSDictionary *tracks, NSDictionary *originals) {
    return JPTPreferredInfoWithArtists(uri, tracks, originals, @{});
}
static NSSet *JPTResolutionArtists(NSDictionary *all, NSSet *uris) {
    NSMutableSet *artists = [JPTTrackArtists(all, uris) mutableCopy];
    for (NSString *uri in uris) {
        JPTTrackInfo *original = JPTSelectedOriginal(uri, all[uri], all, all);
        for (NSArray *artist in original.artists) if (!JPTHasCJK(artist[0])) [artists addObject:artist[1]];
    }
    return artists;
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

static NSString *JPTSubString(const JPTField *f, uint32_t field);

static NSData *JPTRewriteIdentity(const JPTField *value, JPTTrackInfo *track, NSString **oldSummary) {
    NSMutableData *out = [NSMutableData dataWithCapacity:value->len + 32];
    JPTReader r = JPTReaderMake(value->data, value->len);
    JPTField f;
    BOOL ok;
    BOOL hadParent = NO;
    NSMutableData *keptName = [NSMutableData data];
    NSMutableData *keptParent = [NSMutableData data];
    NSMutableData *renamedContributors = [NSMutableData data];
    BOOL renamedArtist = NO;
    NSString *oldName = nil, *oldAlbum = nil;
    NSMutableArray<NSString *> *oldArtists = [NSMutableArray array];
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2) {
            oldName = JPTString(&f);
            JPTWriteRaw(keptName, &f);
            continue;
        }
        if (f.field == 4) {
            hadParent = YES;
            oldAlbum = JPTSubString(&f, 1);
            JPTWriteRaw(keptParent, &f);
            continue;
        }
        if (f.field == 5) {
            NSString *artistName = JPTSubString(&f, 1), *artistURI = JPTSubString(&f, 2), *name = nil;
            [oldArtists addObject:artistName ?: @""];
            for (NSArray<NSString *> *artist in track.artists) if ([artist[1] isEqualToString:artistURI]) name = artist[0];
            NSData *renamed = JPTUpgradesName(artistName, name) ? JPTReplaceString(f.data, f.len, 1, name, NULL) : nil;
            if (renamed) { JPTWriteData(renamedContributors, 5, renamed); renamedArtist = YES; }
            else JPTWriteRaw(renamedContributors, &f);
            continue;
        }
        JPTWriteRaw(out, &f);
    }
    if (!ok) return nil;
    *oldSummary = JPTSummary(oldName, oldArtists);
    // IdentityTrait is what Spotify displays; keep each name unless it gains CJK text.
    NSMutableArray<NSString *> *newArtists = [NSMutableArray array];
    for (NSArray<NSString *> *artist in track.artists) [newArtists addObject:artist[0]];
    BOOL title = JPTUpgradesName(oldName, track.name);
    BOOL album = hadParent && track.albumURI.length && JPTUpgradesName(oldAlbum, track.albumName);
    BOOL artists = track.artists.count && JPTUpgradesName([oldArtists componentsJoinedByString:@", "],
                                                          [newArtists componentsJoinedByString:@", "]);
    if (!title && !album && !artists && !renamedArtist) return [NSData dataWithBytes:value->data length:value->len];
    if (title) JPTWriteString(out, 2, track.name);
    else [out appendData:keptName];
    if (album) {
        NSMutableData *parent = [NSMutableData data];
        JPTWriteString(parent, 1, track.albumName);
        JPTWriteString(parent, 2, track.albumURI);
        JPTWriteData(out, 4, parent);
    } else {
        [out appendData:keptParent];
    }
    if (artists) {
        for (NSArray<NSString *> *artist in track.artists) {
            NSMutableData *contributor = [NSMutableData data];
            JPTWriteString(contributor, 1, artist[0]);
            JPTWriteString(contributor, 2, artist[1]);
            JPTWriteData(out, 5, contributor);
        }
    } else {
        // A list that already has CJK text still renames each same-URI artist that gains it.
        [out appendData:renamedContributors];
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

static BOOL JPTIsMessage(const uint8_t *p, size_t len);

// Change display names only. Playback IDs, restrictions and unknown fields stay byte-for-byte intact.
static NSData *JPTRewriteTrack(const JPTField *value, JPTTrackInfo *preferred) {
    if (!preferred) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:value->len];
    // original_title and version_title form one display title and change together.
    BOOL pair = preferred.originalTitle.length && JPTUpgradesName(
        [NSString stringWithFormat:@"%@ %@", JPTSubString(value, 27) ?: @"", JPTSubString(value, 28) ?: @""],
        [NSString stringWithFormat:@"%@ %@", preferred.originalTitle, preferred.versionTitle ?: @""]);
    JPTReader r = JPTReaderMake(value->data, value->len);
    JPTField f;
    BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2 && f.wire == 2 && JPTUpgradesName(JPTString(&f), preferred.name)) {
            JPTWriteString(out, 2, preferred.name); changed = YES;
        } else if ((f.field == 27 || f.field == 28) && f.wire == 2 && pair) {
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
            NSData *entity = (parsed && JPTUpgradesName(oldName, name))
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
    NSMutableDictionary *metadata = [originals mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *clientMetadata = JPTCollectMetadata(body);
    if (!clientMetadata) return nil;
    [metadata addEntriesFromDictionary:clientMetadata];
    for (NSString *uri in clientMetadata) if ([clientMetadata[uri] isKindOfClass:JPTAlbumInfo.class]) {
        JPTAlbumInfo *client = clientMetadata[uri]; JPTTrackInfo *cached = originals[uri];
        JPTAlbumInfo *album = [JPTAlbumInfo new];
        album.name = JPTPick(client.name, cached.name);
        album.originalTitle = JPTPick(client.originalTitle, cached.originalTitle);
        album.canonicalURI = client.canonicalURI; album.trackURIs = client.trackURIs; metadata[uri] = album;
    }

    NSMutableData *out = [NSMutableData dataWithCapacity:body.length];
    JPTReader r = JPTReaderMake(body.bytes, body.length);
    JPTField f;
    BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        uint64_t kind = (f.field == 2 && f.wire == 2) ? JPTArrayKind(&f) : 0;
        if (kind != kKindTrackV4 && kind != kKindIdentityTrait && kind != kKindArtistV4 && kind != kKindSimpleCard && kind != kKindAlbumV4) {
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
            // Helper entries are not part of the client's response, including failed helpers.
            if ((kind == kKindTrackV4 || kind == kKindAlbumV4) && uri && [added containsObject:uri]) continue;
            if (status == 200 && (!parsed || !JPTIsMessage(value.data, value.len) || (kind == kKindTrackV4 && !tracks[uri]))) {
                [changes addObject:[NSString stringWithFormat:@"WARNING metadata entry parse failure %@ kind %llu", uri, kind]];
                JPTWriteRaw(array, &af); kept++;
                continue;
            }
            if (kind == kKindAlbumV4 || (kind == kKindIdentityTrait && [uri hasPrefix:@"spotify:album:"])) {
                if (kind == kKindAlbumV4 && [added containsObject:uri]) continue;
                JPTAlbumInfo *preferred = parsed && status == 200 ? JPTPreferredAlbum(uri, metadata) : nil;
                if (!preferred.name.length) preferred = nil;
                NSString *oldName = nil;
                NSData *renamed = preferred ? JPTReplaceString(value.data, value.len, 2, preferred.name, &oldName) : nil;
                if (renamed && !JPTUpgradesName(oldName, preferred.name)) { renamed = nil; preferred = nil; }
                if (renamed && kind == kKindAlbumV4 && preferred.originalTitle.length)
                    renamed = JPTReplaceString(renamed.bytes, renamed.length, 18, preferred.originalTitle, NULL);
                if (preferred && !renamed) [changes addObject:[NSString stringWithFormat:@"WARNING album rewrite parse failure %@", uri]];
                NSData *entry = renamed ? JPTRewriteEntry(&af, renamed) : nil;
                if (entry) {
                    JPTWriteData(array, 3, entry);
                    if (![oldName isEqualToString:preferred.name])
                        [changes addObject:[NSString stringWithFormat:@"ALBUM %@: %@ -> %@", uri, oldName, preferred.name]];
                } else JPTWriteRaw(array, &af);
                kept++;
                continue;
            }
            if (kind == kKindTrackV4) {
                // Drop TRACK_V4 entries that the client never asked for
                if (uri && [added containsObject:uri]) continue;
                JPTTrackInfo *preferred = parsed && status == 200 ? JPTNamedArtists(JPTPreferredInfoWithArtists(uri, tracks, originals, artistNames), artistNames) : nil;
                NSData *track = preferred ? JPTRewriteTrack(&value, preferred) : nil;
                if (preferred && !track && !JPTIsMessage(value.data, value.len)) [changes addObject:[NSString stringWithFormat:@"WARNING track rewrite parse failure %@", uri]];
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
                if (value2 && !JPTUpgradesName(oldName, name)) { value2 = nil; name = nil; }
                if (value2 && kind == kKindSimpleCard) {
                    // SimpleCardTrait repeats the title in field 6
                    NSString *oldTitle = nil;
                    NSData *value6 = JPTReplaceString(value2.bytes, value2.length, 6, name, &oldTitle);
                    if (value6 && [oldTitle isEqualToString:oldName]) value2 = value6;
                }
                if (parsed && status == 200 && name && !value2) [changes addObject:[NSString stringWithFormat:@"WARNING artist rewrite parse failure %@", uri]];
                NSData *entry = value2 ? JPTRewriteEntry(&af, value2) : nil;
                if (entry) {
                    JPTWriteData(array, 3, entry);
                    if (![oldName isEqualToString:name]) [changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@", uri, oldName, name]];
                } else {
                    JPTWriteRaw(array, &af);
                }
                continue;
            }
            JPTTrackInfo *track = (uri && kind == kKindIdentityTrait) ? JPTNamedArtists(JPTPreferredInfoWithArtists(uri, tracks, originals, artistNames), artistNames) : nil;
            NSString *oldSummary = nil;
            NSData *identity = (parsed && status == 200 && track) ? JPTRewriteIdentity(&value, track, &oldSummary) : nil;
            if (parsed && status == 200 && track && !identity) [changes addObject:[NSString stringWithFormat:@"WARNING identity rewrite parse failure %@", uri]];
            NSData *entry = identity ? JPTRewriteEntry(&af, identity) : nil;
            if (entry) {
                JPTWriteData(array, 3, entry);
                JPTLearnArtists(tracks[uri], track, artistNames);
                NSMutableArray<NSString *> *artists = [NSMutableArray array];
                for (NSArray<NSString *> *artist in track.artists) [artists addObject:artist[0]];
                NSString *newSummary = JPTSummary(track.name, artists);
                BOOL rewritten = identity.length != value.len || memcmp(identity.bytes, value.data, value.len);
                if (rewritten && ![oldSummary isEqualToString:newSummary]) {
                    [changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@ / %@", uri, oldSummary, newSummary, track.albumName]];
                }
            } else {
                JPTWriteRaw(array, &af);
            }
        }
        if (!aok) return nil;
        if ((kind == kKindTrackV4 || kind == kKindAlbumV4) && kept == 0) continue;
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
        JPTTrackInfo *info = JPTNamedArtists(JPTPreferredInfoWithArtists(uri, originals, originals, artistNames), artistNames);
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

#include "JPTPreviousMetadata.m"
#include "JPTCredits.m"

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
static void JPTCacheOriginals(NSDictionary *values) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    @synchronized (gOriginalCache) {
        for (NSString *uri in values) {
            JPTTrackInfo *incoming = values[uri], *previous = gOriginalCache[uri];
            if ([incoming isKindOfClass:JPTAlbumInfo.class]) {
                JPTAlbumInfo *album = [JPTAlbumInfo new];
                album.name = JPTHasCJK(previous.name) ? previous.name : incoming.name;
                album.originalTitle = JPTHasCJK(previous.originalTitle) ? previous.originalTitle : incoming.originalTitle;
                album.canonicalURI = incoming.canonicalURI;
                album.trackURIs = [(JPTAlbumInfo *)incoming trackURIs]; merged[uri] = album;
            } else {
                JPTTrackInfo *info = JPTMergeInfo(incoming, previous);
                info.name = JPTHasCJK(previous.name) ? previous.name : info.name;
                info.originalTitle = JPTHasCJK(previous.originalTitle) ? previous.originalTitle : info.originalTitle;
                info.versionTitle = JPTHasCJK(previous.versionTitle) ? previous.versionTitle : info.versionTitle;
                info.albumName = JPTHasCJK(previous.albumName) ? previous.albumName : info.albumName;
                merged[uri] = info;
            }
        }
        [gOriginalCache addEntriesFromDictionary:merged];
    }
    JPTIndexOriginals(merged);
}


static BOOL JPTStrictMode(void);
static BOOL JPTCombineTitles(void);

typedef NS_ENUM(NSInteger, JPTLookupFailure) {
    JPTLookupRejected = 1, JPTLookupExhausted = 2, JPTLookupParseFailure = 3
};
static NSString *JPTFailureName(NSError *error) {
    return error.code == JPTLookupRejected ? @"rejected" : error.code == JPTLookupParseFailure ? @"parse-failure" : @"retry-exhausted";
}
static NSError *JPTLookupFailureError(JPTLookupFailure type, NSString *message) {
    return [NSError errorWithDomain:@"JPOriginalTitles.Lookup" code:type userInfo:@{NSLocalizedDescriptionKey:message}];
}

@interface JPTResolution : NSObject
@property (nonatomic, strong) NSError *failure;
@property (nonatomic) BOOL stopped;
@property (nonatomic) BOOL anonymous;
@property (nonatomic, strong) dispatch_group_t anonymousQueries;
@property (nonatomic, strong) NSMutableDictionary *anonymousResults;
@end
@implementation JPTResolution
@end
static char kJPTResolutionKey;
static JPTResolution *JPTResolutionFor(NSURLRequest *request) { return objc_getAssociatedObject(request, &kJPTResolutionKey); }
static NSURLRequest *JPTBeginResolution(NSURLRequest *request) {
    NSURLRequest *copy = [request mutableCopy];
    JPTResolution *state = [JPTResolution new];
    state.anonymousQueries = dispatch_group_create(); state.anonymousResults = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(copy, &kJPTResolutionKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return copy;
}
static NSError *JPTStopped(NSURLRequest *request) {
    JPTResolution *state = JPTResolutionFor(request);
    @synchronized (state) { return state.stopped ? state.failure : nil; }
}
static void JPTRecordFailure(NSURLRequest *request, NSError *error, BOOL terminal) {
    if (!error) return;
    JPTResolution *state = JPTResolutionFor(request);
    @synchronized (state) {
        if (!state.failure) state.failure = error;
        if (terminal || JPTStrictMode()) { state.failure = error; state.stopped = YES; }
    }
}
static NSError *JPTResolutionFailure(NSURLRequest *request) {
    JPTResolution *state = JPTResolutionFor(request);
    @synchronized (state) { return state.failure; }
}
static BOOL JPTBlockDelivery(NSError *error, NSSet *uris) {
    if (!error) return NO;
    BOOL strict = JPTStrictMode();
    JPTLog(@"%@ %@: %@; URIs %@", strict ? @"strict block" : @"WARNING resolution", JPTFailureName(error), error.localizedDescription, uris.allObjects);
    return strict;
}



// Check cancellation when work reaches its account or anonymous request limit.
static void JPTLookupRequestMode(NSURLRequest *request, NSURLRequest *owner, BOOL anonymous, void (^done)(NSData *, NSURLResponse *, NSError *)) {
    static NSOperationQueue *queue, *anonymousQueue;
    static NSURLSession *session, *anonymousSession;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 3;
        anonymousQueue = [NSOperationQueue new]; anonymousQueue.maxConcurrentOperationCount = 3;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
#ifdef JPT_LOOKUP_TEST_PROTOCOL
        config.protocolClasses = @[NSClassFromString(@"JPTTestTransportProtocol")];
#endif
#ifdef JPT_LOOKUP_TEST_TIMEOUT
        config.timeoutIntervalForRequest = JPT_LOOKUP_TEST_TIMEOUT;
        config.timeoutIntervalForResource = JPT_LOOKUP_TEST_TIMEOUT;
#else
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 20;
#endif
        session = [NSURLSession sessionWithConfiguration:config];
        NSURLSessionConfiguration *isolated = [config copy];
        isolated.HTTPCookieStorage = nil; isolated.URLCredentialStorage = nil;
        isolated.URLCache = nil; isolated.HTTPShouldSetCookies = NO;
        anonymousSession = [NSURLSession sessionWithConfiguration:isolated];
    });
    [(anonymous ? anonymousQueue : queue) addOperationWithBlock:^{
        NSError *stopped = JPTStopped(owner);
        if (stopped) { done(nil, nil, stopped); return; }
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        void (^completion)(NSData *, NSURLResponse *, NSError *)=^(NSData *data, NSURLResponse *response, NSError *error) {
            done(data, response, error); dispatch_semaphore_signal(finished);
        };
        [[(anonymous ? anonymousSession : session) dataTaskWithRequest:request completionHandler:completion] resume];
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    }];
}

static void JPTLookupRequest(NSURLRequest *request, NSURLRequest *owner, void (^done)(NSData *, NSURLResponse *, NSError *)) {
    JPTLookupRequestMode(request, owner, JPTResolutionFor(owner).anonymous, done);
}

// Completed absences are distinct from failed or missing entries.
static NSError *JPTInspectLookup(NSData *body, NSSet *uris, NSMutableDictionary *values, BOOL artist,
                                 NSMutableSet *retry, BOOL *whole, BOOL *terminal) {
    NSMutableSet *seen = [NSMutableSet set], *valid = [NSMutableSet set];
    BOOL malformed = NO, entryParse = NO; NSInteger rejected = 0;
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        uint64_t kind = JPTArrayKind(&f);
        if (kind != kKindArtistV4 && kind != kKindAlbumV4 && kind != kKindTrackV4) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
            BOOL parsed = JPTParseEntry(&af, &uri, &status, &value);
            if (!uri) { malformed = YES; continue; }
            if (![uris containsObject:uri]) continue;
            uint64_t expected = artist ? kKindArtistV4 : [uri hasPrefix:@"spotify:album:"] ? kKindAlbumV4 : kKindTrackV4;
            if (kind != expected) continue;
            if ([seen containsObject:uri]) { [retry addObject:uri]; [valid removeObject:uri]; continue; }
            [seen addObject:uri];
            if (status == 429 || status == 401 || status == 403) { rejected = status; [retry addObject:uri]; continue; }
            if (status == 204 || status == 404 || status == 410) continue;
            if (parsed && status == 200 && values[uri]) [valid addObject:uri];
            else { [retry addObject:uri]; if (status == 200 || !parsed) entryParse = YES; }
        }
        if (!aok) malformed = YES;
    }
    if (!ok) malformed = YES;
    for (NSString *uri in uris) if (![seen containsObject:uri]) [retry addObject:uri];
    for (NSString *uri in [values.allKeys copy]) if (![valid containsObject:uri]) [values removeObjectForKey:uri];
    *whole = malformed; *terminal = rejected != 0;
    if (rejected) return JPTLookupFailureError(JPTLookupRejected, [NSString stringWithFormat:@"Entry HTTP %ld", (long)rejected]);
    if (malformed || retry.count) return JPTLookupFailureError(malformed || entryParse ? JPTLookupParseFailure : JPTLookupExhausted,
        [NSString stringWithFormat:@"%@; URIs %@", malformed ? @"Malformed lookup response" : @"Missing, duplicate or failed entries", retry.allObjects]);
    return nil;
}
static NSError *JPTValidateLookup(NSData *body, NSSet *uris, NSMutableDictionary *values, BOOL artist) {
    BOOL whole = NO, terminal = NO;
    return JPTInspectLookup(body, uris, values, artist, [NSMutableSet set], &whole, &terminal);
}

static void JPTStartAnonymousQuery(NSURLRequest *, NSData *, NSSet *, NSString *, BOOL);

// One wire attempt. Entry retries and split retries use this same transport and validator.
static void JPTQueryAttempt(NSURLRequest *template, NSData *body, NSSet *batch, NSString *language, BOOL artist,
                            void (^done)(NSDictionary *, NSSet *, NSError *, BOOL, BOOL)) {
    NSError *stopped = JPTStopped(template);
    if (stopped) { done(@{}, batch, stopped, NO, YES); return; }
    NSMutableURLRequest *request = [template mutableCopy];
    request.HTTPBody = JPTTrackRequest(body, batch);
    [request setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    [request setValue:language forHTTPHeaderField:@"Accept-Language"];
    if ([request valueForHTTPHeaderField:@"Content-Length"])
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)request.HTTPBody.length] forHTTPHeaderField:@"Content-Length"];
    JPTLookupRequest(request, template, ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL terminal = code == 429 || code == 401 || code == 403 ||
            ([error.domain isEqualToString:NSURLErrorDomain] && (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorCancelled)) ||
            [error.domain isEqualToString:@"JPOriginalTitles.Lookup"];
        BOOL whole = error != nil || code != 200;
        NSMutableSet *retry = [NSMutableSet set];
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        NSError *failure = nil;
        if (whole) failure = [error.domain isEqualToString:@"JPOriginalTitles.Lookup"] ? error : JPTLookupFailureError(code == 429 || code == 401 || code == 403 ? JPTLookupRejected : JPTLookupExhausted,
            [NSString stringWithFormat:@"HTTP %ld %@", (long)code, error.localizedDescription ?: @""]);
        else {
            // Collectors can reject a malformed entry; inspection still retains other valid entities.
            NSDictionary *collected = artist ? (NSDictionary *)JPTCollectArtistNames(data)
                : JPTCollectMetadataMode(data, !JPTResolutionFor(template).anonymous);
            if (collected) [values addEntriesFromDictionary:collected];
            failure = JPTInspectLookup(data, batch, values, artist, retry, &whole, &terminal);
        }
        if (whole) [retry unionSet:batch];
        if (terminal) { JPTLog(@"lookup no retry: %@ HTTP %ld; URIs %@", JPTFailureName(failure), (long)code, batch.allObjects); JPTRecordFailure(template, failure, YES); }
        if (!artist && values.count && !JPTResolutionFor(template).anonymous) JPTCacheOriginals(values);
        JPTLog(@"lookup %@: %lu requested, %lu returned, status %ld, complete %d", language, (unsigned long)batch.count,
               (unsigned long)values.count, (long)code, failure == nil);
        done(values, retry, failure, whole, terminal);
    });
}

static void JPTResolveAttempt(NSURLRequest *, NSData *, NSSet *, NSString *, BOOL, void (^)(NSDictionary *, NSError *, BOOL));
// Entry-level failures do not turn a received response into a whole-request failure.
static void JPTRetrySplit(NSURLRequest *template, NSData *body, NSArray<NSSet *> *parents, NSUInteger size,
                           NSString *language, BOOL artist, NSString *reason, void (^done)(NSDictionary *, NSError *)) {
    NSMutableArray *batches = [NSMutableArray array];
    for (NSSet *parent in parents) {
        NSArray *uris = [parent.allObjects sortedArrayUsingSelector:@selector(compare:)];
        JPTLog(@"lookup split retry: %lu -> %lu; reason %@; URIs %@", (unsigned long)uris.count, (unsigned long)size, reason, uris);
        for (NSUInteger offset = 0; offset < uris.count; offset += size)
            [batches addObject:[NSSet setWithArray:[uris subarrayWithRange:NSMakeRange(offset, MIN(size, uris.count-offset))]]];
    }
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *values = [NSMutableDictionary dictionary], *failures = [NSMutableDictionary dictionary];
    NSMutableArray *wholeFailed = [NSMutableArray array]; __block NSUInteger succeeded = 0;
    for (NSUInteger i = 0; i < batches.count; i++) {
        NSSet *batch = batches[i]; NSNumber *index = @(i); dispatch_group_enter(group);
        JPTResolveAttempt(template, body, batch, language, artist, ^(NSDictionary *got, NSError *error, BOOL whole) {
            @synchronized (values) {
                [values addEntriesFromDictionary:got];
                if (whole && error) { [wholeFailed addObject:batch]; if (size == 16) JPTRecordFailure(template, error, NO); }
                if (!whole) succeeded++;
                if (error) failures[index] = error;
            }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *stopped = JPTStopped(template);
        if (!stopped && succeeded && wholeFailed.count && size > 16) {
            // Entry failures have already had their one retry; only whole-request failures split again.
            NSMutableDictionary *entryFailures = [failures mutableCopy];
            for (NSNumber *index in failures.allKeys) if ([wholeFailed containsObject:batches[index.unsignedIntegerValue]]) [entryFailures removeObjectForKey:index];
            JPTRetrySplit(template, body, wholeFailed, 16, language, artist, [failures.allValues.firstObject localizedDescription], ^(NSDictionary *got, NSError *error) {
                [values addEntriesFromDictionary:got];
                NSNumber *first = [[entryFailures.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
                done(values, first ? entryFailures[first] : error);
            });
        } else {
            NSNumber *first = [[failures.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
            done(values, stopped ?: (first ? failures[first] : nil));
        }
    });
}
static void JPTResolveAttempt(NSURLRequest *template, NSData *body, NSSet *batch, NSString *language, BOOL artist,
                               void (^done)(NSDictionary *, NSError *, BOOL)) {
    JPTQueryAttempt(template, body, batch, language, artist, ^(NSDictionary *values, NSSet *retry, NSError *error, BOOL whole, BOOL terminal) {
        if (!error || whole || terminal) { done(values, error, whole); return; }
        JPTLog(@"lookup entry retry: %lu entities; reason %@", (unsigned long)retry.count, error.localizedDescription);
        JPTQueryAttempt(template, body, retry, language, artist, ^(NSDictionary *got, NSSet *failed, NSError *later, BOOL retryWhole, BOOL stop) {
            NSMutableDictionary *merged = [values mutableCopy]; [merged addEntriesFromDictionary:got];
            // Entry retry is never promoted into a fresh split tree.
            if (later) JPTRecordFailure(template, later, stop);
            done(merged, later, NO);
        });
    });
}
static void JPTFetchQueryBatch(NSURLRequest *template, NSData *body, NSSet *batch, NSString *language, BOOL artist,
                               void (^done)(NSDictionary *, NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
#ifndef JPT_TEST_PRIMARY_ONLY
    if (!JPTResolutionFor(template).anonymous) JPTStartAnonymousQuery(template, body, batch, language, artist);
#endif
    JPTResolveAttempt(template, body, batch, language, artist, ^(NSDictionary *values, NSError *error, BOOL whole) {
        void (^complete)(NSDictionary *, NSError *) = ^(NSDictionary *got, NSError *failure) {
            NSMutableDictionary *merged = [values mutableCopy]; [merged addEntriesFromDictionary:got];
            if (failure) { JPTRecordFailure(template, failure, NO); JPTLog(@"WARNING lookup %@: %@; URIs %@", JPTFailureName(failure), failure.localizedDescription, batch.allObjects); }
            done(merged, failure);
        };
        if (error && whole && !JPTStopped(template)) {
            JPTLog(@"lookup split reason %@", error.localizedDescription);
            JPTRetrySplit(template, body, @[batch], 64, language, artist, error.localizedDescription, complete);
        } else complete(@{}, error);
    });
}

static const NSUInteger kJPTLookupBatchSize = 256;

static void JPTFetchQueryBatches(NSURLRequest *template, NSData *body, NSArray *uris, NSUInteger offset,
                                NSString *language, BOOL artist, NSMutableDictionary *collected,
                                void (^done)(NSDictionary *, NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
    NSError *stopped = JPTStopped(template); if (stopped) { done(collected, stopped); return; }
    if (offset == uris.count) { done(collected, nil); return; }
    NSUInteger count = MIN(kJPTLookupBatchSize, uris.count - offset);
    NSSet *batch = [NSSet setWithArray:[uris subarrayWithRange:NSMakeRange(offset, count)]];
    JPTFetchQueryBatch(template, body, batch, language, artist, ^(NSDictionary *values, NSError *failure) {
        [collected addEntriesFromDictionary:values];
        JPTFetchQueryBatches(template, body, uris, offset + count, language, artist, collected,
            ^(NSDictionary *results, NSError *later) { done(results, failure ?: later); });
    });
}

// Independent batches of one album-lookup stage share the global limit of three requests.
static void JPTFetchSiblingBatches(NSURLRequest *template, NSData *body, NSSet *wanted, void (^done)(NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
    NSError *stopped = JPTStopped(template); if (stopped) { done(stopped); return; }
    NSArray *uris = [wanted.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (uris.count <= kJPTLookupBatchSize) {
        JPTFetchQueryBatches(template, body, uris, 0, kJPTOriginalLanguage, NO, [NSMutableDictionary dictionary],
            ^(NSDictionary *values, NSError *error) { done(error); });
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSNumber *, NSError *> *failures = [NSMutableDictionary dictionary];
    for (NSUInteger offset = 0; offset < uris.count; offset += kJPTLookupBatchSize) {
        NSNumber *index = @(offset);
        NSSet *batch = [NSSet setWithArray:[uris subarrayWithRange:NSMakeRange(offset, MIN(kJPTLookupBatchSize, uris.count - offset))]];
        dispatch_group_enter(group);
        JPTFetchQueryBatch(template, body, batch, kJPTOriginalLanguage, NO, ^(NSDictionary *values, NSError *error) {
            if (error) { @synchronized (failures) { failures[index] = error; } }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *first = [[failures.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
        done(first ? failures[first] : nil);
    });
}

static void JPTFetchOriginals(NSURLRequest *template, NSData *body, NSSet *uris, void (^done)(NSError *)) {
    JPTFetchQueryBatches(template, body, [uris.allObjects sortedArrayUsingSelector:@selector(compare:)], 0,
        kJPTOriginalLanguage, NO, [NSMutableDictionary dictionary], ^(NSDictionary *values, NSError *error) { done(error); });
}

// Resolve one server-provided album association, then fetch only its bounded track set.
static void JPTFetchAssociatedAlbums(NSURLRequest *template, NSData *body, NSSet<NSString *> *uris, void (^done)(NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
    NSError *stopped = JPTStopped(template); if (stopped) { done(stopped); return; }
    NSDictionary *initial = JPTOriginalSnapshot();
    NSMutableSet *albums = [NSMutableSet set];
    for (NSString *uri in uris) {
        JPTTrackInfo *track = initial[uri];
        if ([uri hasPrefix:@"spotify:album:"]) [albums addObject:uri];
        else if (track && !JPTHasCJK(track.name) && track.isrc.length && track.albumURI) [albums addObject:track.albumURI];
    }
    if (!albums.count) { done(nil); return; }
    void (^linkedAlbums)(NSError *) = ^(NSError *sourceError) {
        NSDictionary *own = JPTOriginalSnapshot();
        NSMutableSet *linked = [NSMutableSet set];
        for (NSString *uri in albums) {
            JPTTrackInfo *album = own[uri];
            if (![album isKindOfClass:[JPTAlbumInfo class]] || JPTHasCJK(album.name)) continue;
            NSString *target = album.canonicalURI;
            if ([target hasPrefix:@"spotify:album:"] && ![target isEqualToString:uri] && !own[target]) [linked addObject:target];
        }
        void (^albumTracks)(NSError *) = ^(NSError *linkedError) {
            NSDictionary *snapshot = JPTOriginalSnapshot();
            NSMutableSet *missing = [NSMutableSet set];
            for (NSString *uri in albums) {
                JPTAlbumInfo *preferred = JPTPreferredAlbum(uri, snapshot);
                if (!preferred) continue;
                for (NSString *trackURI in preferred.trackURIs) if (!snapshot[trackURI]) [missing addObject:trackURI];
            }
            void (^complete)(NSError *) = ^(NSError *error) {
                NSDictionary *ready = JPTOriginalSnapshot();
                for (NSString *uri in albums) {
                    JPTAlbumInfo *preferred = JPTPreferredAlbum(uri, ready);
                    if (!preferred) continue;
                    for (NSString *trackURI in preferred.trackURIs) {
                        if (!ready[trackURI]) JPTLog(@"incomplete original album %@ missing %@", uri, trackURI);
                    }
                }
                done(sourceError ?: linkedError ?: error);
            };
            if (missing.count) JPTFetchSiblingBatches(template, body, missing, complete);
            else complete(nil);
        };
        if (linked.count) JPTFetchSiblingBatches(template, body, linked, albumTracks);
        else albumTracks(nil);
    };
    NSMutableSet *missing = [NSMutableSet set];
    for (NSString *uri in albums) if (!initial[uri]) [missing addObject:uri];
    if (missing.count) JPTFetchSiblingBatches(template, body, missing, linkedAlbums);
    else linkedAlbums(nil);
}

// Field 22 contains observed performance-language codes; its schema name is inferred.
static BOOL JPTAllowsSiblingLookup(JPTTrackInfo *track) {
    if (!track.performanceLanguages.count) return YES;
    for (NSString *language in track.performanceLanguages)
        if ([language isEqualToString:@"ja"] || [language isEqualToString:@"und"] || [language isEqualToString:@"zxx"]) return YES;
    return NO;
}
static NSSet<NSString *> *JPTSiblingSourceAlbums(NSDictionary *snapshot, NSSet<NSString *> *uris) {
    NSMutableSet *eligible = [NSMutableSet set];
    for (NSString *uri in uris) {
        JPTTrackInfo *own = snapshot[uri]; JPTAlbumInfo *album = snapshot[own.albumURI];
        if (!own || JPTHasCJK(own.name) || !own.isrc.length || JPTAlbumOriginal(own, snapshot)
            || !JPTCanonicalUnresolved(uri, own, snapshot) || !JPTAllowsSiblingLookup(own)) continue;
        if ([album isKindOfClass:[JPTAlbumInfo class]]
            && (!album.canonicalURI.length || [album.canonicalURI isEqualToString:own.albumURI])) [eligible addObject:own.albumURI];
    }
    return eligible;
}

#pragma mark - Paired anonymous credentials

static NSMutableURLRequest *JPTAnonymousRequest(NSURL *url, NSString *token, NSData *body) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPShouldHandleCookies = NO;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (body) {
        request.HTTPMethod = @"POST"; request.HTTPBody = body;
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        [request setValue:@"zh-Hans" forHTTPHeaderField:@"Accept-Language"];
    }
    if (token.length) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return request;
}
static NSDictionary *JPTAnonymousSession(NSData *html, NSDate *now) {
    NSString *text = [[NSString alloc] initWithData:html encoding:NSUTF8StringEncoding];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"<script[^>]*id=[\"']__NEXT_DATA__[\"'][^>]*>([\\s\\S]*?)</script>" options:0 error:nil];
    NSTextCheckingResult *hit = text ? [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (!hit) return nil;
    NSData *json = [[text substringWithRange:[hit rangeAtIndex:1]] dataUsingEncoding:NSUTF8StringEncoding];
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    id props = root[@"props"], page = [props isKindOfClass:NSDictionary.class] ? props[@"pageProps"] : nil;
    id state = [page isKindOfClass:NSDictionary.class] ? page[@"state"] : nil;
    id settings = [state isKindOfClass:NSDictionary.class] ? state[@"settings"] : nil;
    id session = [settings isKindOfClass:NSDictionary.class] ? settings[@"session"] : nil;
    if (![session isKindOfClass:NSDictionary.class] || ![session[@"isAnonymous"] isKindOfClass:NSNumber.class]
        || ![session[@"isAnonymous"] boolValue] || ![session[@"accessToken"] isKindOfClass:NSString.class]
        || ![session[@"accessTokenExpirationTimestampMs"] isKindOfClass:NSNumber.class]) return nil;
    NSString *token = session[@"accessToken"];
    NSTimeInterval expiry = [session[@"accessTokenExpirationTimestampMs"] doubleValue] / 1000;
    if (!token.length || expiry <= now.timeIntervalSince1970) return nil;
    return @{@"token":token, @"expiry":@(expiry)};
}
static NSString *gJPTAnonymousToken;
static NSTimeInterval gJPTAnonymousExpiry;
static NSMutableArray *gJPTAnonymousWaiters;
static void JPTGetAnonymousToken(NSURLRequest *owner, NSString *uri, void (^done)(NSString *)) {
    @synchronized (JPTResolution.class) {
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (gJPTAnonymousToken.length && now < gJPTAnonymousExpiry) { done(gJPTAnonymousToken); return; }
        if (gJPTAnonymousWaiters) { [gJPTAnonymousWaiters addObject:[done copy]]; return; }
        gJPTAnonymousWaiters = [NSMutableArray arrayWithObject:[done copy]];
    }
    NSArray *parts = [uri componentsSeparatedByString:@":"];
    NSURL *url = parts.count == 3 && [parts[2] length] == 22
        ? [NSURL URLWithString:[NSString stringWithFormat:@"https://open.spotify.com/embed/%@/%@", parts[1], parts[2]]] : nil;
    void (^complete)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *session = !error && [(NSHTTPURLResponse *)response statusCode] == 200 ? JPTAnonymousSession(data, NSDate.date) : nil;
        NSArray *waiters;
        @synchronized (JPTResolution.class) {
            gJPTAnonymousToken = session[@"token"]; gJPTAnonymousExpiry = [session[@"expiry"] doubleValue];
            waiters = [gJPTAnonymousWaiters copy]; gJPTAnonymousWaiters = nil;
        }
        JPTLog(@"anonymous bootstrap HTTP %ld accepted %d", (long)[(NSHTTPURLResponse *)response statusCode], session != nil);
        for (void (^callback)(NSString *) in waiters) callback(session[@"token"]);
    };
    if (!url) { complete(nil, nil, nil); return; }
    NSMutableURLRequest *request=JPTAnonymousRequest(url,nil,nil);
    request.timeoutInterval = owner.timeoutInterval;
    JPTLookupRequestMode(request, owner, YES, complete);
}

#include "JPTAnonymousNames.m"

// Discover only one sibling-canonical hop; no title search or recursive album walk.
static void JPTFetchAlbumOriginals(NSURLRequest *template, NSData *body, NSSet<NSString *> *uris, void (^done)(NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
    NSError *stopped = JPTStopped(template); if (stopped) { done(stopped); return; }
    JPTFetchAssociatedAlbums(template, body, uris, ^(NSError *associationError) {
        if (JPTStopped(template)) { done(associationError ?: JPTStopped(template)); return; }
        NSSet *pending = uris;
        NSDictionary *initial = JPTOriginalSnapshot();
        NSSet *sourceAlbums = JPTSiblingSourceAlbums(initial, pending);
        NSMutableSet *needed = [NSMutableSet set];
        for (NSString *uri in pending) {
            JPTTrackInfo *own = initial[uri]; JPTAlbumInfo *album = initial[own.albumURI];
            if (!own || JPTHasCJK(own.name) || !own.isrc.length || JPTAlbumOriginal(own, initial)
                || !JPTCanonicalUnresolved(uri, own, initial)) continue;
            [needed unionSet:JPTReverseCandidates(uri)];
            if ([sourceAlbums containsObject:own.albumURI]) [needed unionSet:album.trackURIs];
        }
        void (^fetchMissing)(NSSet *, void (^)(NSError *)) = ^(NSSet *wanted, void (^next)(NSError *)) {
            NSDictionary *snapshot = JPTOriginalSnapshot(); NSMutableSet *missing = [NSMutableSet set];
            for (NSString *uri in wanted) if (!snapshot[uri]) [missing addObject:uri];
            if (missing.count) JPTFetchSiblingBatches(template, body, missing, next); else next(nil);
        };
        fetchMissing(needed, ^(NSError *siblingError) {
            NSDictionary *snapshot = JPTOriginalSnapshot(); NSMutableSet *links = [NSMutableSet set];
            for (NSString *albumURI in sourceAlbums) for (NSString *uri in [(JPTAlbumInfo *)snapshot[albumURI] trackURIs]) {
                NSString *canonical = JPTRomanizedCanonical(uri, snapshot[uri]);
                if (canonical) [links addObject:canonical];
            }
            fetchMissing(links, ^(NSError *linkError) {
                NSDictionary *linked = JPTOriginalSnapshot(); NSMutableSet *albums = [NSMutableSet set];
                for (NSString *uri in links) if ([linked[uri] albumURI]) [albums addObject:[linked[uri] albumURI]];
                for (NSString *uri in pending) for (NSString *candidate in JPTReverseCandidates(uri))
                    if ([linked[candidate] albumURI]) [albums addObject:[linked[candidate] albumURI]];
                fetchMissing(albums, ^(NSError *albumError) {
                    NSDictionary *snapshot = JPTOriginalSnapshot(); NSMutableSet *tracks = [NSMutableSet set];
                    for (NSString *uri in albums) {
                        JPTAlbumInfo *album = snapshot[uri];
                        if ([album isKindOfClass:[JPTAlbumInfo class]]) [tracks unionSet:album.trackURIs];
                    }
                    fetchMissing(tracks, ^(NSError *trackError) { done(associationError ?: siblingError ?: linkError ?: albumError ?: trackError); });
                });
            });
        });
    });
}

#pragma mark - Learned artist names and request template

static NSMutableSet<NSString *> *gArtistChecked;

static void JPTFetchArtistLanguage(NSURLRequest *template, NSData *body, NSSet *uris, NSString *language,
                                   void (^done)(NSDictionary *, NSError *)) {
    JPTFetchQueryBatches(template, body, [uris.allObjects sortedArrayUsingSelector:@selector(compare:)], 0,
        language, YES, [NSMutableDictionary dictionary], done);
}

static void JPTFetchArtistOriginals(NSURLRequest *template, NSData *body, NSSet *uris, void (^done)(NSError *)) {
    if (!JPTResolutionFor(template)) template = JPTBeginResolution(template);
    NSError *stopped = JPTStopped(template); if (stopped) { done(stopped); return; }
    NSMutableSet *missing = [NSMutableSet set];
    @synchronized (JPTStorageLock()) {
        for (NSString *uri in uris) if (!gArtistNames[uri] && ![gArtistChecked containsObject:uri]) [missing addObject:uri];
    }
    if (!missing.count) { done(nil); return; }
    JPTFetchArtistLanguage(template, body, missing, kJPTOriginalLanguage, ^(NSDictionary *zh, NSError *zhError) {
        if (JPTStopped(template)) { done(JPTStopped(template)); return; }
        NSMutableDictionary *preferred = [NSMutableDictionary dictionary];
        NSMutableSet *japanese = [NSMutableSet set];
        for (NSString *uri in missing) {
            if (JPTHasCJK(zh[uri])) preferred[uri] = zh[uri];
            else if ([zh[uri] length]) [japanese addObject:uri];
        }
        JPTMergeArtistNames(preferred);
        if (!japanese.count) { done(zhError); return; }
        JPTFetchArtistLanguage(template, body, japanese, @"ja", ^(NSDictionary *ja, NSError *error) {
            NSMutableDictionary *names = [NSMutableDictionary dictionary];
            @synchronized (JPTStorageLock()) {
                for (NSString *uri in japanese) {
                    if (!ja[uri]) continue;
                    [gArtistChecked addObject:uri];
                    if (!gArtistNames[uri] && JPTJapaneseNameCandidate(ja[uri])) names[uri] = ja[uri];
                }
                if (gArtistChecked.count > 5000) [gArtistChecked removeAllObjects];
            }
            JPTMergeArtistNames(names);
            done(zhError ?: error);
        });
    });
}

static BOOL JPTKnowsAnyArtist(NSSet<NSString *> *uris) {
    @synchronized (JPTStorageLock()) {
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
@property (nonatomic, strong) NSSet<NSString *> *artistURIs;
@property (nonatomic) BOOL search;
@property (nonatomic) BOOL credits;
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
    // A message to nil returns zero, which is also NSOrderedSame.
    BOOL gzip = encoding.length && [encoding caseInsensitiveCompare:@"gzip"] == NSOrderedSame;
    if (gzip) body = JPTGunzip(body);
    if (!JPTIsHookedDelegate(session.delegate) || !body.length || (encoding.length && !gzip)) {
        JPTLog(@"skip request: delegate=%@ body=%lu stream=%d encoding=%@", delegateName, (unsigned long)body.length,
               request.HTTPBodyStream != nil, encoding);
        return request;
    }
    BOOL credits = JPTRequestHasCredits(body);
    NSData *freshCredits = credits ? JPTCreditsFreshBody(body) : nil;
    if (freshCredits) body = freshCredits;
    JPTSetTemplate(request, body);
    NSMutableSet<NSString *> *uris = [NSMutableSet set];
    NSMutableSet<NSString *> *traitTracks = [NSMutableSet set];
    NSMutableSet<NSString *> *artists = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSData *augmented = JPTAugmentRequest(body, uris, traitTracks, artists, counts);
    BOOL knownArtists = JPTKnowsAnyArtist(artists);
    JPTLog(@"request %@%@ kinds %@, traits %lu, added %lu%@", delegateName, gzip ? @" gzip" : @"", JPTKindSummary(counts),
           (unsigned long)traitTracks.count, (unsigned long)uris.count, knownArtists ? @", known artists" : @"");
    if (!traitTracks.count && !artists.count && !credits) return request;
    JPTTaskState *state = [JPTTaskState new];
    state.credits = credits;
    state.added = uris;
    state.traitTracks = traitTracks;
    state.artistURIs = artists;
    state.clientIsOriginalLanguage = JPTIsOriginalLanguage([request valueForHTTPHeaderField:@"Accept-Language"]);
    state.body = augmented ?: body;
    state.buffer = [NSMutableData data];
    *stateOut = state;
    if (!augmented && !freshCredits) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.HTTPBody = augmented ?: body;
    // The augmented body is sent uncompressed
    if (gzip) [copy setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    if ([copy valueForHTTPHeaderField:@"Content-Length"]) {
        [copy setValue:[NSString stringWithFormat:@"%lu", (unsigned long)copy.HTTPBody.length] forHTTPHeaderField:@"Content-Length"];
    }
    return copy;
}

// Validate the structured search fields we actually parse; arbitrary strings stay opaque.
static BOOL JPTSearchPayloadIsValid(NSData *payload) {
    if (!JPTIsMessage(payload.bytes, payload.length)) return NO;
    __block BOOL valid = YES;
    JPTWalkSearch(payload.bytes, payload.length, 0, ^NSData *(NSString *uri, const uint8_t *p, size_t len) {
        JPTReader r = JPTReaderMake(p, len); JPTField f; BOOL ok;
        while (JPTNext(&r, &f, &ok)) {
            if (f.wire != 2 || !(([uri hasPrefix:@"spotify:track:"] && f.field == 5)
                || ([uri hasPrefix:@"spotify:album:"] && f.field == 6))) continue;
            JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
            while (JPTNext(&ar, &af, &aok)) {
                if (af.wire == 2 && ((f.field == 5 && (af.field == 3 || af.field == 4)) || (f.field == 6 && af.field == 7))
                    && !JPTIsMessage(af.data, af.len)) valid = NO;
            }
            if (!aok) valid = NO;
        }
        if (!ok) valid = NO;
        return nil;
    });
    return valid;
}

// Fetches TRACK_V4 for the search tracks, then for the canonical releases of romanized ones, then rewrites
static void JPTFinishSearch(NSURLSession *session, NSURLRequest *searchRequest, NSData *payload, void (^deliver)(NSData *, NSError *)) {
    NSSet<NSString *> *uris = JPTSearchTracks(payload);
    if (payload.length && !JPTSearchPayloadIsValid(payload)) {
        NSError *failure = JPTLookupFailureError(JPTLookupParseFailure, @"Search response parse failure");
        if (JPTBlockDelivery(failure, uris)) deliver(nil, failure); else deliver(payload, nil);
        return;
    }
    NSOperationQueue *queue = session.delegateQueue;
    void (^finish)(void) = ^{
        NSMutableDictionary<NSString *, NSString *> *names = JPTArtistNamesSnapshot();
        NSMutableArray<NSString *> *changes = [NSMutableArray array];
        NSData *patched = JPTRewriteSearch(payload, JPTOriginalSnapshot(), names, changes);
        if (!patched && !JPTIsMessage(payload.bytes, payload.length)) JPTLog(@"WARNING search rewrite parse failure; URIs %@", uris.allObjects);
        JPTMergeArtistNames(names);
        JPTLog(@"search %lu bytes, tracks %lu, changed %lu", (unsigned long)payload.length, (unsigned long)uris.count,
               (unsigned long)changes.count);
        for (NSString *change in changes) JPTLog(@"  %@", change);
        // Capture only the payload actually delivered to the client.
        NSData *body = patched ?: payload;
        if (JPTCapturePreviousSearch(payload, body)) deliver((JPTCombineTitles() ? JPTPresentSearchTitles(body) : nil) ?: body, nil);
        else deliver(nil, [NSError errorWithDomain:@"JPOriginalTitles.Storage" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not persist name changes"}]);
    };
    NSURLRequest *template = nil;
    NSData *templateBody = nil;
    if (!uris.count || !JPTTemplate(searchRequest, &template, &templateBody)) {
        JPTLog(@"search %lu bytes, tracks %lu%@", (unsigned long)payload.length, (unsigned long)uris.count,
               template ? @"" : @", no metadata template yet");
        if (uris.count) JPTLog(@"WARNING missing metadata template; URIs %@", uris.allObjects);
        finish();
        return;
    }
    template = JPTBeginResolution(template);
    void (^onQueue)(NSError *) = ^(NSError *error) {
        void (^complete)(void) = ^{ NSError *failure = JPTResolutionFailure(template) ?: error;
            if (JPTBlockDelivery(failure, uris)) deliver(nil, failure); else finish(); };
        if (queue) [queue addOperationWithBlock:complete];
        else complete();
    };
    void (^resolveArtists)(NSError *) = ^(NSError *error) {
        NSSet *artists = JPTResolutionArtists(JPTOriginalSnapshot(), uris);
        JPTFetchArtistOriginals(template, templateBody, artists, ^(NSError *artistError) {
            NSMutableSet *targets = [uris mutableCopy]; [targets unionSet:artists];
            JPTFinishAnonymousQueries(template, targets, ^{ onQueue(artistError); });
        }); };
    void (^resolveAlbums)(NSError *) = ^(NSError *error) {
        JPTFetchAlbumOriginals(template, templateBody, uris, resolveArtists); };
    void (^canonicals)(NSError *) = ^(NSError *error) {
        NSDictionary<NSString *, JPTTrackInfo *> *snapshot = JPTOriginalSnapshot();
        NSSet<NSString *> *missing = JPTMissingOriginals(snapshot, uris, snapshot, NO);
        if (missing.count) JPTFetchOriginals(template, templateBody, missing, resolveAlbums);
        else resolveAlbums(nil);
    };
    NSDictionary<NSString *, JPTTrackInfo *> *snapshot = JPTOriginalSnapshot();
    NSMutableSet<NSString *> *own = [NSMutableSet set];
    for (NSString *uri in uris) {
        if (!snapshot[uri]) [own addObject:uri];
    }
    if (own.count) JPTFetchOriginals(template, templateBody, own, canonicals);
    else canonicals(nil);
}

static BOOL JPTClientMetadataIsValid(NSData *body) {
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        uint64_t kind = JPTArrayKind(&f);
        if (kind != kKindTrackV4 && kind != kKindAlbumV4 && kind != kKindArtistV4 && kind != kKindIdentityTrait && kind != kKindSimpleCard) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
            BOOL parsed = JPTParseEntry(&af, &uri, &status, &value);
            if (status != 200) continue;
            if (!parsed || !JPTIsMessage(value.data, value.len)) return NO;
            if (kind == kKindTrackV4 && !JPTParseTrack(value.data, value.len)) return NO;
            if (kind == kKindAlbumV4 && !JPTParseAlbum(value.data, value.len)) return NO;
        }
        if (!aok) return NO;
    }
    return ok;
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
        void (^deliver)(NSData *, NSError *) = ^(NSData *data, NSError *lookupError) {
            if (!lookupError && !error && statusCode == 200 && state.credits) data = JPTNativeCreditsResponse(data);
            if (!lookupError && data.length) origReceive(self, receiveSel, session, (NSURLSessionDataTask *)task, data);
            origComplete(self, completeSel, session, task, lookupError ?: error);
        };
        if (error || statusCode != 200 || !payload.length) {
            deliver(payload, nil);
            return;
        }
        if (state.credits && !state.traitTracks.count && !state.artistURIs.count) { deliver(payload, nil); return; }
        if (state.search) {
            JPTFinishSearch(session, task.currentRequest ?: task.originalRequest, payload, deliver);
            return;
        }
        NSDictionary<NSString *, JPTTrackInfo *> *tracks = JPTCollectMetadata(payload);
        if (!tracks || !JPTClientMetadataIsValid(payload)) {
            NSError *failure = JPTLookupFailureError(JPTLookupParseFailure, @"Metadata response parse failure");
            if (JPTBlockDelivery(failure, state.traitTracks)) { deliver(nil, failure); return; }
            if (!tracks) { deliver(payload, nil); return; }
        }
        NSURLRequest *template = JPTBeginResolution(task.currentRequest ?: task.originalRequest);
        BOOL clientOriginal = state.clientIsOriginalLanguage;
        if (clientOriginal && tracks.count) {
            JPTCacheOriginals(tracks);
        }
        NSDictionary<NSString *, JPTTrackInfo *> *(^originals)(void) = ^NSDictionary<NSString *, JPTTrackInfo *> *{
            return JPTOriginalSnapshot();
        };
        void (^finish)(void) = ^{
            NSMutableArray<NSString *> *changes = [NSMutableArray array];
            NSMutableDictionary<NSString *, NSString *> *names = JPTArtistNamesSnapshot();
            NSData *patched = JPTRewriteResponse(payload, state.added, originals(), names, changes);
            JPTMergeArtistNames(names);
            JPTLog(@"entry statuses %@", JPTEntryStatusSummary(payload));
            JPTLog(@"response %lu bytes, traits %lu, added %lu, changed %lu%@", (unsigned long)payload.length,
                   (unsigned long)state.traitTracks.count, (unsigned long)state.added.count, (unsigned long)changes.count,
                   patched ? @"" : @", parse failed");
            for (NSString *change in changes) JPTLog(@"  %@", change);
            if (!patched) JPTLog(@"WARNING metadata rewrite parse failure; URIs %@", state.traitTracks.allObjects);
            NSError *failure = !patched || (JPTStrictMode() && !JPTClientMetadataIsValid(payload))
                ? JPTLookupFailureError(JPTLookupParseFailure, @"Metadata rewrite parse failure") : nil;
            if (JPTBlockDelivery(failure, state.traitTracks)) deliver(nil, failure);
            else if (JPTCapturePreviousResponse(payload, patched ?: payload))
                deliver((JPTCombineTitles() ? JPTPresentResponseTitles(patched ?: payload) : nil) ?: patched ?: payload, nil);
            else deliver(nil, [NSError errorWithDomain:@"JPOriginalTitles.Storage" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not persist name changes"}]);
        };
        NSSet<NSString *> *missing = tracks ? JPTMissingOriginals(tracks, state.traitTracks, originals(), !clientOriginal) : nil;
        // Deliver later on the delegate queue once original-name metadata is fetched
        NSOperationQueue *queue = session.delegateQueue;
        void (^onQueue)(NSError *) = ^(NSError *error) {
            void (^complete)(void) = ^{ NSError *failure = JPTResolutionFailure(template) ?: error;
                if (JPTBlockDelivery(failure, state.traitTracks)) deliver(nil, failure); else finish(); };
            if (queue) [queue addOperationWithBlock:complete]; else complete();
        };
        void (^resolveArtists)(NSError *) = ^(NSError *error) {
            NSMutableSet *artists = [state.artistURIs mutableCopy] ?: [NSMutableSet set];
            [artists unionSet:JPTResolutionArtists(originals(), state.traitTracks)];
            JPTFetchArtistOriginals(template, state.body, artists, ^(NSError *artistError) {
                NSMutableSet *targets = [state.traitTracks mutableCopy]; [targets unionSet:artists];
                JPTFinishAnonymousQueries(template, targets, ^{ onQueue(artistError); });
            });
        };
        void (^resolveAlbums)(NSError *) = ^(NSError *error) {
            JPTFetchAlbumOriginals(template, state.body, state.traitTracks, resolveArtists); };
        if (!missing.count) { resolveAlbums(nil); return; }
        JPTFetchOriginals(template, state.body, missing, ^(NSError *error) {
            NSDictionary *snapshot = originals();
            NSMutableSet *canonicals = [NSMutableSet set];
            for (NSString *uri in state.traitTracks) {
                NSString *canonical = JPTRomanizedCanonical(uri, tracks[uri] ?: snapshot[uri]);
                if (canonical && !snapshot[canonical]) [canonicals addObject:canonical];
            }
            if (canonicals.count) JPTFetchOriginals(template, state.body, canonicals, resolveAlbums);
            else resolveAlbums(nil);
        });
    }));
}

static void JPTInitializeNetwork(void) {
    @autoreleasepool {
        gOriginalCache = [NSMutableDictionary dictionary];
        JPTArtistNamesSnapshot();
        gArtistChecked = [NSMutableSet set];
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
