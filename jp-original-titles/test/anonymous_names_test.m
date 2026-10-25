// Reuse the paired transport fixtures; no autonomous query entry points are exercised.
#define main JPTPreviousAnonymousTestMain
#include "anonymous_assist_test.m"
#undef main
#include "shared_canonical_fixture.h"
static NSData *NameAlbum(NSUInteger value, NSString *name, NSUInteger track) {
    NSMutableData *data = [Entity(value, name) mutableCopy], *disc = [NSMutableData data];
    JPTWriteData(disc, 3, Entity(track, nil)); JPTWriteData(data, 11, disc); return data;
}
static NSData *NameTrack(NSUInteger value, NSString *name, NSUInteger album, NSString *isrc) {
    NSMutableData *data = [Entity(value, name) mutableCopy], *external = [NSMutableData data];
    JPTWriteData(data, 3, Entity(album, @"ALBUM")); JPTWriteData(data, 4, Entity(201, @"Artist"));
    Number(data, 5, 1); Number(data, 6, 1); Number(data, 7, 200000);
    JPTWriteString(external, 1, @"isrc"); JPTWriteString(external, 2, isrc); JPTWriteData(data, 10, external);
    JPTWriteString(data, 22, @"ja"); JPTWriteString(data, 27, name);
    JPTWriteString(data, 36, URI(@"track", value)); return data;
}

