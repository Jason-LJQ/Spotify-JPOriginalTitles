#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
@interface CreditsDelegate : NSObject <NSURLSessionDataDelegate>
@end
@implementation CreditsDelegate
@end
static NSData *Gzip(NSData *body) {
    z_stream stream={0};deflateInit2(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY);
    NSMutableData *out=[NSMutableData dataWithLength:body.length+128];
    stream.next_in=(Bytef *)body.bytes;stream.avail_in=(uInt)body.length;stream.next_out=out.mutableBytes;stream.avail_out=(uInt)out.length;
    int result=deflate(&stream,Z_FINISH);out.length=stream.total_out;deflateEnd(&stream);return result==Z_STREAM_END?out:nil;
}
static int checks;
static void Check(BOOL value, const char *name) { if (!value) { fprintf(stderr,"FAIL %s\n",name);exit(1); } checks++;printf("PASS %s\n",name); }
static NSData *Request(BOOL etag, BOOL other) {
    NSMutableData *out=[NSMutableData data],*entity=[NSMutableData data],*query=[NSMutableData data];
    JPTWriteString(out,1,@"header");JPTWriteString(entity,1,@"spotify:track:0000000000000000000001");
    JPTWriteVarint(query,8);JPTWriteVarint(query,186);if(etag)JPTWriteString(query,2,@"old-credit-etag");JPTWriteString(query,9,@"unknown");JPTWriteData(entity,2,query);
    if(other){query=[NSMutableData data];JPTWriteVarint(query,8);JPTWriteVarint(query,179);JPTWriteString(query,2,@"preserve-other-etag");JPTWriteData(entity,2,query);}
    JPTWriteData(out,2,entity);return out;
}
int main(void) { @autoreleasepool {
    NSData *body=Request(YES,YES),*fresh=JPTCreditsFreshBody(body);
    Check(JPTRequestHasCredits(body),"credits query recognized");
    Check(fresh.length && ![fresh isEqualToData:body],"credits etag refresh changes request");
    Check(!JPTCreditsFreshBody(Request(NO,NO)),"request without etag remains unchanged");
    NSData *other=[@"preserve-other-etag" dataUsingEncoding:NSUTF8StringEncoding];
    Check([fresh rangeOfData:other options:0 range:NSMakeRange(0,fresh.length)].location!=NSNotFound,"unrelated validators retained");
    CreditsDelegate *delegate=[CreditsDelegate new];gDelegateClasses=[NSMutableArray arrayWithObject:CreditsDelegate.class];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:delegate delegateQueue:nil];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:9/extended-metadata/v0/extended-metadata"]];
    request.HTTPMethod=@"POST";request.HTTPBody=body;[request setValue:[NSString stringWithFormat:@"%lu",(unsigned long)body.length] forHTTPHeaderField:@"Content-Length"];
    JPTTaskState *state=nil;NSURLRequest *prepared=JPTPrepareRequest(session,request,&state);
    Check(state.credits && !state.traitTracks.count && !state.artistURIs.count,"credits-only request receives a buffered task state");
    Check([prepared.HTTPBody isEqualToData:fresh],"prepared body contains only the intended validator change");
    Check((NSUInteger)[[prepared valueForHTTPHeaderField:@"Content-Length"] integerValue]==prepared.HTTPBody.length,"content length matches refreshed body");
    [request setValue:@"gzip" forHTTPHeaderField:@"Content-Encoding"];request.HTTPBody=Gzip(body);
    prepared=JPTPrepareRequest(session,request,&state);
    Check(state.credits && [prepared.HTTPBody isEqualToData:fresh],"gzip credits request refreshes to plain body");
    Check(![prepared valueForHTTPHeaderField:@"Content-Encoding"],"gzip header removed after body refresh");
    [session invalidateAndCancel];printf("TOTAL %d\n",checks);
} }
