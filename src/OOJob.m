#import "OOJob.h"

@implementation OOJobEvent

- (instancetype)initWithKind:(OOJobEventKind)kind status:(OOStatus)status request:(OORequestResult)request error:(NSString *)error at:(NSDate *)at {
  if ((self = [super init])) {
    _kind = kind;
    _status = status;
    _request = request;
    _error = [error copy];
    _at = at;
  }
  return self;
}

+ (instancetype)polledStatus:(OOStatus)status at:(NSDate *)now {
  return [[self alloc] initWithKind:OOJobPolled status:status request:OORequestUnanswered error:nil at:now];
}

+ (instancetype)polledError:(NSString *)error {
  return [[self alloc] initWithKind:OOJobPolled status:OOStatusNone request:OORequestUnanswered error:error at:nil];
}

+ (instancetype)answered:(OORequestResult)request error:(NSString *)error at:(NSDate *)now {
  return [[self alloc] initWithKind:OOJobAnswered status:OOStatusNone request:request error:error at:now];
}

+ (instancetype)timedOut {
  return [[self alloc] initWithKind:OOJobTimedOut status:OOStatusNone request:OORequestUnanswered error:nil at:nil];
}

@end

@implementation OOJob {
  BOOL _hasStatus;
  OOStatus _status;  // last read, when _hasStatus
  NSDate *_sentAt;   // when Sent
}

- (instancetype)initWithPath:(NSString *)path phase:(OOJobPhase)phase hasStatus:(BOOL)hasStatus status:(OOStatus)status
                      sentAt:(NSDate *)sentAt result:(OOApplyResult *)result {
  if ((self = [super init])) {
    _path = [path copy];
    _phase = phase;
    _hasStatus = hasStatus;
    _status = status;
    _sentAt = sentAt;
    _result = result;
  }
  return self;
}

+ (instancetype)unsent:(NSString *)path {
  return [[self alloc] initWithPath:path phase:OOJobUnsent hasStatus:NO status:OOStatusNone sentAt:nil result:nil];
}

+ (instancetype)path:(NSString *)path failure:(NSString *)error {
  return [[self alloc] initWithPath:path phase:OOJobFinal hasStatus:NO status:OOStatusNone sentAt:nil
                             result:[OOApplyResult path:path failure:error]];
}

- (OOJob *)waiting:(OOJobPhase)phase status:(OOStatus)status sentAt:(NSDate *)sentAt {
  return [[OOJob alloc] initWithPath:_path phase:phase hasStatus:YES status:status sentAt:sentAt result:nil];
}

- (OOJob *)final:(OOOutcome)outcome error:(NSString *)error {
  OOApplyResult *r = [OOApplyResult path:_path outcome:outcome status:_status error:error];
  return [[OOJob alloc] initWithPath:_path phase:OOJobFinal hasStatus:YES status:_status sentAt:nil result:r];
}

- (OOJob *)failed:(NSString *)error {
  return [[OOJob alloc] initWithPath:_path phase:OOJobFinal hasStatus:NO status:OOStatusNone sentAt:nil
                              result:[OOApplyResult path:_path failure:error]];
}

- (OOJob *)answered:(OOJobEvent *)event policy:(OOApplyPolicy)policy {
  if (!_hasStatus) return self;  // no poll has asked for a request yet
  if (event.request == OORequestSent)
    return policy.wait ? [self waiting:OOJobSent status:_status sentAt:event.at] : [self final:OOOutcomeRequested error:nil];
  // After one request went through, a failed resend is not the final word.
  if (_phase == OOJobSent) return self;
  if (event.request == OORequestUnanswered) return [self final:OOOutcomeFailed error:event.error];
  return [self final:OOOutcomeFailed
               error:_status == OOStatusNone ? @"not in a Dropbox folder"
                     : [NSString stringWithFormat:@"Dropbox does not offer %@ for this path", OOTargetTitle(policy.target)]];
}

- (OOJob *)next:(OOJobEvent *)event policy:(OOApplyPolicy)policy request:(BOOL *)request {
  if (request) *request = NO;
  if (_phase == OOJobFinal) return self;  // decided; later events change nothing

  switch (event.kind) {
    case OOJobPolled: {
      if (event.error) return [self failed:event.error];
      OOJob *seen = [self waiting:_phase status:event.status sentAt:_sentAt];
      if (event.status == OOTargetStatus(policy.target))
        return [seen final:_phase == OOJobSent ? OOOutcomeDone : OOOutcomeAlready error:nil];
      // Dropbox drops a request for a path it is still syncing, and one it acknowledged can
      // still be dropped, so a settled path that has not moved is asked again.
      BOOL due = event.status != OOStatusSyncing &&
                 (_phase == OOJobUnsent || [event.at timeIntervalSinceDate:_sentAt] >= policy.resendInterval);
      if (request) *request = due;
      return seen;
    }

    case OOJobAnswered:
      return [self answered:event policy:policy];

    case OOJobTimedOut:
      if (!_hasStatus) return [self failed:@"no status from Dropbox before the timeout"];
      return [self final:OOOutcomePending error:_phase == OOJobSent ? nil : @"still syncing; not requested yet"];
  }
  return self;
}

@end
