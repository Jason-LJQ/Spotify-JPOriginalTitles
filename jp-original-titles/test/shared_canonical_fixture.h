// Synthetic five-track release with three shared and two direct canonical paths.
static NSString *SharedURI(NSString *kind, NSUInteger value) {
    uint8_t gid[16]={0}; gid[14]=(uint8_t)(value>>8); gid[15]=(uint8_t)value;
    return [NSString stringWithFormat:@"spotify:%@:%@",kind,JPTBase62(gid,16)];
}
static NSMutableDictionary *SharedCatalog(void) {
    NSMutableDictionary *all=[NSMutableDictionary dictionary];
    NSString *source=SharedURI(@"album",101), *original=SharedURI(@"album",102), *other=SharedURI(@"album",103);
    NSMutableSet *sources=[NSMutableSet set], *originals=[NSMutableSet set];
    for (NSUInteger i=1;i<=5;i++) {
        NSString *a=SharedURI(@"track",i), *b=SharedURI(@"track",10+i);
        JPTTrackInfo *own=[JPTTrackInfo new], *candidate=[JPTTrackInfo new];
        own.name=@"Latin title";own.albumName=@"Latin EP";own.albumURI=source;
        candidate.name=[NSString stringWithFormat:@"日本語 %lu",(unsigned long)i];candidate.albumName=@"日本語 EP";candidate.albumURI=original;
        own.isrc=candidate.isrc=[NSString stringWithFormat:@"RECORDING%lu",(unsigned long)i];
        own.duration=candidate.duration=200000+i;own.disc=candidate.disc=1;own.number=candidate.number=i;
        own.canonicalURI=i<=3?SharedURI(@"track",6):b;
        candidate.canonicalURI=i<=3?SharedURI(@"track",6):a;
        own.performanceLanguages=candidate.performanceLanguages=@[@"ja"];
        own.artists=candidate.artists=[NSMutableArray array];
        all[a]=own;all[b]=candidate;[sources addObject:a];[originals addObject:b];
    }
    JPTTrackInfo *target=[JPTTrackInfo new];target.name=@"Latin canonical";target.albumURI=other;all[SharedURI(@"track",6)]=target;
    for (NSArray *row in @[@[source,@"Latin EP",sources],@[original,@"日本語 EP",originals],@[other,@"Other release",[NSSet set]]]) {
        JPTAlbumInfo *album=[JPTAlbumInfo new];album.name=row[1];album.canonicalURI=row[0];album.trackURIs=row[2];all[row[0]]=album;
    }
    return all;
}
