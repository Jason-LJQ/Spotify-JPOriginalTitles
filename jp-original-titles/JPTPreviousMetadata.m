// Tracks verified previous names independently from the replacement-name cache.
#ifndef JPT_PREVIOUS_METADATA
#define JPT_PREVIOUS_METADATA
#include "JPTStorage.m"
static NSString *const kJPTPreviousMetadataKey = @"JPOriginalTitlesCreditsPreviousMetadataV1";
static NSMutableDictionary *gJPTPreviousMetadataRecords;

static NSObject *JPTPreviousLock(void) {
    return JPTStorageLock();
}

static BOOL JPTPreviousHasText(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 4096
        && [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0;
}

static BOOL JPTPreviousValidURI(id uri) {
    return [uri isKindOfClass:NSString.class] && [uri hasPrefix:@"spotify:track:"] && [uri length] <= 128;
}

static void JPTPreviousLoadLocked(void) {
    if (gJPTPreviousMetadataRecords) return;
    gJPTPreviousMetadataRecords = JPTStorageLoad(YES);
}

static NSUInteger JPTPreviousRecordCount(void) {
    @synchronized (JPTPreviousLock()) { JPTPreviousLoadLocked(); return gJPTPreviousMetadataRecords.count; }
}

static NSDictionary *JPTPreviousFields(NSString *uri) {
    if (!JPTPreviousValidURI(uri)) return @{};
    @synchronized (JPTPreviousLock()) {
        JPTPreviousLoadLocked();
        NSDictionary *record = gJPTPreviousMetadataRecords[uri];
        NSDictionary *fields = [record[@"fields"] isKindOfClass:NSDictionary.class] ? record[@"fields"] : nil;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"title", @"artists", @"album"]) {
            NSDictionary *pair = [fields[key] isKindOfClass:NSDictionary.class] ? fields[key] : nil;
            NSString *old = pair[@"old"], *now = pair[@"new"];
            if (JPTPreviousHasText(old) && JPTPreviousHasText(now) && ![old isEqualToString:now]) result[key] = old;
        }
        return [result copy];
    }
}

// All contributor names must be present; partial lists are not reliable originals.
static NSDictionary *JPTPreviousParseValue(const uint8_t *p, size_t len, BOOL identity, BOOL search) {
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    NSMutableArray *artists = [NSMutableArray array];
    BOOL completeArtists = YES;
    JPTReader r = JPTReaderMake(p, len); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.wire != 2) continue;
        if (f.field == 2) {
            NSString *title = JPTString(&f);
            if (title) names[@"title"] = title;
        } else if ((identity && f.field == 4) || (!identity && !search && f.field == 3)) {
            if (!JPTIsMessage(f.data, f.len)) return nil;
            NSString *album = JPTSubString(&f, identity ? 1 : 2);
            if (album) names[@"album"] = album;
        } else if ((identity && f.field == 5) || (!identity && !search && f.field == 4)) {
            if (!JPTIsMessage(f.data, f.len)) return nil;
            NSString *artist = JPTSubString(&f, identity ? 1 : 2);
            if (!JPTPreviousHasText(artist)) completeArtists = NO;
            else [artists addObject:artist];
        } else if (search && f.field == 5) {
            JPTReader tr = JPTReaderMake(f.data, f.len); JPTField tf; BOOL tok;
            while (JPTNext(&tr, &tf, &tok)) {
                if (tf.wire != 2 || (tf.field != 3 && tf.field != 4)) continue;
                if (!JPTIsMessage(tf.data, tf.len)) return nil;
                NSString *name = JPTSubString(&tf, 2);
                if (tf.field == 3) { if (name) names[@"album"] = name; }
                else if (!JPTPreviousHasText(name)) completeArtists = NO;
                else [artists addObject:name];
            }
            if (!tok) return nil;
        }
    }
    if (!ok) return nil;
    if (!completeArtists) names[@"artists"] = [NSNull null];
    else if (artists.count) names[@"artists"] = [artists componentsJoinedByString:@", "];
    return names;
}

static void JPTPreviousAddCarrier(NSMutableDictionary *carriers, NSString *key, NSDictionary *names) {
    if (!key || !names) return;
    NSMutableArray *entries = carriers[key];
    if (!entries) carriers[key] = entries = [NSMutableArray array];
    [entries addObject:names];
}

