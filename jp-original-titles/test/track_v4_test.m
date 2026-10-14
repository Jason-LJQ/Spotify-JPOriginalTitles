// Offline regression fixtures for client-requested TRACK_V4 and existing paths.
// Build: xcrun clang -fobjc-arc -O2 -framework Foundation -lz track_v4_test.m -o track_v4_test
#define JPT_TEST 1
#include "../JPOriginalTitles.m"

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *label) {
    checks++;
    failures += !condition;
    printf("%s %s\n", condition ? "PASS" : "FAIL", label.UTF8String);
}

static void Number(NSMutableData *data, uint32_t field, uint64_t value) {
    JPTWriteVarint(data, (uint64_t)field << 3);
    JPTWriteVarint(data, value);
}

static NSData *GID(uint8_t seed) {
    uint8_t bytes[16];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) bytes[i] = seed + i;
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *URI(NSString *kind, uint8_t seed) {
    NSData *gid = GID(seed);
    return [NSString stringWithFormat:@"spotify:%@:%@", kind, JPTBase62(gid.bytes, gid.length)];
}

static NSData *Entity(uint8_t seed, NSString *name) {
    NSMutableData *data = [NSMutableData data];
    JPTWriteData(data, 1, GID(seed));
    JPTWriteString(data, 2, name);
    Number(data, 88, 901);
    JPTWriteString(data, 89, @"nested unknown field");
    return data;
}

static NSData *Track(uint8_t seed, NSString *name, NSString *album, NSArray<NSString *> *artists,
                     NSString *canonical) {
    NSMutableData *data = [NSMutableData data];
    JPTWriteData(data, 1, GID(seed));
    JPTWriteString(data, 2, name);
    JPTWriteData(data, 3, Entity(seed + 1, album));
    for (NSUInteger i = 0; i < artists.count; i++) JPTWriteData(data, 4, Entity(seed + 2 + i, artists[i]));
    Number(data, 7, 271234);
    NSMutableData *restriction = [NSMutableData data];
    JPTWriteString(restriction, 1, @"catalogue");
    JPTWriteString(restriction, 2, @"JPUS");
    Number(restriction, 3, 5);
    JPTWriteData(data, 11, restriction);
    if (canonical) JPTWriteString(data, 36, canonical);
    Number(data, 120, 123456789);
    const uint8_t fixed64[8] = {1, 4, 7, 10, 13, 16, 19, 22};
    JPTWriteVarint(data, (121 << 3) | 1);
    [data appendBytes:fixed64 length:8];
    const uint8_t fixed32[4] = {0xde, 0xad, 0xbe, 0xef};
    JPTWriteVarint(data, (122 << 3) | 5);
    [data appendBytes:fixed32 length:4];
    JPTWriteString(data, 123, @"opaque payload 1");
    JPTWriteString(data, 123, @"opaque payload 2");
    return data;
}

static NSData *StructuredTrack(NSData *track, uint8_t seed, NSString *originalTitle, NSString *versionTitle,
                               NSArray<NSString *> *artists) {
    NSMutableData *data = [track mutableCopy];
    JPTWriteString(data, 27, originalTitle);
    JPTWriteString(data, 28, versionTitle);
    for (NSUInteger i = 0; i < artists.count; i++) {
        NSMutableData *role = [NSMutableData data];
        JPTWriteData(role, 1, GID(seed + 2 + i));
        JPTWriteString(role, 2, artists[i]);
        Number(role, 3, i ? 4 : 1);
        JPTWriteString(role, 84, @"unknown role annotation");
        JPTWriteData(data, 32, role);
    }
    return data;
}

static NSData *Entry(NSString *uri, NSData *payload, uint64_t status) {
    NSMutableData *header = [NSMutableData data], *any = [NSMutableData data], *entry = [NSMutableData data];
    Number(header, 1, status);
    JPTWriteString(header, 12, @"preserve entry header");
    JPTWriteString(any, 1, @"type.googleapis.com/fixture.Track");
    JPTWriteData(any, 2, payload);
    Number(any, 23, 1122);
    JPTWriteData(entry, 1, header);
    JPTWriteString(entry, 2, uri);
    JPTWriteData(entry, 3, any);
    JPTWriteString(entry, 44, @"preserve entry extras");
    return entry;
}

