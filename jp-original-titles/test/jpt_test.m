// macOS harness for the protobuf transforms.
// Usage: jpt_test augment <request.bin> <out.bin> <added.txt> <traits.txt>
//        jpt_test originals <response.bin> <traits.txt> <template-request.bin> <out-request.bin> <need-original 0|1>
//        jpt_test rewrite <response.bin> <added.txt> <out.bin> <originals-response.bin|-> <client-original 0|1>
#define JPT_TEST 1
#include "../JPOriginalTitles.m"

static NSSet *JPTReadList(const char *path) {
    NSString *list = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    return [NSSet setWithArray:[list componentsSeparatedByString:@"\n"]];
}

static void JPTWriteList(NSSet *set, const char *path) {
    [[[set allObjects] componentsJoinedByString:@"\n"] writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 6) return 2;
        NSString *mode = @(argv[1]);
        NSData *body = [NSData dataWithContentsOfFile:@(argv[2])];
        if ([mode isEqualToString:@"augment"]) {
            if (body.length > 2 && ((const uint8_t *)body.bytes)[0] == 0x1f && ((const uint8_t *)body.bytes)[1] == 0x8b) {
                body = JPTGunzip(body);
                printf("gunzipped to %lu bytes\n", (unsigned long)body.length);
            }
            NSMutableSet *added = [NSMutableSet set];
            NSMutableSet *traits = [NSMutableSet set];
            NSMutableDictionary *counts = [NSMutableDictionary dictionary];
            NSData *out = JPTAugmentRequest(body, added, traits, counts);
            [out ?: body writeToFile:@(argv[3]) atomically:YES];
            JPTWriteList(added, argv[4]);
            JPTWriteList(traits, argv[5]);
            printf("augmented %lu -> %lu bytes, added %lu, traits %lu\n", (unsigned long)body.length,
                   (unsigned long)(out ?: body).length, (unsigned long)added.count, (unsigned long)traits.count);
            return 0;
        }
        if (argc != 7) return 2;
        if ([mode isEqualToString:@"originals"]) {
            NSDictionary *tracks = JPTCollectTracks(body);
            NSSet *missing = JPTMissingOriginals(tracks, JPTReadList(argv[3]), @{}, atoi(argv[6]) != 0);
            [JPTTrackRequest([NSData dataWithContentsOfFile:@(argv[4])], missing) writeToFile:@(argv[5]) atomically:YES];
            printf("original fetch %lu uris\n", (unsigned long)missing.count);
            return 0;
        }
        NSMutableDictionary *originals = [NSMutableDictionary dictionary];
        if (strcmp(argv[5], "-") != 0) [originals addEntriesFromDictionary:JPTCollectTracks([NSData dataWithContentsOfFile:@(argv[5])])];
        if (atoi(argv[6])) [originals addEntriesFromDictionary:JPTCollectTracks(body)];
        NSMutableArray *changes = [NSMutableArray array];
        NSData *out = JPTRewriteResponse(body, JPTReadList(argv[3]), originals, changes);
        if (!out) {
            fprintf(stderr, "rewrite failed\n");
            return 1;
        }
        [out writeToFile:@(argv[4]) atomically:YES];
        printf("rewrote %lu -> %lu bytes, originals %lu, changes:\n", (unsigned long)body.length, (unsigned long)out.length,
               (unsigned long)originals.count);
        for (NSString *change in changes) printf("  %s\n", change.UTF8String);
    }
    return 0;
}