static NSDictionary *JPTPreviousResponseCarriers(NSData *body) {
    if (!body.length) return nil;
    NSMutableDictionary *carriers = [NSMutableDictionary dictionary];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        uint64_t kind = JPTArrayKind(&f);
        if (kind != kKindTrackV4 && kind != kKindIdentityTrait) continue;
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            if (af.field != 3 || af.wire != 2) continue;
            NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
            if (!JPTParseEntry(&af, &uri, &status, &value) || status != 200 || ![uri hasPrefix:@"spotify:track:"]) continue;
            NSString *key = [NSString stringWithFormat:@"%llu|%@", kind, uri];
            NSDictionary *names = JPTPreviousParseValue(value.data, value.len, kind == kKindIdentityTrait, NO);
            // Keep a placeholder so a bad duplicate cannot shift positional matching.
            JPTPreviousAddCarrier(carriers, key, names ?: @{});
        }
        if (!aok) return nil;
    }
    return ok ? carriers : nil;
}

static NSDictionary *JPTPreviousSearchCarriers(NSData *body) {
    if (!body.length || !JPTIsMessage(body.bytes, body.length)) return nil;
    NSMutableDictionary *carriers = [NSMutableDictionary dictionary];
    JPTWalkSearch(body.bytes, body.length, 0, ^NSData *(NSString *uri, const uint8_t *p, size_t len) {
        if ([uri hasPrefix:@"spotify:track:"])
            JPTPreviousAddCarrier(carriers, [@"search|" stringByAppendingString:uri], JPTPreviousParseValue(p, len, NO, YES) ?: @{});
        return nil;
    });
    return carriers;
}

static BOOL JPTPreviousCompare(NSDictionary *before, NSDictionary *after) {
    if (!before || !after) { @synchronized (JPTStorageLock()) { return JPTStorageCommit(@[]); } }
    NSMutableDictionary *observations = [NSMutableDictionary dictionary];
    for (NSString *carrier in before) {
        NSArray *oldEntries = before[carrier], *newEntries = after[carrier];
        if (!newEntries || oldEntries.count != newEntries.count) continue;
        NSRange separator = [carrier rangeOfString:@"|"];
        if (separator.location == NSNotFound) continue;
        NSString *uri = [carrier substringFromIndex:separator.location + 1];
        NSInteger rank = [carrier hasPrefix:@"178|"] ? 3 : [carrier hasPrefix:@"10|"] ? 2 : 1;
        NSMutableDictionary *fields = observations[uri];
        if (!fields) observations[uri] = fields = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < oldEntries.count; i++) {
            for (NSString *field in @[@"title", @"artists", @"album"]) {
                id old = oldEntries[i][field], now = newEntries[i][field];
                if (!old && !now) continue;
                NSMutableArray *items = fields[field];
                if (!items) fields[field] = items = [NSMutableArray array];
                [items addObject:@{@"old": old ?: NSNull.null, @"new": now ?: NSNull.null, @"rank": @(rank)}];
            }
        }
    }
    @synchronized (JPTPreviousLock()) {
        JPTPreviousLoadLocked();
        NSMutableArray *changes = [NSMutableArray array];
        NSMutableDictionary *updates = [NSMutableDictionary dictionary];
        for (NSString *uri in observations) {
            if (!JPTPreviousValidURI(uri)) continue;
            NSDictionary *existing = gJPTPreviousMetadataRecords[uri];
            NSMutableDictionary *fields = [existing[@"fields"] mutableCopy] ?: [NSMutableDictionary dictionary];
            BOOL changedRecord = NO;
            for (NSString *field in observations[uri]) {
                NSArray *items = observations[uri][field];
                NSInteger rank = 0;
                for (NSDictionary *item in items) rank = MAX(rank, [item[@"rank"] integerValue]);
                NSDictionary *previous = fields[field];
                // Credits uses IdentityTrait. Lower-priority search/track strings must not overwrite it.
                if (previous && [previous[@"rank"] integerValue] > rank) continue;
                id final = nil;
                NSString *old = nil;
                BOOL conflict = NO;
                for (NSDictionary *item in items) {
                    if ([item[@"rank"] integerValue] != rank) continue;
                    id current = item[@"new"];
                    if (final && ![final isEqual:current]) conflict = YES;
                    final = current;
                    if (JPTPreviousHasText(item[@"old"]) && JPTPreviousHasText(current)
                        && ![item[@"old"] isEqual:current]) {
                        if (old && ![old isEqual:item[@"old"]]) conflict = YES;
                        old = item[@"old"];
                    }
                }
                NSDictionary *replacement = nil;
                if (!conflict && JPTPreviousHasText(final)) {
                    if (old) {
                        // A second pass may start from our last delivered name; retain the earlier raw name.
                        NSString *raw = [old isEqual:previous[@"new"]] ? previous[@"old"] : old;
                        if (![raw isEqual:final]) replacement = @{@"old": raw, @"new": final, @"rank": @(rank)};
                    } else if ([final isEqual:previous[@"new"]])
                        replacement = @{@"old": previous[@"old"], @"new": final, @"rank": @(rank)};
                }
                if ([replacement isEqual:previous] || (!replacement && !previous)) continue;
                NSMutableDictionary *change = [@{@"uri": uri, @"field": field} mutableCopy];
                if (replacement) { fields[field] = replacement; change[@"pair"] = replacement; }
                else [fields removeObjectForKey:field];
                [changes addObject:change]; changedRecord = YES;
            }
            if (!changedRecord) continue;
            updates[uri] = fields.count ? @{@"fields": fields} : (id)NSNull.null;
        }
        if (!JPTStorageCommit(changes)) return NO;
        for (NSString *uri in updates) {
            if (updates[uri] == NSNull.null) [gJPTPreviousMetadataRecords removeObjectForKey:uri];
            else gJPTPreviousMetadataRecords[uri] = updates[uri];
        }
        return YES;
    }
}