static NSData *Array(uint64_t kind, NSArray<NSData *> *entries) {
    NSMutableData *array = [NSMutableData data];
    JPTWriteString(array, 1, @"preserve array header");
    Number(array, 2, kind);
    for (NSData *entry in entries) JPTWriteData(array, 3, entry);
    Number(array, 77, 19);
    return array;
}

static NSData *Response(NSArray<NSData *> *arrays) {
    NSMutableData *data = [NSMutableData data];
    JPTWriteString(data, 1, @"preserve batch header");
    for (NSData *array in arrays) JPTWriteData(data, 2, array);
    Number(data, 80, 123);
    return data;
}

static NSData *Request(NSString *uri, NSArray<NSNumber *> *kinds) {
    NSMutableData *entity = [NSMutableData data], *request = [NSMutableData data];
    JPTWriteString(entity, 1, uri);
    for (NSNumber *kind in kinds) {
        NSMutableData *query = [NSMutableData data];
        Number(query, 1, kind.unsignedLongLongValue);
        JPTWriteString(query, 2, @"existing etag");
        JPTWriteData(entity, 2, query);
    }
    JPTWriteString(request, 1, @"request header");
    JPTWriteData(request, 2, entity);
    return request;
}

static NSArray<NSData *> *Fields(NSData *data, uint32_t number) {
    NSMutableArray *values = [NSMutableArray array];
    JPTReader reader = JPTReaderMake(data.bytes, data.length);
    JPTField field;
    BOOL ok;
    while (JPTNext(&reader, &field, &ok)) {
        if (field.field == number && field.wire == 2)
            [values addObject:[NSData dataWithBytes:field.data length:field.len]];
    }
    return ok ? values : nil;
}

static NSString *String(NSData *data, uint32_t number) {
    return [[NSString alloc] initWithData:Fields(data, number).firstObject encoding:NSUTF8StringEncoding];
}

static NSData *Payload(NSData *response, uint64_t kind, NSString *uri) {
    for (NSData *array in Fields(response, 2)) {
        JPTField raw = {0}; raw.data = array.bytes; raw.len = array.length;
        if (JPTArrayKind(&raw) != kind) continue;
        for (NSData *entry in Fields(array, 3)) {
            if (![String(entry, 2) isEqualToString:uri]) continue;
            return Fields(Fields(entry, 3).firstObject, 2).firstObject;
        }
    }
    return nil;
}

// Compare raw bytes of every field outside the explicitly allowed name fields.
static NSData *NonNameFields(NSData *data, BOOL track) {
    NSMutableData *result = [NSMutableData data];
    JPTReader reader = JPTReaderMake(data.bytes, data.length);
    JPTField field;
    BOOL ok;
    while (JPTNext(&reader, &field, &ok)) {
        if (field.field == 2 && field.wire == 2) continue;
        if (track && (field.field == 3 || field.field == 4) && field.wire == 2) {
            NSData *nested = [NSData dataWithBytes:field.data length:field.len];
            JPTWriteData(result, field.field, NonNameFields(nested, NO));
        } else JPTWriteRaw(result, &field);
    }
    return ok ? result : nil;
}

static NSData *Rewrite(NSData *body, NSSet *added, NSDictionary *originals, NSMutableDictionary *names) {
    return JPTRewriteResponse(body, added, originals, names, [NSMutableArray array]);
}

