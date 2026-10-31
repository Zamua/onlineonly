#import "OODomain.h"

NS_ASSUME_NONNULL_BEGIN

// The JSON shape of a result: the CLI's --json and the MCP tools' structuredContent both emit it.
@protocol OOJSON <NSObject>
- (NSDictionary *)JSONObject;
@end

// {"results": [...]}, the envelope around every result list.
NSDictionary *OOResultsJSON(NSArray<id<OOJSON>> *results);

@class OOListing;

// One path's status, or why it could not be read. JSON {path, status} or {path, error}, plus the
// listing of a folder read with its children.
@interface OOStatusReport : NSObject <OOJSON>
+ (instancetype)path:(NSString *)path status:(OOStatus)status;
+ (instancetype)path:(NSString *)path status:(OOStatus)status children:(OOListing *)children;
+ (instancetype)path:(NSString *)path error:(NSString *)error;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString *path;
@property(readonly) OOStatus status;  // meaningful only when error is nil
@property(readonly, nullable) NSString *error;
@property(readonly, nullable) OOListing *children;
@end

// A folder entry. JSON: its report plus {name, directory}.
@interface OOEntry : NSObject <OOJSON>
+ (instancetype)name:(NSString *)name directory:(BOOL)directory report:(OOStatusReport *)report;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString *name;
@property(readonly) BOOL directory;
@property(readonly) OOStatusReport *report;
@end

// A folder's visible entries, or why it could not be listed.
@interface OOListing : NSObject
+ (instancetype)entries:(NSArray<OOEntry *> *)entries truncated:(BOOL)truncated;
+ (instancetype)error:(NSString *)error;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSArray<OOEntry *> *entries;  // empty when error is set
@property(readonly) BOOL truncated;               // stopped at the limit
@property(readonly, nullable) NSString *error;
@end

typedef NS_ENUM(NSInteger, OOOutcome) {
  OOOutcomeRequested,  // Dropbox accepted the request; not waited on
  OOOutcomeDone,       // waited, and the path reached the target state
  OOOutcomePending,    // waited until the timeout without reaching it
  OOOutcomeAlready,    // already in the target state
  OOOutcomeFailed,     // see error
};

NSString *OOOutcomeName(OOOutcome outcome);

// One path's outcome from an apply call. JSON {path, result, status?, error?}: status is the
// last one Dropbox reported, absent when the path failed before any was read.
@interface OOApplyResult : NSObject <OOJSON>
+ (instancetype)path:(NSString *)path
             outcome:(OOOutcome)outcome
              status:(OOStatus)status
               error:(nullable NSString *)error;
+ (instancetype)path:(NSString *)path failure:(NSString *)error;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString *path;
@property(readonly) OOOutcome outcome;
@property(readonly) BOOL hasStatus;
@property(readonly) OOStatus status;  // meaningful only when hasStatus
@property(readonly, nullable) NSString *error;
@end

NS_ASSUME_NONNULL_END
