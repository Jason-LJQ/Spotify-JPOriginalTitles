// Language gating and the per-request source-album budget are independent of matching safety.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n",label.UTF8String);
}
int main(void) { @autoreleasepool {
    JPTTrackInfo *track=[JPTTrackInfo new];
    for (NSArray *row in @[@[@"ja",@YES],@[@"und",@YES],@[@"en",@NO],@[@"zxx",@NO],@[@"ko",@NO]]) {
        track.performanceLanguages=@[row[0]];
        Check(JPTAllowsSiblingLookup(track)==[row[1] boolValue],[NSString stringWithFormat:@"sibling language gate %@",row[0]]);
    }
    track.performanceLanguages=nil;Check(JPTAllowsSiblingLookup(track),@"missing language conservatively allows sibling discovery");
    NSMutableData *payload=[NSMutableData data];JPTWriteString(payload,2,@"Latin title");
    JPTWriteString(payload,22,@"en");JPTWriteString(payload,22,@"ja");
    track=JPTParseTrack(payload.bytes,payload.length);
    Check([track.performanceLanguages isEqualToArray:@[@"en",@"ja"]] && JPTAllowsSiblingLookup(track),@"parse all field-22 language values and allow a Japanese contribution");
    Check([JPTNamedArtists(track,@{}).performanceLanguages isEqualToArray:track.performanceLanguages],@"artist overlay preserves observed language codes");
    NSMutableDictionary *all=[NSMutableDictionary dictionary];NSMutableSet *uris=[NSMutableSet set];
    for(NSUInteger i=0;i<kJPTSiblingAlbumLimit+5;i++) {
        NSString *uri=[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)i];
        NSString *albumURI=[NSString stringWithFormat:@"spotify:album:%022lu",(unsigned long)i];
        JPTTrackInfo *own=[JPTTrackInfo new];own.name=@"Latin";own.isrc=@"recording";own.albumURI=albumURI;own.canonicalURI=uri;own.performanceLanguages=@[@"ja"];
        JPTAlbumInfo *album=[JPTAlbumInfo new];album.name=@"Latin album";album.canonicalURI=albumURI;album.trackURIs=[NSSet setWithObject:uri];
        all[uri]=own;all[albumURI]=album;[uris addObject:uri];
    }
    NSSet *selected=JPTSiblingSourceAlbums(all,uris);
    Check(selected.count==kJPTSiblingAlbumLimit,@"bound the number of sibling source albums per request");
    NSArray *ordered=[selected.allObjects sortedArrayUsingSelector:@selector(compare:)];
    Check([ordered.firstObject isEqualToString:@"spotify:album:0000000000000000000000"] &&
          [ordered.lastObject isEqualToString:[NSString stringWithFormat:@"spotify:album:%022lu",(unsigned long)kJPTSiblingAlbumLimit-1]],@"choose source albums deterministically");
    NSString *first=@"spotify:track:0000000000000000000000";
    [all[first] setPerformanceLanguages:@[@"en"]];
    Check(![JPTSiblingSourceAlbums(all,uris) containsObject:@"spotify:album:0000000000000000000000"],@"explicit English language does not spend the sibling budget");
    [all[first] setPerformanceLanguages:nil];
    Check([JPTSiblingSourceAlbums(all,uris) containsObject:@"spotify:album:0000000000000000000000"],@"a missing language can still spend the sibling budget");
    NSString *log=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];setenv("JPT_TEST_LOG_PATH",log.UTF8String,1);atomic_store(&gJPTLogging,true);
    JPTSiblingSourceAlbums(all,uris);dispatch_sync(JPTLogQueue(),^{});
    NSString *text=[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
    Check([text containsString:@"sibling album limit"] && ![text containsString:@"WARNING"],@"exceeding the source-album budget is an ordinary diagnostic event");
    atomic_store(&gJPTLogging,false);[[NSFileManager defaultManager] removeItemAtPath:log error:nil];
    printf("%lu checks passed\n",(unsigned long)checks);
}return 0;}
