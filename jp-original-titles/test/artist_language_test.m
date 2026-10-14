// Verify same-URI artist names against live catalog samples and safe fallbacks.
#define JPT_TEST 1
#include "../JPOriginalTitles.m"
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n",label.UTF8String);
}
static NSData *Payload(NSData *response, uint64_t kind, NSString *uri) {
    JPTReader r=JPTReaderMake(response.bytes,response.length); JPTField f; BOOL ok;
    while(JPTNext(&r,&f,&ok)) {
        if(f.field!=2 || f.wire!=2 || JPTArrayKind(&f)!=kind)continue;
        JPTReader ar=JPTReaderMake(f.data,f.len);JPTField af;BOOL aok;
        while(JPTNext(&ar,&af,&aok)) {
            if(af.field!=3 || af.wire!=2)continue;
            NSString *entryURI=nil;uint64_t status;JPTField value;
            if(JPTParseEntry(&af,&entryURI,&status,&value) && [entryURI isEqualToString:uri])
                return [NSData dataWithBytes:value.data length:value.len];
        }
    }
    return nil;
}
static NSData *WithoutName(NSData *payload) {
    NSMutableData *out=[NSMutableData data];
    JPTReader r=JPTReaderMake(payload.bytes,payload.length);JPTField f;BOOL ok;
    while(JPTNext(&r,&f,&ok))if(f.field!=2)JPTWriteRaw(out,&f);
    return out;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=4)return 2;
        NSData *zh=[NSData dataWithContentsOfFile:@(argv[1])],*ja=[NSData dataWithContentsOfFile:@(argv[2])];
        NSData *guest=[NSData dataWithContentsOfFile:@(argv[3])];
        NSDictionary *zhNames=JPTCollectArtistNames(zh),*jaNames=JPTCollectArtistNames(ja);
        NSString *yuka=@"spotify:artist:4eEVWfAuVUPgwMXWQiD4zX";
        Check([zhNames[yuka] isEqualToString:@"Yuka Nagase"],@"Chinese lookup can retain romanized artist name");
        Check([jaNames[yuka] isEqualToString:@"長瀬 有花"],@"same artist URI has a Japanese catalog name");
        Check(JPTJapaneseNameCandidate(jaNames[yuka]),@"accept Japanese kanji name");
        Check(!JPTJapaneseNameCandidate(jaNames[@"spotify:artist:0gxyHStUsqpMadRV0Di1Qt"]),@"reject Japanese Rick Astley transcription");
        Check(!JPTJapaneseNameCandidate(jaNames[@"spotify:artist:4dpARuHxo51G3z768sgnrY"]),@"reject Japanese Adele transcription");
        Check(!JPTJapaneseNameCandidate(@"ナナヲアカリ"),@"pure katakana fallback remains conservative");
        Check(!JPTJapaneseNameCandidate(@"방탄소년단"),@"do not silently add a Korean fallback");
        Check(!JPTJapaneseNameCandidate(nil),@"missing name stays unchanged");
        NSMutableDictionary *names=[@{yuka:jaNames[yuka]} mutableCopy];
        NSData *out=JPTRewriteResponse(guest,[NSSet set],@{},names,[NSMutableArray array]);
        NSData *before=Payload(guest,178,yuka),*after=Payload(out,178,yuka);NSString *name=nil;
        JPTReplaceString(after.bytes,after.length,2,@"test",&name);
        Check([name isEqualToString:jaNames[yuka]],@"rewrite the actual guest artist IdentityTrait");
        Check([WithoutName(before) isEqualToData:WithoutName(after)],@"retain all other IdentityTrait fields");
        Check([Payload(guest,185,yuka) isEqualToData:Payload(out,185,yuka)],@"retain verification trait");
        Check([Payload(guest,255,yuka) isEqualToData:Payload(out,255,yuka)],@"retain Spotify-for-Artists profile facts");
        Check([JPTRewriteResponse(guest,[NSSet set],@{},[NSMutableDictionary dictionary],[NSMutableArray array]) isEqualToData:guest],@"failed name discovery keeps artist response bytes");
        NSDictionary *tracks=JPTCollectTracks(zh);
        JPTTrackInfo *track=tracks[@"spotify:track:4Yvp4fsC4fYCFVzHfg2RrN"];
        NSArray *saved=[track.artists copy];JPTTrackInfo *renamed=JPTNamedArtists(track,names);
        Check([track.name isEqualToString:@"hikari"] && [renamed.name isEqualToString:@"hikari"],@"artist fallback does not invent a Japanese song title");
        Check([track.artists isEqualToArray:saved],@"artist rewrite does not mutate shared original cache");
        Check([renamed.artists[0][1] isEqualToString:track.artists[0][1]],@"retain artist navigation URI");
        Check([renamed.artists[0][0] isEqualToString:jaNames[yuka]],@"apply artist name to track contributors");
        const uint8_t bad[]={0x12,0xff};
        Check(!JPTCollectArtistNames([NSData dataWithBytes:bad length:sizeof(bad)]),@"reject malformed artist response");
        NSMutableData *request=[NSMutableData data],*entity=[NSMutableData data],*query=[NSMutableData data];
        JPTWriteString(entity,1,yuka);JPTWriteVarint(query,8);JPTWriteVarint(query,178);JPTWriteString(query,2,@"old etag");
        JPTWriteData(entity,2,query);JPTWriteData(request,2,entity);
        NSMutableSet *added=[NSMutableSet set],*artists=[NSMutableSet set];
        NSData *augmented=JPTAugmentRequest(request,added,[NSMutableSet set],artists,nil);
        Check(augmented && ![augmented isEqualToData:request] && [artists containsObject:yuka],@"remove artist IdentityTrait etag");
        Check(!added.count,@"artist requests do not leak added helper kinds");
        printf("%lu checks passed\n",(unsigned long)checks);
    }
    return 0;
}
