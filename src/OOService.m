#import "OOService.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

NSString *const OOResultRequested = @"requested";
NSString *const OOResultDone = @"done";
NSString *const OOResultPending = @"pending";
NSString *const OOResultAlready = @"already";
NSString *const OOResultFailed = @"failed";

NSString *OOResolvePath(NSString *path, NSString **error) {
  char buf[PATH_MAX];
  if (!realpath(path.stringByExpandingTildeInPath.fileSystemRepresentation, buf)) {
    if (error) *error = @(strerror(errno));
    return nil;
  }
  return @(buf);
}

@interface OOJob : NSObject
@property NSMutableDictionary *result;
@property(nullable) NSDate *sentAt;
@end

@implementation OOJob
@end

@implementation OOService {
  id<OOBackend> _backend;
}

- (instancetype)initWithBackend:(id<OOBackend>)backend {
  if ((self = [super init])) {
    _backend = backend;
    _pollInterval = 1;
    _resendInterval = 15;
    _settleTimeout = 30;
  }
  return self;
}

- (NSDictionary *)statusOf:(NSString *)path {
  NSString *err;
  NSString *p = OOResolvePath(path, &err);
  if (!p) return @{@"path": path, @"error": err};
  int status = [_backend statusOf:p error:&err];
  if (status == OOStatusNoReply) return @{@"path": p, @"error": err};
  return @{@"path": p, @"status": OOStatusName(status)};
}

- (NSArray<NSDictionary *> *)childrenOf:(NSString *)dir
                                  limit:(NSUInteger)limit
                              truncated:(BOOL *)truncated
                                  error:(NSString **)error {
  NSString *p = OOResolvePath(dir, error);
  if (!p) return nil;
  NSError *e;
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:&e];
  if (!names) {
    if (error) *error = e.localizedDescription;
    return nil;
  }
  if (truncated) *truncated = NO;
  NSMutableArray *out = [NSMutableArray new];
  for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
    // Dot files and the Finder's "Icon\r" folder-icon file are not user content.
    if ([name hasPrefix:@"."] || [name isEqualToString:@"Icon\r"]) continue;
    if (out.count == limit) {
      if (truncated) *truncated = YES;
      break;
    }
    NSString *child = [p stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir];
    [out addObject:@{
      @"path": child,
      @"name": name,
      @"directory": @(isDir),
      @"status": OOStatusName([_backend statusOf:child error:NULL]),
    }];
  }
  return out;
}

- (NSArray<NSDictionary *> *)apply:(OOTarget)target
                             paths:(NSArray<NSString *> *)paths
                              wait:(BOOL)wait
                           timeout:(NSTimeInterval)timeout {
  NSString *verb = OOTargetVerb(target);
  OOStatus want = OOTargetStatus(target);
  NSMutableArray<NSMutableDictionary *> *results = [NSMutableArray new];
  NSMutableArray<OOJob *> *jobs = [NSMutableArray new];

  for (NSString *path in paths) {
    NSString *err;
    NSString *p = OOResolvePath(path, &err);
    NSMutableDictionary *r = [@{@"path": p ?: path} mutableCopy];
    [results addObject:r];
    if (p) {
      OOJob *job = [OOJob new];
      job.result = r;
      [jobs addObject:job];
    } else {
      r[@"result"] = OOResultFailed;
      r[@"error"] = err;
    }
  }

  // Dropbox drops a request for a path it is still syncing, so a request is held until the
  // path settles, and re-sent if a settled path has not moved after resendInterval.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait ? timeout : MIN(timeout, _settleTimeout)];
  while (jobs.count) {
    for (OOJob *job in [jobs copy]) {
      NSMutableDictionary *r = job.result;
      NSString *err;
      int status = [_backend statusOf:r[@"path"] error:&err];
      r[@"status"] = OOStatusName(status);
      if (status == OOStatusNoReply) {
        r[@"result"] = OOResultFailed;
        r[@"error"] = err;
      } else if (status == want) {
        r[@"result"] = job.sentAt ? OOResultDone : OOResultAlready;
      } else if (status == OOStatusSyncing ||
                 (job.sentAt && -job.sentAt.timeIntervalSinceNow < _resendInterval)) {
        continue;
      } else {
        // Dropbox offers only the verbs that apply to the path's current state. No answer at
        // all is a failed request, not a verb it declined to offer.
        NSDictionary *verbs = [_backend verbsFor:r[@"path"] error:&err];
        NSString *instance = verbs[verb];
        if (!verbs) {
          if (job.sentAt) continue;
          r[@"result"] = OOResultFailed;
          r[@"error"] = err;
        } else if (!instance) {
          if (job.sentAt) continue;
          r[@"result"] = OOResultFailed;
          r[@"error"] = status == OOStatusNone ? @"not in a Dropbox folder"
                                               : [NSString stringWithFormat:@"Dropbox does not offer %@ for this path", OOTargetTitle(target)];
        } else if (![_backend perform:verb instance:instance path:r[@"path"]]) {
          r[@"result"] = OOResultFailed;
          r[@"error"] = @"no reply from Dropbox";
        } else {
          job.sentAt = [NSDate date];
          if (wait) continue;
          r[@"result"] = OOResultRequested;
        }
      }
      [jobs removeObject:job];
    }
    if (!jobs.count) break;
    if (deadline.timeIntervalSinceNow <= 0) {
      for (OOJob *job in jobs) {
        job.result[@"result"] = OOResultPending;
        if (!job.sentAt) job.result[@"error"] = @"still syncing; not requested yet";
      }
      break;
    }
    [NSThread sleepForTimeInterval:MIN(_pollInterval, MAX(deadline.timeIntervalSinceNow, 0))];
  }
  return results;
}

@end
