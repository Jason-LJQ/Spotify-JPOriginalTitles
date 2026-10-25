// Synthetic recording contradictions and Latin-named associated-album delivery.
#define JPT_MANAGEMENT_TEST 1
#define JPT_LOOKUP_TEST_PROTOCOL 1
#include "../JPOriginalTitles.m"
#include "shared_canonical_fixture.h"

static NSUInteger checks;
static NSDictionary<NSString *, NSData *> *catalog;
static NSMutableSet<NSString *> *requested;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n", label.UTF8String);
}
static void Number(NSMutableData *data, uint32_t field, uint64_t value) {
    JPTWriteVarint(data, (uint64_t)field << 3); JPTWriteVarint(data, value);
}
static NSData *GID(NSUInteger value) {
    uint8_t gid[16] = {0}; gid[14] = (uint8_t)(value >> 8); gid[15] = (uint8_t)value;
    return [NSData dataWithBytes:gid length:16];
}
static NSData *Response(NSString *uri, NSData *payload) {
    NSMutableData *header = [NSMutableData data], *entry = [NSMutableData data], *any = [NSMutableData data];
    NSMutableData *array = [NSMutableData data], *out = [NSMutableData data];
    Number(header, 1, 200); JPTWriteData(entry, 1, header); JPTWriteString(entry, 2, uri);
    JPTWriteData(any, 2, payload); JPTWriteData(entry, 3, any);
    Number(array, 2, [uri hasPrefix:@"spotify:album:"] ? 9 : 10);
    JPTWriteData(array, 3, entry); JPTWriteData(out, 2, array); return out;
}
static NSData *Track(NSUInteger value, NSString *name, NSString *isrc, uint64_t duration, NSUInteger album) {
    NSMutableData *out = [NSMutableData data], *parent = [NSMutableData data], *external = [NSMutableData data];
    JPTWriteData(out, 1, GID(value)); JPTWriteString(out, 2, name);
    JPTWriteData(parent, 1, GID(album)); JPTWriteString(parent, 2, @"LATIN ALBUM"); JPTWriteData(out, 3, parent);
    Number(out, 5, 1); Number(out, 6, 2); Number(out, 7, duration);
    JPTWriteString(external, 1, @"isrc"); JPTWriteString(external, 2, isrc); JPTWriteData(out, 10, external);
    JPTWriteString(out, 22, @"cmn"); JPTWriteString(out, 27, name); JPTWriteString(out, 28, @"Chinese Ver.");
    JPTWriteString(out, 36, SharedURI(@"track", 3)); return out;
}
static NSData *Album(NSUInteger value, NSUInteger linked, NSUInteger track) {
    NSMutableData *out = [NSMutableData data], *disc = [NSMutableData data], *entry = [NSMutableData data];
    JPTWriteData(out, 1, GID(value)); JPTWriteString(out, 2, @"LATIN ALBUM");
    JPTWriteString(out, 35, SharedURI(@"album", linked));
    JPTWriteData(entry, 1, GID(track)); JPTWriteData(disc, 3, entry); JPTWriteData(out, 11, disc); return out;
}

