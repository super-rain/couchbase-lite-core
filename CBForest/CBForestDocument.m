//
//  CBForestDocument.m
//  CBForest
//
//  Created by Jens Alfke on 9/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "CBForestDocument.h"
#import "CBForestPrivate.h"


@implementation CBForestDocument
{
    CBForestDB* _db;
    fdb_doc _info;
    NSString* _docID;
    NSData* _metadata;
    uint64_t _bodyOffset;
}


@synthesize db=_db;


- (id) initWithDB: (CBForestDB*)store docID: (NSString*)docID
{
    NSParameterAssert(store != nil);
    NSParameterAssert(docID != nil);
    self = [super init];
    if (self) {
        _db = store;
        _docID = [docID copy];
        slice idbuf = slicecopy(StringToSlice(docID));
        _info.keylen = idbuf.size;
        _info.key = (void*)idbuf.buf;
        _info.seqnum = kCBForestNoSequence;
    }
    return self;
}


- (id) initWithDB: (CBForestDB*)store
             info: (const fdb_doc*)info
          options: (CBForestContentOptions)options
            error: (NSError**)outError
{
    self = [super init];
    if (self) {
        _db = store;
        _info = *info;
    }
    return self;
}


- (void)dealloc {
    free(_info.key);
    free(_info.body);
    free(_info.meta);
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@]", [self class], _docID];
}


- (BOOL) isEqual: (id)object {
    return [object isKindOfClass: [CBForestDocument class]]
        && _db == [object db]
        && [_docID isEqualToString: [object docID]];
}

- (NSUInteger) hash {
    return _docID.hash;
}


- (NSString*) docID {
    if (!_docID)
        _docID = SliceToString(_info.key, _info.keylen);
    return _docID;
}


- (slice) rawID                     {return (slice){_info.key, _info.keylen};}
- (slice) rawMeta                   {return (slice){_info.meta, _info.metalen};}
- (fdb_doc*) info                   {return &_info;}
- (CBForestSequence) sequence       {return _info.seqnum;}
- (BOOL) exists                     {return _info.seqnum != kCBForestNoSequence;}
- (uint64_t) fileOffset             {return _info.offset;}


- (NSData*) metadata {
    if (!_metadata && _info.meta != NULL) {
        _metadata = [NSData dataWithBytesNoCopy: _info.meta length: _info.metalen
                                   freeWhenDone: YES];
        _info.meta = NULL;
    }
    return _metadata;
}

- (BOOL) reload: (CBForestContentOptions)options error: (NSError **)outError {
    fdb_status status = [_db rawGet: &_info options: options];
    if (status == FDB_RESULT_KEY_NOT_FOUND) {
        _info.seqnum = kCBForestNoSequence;
    } else if (!CheckWithKey(status, _docID, outError)) {
        return NO;
    }
    _metadata = nil; // forget old cached metadata
    return YES;
}


- (UInt64) bodyLength {
    return _info.bodylen;
}


- (NSData*) readBody: (NSError**)outError {
    if (_info.body == NULL) {
        if (_info.offset == 0) {
            if (![self reload: 0 error: outError])
                return nil;
            _metadata = nil;
        } else {
            if (!CheckWithKey([_db rawGet: &_info options: 0], _docID, outError))
                return nil;
        }
    }
    // Rather than copying the body data, just let the NSData adopt it and clear the local ptr.
    // This assumes that the typical client will only read the body once.
    NSData* body = SliceToAdoptingData(_info.body, _info.bodylen);
    _info.body = NULL;
    return body;
}


- (BOOL) writeBody: (NSData*)body metadata: (NSData*)metadata error: (NSError**)outError {
    return [_db inTransaction: ^BOOL{
        fdb_doc newDoc = {
            .key = _info.key,
            .keylen = _info.keylen,
            .meta = (void*)metadata.bytes,
            .metalen = metadata.length,
            .body = (void*)body.bytes,
            .bodylen = body.length,
            .deleted = (body == nil),
        };
        if (![_db rawSet: &newDoc error: outError])
            return NO;
        _metadata = [metadata copy];
        free(_info.meta);
        _info.meta = NULL;
        _info.body = NULL;
        _info.bodylen = newDoc.bodylen;
        _info.seqnum = newDoc.seqnum;
        _info.offset = newDoc.offset;
        return YES;
    }];
}


- (void) asyncWriteBody: (NSData*)body metadata: (NSData*)metadata
             onComplete: (void(^)(CBForestSequence,NSError*))onComplete
{
    [_db asyncSetValue: body
                  meta: metadata
                forKey: SliceToData(_info.key, _info.keylen)
            onComplete: onComplete];
}


- (BOOL) deleteDocument: (NSError**)outError {
    _info.body = NULL;
    _info.bodylen = 0;
    _info.deleted = true;
    if (![_db rawSet: &_info error: outError])
        return NO;
    _info.offset = 0;
    _info.seqnum = kCBForestNoSequence;
    return YES;
}


+ (BOOL) docInfo: (const fdb_doc*)docInfo matchesOptions: (const CBForestEnumerationOptions*)options {
    return YES;
}


@end
