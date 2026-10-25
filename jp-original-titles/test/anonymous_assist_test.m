// Exercise paired providers through the production batching and retry engine.
#define JPT_MANAGEMENT_TEST 1
#define JPT_LOOKUP_TEST_PROTOCOL 1
#include "../JPOriginalTitles.m"
static NSUInteger checks, requests, bootstraps, calls[2];
static NSMutableDictionary *wireValues, *primaryWireValues;
static NSMutableArray *sizes[2];
static NSString *fault;
static BOOL leakedCredentials, holdAccount, holdAnonymous, parallelSeen, accountCompleted, anonymousCompleted, anonymousBeforeAccount;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1); }
    checks++;printf("PASS %s\n",label.UTF8String);
}
static NSString *URI(NSString *kind, NSUInteger value) {
    uint8_t gid[16]={0};gid[14]=value>>8;gid[15]=value;
    return [NSString stringWithFormat:@"spotify:%@:%@",kind,JPTBase62(gid,16)];
}
static void Number(NSMutableData *data,uint32_t field,uint64_t value) {JPTWriteVarint(data,(uint64_t)field<<3);JPTWriteVarint(data,value);}
static NSData *Entity(NSUInteger value,NSString *name) {
    uint8_t gid[16]={0};gid[14]=value>>8;gid[15]=value;
    NSMutableData *data=[NSMutableData data];JPTWriteData(data,1,[NSData dataWithBytes:gid length:16]);if(name)JPTWriteString(data,2,name);return data;
}
static NSData *Entry(NSString *uri,NSUInteger kind,NSData *value) {
    NSMutableData *h=[NSMutableData data],*entry=[NSMutableData data],*any=[NSMutableData data],*array=[NSMutableData data],*out=[NSMutableData data];
    Number(h,1,value?200:404);JPTWriteData(entry,1,h);JPTWriteString(entry,2,uri);
    if(value){JPTWriteData(any,2,value);JPTWriteData(entry,3,any);}Number(array,2,kind);JPTWriteData(array,3,entry);JPTWriteData(out,2,array);return out;
}
@interface JPTTestTransportProtocol : NSURLProtocol
@end
@implementation JPTTestTransportProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)startLoading {
    requests++;NSData *body=nil;NSInteger status=200;
    BOOL bootstrap=[self.request.URL.host isEqualToString:@"open.spotify.com"];
    BOOL account=[[self.request valueForHTTPHeaderField:@"Authorization"]isEqualToString:@"Bearer personal-account"];
    NSUInteger lane=account?0:1;
    if(!account && ([self.request valueForHTTPHeaderField:@"Cookie"]||[self.request valueForHTTPHeaderField:@"client-token"]||self.request.HTTPShouldHandleCookies))leakedCredentials=YES;
    if(bootstrap) {
        bootstraps++;
        if([self.request valueForHTTPHeaderField:@"Authorization"])leakedCredentials=YES;
        NSString *html=[NSString stringWithFormat:@"<script id=\"__NEXT_DATA__\">{\"props\":{\"pageProps\":{\"state\":{\"settings\":{\"session\":{\"isAnonymous\":true,\"accessToken\":\"synthetic-anonymous\",\"accessTokenExpirationTimestampMs\":%.0f}}}}}}</script>",(NSDate.date.timeIntervalSince1970+3600)*1000];
        body=[html dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        NSData *input=self.request.HTTPBody;
        if(!input && self.request.HTTPBodyStream) {
            NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *buffer=[NSMutableData data];uint8_t bytes[4096];NSInteger n;
            while((n=[stream read:bytes maxLength:sizeof(bytes)])>0)[buffer appendBytes:bytes length:n];[stream close];input=buffer;
        }
        NSMutableArray *uris=[NSMutableArray array],*kinds=[NSMutableArray array];
        JPTReader r=JPTReaderMake(input.bytes,input.length);JPTField f;BOOL ok;
        while(JPTNext(&r,&f,&ok))if(f.field==2&&f.wire==2) {
            NSString *uri=JPTSubString(&f,1);NSUInteger kind=0;JPTReader er=JPTReaderMake(f.data,f.len);JPTField ef;BOOL eok;
            while(JPTNext(&er,&ef,&eok))if(ef.field==2){JPTReader qr=JPTReaderMake(ef.data,ef.len);JPTField qf;BOOL qok;while(JPTNext(&qr,&qf,&qok))if(qf.field==1)kind=qf.varint;}
            if(uri){[uris addObject:uri];[kinds addObject:@(kind)];}
        }
        NSUInteger attempt;
        @synchronized(JPTResolution.class){attempt=++calls[lane];[sizes[lane]addObject:@(uris.count)];if(calls[0]&&calls[1])parallelSeen=YES;if(!account&&!accountCompleted)anonymousBeforeAccount=YES;}
        if([fault isEqualToString:@"500-once"]&&attempt==1)status=500;
        if([fault isEqualToString:@"500-always"])status=500;
        if([@[@"401",@"403",@"429"]containsObject:fault])status=fault.integerValue;
        if(!account&&[fault isEqualToString:@"anonymous-429"])status=429;
        if(account&&[fault isEqualToString:@"account-429"])status=429;
        if([@[@"offline",@"cancel",@"timeout-once"]containsObject:fault]&&(![fault isEqualToString:@"timeout-once"]||attempt==1)) {
            NSInteger code=[fault isEqualToString:@"offline"]?NSURLErrorNotConnectedToInternet:[fault isEqualToString:@"cancel"]?NSURLErrorCancelled:NSURLErrorTimedOut;
            [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil]];return;
        }
        NSMutableData *result=[NSMutableData data];
        for(NSUInteger i=0;i<uris.count;i++) {
            if([fault isEqualToString:@"missing-once"]&&attempt==1&&i==0)continue;
            NSData *entry=Entry(uris[i],[kinds[i]unsignedIntegerValue],(account?primaryWireValues:wireValues)[uris[i]]);
            [result appendData:entry];if([fault isEqualToString:@"duplicate-once"]&&attempt==1&&i==0)[result appendData:entry];
        }
        body=([fault isEqualToString:@"malformed-once"]&&attempt==1)?[NSData dataWithBytes:"\xff" length:1]:result;
    }
    void (^complete)(void)=^{
        if(account){@synchronized(JPTResolution.class){accountCompleted=YES;}}
        else if(!bootstrap){@synchronized(JPTResolution.class){anonymousCompleted=YES;}}
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];[self.client URLProtocol:self didLoadData:body];[self.client URLProtocolDidFinishLoading:self];
    };
    if((account&&holdAccount)||(!account&&!bootstrap&&holdAnonymous))dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),complete);else complete();
}
- (void)stopLoading {}
@end
static NSURLRequest *Owner(void) {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata"]];request.HTTPMethod=@"POST";request.timeoutInterval=0.4;
    [request setValue:@"Bearer personal-account" forHTTPHeaderField:@"Authorization"];
    [request setValue:@"private-cookie" forHTTPHeaderField:@"Cookie"];[request setValue:@"private-client" forHTTPHeaderField:@"client-token"];return JPTBeginResolution(request);
}
static void Reset(void) {
    gOriginalCache=[NSMutableDictionary dictionary];gReverseOriginals=[NSMutableDictionary dictionary];gArtistNames=[NSMutableDictionary dictionary];gArtistChecked=[NSMutableSet set];
    gJPTAnonymousToken=@"synthetic-anonymous";gJPTAnonymousExpiry=NSDate.date.timeIntervalSince1970+3600;
    calls[0]=calls[1]=0;sizes[0]=[NSMutableArray array];sizes[1]=[NSMutableArray array];fault=nil;holdAccount=NO;holdAnonymous=NO;parallelSeen=NO;accountCompleted=NO;anonymousCompleted=NO;anonymousBeforeAccount=NO;atomic_store(&gJPTStrict,false);
}
static NSDictionary *Lookup(NSURLRequest *owner,NSSet *uris,BOOL artist) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *values;
    JPTFetchQueryBatch(owner,NSData.data,uris,@"zh-Hans",artist,^(NSDictionary *result,NSError *error){values=result;dispatch_semaphore_signal(done);});
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)),@"account lookup completes");return values;
}
static void Finish(NSURLRequest *owner,NSSet *uris) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);JPTFinishAnonymousQueries(owner,uris,^{dispatch_semaphore_signal(done);});
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)),@"provider results are consumed in priority order");
    // Drain unused copies before mutating the shared test transport fixtures.
    if(dispatch_group_wait(JPTResolutionFor(owner).anonymousQueries,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))exit(3);
}
int main(void){@autoreleasepool{
    NSMutableSet *uris=[NSMutableSet set];wireValues=[NSMutableDictionary dictionary];primaryWireValues=[NSMutableDictionary dictionary];
    for(NSUInteger i=1;i<=256;i++){NSString *uri=URI(@"artist",i);[uris addObject:uri];primaryWireValues[uri]=Entity(i,@"Latin");wireValues[uri]=Entity(i,@"補完");}
    for(NSString *mode in @[@"success",@"500-once",@"500-always",@"missing-once",@"duplicate-once",@"malformed-once",@"timeout-once",@"401",@"403",@"429",@"offline",@"cancel"]) {
        Reset();fault=mode;holdAccount=[mode isEqualToString:@"success"];NSURLRequest *owner=Owner();Lookup(owner,uris,YES);Finish(owner,uris);
        Check([sizes[0]isEqualToArray:sizes[1]],@"account and anonymous use identical batch retry and split rules");
        if([@[@"401",@"403",@"429",@"offline",@"cancel"]containsObject:mode])Check(calls[0]==1&&calls[1]==1,@"terminal failures are not retried by either provider");
        if([mode isEqualToString:@"500-once"]||[mode isEqualToString:@"malformed-once"]||[mode isEqualToString:@"timeout-once"])Check(calls[0]==5,@"whole request failure uses the existing four 64-entry children");
        if([mode isEqualToString:@"missing-once"]||[mode isEqualToString:@"duplicate-once"])Check([sizes[0]isEqualToArray:@[@256,@1]],@"only the affected entry is retried once");
        if([mode isEqualToString:@"success"])Check(parallelSeen&&anonymousBeforeAccount,@"both providers start before the delayed account response finishes");
    }
    Reset();fault=@"429";NSURLRequest *first=Owner();Lookup(first,uris,YES);Finish(first,uris);NSUInteger before=calls[1];
    NSURLRequest *next=Owner();Lookup(next,uris,YES);Finish(next,uris);Check(calls[1]>before,@"next response is not suppressed by a sixty-second anonymous cooldown");
    Check(!leakedCredentials,@"anonymous requests isolate account authorization cookies and client-token");
    NSMutableURLRequest *request=JPTAnonymousRequest([NSURL URLWithString:@"https://example.invalid"],nil,nil);
    Check(request.timeoutInterval==[NSURLRequest requestWithURL:request.URL].timeoutInterval,@"anonymous request has no custom six-second timeout");
    printf("%lu checks passed\n",(unsigned long)checks);return 0;
}}
