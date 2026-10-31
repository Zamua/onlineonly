#import "OOResult.h"

NSDictionary *OOResultsJSON(NSArray<id<OOJSON>> *results) {
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:results.count];
  for (id<OOJSON> r in results) [out addObject:r.JSONObject];
  return @{@"results": out};
}

@implementation OOStatusReport

- (instancetype)initWithPath:(NSString *)path status:(OOStatus)status error:(NSString *)error children:(OOListing *)children {
  if ((self = [super init])) {
    _path = [path copy];
    _status = status;
    _error = [error copy];
    _children = children;
  }
  return self;
}

+ (instancetype)path:(NSString *)path status:(OOStatus)status {
  return [[self alloc] initWithPath:path status:status error:nil children:nil];
}

+ (instancetype)path:(NSString *)path status:(OOStatus)status children:(OOListing *)children {
  return [[self alloc] initWithPath:path status:status error:nil children:children];
}

+ (instancetype)path:(NSString *)path error:(NSString *)error {
  return [[self alloc] initWithPath:path status:OOStatusNone error:error children:nil];
}

- (NSDictionary *)JSONObject {
  NSMutableDictionary *d = [@{@"path": _path} mutableCopy];
  if (_error) d[@"error"] = _error;
  else d[@"status"] = OOStatusName(_status);
  if (_children.error) {
    d[@"children_error"] = _children.error;
  } else if (_children) {
    d[@"children"] = OOResultsJSON(_children.entries)[@"results"];
    if (_children.truncated) d[@"children_truncated"] = @YES;
  }
  return d;
}

@end

@implementation OOEntry

- (instancetype)initWithName:(NSString *)name directory:(BOOL)directory report:(OOStatusReport *)report {
  if ((self = [super init])) {
    _name = [name copy];
    _directory = directory;
    _report = report;
  }
  return self;
}

+ (instancetype)name:(NSString *)name directory:(BOOL)directory report:(OOStatusReport *)report {
  return [[self alloc] initWithName:name directory:directory report:report];
}

- (NSDictionary *)JSONObject {
  NSMutableDictionary *d = [_report.JSONObject mutableCopy];
  d[@"name"] = _name;
  d[@"directory"] = @(_directory);
  return d;
}

@end

@implementation OOListing

- (instancetype)initWithEntries:(NSArray<OOEntry *> *)entries truncated:(BOOL)truncated error:(NSString *)error {
  if ((self = [super init])) {
    _entries = [entries copy];
    _truncated = truncated;
    _error = [error copy];
  }
  return self;
}

+ (instancetype)entries:(NSArray<OOEntry *> *)entries truncated:(BOOL)truncated {
  return [[self alloc] initWithEntries:entries truncated:truncated error:nil];
}

+ (instancetype)error:(NSString *)error {
  return [[self alloc] initWithEntries:@[] truncated:NO error:error];
}

@end

NSString *OOOutcomeName(OOOutcome outcome) {
  switch (outcome) {
    case OOOutcomeRequested: return @"requested";
    case OOOutcomeDone: return @"done";
    case OOOutcomePending: return @"pending";
    case OOOutcomeAlready: return @"already";
    case OOOutcomeFailed: return @"failed";
  }
  return [NSString stringWithFormat:@"unknown(%ld)", (long)outcome];
}

@implementation OOApplyResult

- (instancetype)initWithPath:(NSString *)path outcome:(OOOutcome)outcome hasStatus:(BOOL)hasStatus status:(OOStatus)status error:(NSString *)error {
  if ((self = [super init])) {
    _path = [path copy];
    _outcome = outcome;
    _hasStatus = hasStatus;
    _status = status;
    _error = [error copy];
  }
  return self;
}

+ (instancetype)path:(NSString *)path outcome:(OOOutcome)outcome status:(OOStatus)status error:(NSString *)error {
  return [[self alloc] initWithPath:path outcome:outcome hasStatus:YES status:status error:error];
}

+ (instancetype)path:(NSString *)path failure:(NSString *)error {
  return [[self alloc] initWithPath:path outcome:OOOutcomeFailed hasStatus:NO status:OOStatusNone error:error];
}

- (NSDictionary *)JSONObject {
  NSMutableDictionary *d = [@{@"path": _path, @"result": OOOutcomeName(_outcome)} mutableCopy];
  if (_hasStatus) d[@"status"] = OOStatusName(_status);
  if (_error) d[@"error"] = _error;
  return d;
}

@end
