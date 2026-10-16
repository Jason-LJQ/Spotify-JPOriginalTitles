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
    JPTWriteVarint(query,8);JPTWriteVarint(query,178);JPTWriteString(entity,1,uri);JPTWriteData(entity,2,query);JPTWriteData(body,2,entity);
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
