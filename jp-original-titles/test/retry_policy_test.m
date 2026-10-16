// Exercise real asynchronous batching and delegate delivery against a local fixture server.
#define JPT_MANAGEMENT_TEST 1
#define JPT_LOOKUP_TEST_TIMEOUT 0.15
#define JPT_LOOKUP_TEST_PROTOCOL 1
#include "../JPOriginalTitles.m"
static NSUInteger transportAttempts;
@interface JPTTestTransportProtocol : NSURLProtocol
@end
@implementation JPTTestTransportProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"jpt.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    transportAttempts++;
    NSInteger code = [self.request.URL.path isEqualToString:@"/offline"] ? NSURLErrorNotConnectedToInternet : NSURLErrorCancelled;
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil]];
}
- (void)stopLoading {}
@end
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n",label.UTF8String);
}
static void Await(void (^start)(void (^)(NSError *)), BOOL success, NSString *label) {
    dispatch_semaphore_t ready=dispatch_semaphore_create(0); __block NSError *failure=nil;
    start(^(NSError *error){failure=error;dispatch_semaphore_signal(ready);});
    Check(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC))==0,@"asynchronous lookup completes");
    Check((failure==nil)==success,label);
}
static NSMutableData *received;
static NSError *deliveryError;
static dispatch_semaphore_t delivered;
@interface JPTBatchDelegate : NSObject <NSURLSessionDataDelegate>
@end
@implementation JPTBatchDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data { [received appendData:data]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    deliveryError=error;dispatch_semaphore_signal(delivered);
}
@end
static void ClientRequest(NSString *url, NSString *uri) {
    NSMutableData *body=[NSMutableData data],*entity=[NSMutableData data],*query=[NSMutableData data];
    JPTWriteVarint(query,8);JPTWriteVarint(query,[url containsString:@"original-empty-artist"] ? 8 : [url containsString:@"original-empty-album"] ? 9 : 178);JPTWriteString(entity,1,uri);JPTWriteData(entity,2,query);JPTWriteData(body,2,entity);
    if ([url containsString:@"mixed-bad"]) {
        [entity setLength:0];[query setLength:0];JPTWriteVarint(query,8);JPTWriteVarint(query,10);
        JPTWriteString(entity,1,@"spotify:track:8888888888888888888888");JPTWriteData(entity,2,query);JPTWriteData(body,2,entity);
    }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.URL=[NSURL URLWithString:[url stringByAppendingString:@"/extended-metadata/v0/extended-metadata"]];
    request.HTTPMethod=@"POST";request.HTTPBody=body;[request setValue:@"en-US" forHTTPHeaderField:@"Accept-Language"];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        delegate:[JPTBatchDelegate new] delegateQueue:[NSOperationQueue new]];
    JPTTaskState *state=nil;NSURLRequest *prepared=JPTPrepareRequest(session,request,&state);
    Check(state!=nil,@"client request enters the production hook");
    received=[NSMutableData data];deliveryError=nil;delivered=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[session dataTaskWithRequest:prepared];objc_setAssociatedObject(task,&kJPTStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[task resume];
    Check(dispatch_semaphore_wait(delivered,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC))==0,@"client delegate completes");
    [session finishTasksAndInvalidate];
}
static NSData *Payload(NSData *body, uint64_t kind, NSString *wanted) {
    JPTReader r=JPTReaderMake(body.bytes,body.length);JPTField f;BOOL ok;
    while(JPTNext(&r,&f,&ok))if(f.field==2 && JPTArrayKind(&f)==kind){
        JPTReader ar=JPTReaderMake(f.data,f.len);JPTField af;BOOL aok;
        while(JPTNext(&ar,&af,&aok))if(af.field==3){NSString *uri=nil;uint64_t status;JPTField value;
            if(JPTParseEntry(&af,&uri,&status,&value) && [uri isEqualToString:wanted])return [NSData dataWithBytes:value.data length:value.len];}
    }return nil;
}
static NSData *Response(uint64_t kind, NSString *uri, NSData *payload) {
    NSMutableData *entry=[NSMutableData data],*header=[NSMutableData data],*any=[NSMutableData data],*array=[NSMutableData data],*response=[NSMutableData data];
    JPTWriteVarint(header,8);JPTWriteVarint(header,200);JPTWriteData(entry,1,header);JPTWriteString(entry,2,uri);
    JPTWriteData(any,2,payload);JPTWriteData(entry,3,any);JPTWriteVarint(array,16);JPTWriteVarint(array,kind);JPTWriteData(array,3,entry);JPTWriteData(response,2,array);return response;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc!=4)return 2;
    NSString *base=@(argv[1]); NSData *body=[NSData dataWithContentsOfFile:@(argv[3])];
    NSMutableSet *uris=[NSMutableSet set];
    for(NSUInteger i=0;i<256;i++)[uris addObject:[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)i]];
    gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:base]];request.HTTPMethod=@"POST";
    for(NSString *mode in @[@"first-500",@"over-64",@"poison",@"http-failure",@"missing-once",@"entry-once",@"entry-parse-once",@"duplicate-once",@"malformed",@"timeout",@"429",@"401",@"403"]) {
        request.URL=[NSURL URLWithString:[base stringByAppendingFormat:@"/%@",mode]];
        gOriginalCache=[NSMutableDictionary dictionary];
        BOOL good=[@[@"first-500",@"over-64",@"missing-once",@"entry-once",@"entry-parse-once",@"duplicate-once"] containsObject:mode];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,uris,done);},good,[mode stringByAppendingString:@" resolution"]);
        NSUInteger count=good?256:[mode isEqualToString:@"poison"]?240:0;
        Check(gOriginalCache.count==count,[mode stringByAppendingString:@" retains exactly validated entities"]);
    }
    request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/mixed-split"]];gOriginalCache=[NSMutableDictionary dictionary];
    Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,uris,done);},NO,@"mixed whole-request and entry failures report final unresolved items");
    Check(gOriginalCache.count==237,@"entry failures in other 64-entity children do not prevent recovering the failed child at 16");
    for(NSNumber *kind in @[@8,@9,@10]) for(NSNumber *explicitName in @[@NO,@YES]) {
        NSString *uri=[NSString stringWithFormat:@"spotify:%@:9999999999999999999999",kind.intValue==8?@"artist":kind.intValue==9?@"album":@"track"];
        NSMutableData *empty=[NSMutableData data];if(explicitName.boolValue)JPTWriteString(empty,2,@"");
        NSData *response=Response(kind.unsignedLongLongValue,uri,empty);
        NSMutableDictionary *values=[(kind.intValue==8?(NSDictionary *)JPTCollectArtistNames(response):(NSDictionary *)JPTCollectMetadata(response)) mutableCopy];
        Check(values[uri]!=nil,@"structurally valid absent or empty name remains a completed value");
        Check(JPTClientMetadataIsValid(response),@"client preflight accepts empty track, album and artist names");
        Check(!JPTValidateLookup(response,[NSSet setWithObject:uri],values,kind.intValue==8),@"lookup validator accepts completed empty names without retry");
    }
    for(NSNumber *strict in @[@NO,@YES]) for(NSString *mode in @[@"empty-name",@"absent-name"]) for(NSString *type in @[@"album",@"artist"]) {
        atomic_store(&gJPTStrict,strict.boolValue);
        request.URL=[NSURL URLWithString:[base stringByAppendingFormat:@"/%@-%@-%@",mode,type,strict]];
        NSString *uri=[NSString stringWithFormat:@"spotify:%@:9999999999999999999999",type];
        Await(^(void (^done)(NSError *)){JPTFetchQueryBatch(request,body,[NSSet setWithObject:uri],@"zh-Hans",[type isEqualToString:@"artist"],^(NSDictionary *values,NSError *error){done(error);});},YES,@"empty album/artist lookup completes in either strict mode");
    }
    request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/empty-artist-resolve"]];gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
    Await(^(void (^done)(NSError *)){JPTFetchArtistOriginals(request,body,[NSSet setWithObject:@"spotify:artist:9999999999999999999999"],done);},YES,@"empty Chinese artist name completes without an unnecessary Japanese request");
    Check(!gArtistNames.count,@"completed empty artist name never becomes a replacement name");
    atomic_store(&gJPTStrict,false);
    gDelegateClasses=[NSMutableArray array];JPTHookDelegate(@"JPTBatchDelegate");
    NSString *target=@"spotify:track:9999999999999999999999";
    for(NSNumber *strict in @[@NO,@YES]) {
        atomic_store(&gJPTStrict,strict.boolValue);
        for(NSString *mode in @[@"429",@"401",@"403",@"failure",@"malformed",@"good",@"empty",@"absence-204",@"absence-404",@"absence-410",@"album-404",@"original-503",@"original-empty",@"nested-malformed"]) {
            gOriginalCache=[NSMutableDictionary dictionary];
            NSString *path=[base stringByAppendingFormat:@"/client-%@",mode];
            ClientRequest(path,[mode isEqualToString:@"album-404"] ? @"spotify:track:1wXrIFdqheifq4ETjCpqoi" : target);
            BOOL fails=[@[@"429",@"401",@"403",@"failure",@"malformed",@"nested-malformed"] containsObject:mode];
            if(strict.boolValue && fails) Check([deliveryError.domain isEqualToString:@"JPOriginalTitles.Lookup"] && !received.length,[mode stringByAppendingString:@" strict delivery is zero bytes plus lookup error"]);
            else if ([mode isEqualToString:@"original-empty"]) Check(!deliveryError && !received.length,@"Spotify empty original body bypasses strict mode");
            else Check(!deliveryError && received.length,[mode stringByAppendingString:@" client delivery stays usable"]);
        }
    }
    for(NSNumber *strict in @[@NO,@YES]) {
        atomic_store(&gJPTStrict,strict.boolValue);gOriginalCache=[NSMutableDictionary dictionary];gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
        NSString *track=@"spotify:track:1wXrIFdqheifq4ETjCpqoi", *bad=@"spotify:track:8888888888888888888888";
        ClientRequest([base stringByAppendingString:@"/client-mixed-bad"],track);
        if(strict.boolValue) Check(deliveryError.code==JPTLookupParseFailure && !received.length,@"strict mixed response blocks before enrichment");
        else {
            NSData *identity=Payload(received,178,track);NSString *title=nil;JPTReplaceString(identity.bytes,identity.length,2,@"test",&title);
            Check(!deliveryError && [title isEqualToString:@"救世主"],@"default mixed response still delivers the verified Japanese title");
            const uint8_t invalid[]={0xff};Check([Payload(received,10,bad) isEqualToData:[NSData dataWithBytes:invalid length:1]],@"default mixed response retains the client's bad entry byte-for-byte");
            Check(!Payload(received,10,track),@"default mixed response removes the plugin-added helper");
        }
        for(NSString *type in @[@"album",@"artist"]) {
            gOriginalCache=[NSMutableDictionary dictionary];gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
            NSString *uri=[NSString stringWithFormat:@"spotify:%@:9999999999999999999999",type];
            ClientRequest([base stringByAppendingFormat:@"/client-original-empty-%@",type],uri);
            Check(!deliveryError && received.length,@"empty client-requested album or artist completes normally in either mode");
        }
    }
    atomic_store(&gJPTStrict,true);
    request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/strict-exhausted"]];
    NSMutableSet *large=[uris mutableCopy];[large addObject:target];
    gOriginalCache=[NSMutableDictionary dictionary];
    Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,large,done);},NO,@"strict systemic failure stops later root batches");
    atomic_store(&gJPTStrict,false);
    for(NSString *mode in @[@"offline",@"cancelled"]) {
        request.URL=[NSURL URLWithString:[@"http://jpt.invalid/" stringByAppendingString:mode]];
        transportAttempts=0;gOriginalCache=[NSMutableDictionary dictionary];
        NSMutableSet *large=[uris mutableCopy];[large addObject:target];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,large,done);},NO,[mode stringByAppendingString:@" is a terminal transport failure"]);
        Check(transportAttempts==1 && !gOriginalCache.count,@"terminal transport sends one request and stops later sequential batches");
    }
    printf("%lu checks passed\n",(unsigned long)checks);
}return 0;}
