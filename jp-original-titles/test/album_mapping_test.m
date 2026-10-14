// Release matching against captured public catalog responses and adverse fixtures.
#define JPT_TEST 1
#include "../JPOriginalTitles.m"

static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n", label.UTF8String);
}
static void Number(NSMutableData *out, uint32_t field, uint64_t value) {
    JPTWriteVarint(out, (uint64_t)field << 3); JPTWriteVarint(out, value);
}
static NSData *Payload(NSData *response, uint64_t kind, NSString *wanted) {
    JPTReader r = JPTReaderMake(response.bytes, response.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2 || JPTArrayKind(&f) != kind) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status; JPTField value;
            if (JPTParseEntry(&af, &uri, &status, &value) && [uri isEqualToString:wanted])
                return [NSData dataWithBytes:value.data length:value.len];
        }
    }
    return nil;
}
static NSData *OpaqueFields(NSData *payload, NSSet *rewritten) {
    NSMutableData *out = [NSMutableData data];
    JPTReader r = JPTReaderMake(payload.bytes, payload.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) if (![rewritten containsObject:@(f.field)]) JPTWriteRaw(out, &f);
    return out;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSData *jp = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *intl = [NSData dataWithContentsOfFile:@(argv[2])];
        NSMutableDictionary *all = [JPTCollectMetadata(jp) mutableCopy];
        [all addEntriesFromDictionary:JPTCollectMetadata(intl)];
        NSString *albumURI = @"spotify:album:4ncDSulCMzzASL7VcjTa28";
        NSString *jpURI = @"spotify:album:0zUeyb0nCCpCGxc3h2DCR2";
        JPTAlbumInfo *album = (JPTAlbumInfo *)all[albumURI], *originalAlbum = (JPTAlbumInfo *)all[jpURI];
        Check(album.trackURIs.count == 7 && originalAlbum.trackURIs.count == 7, @"parse both album track sets");
        Check([album.canonicalURI isEqualToString:jpURI], @"parse explicit album association");
        NSMutableArray *changes = [NSMutableArray array];
        NSData *rewritten = JPTRewriteResponse(intl, [NSSet set], all, [NSMutableDictionary dictionary], changes);
        NSDictionary *tracks = JPTCollectTracks(intl), *after = JPTCollectTracks(rewritten);
        for (NSString *uri in album.trackURIs) {
            JPTTrackInfo *expected = JPTAlbumOriginal(tracks[uri], all);
            Check(expected && [after[uri] name] && [[after[uri] name] isEqualToString:expected.name],
                  [NSString stringWithFormat:@"original name for %@", [tracks[uri] name]]);
            NSData *beforeData = Payload(intl, 10, uri), *afterData = Payload(rewritten, 10, uri);
            Check([OpaqueFields(beforeData, [NSSet setWithArray:@[@2,@3,@4,@27,@28,@32]])
                   isEqualToData:OpaqueFields(afterData, [NSSet setWithArray:@[@2,@3,@4,@27,@28,@32]])],
                  @"retain track IDs, canonical URI, duration, ISRC and opaque fields");
            JPTField field = {.data = Payload(rewritten, 178, uri).bytes, .len = Payload(rewritten, 178, uri).length};
            NSString *old = nil;
            NSData *identity = JPTReplaceString(field.data, field.len, 2, expected.name, &old);
            Check(identity && [old isEqualToString:expected.name], @"rewrite IdentityTrait title");
        }
        Check([[JPTCollectMetadata(rewritten)[albumURI] name] isEqualToString:@"アナザームーン"], @"rewrite ALBUM_V4 name");
        NSString *traitName = nil; NSData *trait = Payload(rewritten, 178, albumURI);
        JPTReplaceString(trait.bytes, trait.length, 2, @"test", &traitName);
        Check([traitName isEqualToString:@"アナザームーン"], @"rewrite album IdentityTrait name");
        Check([OpaqueFields(Payload(intl, 9, albumURI), [NSSet setWithArray:@[@2,@18]])
               isEqualToData:OpaqueFields(Payload(rewritten, 9, albumURI), [NSSet setWithArray:@[@2,@18]])],
              @"retain album GID, association, disc order and all opaque fields");
        NSString *trackURI = @"spotify:track:1wXrIFdqheifq4ETjCpqoi";
        JPTTrackInfo *own = all[trackURI], *match = JPTAlbumOriginal(own, all);
        Check([match.name isEqualToString:@"救世主"], @"self-canonical Kyuseishu resolves through album");
        uint64_t duration = own.duration, number = own.number, disc = own.disc;
        own.duration++; Check(!JPTAlbumOriginal(own, all), @"reject duration mismatch"); own.duration = duration;
        own.number++; Check(!JPTAlbumOriginal(own, all), @"reject track-position mismatch"); own.number = number;
        own.disc++; Check(!JPTAlbumOriginal(own, all), @"reject disc mismatch"); own.disc = disc;
        NSString *isrc = own.isrc; own.isrc = nil;
        Check(!JPTAlbumOriginal(own, all), @"reject missing ISRC"); own.isrc = isrc;
        NSString *name = match.name; match.name = @"English title";
        Check(!JPTAlbumOriginal(own, all), @"do not replace English with English"); match.name = name;
        NSMutableSet *duplicates = [originalAlbum.trackURIs mutableCopy];
        [duplicates addObject:@"spotify:track:duplicate"]; NSSet *savedTracks = originalAlbum.trackURIs;
        originalAlbum.trackURIs = duplicates; all[@"spotify:track:duplicate"] = match;
        Check(!JPTAlbumOriginal(own, all), @"reject duplicate ISRC within original album");
        originalAlbum.trackURIs = savedTracks; [all removeObjectForKey:@"spotify:track:duplicate"];
        NSString *association = album.canonicalURI; album.canonicalURI = albumURI;
        Check(!JPTAlbumOriginal(own, all), @"do not match across unassociated albums"); album.canonicalURI = association;
        NSMutableDictionary *incomplete = [all mutableCopy]; [incomplete removeObjectForKey:jpURI];
        Check(!JPTAlbumOriginal(own, incomplete), @"failed original album lookup keeps current title");
        album.canonicalURI = nil;
        Check(!JPTAlbumOriginal(own, all), @"missing album association keeps current title");
        album.canonicalURI = association;
        incomplete = [all mutableCopy];
        NSString *other = nil;
        for (NSString *uri in originalAlbum.trackURIs) if (all[uri] != match) { other = uri; break; }
        [incomplete removeObjectForKey:other];
        Check(!JPTAlbumOriginal(own, incomplete), @"partial original track lookup cannot prove unique ISRC");
        Check(!JPTPreferredAlbum(nil, all), @"missing album URI is safe");
        NSMutableData *request = [NSMutableData data], *entity = [NSMutableData data], *query = [NSMutableData data];
        Number(query, 1, 178); JPTWriteString(query, 2, @"old etag");
        JPTWriteString(entity, 1, albumURI); JPTWriteData(entity, 2, query); JPTWriteData(request, 2, entity);
        NSMutableSet *added = [NSMutableSet set], *targets = [NSMutableSet set];
        NSData *augmented = JPTAugmentRequest(request, added, targets, [NSMutableSet set], nil);
        Check(augmented && [added containsObject:albumURI] && [targets containsObject:albumURI], @"augment album-only Identity request");
        NSData *filtered = JPTRewriteResponse(intl, added, all, [NSMutableDictionary dictionary], [NSMutableArray array]);
        Check(!Payload(filtered, 9, albumURI) && Payload(filtered, 178, albumURI), @"drop only added ALBUM_V4 helper");
        const uint8_t broken[] = {0x12, 0xff};
        Check(!JPTParseAlbum(broken, sizeof(broken)), @"reject malformed album protobuf");
        printf("%lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