static BOOL JPTCapturePreviousResponse(NSData *before, NSData *after) {
    if (!after) return YES;
    return JPTPreviousCompare(JPTPreviousResponseCarriers(before), JPTPreviousResponseCarriers(after));
}

static BOOL JPTCapturePreviousSearch(NSData *before, NSData *after) {
    if (!after) return YES;
    return JPTPreviousCompare(JPTPreviousSearchCarriers(before), JPTPreviousSearchCarriers(after));
}

// Display only: stored pairs keep raw names, so the bar is added after capture to titles matching a stored new name.
static NSString *JPTPresentedTitle(NSString *uri, NSString *title) {
    if (!JPTPreviousValidURI(uri) || !JPTPreviousHasText(title)) return nil;
    @synchronized (JPTPreviousLock()) {
        JPTPreviousLoadLocked();
        NSDictionary *record = gJPTPreviousMetadataRecords[uri];
        NSDictionary *fields = [record[@"fields"] isKindOfClass:NSDictionary.class] ? record[@"fields"] : nil;
        NSDictionary *pair = [fields[@"title"] isKindOfClass:NSDictionary.class] ? fields[@"title"] : nil;
        NSString *old = pair[@"old"];
        if (!JPTPreviousHasText(old) || ![pair[@"new"] isEqual:title] || [old isEqual:title]) return nil;
        return [NSString stringWithFormat:@"%@\uFF5C%@", title, old];
    }
}

static NSData *JPTPresentTitleValue(NSString *uri, const uint8_t *p, size_t len) {
    JPTReader r = JPTReaderMake(p, len); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) {
        if (f.field != 2 || f.wire != 2) continue;
        NSString *title = JPTPresentedTitle(uri, JPTString(&f));
        return title ? JPTReplaceString(p, len, 2, title, NULL) : nil;
    }
    return nil;
}

// TRACK_V4 and IdentityTrait carry the rewritten track titles; nil when nothing changes or parsing fails.
static NSData *JPTPresentResponseTitles(NSData *body) {
    NSMutableData *out = [NSMutableData dataWithCapacity:body.length + 256];
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok, changed = NO;
    while (JPTNext(&r, &f, &ok)) {
        uint64_t kind = (f.field == 2 && f.wire == 2) ? JPTArrayKind(&f) : 0;
        if (kind != kKindTrackV4 && kind != kKindIdentityTrait) { JPTWriteRaw(out, &f); continue; }
        NSMutableData *array = [NSMutableData dataWithCapacity:f.len + 256];
        JPTReader ar = JPTReaderMake(f.data, f.len); JPTField af; BOOL aok;
        while (JPTNext(&ar, &af, &aok)) {
            NSString *uri = nil; uint64_t status = 0; JPTField value = {0};
            NSData *entry = nil;
            if (af.field == 3 && af.wire == 2 && JPTParseEntry(&af, &uri, &status, &value) && status == 200) {
                NSData *presented = JPTPresentTitleValue(uri, value.data, value.len);
                entry = presented ? JPTRewriteEntry(&af, presented) : nil;
            }
            if (entry) { JPTWriteData(array, 3, entry); changed = YES; }
            else JPTWriteRaw(array, &af);
        }
        if (!aok) return nil;
        JPTWriteData(out, 2, array);
    }
    return ok && changed ? out : nil;
}

static NSData *JPTPresentSearchTitles(NSData *body) {
    if (!JPTIsMessage(body.bytes, body.length)) return nil;
    return JPTWalkSearch(body.bytes, body.length, 0, ^NSData *(NSString *uri, const uint8_t *p, size_t len) {
        return [uri hasPrefix:@"spotify:track:"] ? JPTPresentTitleValue(uri, p, len) : nil;
    });
}
#endif
