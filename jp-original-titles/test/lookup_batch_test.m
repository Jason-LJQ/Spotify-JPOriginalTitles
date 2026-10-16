// Exercise real asynchronous batching and delegate delivery against a local fixture server.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
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
    JPTWriteVarint(query,8);JPTWriteVarint(query,178);JPTWriteString(entity,1,uri);JPTWriteData(entity,2,query);JPTWriteData(body,2,entity);
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.URL=[NSURL URLWithString:[url stringByAppendingString:@"/extended-metadata/v0/extended-metadata"]];
    request.HTTPMethod=@"POST";request.HTTPBody=body;[request setValue:@"zh-Hans-US" forHTTPHeaderField:@"Accept-Language"];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        delegate:[JPTBatchDelegate new] delegateQueue:[NSOperationQueue new]];
    JPTTaskState *state=nil;NSURLRequest *prepared=JPTPrepareRequest(session,request,&state);
    Check(state!=nil,@"client request enters the production hook");
    received=[NSMutableData data];deliveryError=nil;delivered=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[session dataTaskWithRequest:prepared];objc_setAssociatedObject(task,&kJPTStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[task resume];
    Check(dispatch_semaphore_wait(delivered,dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC))==0,@"client delegate completes");
    [session finishTasksAndInvalidate];
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=4)return 2;
        NSString *base=@(argv[1]);NSData *raw=[NSData dataWithContentsOfFile:@(argv[2])],*body=[NSData dataWithContentsOfFile:@(argv[3])];
        NSDictionary *tracks=JPTCollectMetadata(raw);NSString *target=@"spotify:track:1wXrIFdqheifq4ETjCpqoi";
        Check(tracks.count==300,@"load the real 300-track cold batch");
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/good"]]];request.HTTPMethod=@"POST";
        gOriginalCache=[tracks mutableCopy];gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
        Await(^(void (^done)(NSError *)){JPTFetchAlbumOriginals(request,body,[NSSet setWithArray:tracks.allKeys],done);},YES,@"a real large album set resolves instead of being skipped");
        NSData *rewritten=JPTRewriteResponse(raw,[NSSet set],JPTOriginalSnapshot(),[NSMutableDictionary dictionary],[NSMutableArray array]);
        Check([[JPTCollectTracks(rewritten)[target] name] isEqualToString:@"救世主"],@"cold large batch delivers the original name without prewarming");
        gOriginalCache=[NSMutableDictionary dictionary];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,[NSSet setWithArray:tracks.allKeys],done);},YES,@"more than 256 tracks are fetched in complete batches");
        Check(gOriginalCache.count==300,@"all 300 requested tracks reach the plugin cache");
        for(NSUInteger i=0;i<5000;i++)gArtistNames[[NSString stringWithFormat:@"spotify:artist:retained-%lu",(unsigned long)i]]=@"既存";
        NSMutableSet *artists=[NSMutableSet set];for(NSUInteger i=0;i<130;i++)[artists addObject:[NSString stringWithFormat:@"spotify:artist:%022lu",(unsigned long)i]];
        Await(^(void (^done)(NSError *)){JPTFetchArtistOriginals(request,body,artists,done);},YES,@"more than 64 artists are fully resolved in both languages");
        Check(gArtistNames.count==5130,@"all new and existing artist names survive more than 5000 learned entries");
        for(NSString *mode in @[@"http-failure",@"partial",@"entry-failure",@"malformed"]) {
            request.URL=[NSURL URLWithString:[base stringByAppendingFormat:@"/%@",mode]];gOriginalCache=[NSMutableDictionary dictionary];
            Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,[NSSet setWithObject:target],done);},NO,[NSString stringWithFormat:@"%@ propagates failure",mode]);
            Check(!gOriginalCache[target],@"failed lookup does not create a successful cache value");
        }
        NSArray *pair=[[tracks allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSString *kept=pair[0],*omitted=pair[1];gOriginalCache=[NSMutableDictionary dictionary];
        request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/partial"]];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,[NSSet setWithArray:@[kept,omitted]],done);},NO,@"mixed response reports its missing entry");
        Check(gOriginalCache[kept]!=nil && !gOriginalCache[omitted],@"same failed batch caches only its individually valid entry");
        request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/good"]];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,[NSSet setWithObject:omitted],done);},YES,@"missing entry retries through the real asynchronous lookup");
        Check(gOriginalCache[omitted]!=nil,@"retry caches the previously missing entry");
        request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/good"]];
        Await(^(void (^done)(NSError *)){JPTFetchOriginals(request,body,[NSSet setWithObject:target],done);},YES,@"a later request retries successfully after failure");
        Check(gOriginalCache[target]!=nil,@"successful retry supplies metadata");
        NSArray *orderedTracks=[tracks.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSSet *siblingBatch=[NSSet setWithArray:[orderedTracks subarrayWithRange:NSMakeRange(0,130)]];
        gOriginalCache=[NSMutableDictionary dictionary];
        Await(^(void (^done)(NSError *)){JPTFetchSiblingBatches(request,body,siblingBatch,done);},YES,@"parallel sibling batches finish under the shared limit");
        Check(gOriginalCache.count==130,@"all parallel sibling results are merged before completion");
        request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/partial"]];gOriginalCache=[NSMutableDictionary dictionary];
        Await(^(void (^done)(NSError *)){JPTFetchSiblingBatches(request,body,siblingBatch,done);},NO,@"parallel sibling batches report missing entries");
        Check(gOriginalCache.count==129,@"parallel partial failure retains exactly the valid entries");
        request.URL=[NSURL URLWithString:[base stringByAppendingString:@"/good"]];
        Await(^(void (^done)(NSError *)){JPTFetchSiblingBatches(request,body,siblingBatch,done);},YES,@"failed parallel entries remain retryable");
        Check(gOriginalCache.count==130,@"parallel retry completes the missing metadata");
        gDelegateClasses=[NSMutableArray array];JPTHookDelegate(@"JPTBatchDelegate");gOriginalCache=[NSMutableDictionary dictionary];
        ClientRequest([base stringByAppendingString:@"/client-failure"],target);
        Check(!deliveryError && received.length>0,@"failed enrichment delivers official data without a lookup error");
        gArtistNames=[@{@"spotify:artist:2mcj8ajoE1eFlNkAihw5Cg":@"月詠み"} mutableCopy];
        ClientRequest([base stringByAppendingString:@"/good"],target);
        Check(!deliveryError && received.length>0,@"retry delivers a complete successful body");
        NSString *name=nil;JPTReader r=JPTReaderMake(received.bytes,received.length);JPTField f;BOOL ok;
        while(JPTNext(&r,&f,&ok))if(f.field==2 && JPTArrayKind(&f)==178){JPTReader ar=JPTReaderMake(f.data,f.len);JPTField af;BOOL aok;while(JPTNext(&ar,&af,&aok))if(af.field==3){NSString *u=nil;uint64_t status;JPTField value;if(JPTParseEntry(&af,&u,&status,&value)&&[u isEqualToString:target])JPTReplaceString(value.data,value.len,2,@"test",&name);}}
        Check([name isEqualToString:@"救世主"],@"the client receives Japanese IdentityTrait after retry");
        dispatch_group_t group=dispatch_group_create();__block NSUInteger failed=0;
        for(NSUInteger i=0;i<9;i++) { dispatch_group_enter(group);JPTFetchOriginals(request,body,[NSSet setWithObject:target],^(NSError *error){if(error){@synchronized(gOriginalCache){failed++;}}dispatch_group_leave(group);}); }
        Check(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0 && !failed,@"parallel lookup jobs all finish under the shared concurrency bound");
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kJPTArtistNamesKey];
        printf("%lu checks passed\n",(unsigned long)checks);
    }return 0;
}