int main(void){@autoreleasepool{
    NSString *track=URI(@"track",1),*album=URI(@"album",101),*artist=URI(@"artist",201);
    Reset();holdAccount=YES;
    primaryWireValues=[@{track:NameTrack(1,@"Latin",101,@"RECORDING"),album:NameAlbum(101,@"ALBUM",1)}mutableCopy];
    wireValues=[@{track:NameTrack(1,@"補完",101,@"OTHER"),album:NameAlbum(101,@"補完アルバム",2)}mutableCopy];
    NSURLRequest *owner=Owner();NSSet *uris=[NSSet setWithArray:@[track,album]];
    NSDictionary *account=Lookup(owner,uris,NO);
    Check([[account[track]name]isEqualToString:@"Latin"]&&[[gOriginalCache[track]name]isEqualToString:@"Latin"],@"anonymous result cannot publish before account processing completes");
    Check(parallelSeen,@"anonymous metadata starts while account response is pending");Finish(owner,uris);
    Check([[gOriginalCache[track]name]isEqualToString:@"補完"],@"missing account original is filled from the already fetched copy");
    Check([[gOriginalCache[track]isrc]isEqualToString:@"RECORDING"],@"same-URI merge retains account recording fields");
    Check([[gOriginalCache[album]name]isEqualToString:@"補完アルバム"],@"same-entity album supplement uses its normal cache");
    Check([[(JPTAlbumInfo *)gOriginalCache[album]trackURIs]containsObject:track],@"same-entity adoption retains account album membership");
    Check([gOriginalCache[track].albumName isEqualToString:@"ALBUM"],@"no extra parent display hydration was added");
    NSData *original=Entry(track,10,primaryWireValues[track]);
    NSDictionary *rewritten=JPTCollectMetadataMode(JPTRewriteResponse(original,NSSet.set,JPTOriginalSnapshot(),JPTArtistNamesSnapshot(),NSMutableArray.array),NO);
    Check([[rewritten[track]name]isEqualToString:@"補完"],@"normal writer consumes the retained name");
    JPTCacheOriginals(JPTCollectMetadataMode(original,NO));
    Check([[gOriginalCache[track]name]isEqualToString:@"補完"],@"later Latin account data does not discard accepted original");
    // Account direct and associated resolution always wins over a shadow own-entity title.
    Reset();NSMutableData *source=[NameTrack(1,@"Latin",101,@"RECORDING")mutableCopy];JPTWriteString(source,36,URI(@"track",11));
    primaryWireValues=[@{track:source,URI(@"track",11):NameTrack(11,@"主経路",102,@"RECORDING")}mutableCopy];
    wireValues=[@{track:NameTrack(1,@"補助経路",101,@"RECORDING"),URI(@"track",11):NameTrack(11,@"補助候補",102,@"RECORDING")}mutableCopy];
    owner=Owner();uris=[NSSet setWithArray:@[track,URI(@"track",11)]];Lookup(owner,uris,NO);Finish(owner,uris);
    Check([JPTPreferredInfo(track,JPTOriginalSnapshot(),JPTOriginalSnapshot()).name isEqualToString:@"主経路"],@"account canonical result has priority over anonymous own-entity result");
    Check([gOriginalCache[track].name isEqualToString:@"Latin"],@"account-resolved source model is not replaced by a shadow name");
    // Artists use the same two copies and the existing storage transaction.
    Reset();primaryWireValues=[@{artist:Entity(201,@"Latin")}mutableCopy];wireValues=[@{artist:Entity(201,@"補完芸人")}mutableCopy];
    owner=Owner();Lookup(owner,[NSSet setWithObject:artist],YES);Finish(owner,[NSSet setWithObject:artist]);
    Check([gArtistNames[artist]isEqualToString:@"補完芸人"],@"anonymous artist is used only after missing account original");
    Check(JPTStorageCommit(@[])&&[JPTStorageLoad(NO)[artist]isEqualToString:@"補完芸人"],@"normal durable artist storage is reused");
    Reset();primaryWireValues=[@{artist:Entity(201,@"主芸人")}mutableCopy];wireValues=[@{artist:Entity(201,@"補助芸人")}mutableCopy];
    owner=Owner();account=Lookup(owner,[NSSet setWithObject:artist],YES);JPTMergeArtistNames(account);Finish(owner,[NSSet setWithObject:artist]);
    Check([gArtistNames[artist]isEqualToString:@"主芸人"],@"account original artist is never overridden by the shadow");
    Reset();holdAnonymous=YES;
    primaryWireValues=[@{track:NameTrack(1,@"主経路",101,@"RECORDING")}mutableCopy];wireValues=[@{track:NameTrack(1,@"補助経路",101,@"RECORDING")}mutableCopy];
    owner=Owner();Lookup(owner,[NSSet setWithObject:track],NO);
    __block BOOL completed=NO;
    JPTFinishAnonymousQueries(owner,[NSSet setWithObject:track],^{completed=YES;});
    Check(completed&&!anonymousCompleted,@"a fully resolved account result is delivered without waiting for the anonymous response");
    if(dispatch_group_wait(JPTResolutionFor(owner).anonymousQueries,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)))exit(3);
    // Independent search cards must not expand the baseline request set.
    Reset();gTemplateRequest=Owner();gTemplateBody=NSData.data;NSMutableData *search=[NSMutableData data];
    for(NSUInteger i=1;i<=50;i++){NSMutableData *entity=[NSMutableData data];JPTWriteString(entity,1,URI(i%2?@"artist":@"album",i));JPTWriteString(entity,2,@"Latin");JPTWriteData(search,1,entity);}
    NSUInteger before=requests;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    __block NSData *delivered=nil;JPTFinishSearch(session,Owner(),search,^(NSData *data,NSError *error){delivered=data;dispatch_semaphore_signal(done);});
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&[delivered isEqualToData:search],@"fifty independent cards follow main search behavior");
    Check(requests==before,@"fifty independent search cards launch zero extra account or anonymous requests");[session finishTasksAndInvalidate];
    // A normal batch remains one request per provider, not one request per card.
    Reset();primaryWireValues=[NSMutableDictionary dictionary];wireValues=[NSMutableDictionary dictionary];NSMutableSet *many=[NSMutableSet set];
    for(NSUInteger i=1;i<=50;i++){NSString *uri=URI(@"track",i);[many addObject:uri];primaryWireValues[uri]=NameTrack(i,@"Latin",101,@"RECORDING");wireValues[uri]=NameTrack(i,@"補完",101,@"RECORDING");}
    owner=Owner();Lookup(owner,many,NO);Finish(owner,many);
    Check([sizes[0]isEqualToArray:@[@50]]&&[sizes[1]isEqualToArray:@[@50]],@"a fifty-entity lookup is two batched requests, not one hundred requests");
    Reset();atomic_store(&gJPTStrict,true);fault=@"anonymous-429";
    primaryWireValues=[@{track:NameTrack(1,@"Latin",101,@"RECORDING")}mutableCopy];wireValues=[@{track:NameTrack(1,@"補完",101,@"RECORDING")}mutableCopy];
    owner=Owner();Lookup(owner,[NSSet setWithObject:track],NO);Finish(owner,[NSSet setWithObject:track]);
    Check(!JPTStopped(owner)&&!JPTResolutionFailure(owner)&&[gOriginalCache[track].name isEqualToString:@"Latin"],@"optional copy failure does not poison successful account strict state");
    Reset();fault=@"account-429";
    primaryWireValues=[@{track:NameTrack(1,@"Latin",101,@"RECORDING")}mutableCopy];wireValues=[@{track:NameTrack(1,@"補完",101,@"RECORDING")}mutableCopy];
    owner=Owner();Lookup(owner,[NSSet setWithObject:track],NO);Finish(owner,[NSSet setWithObject:track]);
    Check([gOriginalCache[track].name isEqualToString:@"補完"],@"independent anonymous copy can finish when account lookup is rejected");
    atomic_store(&gJPTStrict,false);
    printf("%lu checks passed\n",(unsigned long)checks);return 0;
}}
