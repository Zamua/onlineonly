#import "OOService.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

NSString *OOResolvePath(NSString *path, NSString **error) {
  char buf[PATH_MAX];
  if (!realpath(path.stringByExpandingTildeInPath.fileSystemRepresentation, buf)) {
    if (error) *error = @(strerror(errno));
    return nil;
  }
  return @(buf);
}

// One path's progress through apply.
@interface OOJob : NSObject
@property NSString *path;
@property(nullable) OOApplyResult *result;  // set once the outcome is final
@property(nullable) NSDate *sentAt;
@property OOStatus status;  // last read
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

- (OOStatusReport *)reportOfResolved:(NSString *)path {
  OOStatus status;
  NSString *err;
  if (![_backend status:&status of:path error:&err]) return [OOStatusReport path:path error:err];
  return [OOStatusReport path:path status:status];
}

- (OOStatusReport *)statusOf:(NSString *)path {
  NSString *err;
  NSString *p = OOResolvePath(path, &err);
  return p ? [self reportOfResolved:p] : [OOStatusReport path:path error:err];
}

- (OOStatusReport *)statusOf:(NSString *)path childLimit:(NSUInteger)limit {
  OOStatusReport *r = [self statusOf:path];
  BOOL isDir = NO;
  if (r.error || ![[NSFileManager defaultManager] fileExistsAtPath:r.path isDirectory:&isDir] || !isDir) return r;
  return [OOStatusReport path:r.path status:r.status children:[self childrenOf:r.path limit:limit]];
}

- (OOListing *)childrenOf:(NSString *)dir limit:(NSUInteger)limit {
  NSString *err;
  NSString *p = OOResolvePath(dir, &err);
  if (!p) return [OOListing error:err];
  NSError *e;
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:&e];
  if (!names) return [OOListing error:e.localizedDescription];
  NSMutableArray *entries = [NSMutableArray new];
  for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
    // Dot files and the Finder's "Icon\r" folder-icon file are not user content.
    if ([name hasPrefix:@"."] || [name isEqualToString:@"Icon\r"]) continue;
    if (entries.count == limit) return [OOListing entries:entries truncated:YES];
    NSString *child = [p stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir];
    [entries addObject:[OOEntry name:name directory:isDir report:[self reportOfResolved:child]]];
  }
  return [OOListing entries:entries truncated:NO];
}

- (NSArray<OOApplyResult *> *)apply:(OOTarget)target
                              paths:(NSArray<NSString *> *)paths
                               wait:(BOOL)wait
                            timeout:(NSTimeInterval)timeout {
  NSMutableArray<OOJob *> *jobs = [NSMutableArray new];
  NSMutableArray<OOJob *> *open = [NSMutableArray new];
  for (NSString *path in paths) {
    OOJob *job = [OOJob new];
    NSString *err;
    NSString *p = OOResolvePath(path, &err);
    job.path = p ?: path;
    [jobs addObject:job];
    if (p) [open addObject:job];
    else job.result = [OOApplyResult path:path failure:err];
  }

  // Dropbox drops a request for a path it is still syncing, so a request is held until the
  // path settles, and re-sent if a settled path has not moved after resendInterval.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait ? timeout : MIN(timeout, _settleTimeout)];
  while (open.count) {
    for (OOJob *job in [open copy]) {
      [self advance:job toward:target wait:wait];
      if (job.result) [open removeObject:job];
    }
    if (!open.count) break;
    if (deadline.timeIntervalSinceNow <= 0) {
      for (OOJob *job in open)
        job.result = [OOApplyResult path:job.path outcome:OOOutcomePending status:job.status
                                   error:job.sentAt ? nil : @"still syncing; not requested yet"];
      break;
    }
    [NSThread sleepForTimeInterval:MIN(_pollInterval, MAX(deadline.timeIntervalSinceNow, 0))];
  }

  NSMutableArray<OOApplyResult *> *results = [NSMutableArray new];
  for (OOJob *job in jobs) [results addObject:job.result];
  return results;
}

// One poll of a path; sets job.result once the outcome is final.
- (void)advance:(OOJob *)job toward:(OOTarget)target wait:(BOOL)wait {
  NSString *err;
  OOStatus status;
  if (![_backend status:&status of:job.path error:&err]) {
    job.result = [OOApplyResult path:job.path failure:err];
    return;
  }
  job.status = status;
  OOApplyResult *(^finish)(OOOutcome, NSString *) = ^(OOOutcome outcome, NSString *error) {
    return [OOApplyResult path:job.path outcome:outcome status:status error:error];
  };
  if (status == OOTargetStatus(target)) {
    job.result = finish(job.sentAt ? OOOutcomeDone : OOOutcomeAlready, nil);
    return;
  }
  if (status == OOStatusSyncing || (job.sentAt && -job.sentAt.timeIntervalSinceNow < _resendInterval)) return;

  // After a first request went through, a failed resend is not the final word: keep waiting.
  switch ([_backend request:target for:job.path error:&err]) {
    case OORequestSent:
      job.sentAt = [NSDate date];
      if (!wait) job.result = finish(OOOutcomeRequested, nil);
      return;
    case OORequestUnanswered:
      if (!job.sentAt) job.result = finish(OOOutcomeFailed, err);
      return;
    case OORequestNotOffered:
      if (!job.sentAt)
        job.result = finish(OOOutcomeFailed, status == OOStatusNone ? @"not in a Dropbox folder"
                                                                    : [NSString stringWithFormat:@"Dropbox does not offer %@ for this path", OOTargetTitle(target)]);
      return;
  }
}

@end
