// Hold real URLSession requests to verify the two independent scheduling limits.
#define JPT_MANAGEMENT_TEST 1
#define JPT_LOOKUP_TEST_PROTOCOL 1
#include "../JPOriginalTitles.m"

static NSMutableArray *held;
static NSUInteger active[2], peak[2], totalPeak, checks;
static dispatch_semaphore_t started[2], completed;

@interface JPTTestTransportProtocol : NSURLProtocol
@end
@implementation JPTTestTransportProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"jpt.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSUInteger lane = [self.request.URL.path hasPrefix:@"/anonymous"] ? 1 : 0;
    @synchronized (held) {
        [held addObject:self]; active[lane]++;
        peak[lane] = MAX(peak[lane], active[lane]);
        totalPeak = MAX(totalPeak, active[0] + active[1]);
    }
    dispatch_semaphore_signal(started[lane]);
}
- (void)stopLoading {}
@end

static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n", label.UTF8String);
}
static void Submit(BOOL anonymous, NSUInteger number) {
    NSString *url = [NSString stringWithFormat:@"https://jpt.invalid/%@/%lu", anonymous ? @"anonymous" : @"account", (unsigned long)number];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    JPTLookupRequestMode(request, JPTBeginResolution(request), anonymous, ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || [(NSHTTPURLResponse *)response statusCode] != 200) exit(2);
        dispatch_semaphore_signal(completed);
    });
}
static void ReleaseOne(NSUInteger lane) {
    JPTTestTransportProtocol *protocol = nil;
    @synchronized (held) {
        for (JPTTestTransportProtocol *item in held) {
            if ([item.request.URL.path hasPrefix:@"/anonymous"] == (lane == 1)) { protocol = item; break; }
        }
        if (protocol) { [held removeObject:protocol]; active[lane]--; }
    }
    Check(protocol != nil, @"a held request can finish");
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:protocol.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    [protocol.client URLProtocol:protocol didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocolDidFinishLoading:protocol];
}
static BOOL Wait(dispatch_semaphore_t semaphore, double seconds) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}
static void Exercise(NSUInteger first) {
    NSUInteger other = 1 - first;
    for (NSUInteger i = 0; i < 4; i++) Submit(first == 1, i);
    for (NSUInteger i = 0; i < 3; i++) Check(Wait(started[first], 2), @"first lane starts three requests");
    Check(!Wait(started[first], 0.15), @"fourth request waits at its lane limit");
    for (NSUInteger i = 0; i < 4; i++) Submit(other == 1, i);
    for (NSUInteger i = 0; i < 3; i++) Check(Wait(started[other], 2), @"other lane starts while the first lane is full");
    Check(!Wait(started[other], 0.15), @"other lane also queues its fourth request");
    @synchronized (held) { Check(active[0] == 3 && active[1] == 3, @"account and anonymous each hold three active requests"); }
    ReleaseOne(first);
    Check(Wait(started[first], 2), @"finishing first lane starts its queued request");
    Check(!Wait(started[other], 0.1), @"finishing first lane does not release another lane's slot");
    ReleaseOne(other);
    Check(Wait(started[other], 2), @"other lane releases its own queued request");
    for (NSUInteger lane = 0; lane < 2; lane++) for (NSUInteger i = 0; i < 3; i++) ReleaseOne(lane);
    for (NSUInteger i = 0; i < 8; i++) Check(Wait(completed, 2), @"request completion is delivered");
}
int main(void) { @autoreleasepool {
    held = [NSMutableArray array]; completed = dispatch_semaphore_create(0);
    started[0] = dispatch_semaphore_create(0); started[1] = dispatch_semaphore_create(0);
    Exercise(0); Exercise(1);
    Check(peak[0] == 3 && peak[1] == 3 && totalPeak == 6, @"observed peak concurrency is three plus three");
    printf("%lu checks passed\n", (unsigned long)checks); return 0;
} }
