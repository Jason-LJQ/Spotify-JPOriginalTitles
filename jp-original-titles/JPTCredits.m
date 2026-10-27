// Renames same-URI contributors and adds previous metadata to the existing Credits Contributor/RoleGroup schema.
#ifndef JPT_NATIVE_CREDITS
#define JPT_NATIVE_CREDITS
static const uint64_t kJPTNativeCreditsKind = 186;

static BOOL JPTRequestHasCredits(NSData *body) {
    if (!body.length) return NO;
    BOOL found = NO;
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        JPTReader er = JPTReaderMake(f.data, f.len); JPTField ef; BOOL eok;
        while (JPTNext(&er, &ef, &eok)) {
            if (ef.field != 2 || ef.wire != 2) continue;
            JPTReader qr = JPTReaderMake(ef.data, ef.len); JPTField qf; BOOL qok;
            while (JPTNext(&qr, &qf, &qok))
                if (qf.field == 1 && qf.wire == 0 && qf.varint == kJPTNativeCreditsKind) found = YES;
            if (!qok) return NO;
        }
        if (!eok) return NO;
    }
    return ok && found;
}

// Reject ambiguous singular wrappers before using the shared entry rewriter.
static BOOL JPTNativeCreditsEntryValid(const JPTField *entry) {
    JPTReader r = JPTReaderMake(entry->data, entry->len); JPTField f; BOOL ok;
    NSUInteger headers = 0, uris = 0, anys = 0, values = 0;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field == 2) { if (f.wire != 2 || ++uris > 1 || !JPTString(&f)) return NO; }
        if (f.field != 1 && f.field != 3) continue;
        if (f.wire != 2) return NO;
        if (f.field == 1 ? ++headers > 1 : ++anys > 1) return NO;
        JPTReader sr = JPTReaderMake(f.data, f.len); JPTField sf; BOOL sok;
        NSUInteger statuses = 0;
        while (JPTNext(&sr, &sf, &sok)) {
            if (f.field == 1 && sf.field == 1 && (sf.wire != 0 || ++statuses > 1)) return NO;
            if (f.field == 3 && sf.field == 2 && (sf.wire != 2 || ++values > 1)) return NO;
        }
        if (!sok) return NO;
    }
    return ok && headers == 1 && uris == 1 && anys == 1 && values == 1;
}

// `artistNames` maps artist URIs to delivered IdentityTrait names; `combine` shows them as new｜old.
static NSData *JPTNativeCreditsValue(const JPTField *value, NSDictionary *previous, NSDictionary *artistNames, BOOL combine) {
    if (!previous.count && !artistNames.count) return nil;
    NSMutableSet *existing = [NSMutableSet set];
    NSMutableData *out = [NSMutableData dataWithCapacity:value->len + 256];
    BOOL changed = NO;
    JPTReader r = JPTReaderMake(value->data, value->len); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 1) { JPTWriteRaw(out, &f); continue; }
        if (f.wire != 2) return nil;
        NSString *name = nil, *group = nil, *role = nil, *uri = nil;
        BOOL navigable = NO;
        NSUInteger names = 0, groups = 0, roles = 0;
        JPTReader cr = JPTReaderMake(f.data, f.len); JPTField cf; BOOL cok;
        while (JPTNext(&cr, &cf, &cok)) {
            if (cf.field == 1) {
                if (cf.wire != 2 || ++names > 1 || !(name = JPTString(&cf))) return nil;
            } else if (cf.field == 2) {
                if (cf.wire != 2 || ++roles > 1 || !(role = JPTString(&cf))) return nil;
            } else if (cf.field == 3 || cf.field == 5) {
                navigable = YES;
                if (cf.field == 3 && cf.wire == 2) uri = JPTString(&cf);
            }
            else if (cf.field == 6) {
                if (cf.wire != 2 || ++groups > 1) return nil;
                JPTReader gr = JPTReaderMake(cf.data, cf.len); JPTField gf; BOOL gok;
                NSUInteger groupNames = 0;
                while (JPTNext(&gr, &gf, &gok)) {
                    if (gf.field == 1 && (gf.wire != 2 || ++groupNames > 1 || !(group = JPTString(&gf)))) return nil;
                }
                if (!gok) return nil;
            }
        }
        if (!cok) return nil;
        if (!navigable && name && role && [group isEqualToString:@"Original Metadata"]) [existing addObject:@[role, name]];
        // Only the display name changes; role, URI, links and group stay as Spotify sent them.
        NSString *renamed = uri ? artistNames[uri] : nil;
        if (renamed && combine) renamed = [NSString stringWithFormat:@"%@\uFF5C%@", renamed, name];
        NSData *contributor = name && JPTUpgradesName(name, renamed) ? JPTReplaceString(f.data, f.len, 1, renamed, NULL) : nil;
        if (contributor) { JPTWriteData(out, 1, contributor); changed = YES; }
        else JPTWriteRaw(out, &f);
    }
    if (!ok) return nil;
    NSArray *keys = @[@"title", @"artists", @"album"];
    NSArray *labels = @[@"Title", @"Artist", @"Album"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *name = previous[keys[i]], *label = labels[i];
        if (!JPTPreviousHasText(name) || [existing containsObject:@[label, name]]) continue;
        NSMutableData *group = [NSMutableData data], *contributor = [NSMutableData data];
        JPTWriteString(group, 1, @"Original Metadata");
        JPTWriteString(contributor, 1, name);
        JPTWriteString(contributor, 2, label);
        JPTWriteData(contributor, 6, group);
        JPTWriteData(out, 1, contributor);
        changed = YES;
    }
    return changed ? out : nil;
}

