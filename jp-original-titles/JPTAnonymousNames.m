// Fetch the anonymous copy alongside each existing lookup; consume account results first.

static NSDictionary *JPTAnonymousResolvedValues(NSDictionary *primary, NSDictionary *values, NSSet *uris) {
    NSMutableDictionary *all = [primary mutableCopy]; [all addEntriesFromDictionary:values];
    NSMutableDictionary *sources = [primary mutableCopy];
    for (NSString *uri in uris) if ([uri hasPrefix:@"spotify:track:"] && ![primary[uri] name].length && [values[uri] isKindOfClass:JPTTrackInfo.class])
        sources[uri] = JPTMergeInfo(primary[uri], values[uri]);
    NSMutableDictionary *accepted = [NSMutableDictionary dictionary], *resolvedSources = [NSMutableDictionary dictionary];
    for (NSString *uri in uris) {
        if ([uri hasPrefix:@"spotify:album:"]) {
            JPTAlbumInfo *previous = JPTPreferredAlbum(uri, primary), *candidate = JPTPreferredAlbum(uri, all);
            JPTAlbumInfo *source = primary[uri] ?: values[uri];
            if (JPTHasCJK(previous.name) || !JPTHasCJK(candidate.name) || !source) continue;
            JPTAlbumInfo *album = [JPTAlbumInfo new];
            album.name = candidate.name; album.originalTitle = JPTPick(source.originalTitle, candidate.originalTitle);
            album.canonicalURI = source.canonicalURI; album.trackURIs = source.trackURIs; accepted[uri] = album;
        } else if ([uri hasPrefix:@"spotify:track:"]) {
            JPTTrackInfo *source = primary[uri] ?: values[uri];
            JPTTrackInfo *previous = JPTPreferredInfo(uri, primary, primary);
            JPTTrackInfo *preferred = JPTPreferredInfo(uri, sources, all);
            if (!source || !preferred || JPTHasCJK(previous.name) || !JPTHasCJK(preferred.name)) continue;
            resolvedSources[uri] = JPTMergeInfo(source, preferred);
            JPTTrackInfo *original = JPTSelectedOriginal(uri, source, primary, all);
            JPTAlbumInfo *album = all[original.albumURI];
            if (original && album) {
                accepted[original.albumURI] = album;
                for (NSString *track in album.trackURIs) if (all[track]) accepted[track] = all[track];
            }
            if (original && source.canonicalURI && values[source.canonicalURI]) accepted[source.canonicalURI] = values[source.canonicalURI];
        }
    }
    [accepted addEntriesFromDictionary:resolvedSources];
    return accepted;
}

static void JPTStartAnonymousQuery(NSURLRequest *owner, NSData *body, NSSet *batch, NSString *language, BOOL artist) {
    JPTResolution *state = JPTResolutionFor(owner);
    dispatch_group_enter(state.anonymousQueries);
    NSURLRequest *bootstrapOwner = JPTBeginResolution(owner);
    JPTGetAnonymousToken(bootstrapOwner, [[batch.allObjects sortedArrayUsingSelector:@selector(compare:)] firstObject], ^(NSString *token) {
        if (!token) { dispatch_group_leave(state.anonymousQueries); return; }
        NSMutableURLRequest *request = JPTAnonymousRequest(owner.URL, token, nil);
        request.HTTPMethod = @"POST"; request.timeoutInterval = owner.timeoutInterval;
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        NSURLRequest *lookup = JPTBeginResolution(request);
        JPTResolutionFor(lookup).anonymous = YES;
        JPTFetchQueryBatch(lookup, body, batch, language, artist, ^(NSDictionary *values, NSError *error) {
            @synchronized (state) {
                NSMutableDictionary *results = state.anonymousResults[language];
                if (!results) state.anonymousResults[language] = results = [NSMutableDictionary dictionary];
                [results addEntriesFromDictionary:values];
            }
            dispatch_group_leave(state.anonymousQueries);
        });
    });
}

static void JPTFinishAnonymousQueries(NSURLRequest *owner, NSSet *uris, void (^done)(void)) {
    JPTResolution *state = JPTResolutionFor(owner);
    NSDictionary *primary = JPTOriginalSnapshot(), *known = JPTArtistNamesSnapshot();
    BOOL unresolved = NO;
    for (NSString *uri in uris) {
        NSString *name = [uri hasPrefix:@"spotify:artist:"] ? known[uri]
            : [uri hasPrefix:@"spotify:album:"] ? JPTPreferredAlbum(uri, primary).name
            : JPTPreferredInfo(uri, primary, primary).name;
        if (!JPTHasCJK(name)) { unresolved = YES; break; }
    }
    if (!unresolved) { done(); return; }
    dispatch_group_notify(state.anonymousQueries, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *zh, *ja;
        @synchronized (state) {
            zh = [state.anonymousResults[kJPTOriginalLanguage] copy] ?: @{};
            ja = [state.anonymousResults[@"ja"] copy] ?: @{};
        }
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary], *names = [NSMutableDictionary dictionary];
        NSDictionary *known = JPTArtistNamesSnapshot();
        for (NSString *uri in zh) {
            id value = zh[uri];
            if ([value isKindOfClass:JPTTrackInfo.class]) metadata[uri] = value;
            else if (!JPTHasCJK(known[uri]) && JPTHasCJK(value)) names[uri] = value;
        }
        for (NSString *uri in ja) if (!JPTHasCJK(known[uri]) && !names[uri] && JPTJapaneseNameCandidate(ja[uri])) names[uri] = ja[uri];
        JPTCacheOriginals(JPTAnonymousResolvedValues(JPTOriginalSnapshot(), metadata, [NSSet setWithArray:metadata.allKeys]));
        JPTMergeArtistNames(names);
        done();
    });
}