@interface JPTTestTransportProtocol : NSURLProtocol
@end
@implementation JPTTestTransportProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"jpt.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSData *body = self.request.HTTPBody;
    if (!body && self.request.HTTPBodyStream) {
        NSInputStream *stream = self.request.HTTPBodyStream; [stream open];
        NSMutableData *data = [NSMutableData data]; uint8_t bytes[4096]; NSInteger count;
        while ((count = [stream read:bytes maxLength:sizeof(bytes)]) > 0) [data appendBytes:bytes length:(NSUInteger)count];
        [stream close]; body = data;
    }
    NSMutableData *out = [NSMutableData data];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField field; BOOL ok;
    while (JPTNext(&r, &field, &ok)) if (field.field == 2 && field.wire == 2) {
        JPTReader entity = JPTReaderMake(field.data, field.len); JPTField part; BOOL valid;
        while (JPTNext(&entity, &part, &valid)) if (part.field == 1) {
            NSString *uri = JPTString(&part); @synchronized (requested) { [requested addObject:uri]; }
            if (catalog[uri]) [out appendData:catalog[uri]];
        }
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:out]; [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

int main(void) { @autoreleasepool {
    NSString *source = SharedURI(@"track", 1), *correct = SharedURI(@"track", 2), *wrong = SharedURI(@"track", 3);
    NSString *a = SharedURI(@"album", 100), *b = SharedURI(@"album", 101);
    NSData *raw = Response(source, Track(1, @"Romanized - Chinese Ver.", @"RECORDING_CN", 435920, 100));
    NSData *right = Response(correct, Track(2, @"原曲 - Chinese Ver.", @"RECORDING_CN", 435920, 101));
    NSData *bad = Response(wrong, Track(3, @"原曲", @"RECORDING_JA", 435944, 100));
    NSMutableDictionary *all = [JPTCollectMetadata(raw) mutableCopy];
    [all addEntriesFromDictionary:JPTCollectMetadata(bad)];
    JPTTrackInfo *own = all[source], *target = all[wrong];
    Check(!JPTSelectedOriginal(source, own, all, all), @"reject direct canonical when ISRC and exact duration both differ");
    Check(JPTCanonicalUnresolved(source, own, all), @"rejected CJK canonical remains unresolved");
    target.duration = own.duration;
    Check(JPTSelectedOriginal(source, own, all, all) == target, @"changed ISRC alone remains allowed");
    target.duration++; target.isrc = own.isrc;
    Check(JPTSelectedOriginal(source, own, all, all) == target, @"changed duration alone remains allowed");
    target.isrc = nil;
    Check(JPTSelectedOriginal(source, own, all, all) == target, @"missing target ISRC does not prove a contradiction");
    target.isrc = @"RECORDING_JA"; target.duration = 0;
    Check(JPTSelectedOriginal(source, own, all, all) == target, @"missing target duration does not prove a contradiction");
    target.duration = own.duration + 2;
    Check(!JPTSelectedOriginal(source, own, all, all), @"one decoded millisecond plus a different ISRC rejects direct adoption");
    [all addEntriesFromDictionary:JPTCollectMetadata(Response(a, Album(100, 101, 1)))];
    [all addEntriesFromDictionary:JPTCollectMetadata(Response(b, Album(101, 101, 2)))];
    Check(JPTPreferredAlbum(a, all) == all[b], @"Latin-named linked album is preferred");
    Check(!JPTAlbumOriginal(own, all), @"missing candidate track still rejects an incomplete album");
    [all addEntriesFromDictionary:JPTCollectMetadata(right)];
    JPTTrackInfo *candidate = all[correct];
    Check(JPTSelectedOriginal(source, own, all, all) == candidate, @"rejected direct canonical falls through to exact associated recording");
    for (NSString *key in @[@"duration", @"number", @"disc"]) {
        uint64_t saved = [[candidate valueForKey:key] unsignedLongLongValue];
        [candidate setValue:@(saved + 1) forKey:key];
        Check(!JPTAlbumOriginal(own, all), [@"associated match still rejects mismatched " stringByAppendingString:key]);
        [candidate setValue:@(saved) forKey:key];
    }
    candidate.isrc = @"OTHER"; Check(!JPTAlbumOriginal(own, all), @"associated match still requires the same ISRC"); candidate.isrc = own.isrc;
    NSString *name = candidate.name; candidate.name = @"Latin candidate";
    Check(!JPTAlbumOriginal(own, all), @"candidate title still requires CJK"); candidate.name = name;
    JPTAlbumInfo *album = all[b]; album.trackURIs = [NSSet setWithArray:@[correct, wrong]];
    target.isrc = own.isrc;
    Check(!JPTAlbumOriginal(own, all), @"duplicate ISRC rejects even when the other duration differs");
    album.trackURIs = [NSSet setWithObject:correct]; target.isrc = @"RECORDING_JA";
    JPTTrackInfo *rewritten = JPTCollectTracks(JPTRewriteResponse(raw, [NSSet set], all, [NSMutableDictionary dictionary], [NSMutableArray array]))[source];
    Check([rewritten.name isEqualToString:name] && [rewritten.versionTitle isEqualToString:@"Chinese Ver."], @"wire delivery restores original title and preserves the language version");
    Check([rewritten.isrc isEqualToString:own.isrc] && rewritten.duration == own.duration
        && [rewritten.albumURI isEqualToString:a] && [rewritten.performanceLanguages isEqualToArray:own.performanceLanguages], @"wire delivery retains source recording fields and TRACK parent GID");
    gOriginalCache = [@{source: own, wrong: target} mutableCopy]; gReverseOriginals = [NSMutableDictionary dictionary];
    requested = [NSMutableSet set]; catalog = @{a: Response(a, Album(100, 101, 1)), b: Response(b, Album(101, 101, 2)), correct: right};
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://jpt.invalid/metadata"]]; request.HTTPMethod = @"POST";
    dispatch_semaphore_t ready = dispatch_semaphore_create(0); __block NSError *failure = nil;
    JPTFetchAssociatedAlbums(request, [NSData data], [NSSet setWithObject:source], ^(NSError *error) { failure = error; dispatch_semaphore_signal(ready); });
    Check(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 && !failure, @"cold associated-album dependency lookup completes");
    Check([requested isEqualToSet:[NSSet setWithArray:@[a, b, correct]]], @"cold lookup fetches source album, Latin linked album and its complete track set");
    NSDictionary *snapshot = JPTOriginalSnapshot();
    Check([JPTPreferredInfo(source, snapshot, snapshot).name isEqualToString:name], @"cold lookup selects the exact foreign-language recording after rejecting direct canonical");
    printf("%lu checks passed\n", (unsigned long)checks);
} return 0; }
