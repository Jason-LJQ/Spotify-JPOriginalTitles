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
static void Seed(NSDictionary *fields) { gJPTPreviousMetadataRecords=[@{@"spotify:track:target":@{@"fields":fields,@"touched":@1}} mutableCopy]; }
static NSDictionary *Pair(NSString *a, NSString *b) {return @{@"old":a,@"new":b};}
int main(void) { @autoreleasepool {
    NSString *uri=@"spotify:track:target";
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主"),@"artists":Pair(@"Artist A, Artist B",@"歌手A, 歌手B"),@"album":Pair(@"Album",@"アルバム")});
    NSMutableData *official=[NSMutableData data];JPTWriteData(official,1,Contributor(@"Official Author",@"Writer",YES));JPTWriteString(official,2,@"source opaque");JPTWriteString(official,77,@"credits-unknown");
    NSData *before=Response(@[Entry(official,uri,200)],186),*after=JPTNativeCreditsResponse(before);
    NSArray *rows=Rows(Values(after)[0]);
    Check(rows.count==4,@"three changed dimensions create three native rows");
    Check([rows[0] isEqual:@[@"Writer",@"Official Author",@""]],@"official contributor preserved");
    Check([rows[1] isEqual:@[@"Previous metadata",@"Kyuseishu",@"Previous title"]],@"title uses exact previous value");
    Check([rows[2] isEqual:@[@"Previous metadata",@"Artist A, Artist B",@"Previous artist"]],@"artist list preserves order");
    Check([rows[3] isEqual:@[@"Previous metadata",@"Album",@"Previous album"]],@"album row present");
    NSData *value=Values(after)[0];Check([[value subdataWithRange:NSMakeRange(0,official.length)] isEqual:official],@"official credits and unknown bytes are unchanged prefix");
    NSMutableData *expected=[official mutableCopy];for(NSArray *row in [rows subarrayWithRange:NSMakeRange(1,3)]) { NSMutableData *c=[NSMutableData data];JPTWriteString(c,1,row[1]);JPTWriteString(c,2,row[2]);JPTWriteData(c,6,Text(1,row[0]));JPTWriteData(expected,1,c); }
    Check([after isEqual:Response(@[Entry(expected,uri,200)],186)],@"outer entry Any and unknown fields preserved");
    Check([JPTNativeCreditsResponse(after) isEqual:after],@"second pass is byte-identical");
    Check([JPTNativeCreditsResponse(Response(@[Entry(official,uri,200)],178)) isEqual:Response(@[Entry(official,uri,200)],178)],@"other kind unchanged");
    for(NSNumber *status in @[@204,@304,@404,@500]){NSData *d=Response(@[Entry(official,uri,status.unsignedLongLongValue)],186);Check([JPTNativeCreditsResponse(d)isEqual:d],[NSString stringWithFormat:@"status %@ unchanged",status]);}
    for(NSString *other in @[@"spotify:track:other",@"spotify:album:target",@"spotify:artist:target"]){NSData *d=Response(@[Entry(official,other,200)],186);Check([JPTNativeCreditsResponse(d)isEqual:d],[NSString stringWithFormat:@"unrelated URI %@ unchanged",other]);}
    Seed(@{@"title":Pair(@"same",@"same"),@"artists":Pair(@"",@"New"),@"album":Pair(@"   ",@"New")});
    Check([JPTNativeCreditsResponse(before)isEqual:before],@"unchanged empty whitespace values hidden");
    Seed(@{@"title":Pair(@"Old (Live) 日本語",@"新しい名")});
    Check(Rows(Values(JPTNativeCreditsResponse(before))[0]).count==2,@"only actual changed dimension is added");
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主"),@"album":Pair(@"Kyuseishu",@"救世主")});
    NSArray *equalRows=Rows(Values(JPTNativeCreditsResponse(before))[0]);
    Check(equalRows.count==3 && [equalRows[1][1] isEqual:equalRows[2][1]] && ![equalRows[1][2] isEqual:equalRows[2][2]],@"identical previous title and album have distinct native roles");
    Seed(@{});Check([JPTNativeCreditsResponse(before)isEqual:before],@"missing record unchanged");
    Seed(@{@"title":Pair(@"Kyuseishu",@"救世主")});
    NSMutableData *collision=[official mutableCopy];JPTWriteData(collision,1,Contributor(@"Kyuseishu",@"Previous title",YES));
    Check(Rows(Values(JPTNativeCreditsResponse(Response(@[Entry(collision,uri,200)],186)))[0]).count==3,@"navigable official collision is not treated as prototype row");
    const uint8_t invalid[]={0x0a,0x80};NSData *bad=[NSData dataWithBytes:invalid length:sizeof(invalid)];
    NSData *badEntry=Response(@[Entry(bad,uri,200)],186);Check([JPTNativeCreditsResponse(badEntry)isEqual:badEntry],@"malformed credits retained");
    NSMutableData *badOuter=[before mutableCopy];[badOuter appendData:bad];Check([JPTNativeCreditsResponse(badOuter)isEqual:badOuter],@"malformed outer response rolls back all edits");
    NSMutableData *badWrapper=[Entry(official,uri,200) mutableCopy];JPTWriteData(badWrapper,3,bad);NSData *bw=Response(@[badWrapper],186);Check([JPTNativeCreditsResponse(bw)isEqual:bw],@"ambiguous malformed Any wrapper retained");
    NSData *mixed=Response(@[Entry(official,uri,200),Entry(bad,uri,200),Entry(official,@"spotify:track:other",200)],186);NSArray *mv=Values(JPTNativeCreditsResponse(mixed));Check(mv.count==3&&[mv[1]isEqual:bad]&&[mv[2]isEqual:official]&&Rows(mv[0]).count==2,@"malformed sibling cannot damage valid or unrelated entries");
    NSMutableData *query=[NSMutableData data],*entity=[NSMutableData data],*request=[NSMutableData data];JPTWriteVarint(query,8);JPTWriteVarint(query,186);JPTWriteString(entity,1,uri);JPTWriteData(entity,2,query);JPTWriteData(request,2,entity);
    Check(JPTRequestHasCredits(request),@"credits request detected");
    [request appendData:bad];Check(!JPTRequestHasCredits(request),@"malformed request does not match");
    Check(!JPTRequestHasCredits([NSData data]),@"empty request does not match");
    Check(JPTNativeCreditsResponse(nil)==nil,@"nil response retained");
    printf("%d checks passed\n",passed);
} return 0; }