int main(void) {
    @autoreleasepool {
        NSString *ownURI = URI(@"track", 10), *originalURI = URI(@"track", 40);
        NSData *ownTrack = Track(10, @"ray - Cosmic Princess Kaguya! Version", @"Cosmic Princess Kaguya!",
                                @[@"Kaguya(cv.Yuko Natsuyoshi)", @"Yachiyo Runami"], originalURI);
        NSData *originalTrack = Track(40, @"ray - 超かぐや姫！Version", @"超かぐや姫！",
                                     @[@"かぐや（cv.夏吉ゆうこ）", @"月見ヤチヨ"], nil);
        NSData *body = Response(@[Array(10, @[Entry(ownURI, ownTrack, 200)])]);
        NSDictionary *originals = JPTCollectTracks(Response(@[Array(10, @[Entry(originalURI, originalTrack, 200)])]));
        NSMutableSet *added = [NSMutableSet set], *tracked = [NSMutableSet set], *artistURIs = [NSMutableSet set];
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        NSData *augmented = JPTAugmentRequest(Request(ownURI, @[@10]), added, tracked, artistURIs, counts);
        Check(augmented && !added.count && [tracked containsObject:ownURI] && [counts[@10] isEqual:@1]
              && !Fields(Fields(Fields(augmented, 2).firstObject, 2).firstObject, 2).count,
              @"TRACK_V4-only request removes its etag without adding a query");
        [added removeAllObjects]; [tracked removeAllObjects];
        augmented = JPTAugmentRequest(Request(ownURI, @[@178, @10]), added, tracked, artistURIs, counts);
        Check(augmented && !added.count && tracked.count == 1, @"mixed existing name queries are refreshed without duplicate queries");
        BOOL noEtags = YES;
        for (NSData *query in Fields(Fields(augmented, 2).firstObject, 2)) if (Fields(query, 2).count) noEtags = NO;
        Check(noEtags, @"both TRACK_V4 and IdentityTrait validators are removed");
        NSData *once = augmented;
        Check(!JPTAugmentRequest(once, [NSMutableSet set], [NSMutableSet set], [NSMutableSet set], nil),
              @"unconditional existing queries remain byte-for-byte unchanged");
        NSData *mixedKinds = JPTAugmentRequest(Request(ownURI, @[@178, @10, @179]), [NSMutableSet set], [NSMutableSet set], [NSMutableSet set], nil);
        NSArray *queries = Fields(Fields(mixedKinds, 2).firstObject, 2);
        Check([String(queries[2], 2) isEqual:@"existing etag"] && !Fields(queries[0], 2).count && !Fields(queries[1], 2).count,
              @"unrelated extension validators remain intact");
        NSData *artistRequest = Request(URI(@"artist", 10), @[@178]);
        NSData *freshArtist = JPTAugmentRequest(artistRequest, [NSMutableSet set], [NSMutableSet set], [NSMutableSet set], nil);
        Check(freshArtist && !Fields(Fields(Fields(freshArtist, 2).firstObject, 2).firstObject, 2).count,
              @"artist name requests refresh their cache validators");
        [added removeAllObjects]; [tracked removeAllObjects];
        augmented = JPTAugmentRequest(Request(ownURI, @[@178]), added, tracked, artistURIs, counts);
        Check(augmented && [added containsObject:ownURI] && [tracked containsObject:ownURI],
              @"IdentityTrait-only request still adds TRACK_V4");

        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        NSData *rewritten = Rewrite(body, [NSSet set], originals, names);
        NSData *payload = Payload(rewritten, 10, ownURI);
        JPTTrackInfo *info = JPTCollectTracks(rewritten)[ownURI];
        Check([info.name isEqual:@"ray - 超かぐや姫！Version"] && [info.albumName isEqual:@"超かぐや姫！"] &&
              [info.artists[0][0] isEqual:@"かぐや（cv.夏吉ゆうこ）"] && [info.artists[1][0] isEqual:@"月見ヤチヨ"],
              @"international TRACK_V4 adopts canonical Japanese track, album and artists");
        Check([NonNameFields(payload, YES) isEqual:NonNameFields(ownTrack, YES)],
              @"TRACK_V4 preserves all GIDs, canonical URI, duration, restrictions and unknown fields byte-for-byte");
        NSData *expectedTrack = Track(10, @"ray - 超かぐや姫！Version", @"超かぐや姫！",
                                     @[@"かぐや（cv.夏吉ゆうこ）", @"月見ヤチヨ"], originalURI);
        Check([rewritten isEqual:Response(@[Array(10, @[Entry(ownURI, expectedTrack, 200)])])],
              @"batch, array, entry and Any envelopes preserve all unrelated bytes");
        Check([names[URI(@"artist", 12)] isEqual:@"かぐや（cv.夏吉ゆうこ）"] &&
              [names[URI(@"artist", 13)] isEqual:@"月見ヤチヨ"], @"TRACK_V4 learns names for international artist URIs");
        NSData *combined = Response(@[Array(10, @[Entry(ownURI, ownTrack, 200), Entry(originalURI, originalTrack, 200)])]);
        NSData *combinedResult = Rewrite(combined, [NSSet set], @{}, [NSMutableDictionary dictionary]);
        Check([Payload(combinedResult, 10, ownURI) isEqual:expectedTrack] &&
              [Payload(combinedResult, 10, originalURI) isEqual:originalTrack],
              @"canonical present in the client response is reused and its requested entry remains intact");
        NSData *localizedTrack = Track(10, @"日本語の曲", @"日本語のアルバム", @[@"日本語の歌手", @"日本語の共演者"], nil);
        NSDictionary *localizedOriginals = JPTCollectTracks(Response(@[Array(10, @[Entry(ownURI, localizedTrack, 200)])]));
        NSData *localizedResult = Rewrite(body, [NSSet set], localizedOriginals, [NSMutableDictionary dictionary]);
        Check([String(Payload(localizedResult, 10, ownURI), 2) isEqual:@"日本語の曲"] &&
              [NonNameFields(Payload(localizedResult, 10, ownURI), YES) isEqual:NonNameFields(ownTrack, YES)],
              @"same-track language fallback renames names without changing release identifiers");

        NSData *structuredOwn = StructuredTrack(ownTrack, 10, @"ray", @"Cosmic Princess Kaguya! Version",
                                                 @[@"Kaguya(cv.Yuko Natsuyoshi)", @"Yachiyo Runami"]);
        NSData *structuredOriginal = StructuredTrack(originalTrack, 40, @"ray", @"超かぐや姫！ Version",
                                                      @[@"かぐや（cv.夏吉ゆうこ）", @"月見ヤチヨ"]);
        NSDictionary *structuredOriginals = JPTCollectTracks(Response(@[Array(10, @[Entry(originalURI, structuredOriginal, 200)])]));
        NSData *structuredBody = Response(@[Array(10, @[Entry(ownURI, structuredOwn, 200)])]);
        NSData *structuredResult = Rewrite(structuredBody, [NSSet set], structuredOriginals, [NSMutableDictionary dictionary]);
        NSData *structuredValue = Payload(structuredResult, 10, ownURI);
        NSData *structuredExpected = StructuredTrack(expectedTrack, 10, @"ray", @"超かぐや姫！ Version",
                                                      @[@"かぐや（cv.夏吉ゆうこ）", @"月見ヤチヨ"]);
        Check([structuredValue isEqual:structuredExpected],
              @"canonical TRACK_V4 updates full title, structured titles and role artist names together");
        Check([String(structuredValue, 27) isEqual:@"ray"] && [String(structuredValue, 28) isEqual:@"超かぐや姫！ Version"],
              @"original_title and version_title agree with the Japanese full title");
        NSArray<NSData *> *oldRoles = Fields(structuredOwn, 32), *newRoles = Fields(structuredValue, 32);
        BOOL rolesPreserved = oldRoles.count == newRoles.count && oldRoles.count == 2;
        for (NSUInteger i = 0; rolesPreserved && i < oldRoles.count; i++)
            rolesPreserved = [NonNameFields(oldRoles[i], NO) isEqual:NonNameFields(newRoles[i], NO)];
        Check(rolesPreserved, @"ArtistWithRole retains international GIDs, enum roles and unknown annotations");
        Check([String(newRoles[0], 2) isEqual:@"かぐや（cv.夏吉ゆうこ）"] &&
              [String(newRoles[1], 2) isEqual:@"月見ヤチヨ"], @"ArtistWithRole uses names on the international artist identities");

        NSData *partlyFixed = StructuredTrack(expectedTrack, 10, @"ray", @"Cosmic Princess Kaguya! Version",
                                              @[@"Kaguya(cv.Yuko Natsuyoshi)", @"Yachiyo Runami"]);
        NSData *sameReleaseJP = StructuredTrack(expectedTrack, 10, @"ray", @"超かぐや姫！ Version",
                                                @[@"かぐや（cv.夏吉ゆうこ）", @"月見ヤチヨ"]);
        NSDictionary *sameReleaseOriginals = JPTCollectTracks(Response(@[Array(10, @[Entry(ownURI, sameReleaseJP, 200)])]));
        NSData *partlyResult = Rewrite(Response(@[Array(10, @[Entry(ownURI, partlyFixed, 200)])]), [NSSet set],
                                      sameReleaseOriginals, [NSMutableDictionary dictionary]);
        Check([Payload(partlyResult, 10, ownURI) isEqual:sameReleaseJP],
              @"Japanese field 2 with stale English field 28 is repaired consistently from same-release metadata");
        NSData *romanizedParts = StructuredTrack(Track(10, @"Melt - Kaguya Version", @"Album", @[@"Artist"], nil),
                                                 10, @"Melt", @"Kaguya Version", @[@"Artist"]);
        NSData *japaneseParts = StructuredTrack(Track(10, @"メルト - かぐや Version", @"アルバム", @[@"歌手"], nil),
                                                10, @"メルト", @"かぐや Version", @[@"歌手"]);
        NSDictionary *partOriginals = JPTCollectTracks(Response(@[Array(10, @[Entry(ownURI, japaneseParts, 200)])]));
        NSData *partsResult = Rewrite(Response(@[Array(10, @[Entry(ownURI, romanizedParts, 200)])]), [NSSet set],
                                      partOriginals, [NSMutableDictionary dictionary]);
        Check([Payload(partsResult, 10, ownURI) isEqual:japaneseParts],
              @"both romanized original_title and version_title adopt Japanese language fallback");

        NSData *cjkTrack = Track(10, @"既存の曲", @"既存のアルバム", @[@"既存の歌手"], originalURI);
        NSData *cjkBody = Response(@[Array(10, @[Entry(ownURI, cjkTrack, 200)])]);
        NSData *unrelated = Track(10, @"Other Song", @"Other Album", @[@"Other Artist"], originalURI);
        NSDictionary *unrelatedOriginals = JPTCollectTracks(Response(@[Array(10, @[Entry(ownURI, unrelated, 200)])]));
        Check([Rewrite(cjkBody, [NSSet set], unrelatedOriginals, [NSMutableDictionary dictionary]) isEqual:cjkBody],
              @"CJK client names survive unrelated English original-language values");
        NSData *english = Track(10, @"English Song", @"English Album", @[@"English Artist"], originalURI);
        NSData *remaster = Track(40, @"English Song - Remaster", @"Remastered Album", @[@"English Artist"], nil);
        NSData *englishBody = Response(@[Array(10, @[Entry(ownURI, english, 200)])]);
        NSDictionary *remastered = JPTCollectTracks(Response(@[Array(10, @[Entry(originalURI, remaster, 200)])]));
        Check([Rewrite(englishBody, [NSSet set], remastered, [NSMutableDictionary dictionary]) isEqual:englishBody],
              @"English canonical remaster does not replace the client release");

        NSMutableData *identity = [NSMutableData data], *parent = [NSMutableData data];
        JPTWriteString(identity, 1, ownURI); JPTWriteString(identity, 2, @"Localized title");
        JPTWriteString(parent, 1, @"Localized album"); JPTWriteString(parent, 2, URI(@"album", 11));
        JPTWriteData(identity, 4, parent);
        for (NSUInteger i = 0; i < 2; i++) {
            NSMutableData *artist = [NSMutableData data];
            JPTWriteString(artist, 1, @"Localized artist"); JPTWriteString(artist, 2, URI(@"artist", 12 + i));
            JPTWriteData(identity, 5, artist);
        }
        Number(identity, 60, 999);
        NSData *mixed = Response(@[Array(178, @[Entry(ownURI, identity, 200)]), Array(10, @[Entry(ownURI, ownTrack, 200)])]);
        NSData *stripped = Rewrite(mixed, [NSSet setWithObject:ownURI], originals, [NSMutableDictionary dictionary]);
        NSData *fixedIdentity = Payload(stripped, 178, ownURI);
        NSArray *contributors = Fields(fixedIdentity, 5);
        Check(!Payload(stripped, 10, ownURI) && Fields(stripped, 2).count == 1,
              @"extra TRACK_V4 query result is removed from delivered response");
        NSString *otherURI = URI(@"track", 70);
        NSData *otherTrack = Track(70, @"Unrelated Song", @"Unrelated Album", @[@"Unrelated Artist"], nil);
        NSData *mixedTracks = Response(@[Array(10, @[Entry(ownURI, ownTrack, 200), Entry(otherURI, otherTrack, 200)])]);
        NSData *keptTracks = Rewrite(mixedTracks, [NSSet setWithObject:ownURI], originals, [NSMutableDictionary dictionary]);
        Check(!Payload(keptTracks, 10, ownURI) && [Payload(keptTracks, 10, otherURI) isEqual:otherTrack] &&
              [keptTracks isEqual:Response(@[Array(10, @[Entry(otherURI, otherTrack, 200)])])],
              @"stripping an added entry preserves a client-requested entry in the same array");
        Check([String(fixedIdentity, 2) isEqual:@"ray - 超かぐや姫！Version"] && contributors.count == 2 &&
              [String(contributors[0], 2) isEqual:URI(@"artist", 12)] &&
              [String(contributors[1], 2) isEqual:URI(@"artist", 13)] &&
              [String(contributors[0], 1) isEqual:@"かぐや（cv.夏吉ゆうこ）"],
              @"IdentityTrait keeps international artist page URIs while adopting Japanese names");

        NSMutableDictionary *saved = [originals mutableCopy];
        [saved addEntriesFromDictionary:JPTCollectTracks(body)];
        NSData *identityOnly = Response(@[Array(178, @[Entry(ownURI, identity, 200)])]);
        NSData *repaired = Rewrite(identityOnly, [NSSet set], saved, [NSMutableDictionary dictionary]);
        Check([String(Payload(repaired, 178, ownURI), 2) isEqual:@"ray - 超かぐや姫！Version"],
              @"IdentityTrait can use a cached own track when the response omits TRACK_V4");
        Check([JPTMissingOriginals(@{}, [NSSet setWithObject:ownURI], @{}, NO) containsObject:ownURI],
              @"missing own TRACK_V4 is fetched even for a Chinese client");
        Check([JPTMissingOriginals(@{}, [NSSet setWithObject:ownURI], JPTCollectTracks(body), NO) containsObject:originalURI],
              @"canonical lookup continues after recovering a missing own track");

        NSData *errorBody = Response(@[Array(10, @[Entry(ownURI, ownTrack, 404)])]);
        Check([Rewrite(errorBody, [NSSet set], originals, [NSMutableDictionary dictionary]) isEqual:errorBody] &&
              !JPTCollectTracks(errorBody).count, @"unsuccessful entry remains unchanged and is not collected");
        const uint8_t malformed[] = {0x12, 0x07, 0x41};
        NSData *bad = [NSData dataWithBytes:malformed length:sizeof(malformed)];
        NSData *badPayload = Response(@[Array(10, @[Entry(ownURI, bad, 200)])]);
        Check([Rewrite(badPayload, [NSSet set], originals, [NSMutableDictionary dictionary]) isEqual:badPayload],
              @"malformed TRACK_V4 payload is preserved without a partial rename");
        Check(!Rewrite(bad, [NSSet set], originals, [NSMutableDictionary dictionary]) && !JPTCollectTracks(bad),
              @"malformed outer response fails safely");
        NSMutableData *badArray = [Array(10, @[]) mutableCopy]; [badArray appendData:bad];
        Check(!Rewrite(Response(@[badArray]), [NSSet set], originals, [NSMutableDictionary dictionary]),
              @"malformed extension array fails safely");

        NSMutableData *searchEntity = [NSMutableData data], *searchTrack = [NSMutableData data], *search = [NSMutableData data];
        JPTWriteString(searchEntity, 1, ownURI); JPTWriteString(searchEntity, 2, @"ray - Cosmic Princess Kaguya! Version");
        NSMutableData *reference = [NSMutableData data];
        JPTWriteString(reference, 1, URI(@"album", 11)); JPTWriteString(reference, 2, @"Cosmic Princess Kaguya!");
        JPTWriteData(searchTrack, 3, reference);
        for (NSUInteger i = 0; i < 2; i++) {
            [reference setLength:0]; JPTWriteString(reference, 1, URI(@"artist", 12 + i));
            JPTWriteString(reference, 2, i ? @"Yachiyo Runami" : @"Kaguya(cv.Yuko Natsuyoshi)");
            JPTWriteData(searchTrack, 4, reference);
        }
        JPTWriteData(searchEntity, 5, searchTrack); JPTWriteString(searchEntity, 3, @"unchanged image URL");
        JPTWriteData(search, 14, searchEntity);
        NSMutableDictionary *searchOriginals = [JPTCollectTracks(body) mutableCopy]; [searchOriginals addEntriesFromDictionary:originals];
        NSData *fixedSearch = JPTRewriteSearch(search, searchOriginals, [NSMutableDictionary dictionary], [NSMutableArray array]);
        NSData *fixedEntity = Fields(fixedSearch, 14).firstObject;
        NSData *fixedSearchTrack = Fields(fixedEntity, 5).firstObject;
        Check([JPTSearchTracks(search) containsObject:ownURI] && [String(fixedEntity, 1) isEqual:ownURI] &&
              [String(fixedEntity, 2) isEqual:@"ray - 超かぐや姫！Version"] &&
              [String(Fields(fixedSearchTrack, 4).firstObject, 1) isEqual:URI(@"artist", 12)] &&
              [String(fixedEntity, 3) isEqual:@"unchanged image URL"],
              @"search path still renames the international track and preserves artist URI and image");
        printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
