// Exercise the real request hook without launching Spotify or sending requests.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"

@interface JPTFixtureDelegate : NSObject <NSURLSessionDataDelegate>
@end
@implementation JPTFixtureDelegate
@end

static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1); }
    checks++;printf("PASS %s\n",label.UTF8String);
}

static NSData *Gzip(NSData *input) {
    z_stream stream={0};
    if (deflateInit2(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY)!=Z_OK) return nil;
    NSMutableData *output=[NSMutableData dataWithLength:input.length+128];
    stream.next_in=(Bytef*)input.bytes;stream.avail_in=(uInt)input.length;
    stream.next_out=output.mutableBytes;stream.avail_out=(uInt)output.length;
    int status=deflate(&stream,Z_FINISH);output.length=stream.total_out;deflateEnd(&stream);
    return status==Z_STREAM_END ? output : nil;
}

int main(void) {
    @autoreleasepool {
        gDelegateClasses=[NSMutableArray arrayWithObject:JPTFixtureDelegate.class];
        gArtistNames=[NSMutableDictionary dictionary];gOriginalCache=[NSMutableDictionary dictionary];
        NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
            delegate:[JPTFixtureDelegate new] delegateQueue:nil];
        NSMutableData *query=[NSMutableData data],*entity=[NSMutableData data],*body=[NSMutableData data];
        JPTWriteVarint(query,8);JPTWriteVarint(query,kKindIdentityTrait);JPTWriteString(query,2,@"old-etag");
        JPTWriteString(entity,1,@"spotify:track:57UeOQ9Ae6o6PdWU4nxzK3");JPTWriteData(entity,2,query);JPTWriteData(body,2,entity);
        for (id encoding in @[NSNull.null,@"",@"gzip",@"GZIP"]) {
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/extended-metadata/v0/extended-metadata"]];
            request.HTTPMethod=@"POST";
            BOOL compressed=[encoding isKindOfClass:NSString.class] && [encoding length]>0;
            request.HTTPBody=compressed ? Gzip(body) : body;
            if (encoding!=NSNull.null) [request setValue:encoding forHTTPHeaderField:@"Content-Encoding"];
            JPTTaskState *state=nil;NSURLRequest *prepared=JPTPrepareRequest(session,request,&state);
            NSString *label=encoding==NSNull.null ? @"absent" : ([encoding length] ? encoding : @"empty");
            Check(state && state.traitTracks.count==1 && state.added.count==1,[NSString stringWithFormat:@"%@ encoding enters metadata interception",label]);
            Check([prepared.HTTPBody isEqual:state.body] && ![prepared.HTTPBody isEqual:body],[NSString stringWithFormat:@"%@ encoding adds TRACK_V4 and strips the old etag",label]);
            Check(![prepared valueForHTTPHeaderField:@"Content-Encoding"].length,[NSString stringWithFormat:@"%@ encoding delivers an uncompressed request",label]);
            Check([request.HTTPBody isEqual:compressed ? Gzip(body) : body],[NSString stringWithFormat:@"%@ encoding leaves the original request intact",label]);
        }
        for (NSString *encoding in @[@"br",@"gzip"]) {
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/extended-metadata/v0/extended-metadata"]];
            request.HTTPMethod=@"POST";request.HTTPBody=body;[request setValue:encoding forHTTPHeaderField:@"Content-Encoding"];
            JPTTaskState *state=nil;
            Check(JPTPrepareRequest(session,request,&state)==request && !state,[NSString stringWithFormat:@"unsupported or malformed %@ body passes through",encoding]);
        }
        [session invalidateAndCancel];printf("%lu checks passed\n",(unsigned long)checks);
    }
}