static NSData *JPTNativeCreditsResponse(NSData *body, BOOL combine) {
    if (!body.length) return body;
    NSDictionary *artistNames = JPTCreditArtistNamesSnapshot();
    NSMutableData *out = [NSMutableData dataWithCapacity:body.length];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    BOOL changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) { JPTWriteRaw(out, &f); continue; }
        // Parse the complete array before committing changes to it.
        JPTReader kr = JPTReaderMake(f.data, f.len); JPTField kf; BOOL kok;
        uint64_t kind = 0; NSUInteger kinds = 0;
        while (JPTNext(&kr, &kf, &kok)) {
            if (kf.field == 2) {
                if (kf.wire != 0) { kinds = 2; continue; }
                kinds++; kind = kf.varint;
            }
        }
        if (!kok) return body;
        if (kinds != 1 || kind != kJPTNativeCreditsKind) { JPTWriteRaw(out, &f); continue; }
        NSMutableData *array = [NSMutableData data]; BOOL arrayChanged = NO;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            NSData *rewritten = nil;
            if (af.field == 3 && af.wire == 2 && JPTNativeCreditsEntryValid(&af)) {
                NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
                if (JPTParseEntry(&af, &uri, &status, &value) && status == 200 && [uri hasPrefix:@"spotify:track:"]) {
                    NSData *newValue = JPTNativeCreditsValue(&value, JPTPreviousFields(uri), artistNames, combine);
                    if (newValue) rewritten = JPTRewriteEntry(&af, newValue);
                }
            }
            if (rewritten) { JPTWriteData(array, 3, rewritten); arrayChanged = YES; }
            else JPTWriteRaw(array, &af);
        }
        if (!aok) return body;
        if (arrayChanged) { JPTWriteData(out, 2, array); changed = YES; }
        else JPTWriteRaw(out, &f);
    }
    return ok && changed ? out : body;
}
// Refresh only Credits validators while preserving unrelated metadata validators.
static NSData *JPTCreditsFreshBody(NSData *body) {
    NSMutableData *out = [NSMutableData data];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) { JPTWriteRaw(out, &f); continue; }
        NSMutableData *entity = [NSMutableData data]; BOOL entityChanged = NO;
        JPTReader er = JPTReaderMake(f.data, f.len); JPTField ef; BOOL eok;
        while (JPTNext(&er, &ef, &eok)) {
            if (ef.field != 2 || ef.wire != 2) { JPTWriteRaw(entity, &ef); continue; }
            JPTReader qr = JPTReaderMake(ef.data, ef.len); JPTField qf; BOOL qok;
            uint64_t kind = 0;
            while (JPTNext(&qr, &qf, &qok)) if (qf.field == 1 && qf.wire == 0) kind = qf.varint;
            if (!qok) return nil;
            if (kind != kJPTNativeCreditsKind) { JPTWriteRaw(entity, &ef); continue; }
            NSMutableData *query = [NSMutableData data]; BOOL queryChanged = NO;
            qr = JPTReaderMake(ef.data, ef.len);
            while (JPTNext(&qr, &qf, &qok)) {
                if (qf.field == 2 && qf.wire == 2) queryChanged = YES;
                else JPTWriteRaw(query, &qf);
            }
            if (!qok) return nil;
            if (queryChanged) { JPTWriteData(entity, 2, query); entityChanged = YES; }
            else JPTWriteRaw(entity, &ef);
        }
        if (!eok) return nil;
        if (entityChanged) { JPTWriteData(out, 2, entity); changed = YES; }
        else JPTWriteRaw(out, &f);
    }
    return ok && changed ? out : nil;
}

#endif
