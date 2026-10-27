#define JPT_TEST 1
#include "../JPOriginalTitles.m"
static int passed = 0;
static void Check(BOOL condition, NSString *name) {
    if (!condition) { fprintf(stderr, "FAIL %s\n", name.UTF8String); exit(1); }
    passed++; printf("PASS %s\n", name.UTF8String);
}
static NSData *Text(uint32_t field, NSString *value) { NSMutableData *d = [NSMutableData data]; JPTWriteString(d, field, value); return d; }
static NSData *Contributor(NSString *name, NSString *group, BOOL navigable) {
    NSMutableData *d = [NSMutableData data]; JPTWriteString(d, 1, name);
    if (group) JPTWriteData(d, 6, Text(1, group));
    if (navigable) JPTWriteString(d, 3, @"spotify:artist:official");
    return d;
}
static NSData *Entry(NSData *value, NSString *uri, uint64_t status) {
    NSMutableData *header = [NSMutableData data], *any = [NSMutableData data], *entry = [NSMutableData data];
    JPTWriteVarint(header, 8); JPTWriteVarint(header, status);
    JPTWriteData(entry, 1, header); JPTWriteString(entry, 2, uri);
    JPTWriteString(any, 1, @"type.googleapis.com/spotify.contentagnostic.v2.CreditsTrait");
    JPTWriteData(any, 2, value); JPTWriteString(any, 123, @"any-unknown");
    JPTWriteData(entry, 3, any); JPTWriteString(entry, 99, @"entry-unknown"); return entry;
}
static NSData *Response(NSArray *entries, uint64_t kind) {
    NSMutableData *array = [NSMutableData data], *out = [NSMutableData data];
    JPTWriteString(array, 1, @"array-unknown"); JPTWriteVarint(array, 16); JPTWriteVarint(array, kind);
    for (NSData *entry in entries) JPTWriteData(array, 3, entry);
    JPTWriteString(out, 1, @"outer-header"); JPTWriteData(out, 2, array); JPTWriteString(out, 90, @"outer-tail"); return out;
}
static NSArray *Values(NSData *body) {
    NSMutableArray *values = [NSMutableArray array]; JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r,&f,&ok)) if(f.field == 2 && f.wire == 2) {
        JPTReader ar = JPTReaderMake(f.data,f.len); JPTField af; BOOL aok;
        while(JPTNext(&ar,&af,&aok)) if(af.field==3 && af.wire==2) {
            NSString *u=nil; uint64_t status; JPTField v={0};
            if(JPTParseEntry(&af,&u,&status,&v)) [values addObject:[NSData dataWithBytes:v.data length:v.len]];
        }
    }
    return values;
}
static NSArray *Rows(NSData *value) {
    NSMutableArray *rows=[NSMutableArray array]; JPTReader r=JPTReaderMake(value.bytes,value.length);JPTField f;BOOL ok;
    while(JPTNext(&r,&f,&ok)) if(f.field==1&&f.wire==2) {
        NSString *name=JPTSubString(&f,1); NSString *role=JPTSubString(&f,2); NSString *group=nil;
        JPTReader cr=JPTReaderMake(f.data,f.len);JPTField cf;BOOL cok;
        while(JPTNext(&cr,&cf,&cok)) if(cf.field==6&&cf.wire==2) group=JPTSubString(&cf,1);
        [rows addObject:@[group?:@"",name?:@"",role?:@""]];
    }
    return rows;
}
static NSData *Credits(NSData *body) { return JPTNativeCreditsResponse(body, YES); }
static NSData *Person(NSString *name, NSString *uri) {
    NSMutableData *d = [NSMutableData data]; JPTWriteString(d, 1, name); JPTWriteString(d, 2, @"Performer");
    if (uri) JPTWriteString(d, 3, uri);
    JPTWriteString(d, 4, @"reference opaque"); JPTWriteData(d, 6, Text(1, @"Performers")); JPTWriteString(d, 55, @"contributor-unknown");
    return d;
}
static NSUInteger StoredArtists(void) {
    sqlite3_stmt *stmt = NULL; sqlite3_prepare_v2(gJPTStore, "SELECT count(*) FROM artist_names", -1, &stmt, NULL);
    NSUInteger n = sqlite3_step(stmt) == SQLITE_ROW ? (NSUInteger)sqlite3_column_int64(stmt, 0) : 0; sqlite3_finalize(stmt); return n;
}
static void Seed(NSDictionary *fields) { gJPTPreviousMetadataRecords=[@{@"spotify:track:target":@{@"fields":fields,@"touched":@1}} mutableCopy]; }
static NSDictionary *Pair(NSString *a, NSString *b) {return @{@"old":a,@"new":b};}
int main(void) { @autoreleasepool {
    NSString *uri=@"spotify:track:target";
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主"),@"artists":Pair(@"Artist A, Artist B",@"歌手A, 歌手B"),@"album":Pair(@"Album",@"アルバム")});
    NSMutableData *official=[NSMutableData data];JPTWriteData(official,1,Contributor(@"Official Author",@"Writer",YES));JPTWriteString(official,2,@"source opaque");JPTWriteString(official,77,@"credits-unknown");
    NSData *before=Response(@[Entry(official,uri,200)],186),*after=Credits(before);
    NSArray *rows=Rows(Values(after)[0]);
    Check(rows.count==4,@"three changed dimensions create three native rows");
    Check([rows[0] isEqual:@[@"Writer",@"Official Author",@""]],@"official contributor preserved");
    Check([rows[1] isEqual:@[@"Original Metadata",@"Kyuseishu",@"Title"]],@"title uses exact previous value");
    Check([rows[2] isEqual:@[@"Original Metadata",@"Artist A, Artist B",@"Artist"]],@"artist list preserves order");
    Check([rows[3] isEqual:@[@"Original Metadata",@"Album",@"Album"]],@"album row present");
    NSData *value=Values(after)[0];Check([[value subdataWithRange:NSMakeRange(0,official.length)] isEqual:official],@"official credits and unknown bytes are unchanged prefix");
    NSMutableData *expected=[official mutableCopy];for(NSArray *row in [rows subarrayWithRange:NSMakeRange(1,3)]) { NSMutableData *c=[NSMutableData data];JPTWriteString(c,1,row[1]);JPTWriteString(c,2,row[2]);JPTWriteData(c,6,Text(1,row[0]));JPTWriteData(expected,1,c); }
    Check([after isEqual:Response(@[Entry(expected,uri,200)],186)],@"outer entry Any and unknown fields preserved");
    Check([Credits(after) isEqual:after],@"second pass is byte-identical");
    Check([Credits(Response(@[Entry(official,uri,200)],178)) isEqual:Response(@[Entry(official,uri,200)],178)],@"other kind unchanged");
    for(NSNumber *status in @[@204,@304,@404,@500]){NSData *d=Response(@[Entry(official,uri,status.unsignedLongLongValue)],186);Check([Credits(d)isEqual:d],[NSString stringWithFormat:@"status %@ unchanged",status]);}
    for(NSString *other in @[@"spotify:track:other",@"spotify:album:target",@"spotify:artist:target"]){NSData *d=Response(@[Entry(official,other,200)],186);Check([Credits(d)isEqual:d],[NSString stringWithFormat:@"unrelated URI %@ unchanged",other]);}
    Seed(@{@"title":Pair(@"same",@"same"),@"artists":Pair(@"",@"New"),@"album":Pair(@"   ",@"New")});
    Check([Credits(before)isEqual:before],@"unchanged empty whitespace values hidden");
    Seed(@{@"title":Pair(@"Old (Live) 日本語",@"新しい名")});
    Check(Rows(Values(Credits(before))[0]).count==2,@"only actual changed dimension is added");
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主"),@"album":Pair(@"Kyuseishu",@"救世主")});
    NSArray *equalRows=Rows(Values(Credits(before))[0]);
    Check(equalRows.count==3 && [equalRows[1][1] isEqual:equalRows[2][1]] && ![equalRows[1][2] isEqual:equalRows[2][2]],@"identical previous title and album have distinct native roles");
    Seed(@{});Check([Credits(before)isEqual:before],@"missing record unchanged");
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主")});
    NSMutableData *collision=[official mutableCopy];JPTWriteData(collision,1,Contributor(@"Kyuseishu",@"Title",YES));
    Check(Rows(Values(Credits(Response(@[Entry(collision,uri,200)],186)))[0]).count==3,@"navigable official collision is not treated as prototype row");
    const uint8_t invalid[]={0x0a,0x80};NSData *bad=[NSData dataWithBytes:invalid length:sizeof(invalid)];
    NSData *badEntry=Response(@[Entry(bad,uri,200)],186);Check([Credits(badEntry)isEqual:badEntry],@"malformed credits retained");
    NSMutableData *badOuter=[before mutableCopy];[badOuter appendData:bad];Check([Credits(badOuter)isEqual:badOuter],@"malformed outer response rolls back all edits");
    NSMutableData *badWrapper=[Entry(official,uri,200) mutableCopy];JPTWriteData(badWrapper,3,bad);NSData *bw=Response(@[badWrapper],186);Check([Credits(bw)isEqual:bw],@"ambiguous malformed Any wrapper retained");
    NSData *mixed=Response(@[Entry(official,uri,200),Entry(bad,uri,200),Entry(official,@"spotify:track:other",200)],186);NSArray *mv=Values(Credits(mixed));Check(mv.count==3&&[mv[1]isEqual:bad]&&[mv[2]isEqual:official]&&Rows(mv[0]).count==2,@"malformed sibling cannot damage valid or unrelated entries");
    NSMutableData *query=[NSMutableData data],*entity=[NSMutableData data],*request=[NSMutableData data];JPTWriteVarint(query,8);JPTWriteVarint(query,186);JPTWriteString(entity,1,uri);JPTWriteData(entity,2,query);JPTWriteData(request,2,entity);
    Check(JPTRequestHasCredits(request),@"credits request detected");
    [request appendData:bad];Check(!JPTRequestHasCredits(request),@"malformed request does not match");
    Check(!JPTRequestHasCredits([NSData data]),@"empty request does not match");
    Check(Credits(nil)==nil,@"nil response retained");
    // Credits contributors take the plugin's artist_names entry for the same artist URI.
    JPTStorageClear(); Seed(@{});
    NSString *tanaka=@"spotify:artist:tanaka", *other=@"spotify:artist:other";
    JPTMergeArtistNames(@{tanaka:@"田中 望",other:@"Other B"});
    Check(JPTStorageCommit(@[])&&StoredArtists()==2,@"artist names are read from the single artist_names table");
    NSMutableData *credits=[NSMutableData data];
    NSData *tanakaRow=Person(@"NOZOMU TANAKA",tanaka),*plain=Person(@"NOZOMU TANAKA",nil),*unknown=Person(@"Other",other),*already=Person(@"田中",tanaka);
    for(NSData *row in @[tanakaRow,plain,unknown,already]) JPTWriteData(credits,1,row);
    JPTWriteString(credits,2,@"source opaque");
    NSData *creditsResponse=Response(@[Entry(credits,@"spotify:track:anywhere",200)],186);
    NSData *(^Expected)(NSString *)=^NSData *(NSString *name){
        NSMutableData *v=[NSMutableData data]; JPTWriteData(v,1,JPTReplaceString(tanakaRow.bytes,tanakaRow.length,1,name,NULL));
        for(NSData *row in @[plain,unknown,already]) JPTWriteData(v,1,row);
        JPTWriteString(v,2,@"source opaque"); return Response(@[Entry(v,@"spotify:track:anywhere",200)],186);
    };
    NSData *plainOut=JPTNativeCreditsResponse(creditsResponse,NO),*barOut=JPTNativeCreditsResponse(creditsResponse,YES);
    Check([plainOut isEqual:Expected(@"田中 望")],@"bar off: only the matching contributor name changes; role, URI, reference, group, unknown fields and sources stay");
    Check(![plainOut isEqual:creditsResponse]&&[Rows(Values(plainOut)[0])[2][1] isEqual:@"Other"],@"an artist_names entry without CJK text never renames a contributor");
    Check([barOut isEqual:Expected(@"田中 望\uFF5CNOZOMU TANAKA")],@"bar on: renamed contributor shows new｜Credits name");
    Check([JPTNativeCreditsResponse(plainOut,NO) isEqual:plainOut]&&[JPTNativeCreditsResponse(barOut,YES) isEqual:barOut],@"rename second pass is byte-identical");
    Check([JPTNativeCreditsResponse(barOut,NO) isEqual:barOut]&&[JPTNativeCreditsResponse(plainOut,YES) isEqual:plainOut],@"names with CJK text are never renamed again");
    NSData *noMatch=Response(@[Entry(official,@"spotify:track:anywhere",200)],186);
    Check([JPTNativeCreditsResponse(noMatch,YES) isEqual:noMatch],@"credits without a stored URI are unchanged");
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主")});
    NSArray *both=Rows(Values(JPTNativeCreditsResponse(Response(@[Entry(credits,uri,200)],186),YES))[0]);
    Check(both.count==5&&[both[0][1] isEqual:@"田中 望\uFF5CNOZOMU TANAKA"]&&[both[4] isEqual:@[@"Original Metadata",@"Kyuseishu",@"Title"]],@"rename and Original Metadata rows apply together");
    Check(JPTStorageClear()&&!JPTArtistNamesSnapshot().count&&!StoredArtists()&&[JPTNativeCreditsResponse(creditsResponse,YES) isEqual:creditsResponse],@"plugin reset clears the names Credits use");
    printf("%d checks passed\n",passed);
} return 0; }
