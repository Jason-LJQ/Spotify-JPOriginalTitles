// Language gating preserves matching safety without limiting source albums.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n",label.UTF8String);
}
int main(void) { @autoreleasepool {
    JPTTrackInfo *track=[JPTTrackInfo new];
    for (NSArray *row in @[@[@"ja",@YES],@[@"und",@YES],@[@"en",@NO],@[@"zxx",@YES],@[@"ko",@NO]]) {
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
    for(NSUInteger i=0;i<40;i++) {
        NSString *uri=[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)i];
        NSString *albumURI=[NSString stringWithFormat:@"spotify:album:%022lu",(unsigned long)i];
        JPTTrackInfo *own=[JPTTrackInfo new];own.name=@"Latin";own.isrc=@"recording";own.albumURI=albumURI;own.canonicalURI=uri;own.performanceLanguages=@[@"ja"];
        JPTAlbumInfo *album=[JPTAlbumInfo new];album.name=@"Latin album";album.canonicalURI=albumURI;album.trackURIs=[NSSet setWithObject:uri];
        all[uri]=own;all[albumURI]=album;[uris addObject:uri];
    }
    NSSet *selected=JPTSiblingSourceAlbums(all,uris);
    Check(selected.count==40,@"all forty eligible source albums are selected");
    NSString *first=@"spotify:track:0000000000000000000000";
    [all[first] setPerformanceLanguages:@[@"en"]];
    Check(![JPTSiblingSourceAlbums(all,uris) containsObject:@"spotify:album:0000000000000000000000"],@"explicit English language does not enter sibling discovery");
    [all[first] setPerformanceLanguages:nil];
    Check([JPTSiblingSourceAlbums(all,uris) containsObject:@"spotify:album:0000000000000000000000"],@"a missing language still enters sibling discovery");
    printf("%lu checks passed\n",(unsigned long)checks);
}return 0;}
