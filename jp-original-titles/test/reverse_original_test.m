// Verify reverse and sibling candidates against live catalog fixtures and adverse variants.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n",label.UTF8String);
}
static NSData *Response(NSString *uri, uint64_t status, NSData *value) {
    NSMutableData *e=[NSMutableData data],*h=[NSMutableData data],*a=[NSMutableData data],*out=[NSMutableData data];
    JPTWriteVarint(h,8);JPTWriteVarint(h,status);JPTWriteData(e,1,h);JPTWriteString(e,2,uri);
    if(value){NSMutableData *any=[NSMutableData data];JPTWriteData(any,2,value);JPTWriteData(e,3,any);}
    JPTWriteVarint(a,16);JPTWriteVarint(a,10);JPTWriteData(a,3,e);JPTWriteData(out,2,a);return out;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc!=3)return 2;
    NSMutableDictionary *all=[JPTCollectMetadata([NSData dataWithContentsOfFile:@(argv[1])]) mutableCopy];
    NSDictionary *names=JPTCollectArtistNames([NSData dataWithContentsOfFile:@(argv[2])]);
    NSString *uri=@"spotify:track:6W3beEMj18hHp1wDlqGcbt";
    JPTTrackInfo *own=all[uri];
    Check([own.name isEqualToString:@"Cubism"],@"load real self-canonical international track");
    JPTAlbumInfo *source=all[own.albumURI];
    Check([source.canonicalURI isEqualToString:own.albumURI],@"source album association points to itself");
    gReverseOriginals=[NSMutableDictionary dictionary];
    JPTTrackInfo *match=JPTIndirectOriginal(uri,own,all);
    Check([match.name isEqualToString:@"きゅびずむ"],@"cold sibling canonical discovers the original recording");
    Check([match.canonicalURI isEqualToString:uri],@"original canonical points back to the requested recording");
    Check([JPTResolutionArtists(all,[NSSet setWithObject:uri]) containsObject:@"spotify:artist:7uugnrrGcHNunhme3bP1y3"],@"include the selected original artist in language lookup");
    Check([names[@"spotify:artist:7uugnrrGcHNunhme3bP1y3"] isEqualToString:@"原口沙輔"],@"Japanese original artist lookup supplies kanji");
    NSArray *before=[own.artists copy];
    JPTTrackInfo *preferred=JPTPreferredInfoWithArtists(uri,all,all,names);
    Check([preferred.artists[2][0] isEqualToString:@"原口沙輔"],@"resolve original artist names before positional adoption");
    Check([preferred.artists[2][1] isEqualToString:own.artists[2][1]],@"keep the international artist link");
    Check([preferred.artists[0][0] isEqualToString:@"超てんちゃん"],@"retain existing original CJK artist name");
    Check([own.artists isEqualToArray:before],@"do not mutate shared artist lists");
    NSMutableDictionary *learned=[NSMutableDictionary dictionary];JPTLearnArtists(own,preferred,learned);
    Check([learned[@"spotify:artist:290RfJGAmzANeDRd0ArLOj"] isEqualToString:@"原口沙輔"],@"learn original name on international artist URI");
    JPTIndexOriginals(all);
    NSMutableDictionary *reverseOnly=[all mutableCopy];[reverseOnly removeObjectForKey:own.albumURI];
    Check([JPTIndirectOriginal(uri,own,reverseOnly).name isEqualToString:@"きゅびずむ"],@"reverse index works without source album siblings");
    uint64_t duration=match.duration;match.duration++;
    Check(!JPTIndirectOriginal(uri,own,all),@"reject duration mismatch");match.duration=duration;
    uint64_t disc=match.disc;match.disc++;
    Check(!JPTIndirectOriginal(uri,own,all),@"reject disc mismatch");match.disc=disc;
    uint64_t number=match.number;match.number++;
    Check(!JPTIndirectOriginal(uri,own,all),@"reject track position mismatch");match.number=number;
    NSString *canonical=match.canonicalURI;match.canonicalURI=@"spotify:track:other";
    Check(!JPTIndirectOriginal(uri,own,all),@"reject missing canonical backlink");match.canonicalURI=canonical;
    JPTAlbumInfo *album=all[match.albumURI];NSSet *saved=album.trackURIs;NSMutableSet *duplicate=[saved mutableCopy];
    [duplicate addObject:@"spotify:track:duplicate"];album.trackURIs=duplicate;all[@"spotify:track:duplicate"]=match;
    Check(!JPTIndirectOriginal(uri,own,all),@"reject duplicate ISRC in candidate album");
    [all removeObjectForKey:@"spotify:track:duplicate"];album.trackURIs=saved;
    NSMutableDictionary *incomplete=[all mutableCopy];NSString *missing=nil;
    for(NSString *u in saved)if(incomplete[u]!=match){missing=u;break;}
    Check(missing!=nil,@"candidate album includes another recording");[incomplete removeObjectForKey:missing];
    Check(!JPTIndirectOriginal(uri,own,incomplete),@"reject incomplete original album");
    NSString *empty=@"spotify:track:777NZe9GYOhFtJhIkPuYHj";
    NSData *emptyResponse=Response(empty,200,[NSData data]);
    NSMutableDictionary *values=[JPTCollectMetadata(emptyResponse) mutableCopy];
    Check(values[empty]!=nil && ![values[empty] name].length,@"parse completed empty-name track");
    Check(!JPTValidateLookup(emptyResponse,[NSSet setWithObject:empty],values,NO),@"empty-name lookup is complete rather than failure");
    NSData *bad=Response(@"spotify:track:bad",500,nil);NSMutableData *mixed=[emptyResponse mutableCopy];[mixed appendData:bad];
    values=[JPTCollectMetadata(mixed) mutableCopy];
    Check(JPTValidateLookup(mixed,[NSSet setWithArray:@[empty,@"spotify:track:bad"]],values,NO)!=nil,@"report failed entry within a mixed response");
    Check(values.count==1 && values[empty]!=nil,@"keep valid partial data and exclude the failed entry");
    printf("%lu checks passed\n",(unsigned long)checks);
}return 0;}
