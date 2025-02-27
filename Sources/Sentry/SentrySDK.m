#import "SentrySDK.h"
#import "PrivateSentrySDKOnly.h"
#import "SentryAppStartMeasurement.h"
#import "SentryAppStateManager.h"
#import "SentryBinaryImageCache.h"
#import "SentryBreadcrumb.h"
#import "SentryClient+Private.h"
#import "SentryCrash.h"
#import "SentryCrashWrapper.h"
#import "SentryCurrentDateProvider.h"
#import "SentryDependencyContainer.h"
#import "SentryDispatchQueueWrapper.h"
#import "SentryFileManager.h"
#import "SentryHub+Private.h"
#import "SentryInternalDefines.h"
#import "SentryLog.h"
#import "SentryMeta.h"
#import "SentryOptions+Private.h"
#import "SentryProfilingConditionals.h"
#import "SentrySamplingContext.h"
#import "SentryScope.h"
#import "SentrySerialization.h"
#import "SentryThreadWrapper.h"
#import "SentryTransactionContext.h"
#import "SentryUIDeviceWrapper.h"

#if SENTRY_TARGET_PROFILING_SUPPORTED
#    import "SentryLaunchProfiling.h"
#endif // SENTRY_TARGET_PROFILING_SUPPORTED

@interface
SentrySDK ()

@property (class) SentryHub *currentHub;

@end

NS_ASSUME_NONNULL_BEGIN
@implementation SentrySDK

static SentryHub *_Nullable currentHub;
static BOOL crashedLastRunCalled;
static SentryAppStartMeasurement *sentrySDKappStartMeasurement;
static NSObject *sentrySDKappStartMeasurementLock;

/**
 * @brief We need to keep track of the number of times @c +[startWith...] is called, because our OOM
 * reporting breaks if it's called more than once.
 * @discussion This doesn't just protect from multiple sequential calls to start the SDK, so we
 * can't simply @c dispatch_once the logic inside the start method; there is also a valid workflow
 * where a consumer could start the SDK, then call @c +[close] and then start again, and we want to
 * reenable the integrations.
 */
static NSUInteger startInvocations;
static NSDate *_Nullable startTimestamp = nil;

+ (void)initialize
{
    if (self == [SentrySDK class]) {
        sentrySDKappStartMeasurementLock = [[NSObject alloc] init];
        startInvocations = 0;
    }
}

+ (SentryHub *)currentHub
{
    @synchronized(self) {
        if (nil == currentHub) {
            currentHub = [[SentryHub alloc] initWithClient:nil andScope:nil];
        }
        return currentHub;
    }
}

+ (nullable SentryOptions *)options
{
    @synchronized(self) {
        return [[currentHub getClient] options];
    }
}

/** Internal, only needed for testing. */
+ (void)setCurrentHub:(nullable SentryHub *)hub
{
    @synchronized(self) {
        currentHub = hub;
    }
}

+ (nullable id<SentrySpan>)span
{
    return currentHub.scope.span;
}

+ (BOOL)isEnabled
{
    return currentHub != nil && [currentHub getClient] != nil;
}

+ (BOOL)crashedLastRunCalled
{
    return crashedLastRunCalled;
}

+ (void)setCrashedLastRunCalled:(BOOL)value
{
    crashedLastRunCalled = value;
}

/**
 * Not public, only for internal use.
 */
+ (void)setAppStartMeasurement:(nullable SentryAppStartMeasurement *)value
{
    @synchronized(sentrySDKappStartMeasurementLock) {
        sentrySDKappStartMeasurement = value;
    }
    if (PrivateSentrySDKOnly.onAppStartMeasurementAvailable) {
        PrivateSentrySDKOnly.onAppStartMeasurementAvailable(value);
    }
}

/**
 * Not public, only for internal use.
 */
+ (nullable SentryAppStartMeasurement *)getAppStartMeasurement
{
    @synchronized(sentrySDKappStartMeasurementLock) {
        return sentrySDKappStartMeasurement;
    }
}

/**
 * Not public, only for internal use.
 */
+ (NSUInteger)startInvocations
{
    return startInvocations;
}

/**
 * Only needed for testing.
 */
+ (void)setStartInvocations:(NSUInteger)value
{
    startInvocations = value;
}

/**
 * Not public, only for internal use.
 */
+ (nullable NSDate *)startTimestamp
{
    return startTimestamp;
}

/**
 * Only needed for testing.
 */
+ (void)setStartTimestamp:(NSDate *)value
{
    startTimestamp = value;
}

+ (void)startWithOptions:(SentryOptions *)options
{
    [SentryLog configure:options.debug diagnosticLevel:options.diagnosticLevel];

    // We accept the tradeoff that the SDK might not be fully initialized directly after
    // initializing it on a background thread because scheduling the init synchronously on the main
    // thread could lead to deadlocks.
    SENTRY_LOG_DEBUG(@"Starting SDK...");

#if defined(DEBUG) || defined(TEST) || defined(TESTCI)
    SENTRY_LOG_DEBUG(@"Configured options: %@", options.debugDescription);
#endif // defined(DEBUG) || defined(TEST) || defined(TESTCI)

    startInvocations++;
    startTimestamp = [SentryDependencyContainer.sharedInstance.dateProvider date];

    SentryClient *newClient = [[SentryClient alloc] initWithOptions:options];
    [newClient.fileManager moveAppStateToPreviousAppState];
    [newClient.fileManager moveBreadcrumbsToPreviousBreadcrumbs];

    SentryScope *scope
        = options.initialScope([[SentryScope alloc] initWithMaxBreadcrumbs:options.maxBreadcrumbs]);
    // The Hub needs to be initialized with a client so that closing a session
    // can happen.
    SentryHub *hub = [[SentryHub alloc] initWithClient:newClient andScope:scope];
    [SentrySDK setCurrentHub:hub];
    SENTRY_LOG_DEBUG(@"SDK initialized! Version: %@", SentryMeta.versionString);

    SENTRY_LOG_DEBUG(@"Dispatching init work required to run on main thread.");
    [SentryThreadWrapper onMainThread:^{
        SENTRY_LOG_DEBUG(@"SDK main thread init started...");

        [SentryCrashWrapper.sharedInstance startBinaryImageCache];
        [SentryDependencyContainer.sharedInstance.binaryImageCache start];

        [SentrySDK installIntegrations];
#if TARGET_OS_IOS && SENTRY_HAS_UIKIT
        [SentryDependencyContainer.sharedInstance.uiDeviceWrapper start];
#endif // TARGET_OS_IOS && SENTRY_HAS_UIKIT

#if SENTRY_TARGET_PROFILING_SUPPORTED
        [SentryDependencyContainer.sharedInstance.dispatchQueueWrapper dispatchAsyncWithBlock:^{
            stopLaunchProfile(hub);
            configureLaunchProfiling(options);
        }];
#endif // SENTRY_TARGET_PROFILING_SUPPORTED
    }];
}

+ (void)startWithConfigureOptions:(void (^)(SentryOptions *options))configureOptions
{
    SentryOptions *options = [[SentryOptions alloc] init];
    configureOptions(options);
    [SentrySDK startWithOptions:options];
}

+ (void)captureCrashEvent:(SentryEvent *)event
{
    [SentrySDK.currentHub captureCrashEvent:event];
}

+ (void)captureCrashEvent:(SentryEvent *)event withScope:(SentryScope *)scope
{
    [SentrySDK.currentHub captureCrashEvent:event withScope:scope];
}

+ (SentryId *)captureEvent:(SentryEvent *)event
{
    return [SentrySDK captureEvent:event withScope:SentrySDK.currentHub.scope];
}

+ (SentryId *)captureEvent:(SentryEvent *)event withScopeBlock:(void (^)(SentryScope *))block
{
    SentryScope *scope = [[SentryScope alloc] initWithScope:SentrySDK.currentHub.scope];
    block(scope);
    return [SentrySDK captureEvent:event withScope:scope];
}

+ (SentryId *)captureEvent:(SentryEvent *)event withScope:(SentryScope *)scope
{
    return [SentrySDK.currentHub captureEvent:event withScope:scope];
}

+ (id<SentrySpan>)startTransactionWithName:(NSString *)name operation:(NSString *)operation
{
    return [SentrySDK.currentHub startTransactionWithName:name operation:operation];
}

+ (id<SentrySpan>)startTransactionWithName:(NSString *)name
                                 operation:(NSString *)operation
                               bindToScope:(BOOL)bindToScope
{
    return [SentrySDK.currentHub startTransactionWithName:name
                                                operation:operation
                                              bindToScope:bindToScope];
}

+ (id<SentrySpan>)startTransactionWithContext:(SentryTransactionContext *)transactionContext
{
    return [SentrySDK.currentHub startTransactionWithContext:transactionContext];
}

+ (id<SentrySpan>)startTransactionWithContext:(SentryTransactionContext *)transactionContext
                                  bindToScope:(BOOL)bindToScope
{
    return [SentrySDK.currentHub startTransactionWithContext:transactionContext
                                                 bindToScope:bindToScope];
}

+ (id<SentrySpan>)startTransactionWithContext:(SentryTransactionContext *)transactionContext
                                  bindToScope:(BOOL)bindToScope
                        customSamplingContext:(NSDictionary<NSString *, id> *)customSamplingContext
{
    return [SentrySDK.currentHub startTransactionWithContext:transactionContext
                                                 bindToScope:bindToScope
                                       customSamplingContext:customSamplingContext];
}

+ (id<SentrySpan>)startTransactionWithContext:(SentryTransactionContext *)transactionContext
                        customSamplingContext:(NSDictionary<NSString *, id> *)customSamplingContext
{
    return [SentrySDK.currentHub startTransactionWithContext:transactionContext
                                       customSamplingContext:customSamplingContext];
}

+ (SentryId *)captureError:(NSError *)error
{
    return [SentrySDK captureError:error withScope:SentrySDK.currentHub.scope];
}

+ (SentryId *)captureError:(NSError *)error withScopeBlock:(void (^)(SentryScope *_Nonnull))block
{
    SentryScope *scope = [[SentryScope alloc] initWithScope:SentrySDK.currentHub.scope];
    block(scope);
    return [SentrySDK captureError:error withScope:scope];
}

+ (SentryId *)captureError:(NSError *)error withScope:(SentryScope *)scope
{
    return [SentrySDK.currentHub captureError:error withScope:scope];
}

+ (SentryId *)captureException:(NSException *)exception
{
    return [SentrySDK captureException:exception withScope:SentrySDK.currentHub.scope];
}

+ (SentryId *)captureException:(NSException *)exception
                withScopeBlock:(void (^)(SentryScope *))block
{
    SentryScope *scope = [[SentryScope alloc] initWithScope:SentrySDK.currentHub.scope];
    block(scope);
    return [SentrySDK captureException:exception withScope:scope];
}

+ (SentryId *)captureException:(NSException *)exception withScope:(SentryScope *)scope
{
    return [SentrySDK.currentHub captureException:exception withScope:scope];
}

+ (SentryId *)captureMessage:(NSString *)message
{
    return [SentrySDK captureMessage:message withScope:SentrySDK.currentHub.scope];
}

+ (SentryId *)captureMessage:(NSString *)message withScopeBlock:(void (^)(SentryScope *))block
{
    SentryScope *scope = [[SentryScope alloc] initWithScope:SentrySDK.currentHub.scope];
    block(scope);
    return [SentrySDK captureMessage:message withScope:scope];
}

+ (SentryId *)captureMessage:(NSString *)message withScope:(SentryScope *)scope
{
    return [SentrySDK.currentHub captureMessage:message withScope:scope];
}

/**
 * Needed by hybrid SDKs as react-native to synchronously capture an envelope.
 */
+ (void)captureEnvelope:(SentryEnvelope *)envelope
{
    [SentrySDK.currentHub captureEnvelope:envelope];
}

/**
 * Needed by hybrid SDKs as react-native to synchronously store an envelope to disk.
 */
+ (void)storeEnvelope:(SentryEnvelope *)envelope
{
    if (nil != [SentrySDK.currentHub getClient]) {
        [[SentrySDK.currentHub getClient] storeEnvelope:envelope];
    }
}

+ (void)captureUserFeedback:(SentryUserFeedback *)userFeedback
{
    [SentrySDK.currentHub captureUserFeedback:userFeedback];
}

+ (void)addBreadcrumb:(SentryBreadcrumb *)crumb
{
    [SentrySDK.currentHub addBreadcrumb:crumb];
}

+ (void)configureScope:(void (^)(SentryScope *scope))callback
{
    [SentrySDK.currentHub configureScope:callback];
}

+ (void)setUser:(SentryUser *_Nullable)user
{
    [SentrySDK.currentHub setUser:user];
}

+ (BOOL)crashedLastRun
{
    return SentryDependencyContainer.sharedInstance.crashReporter.crashedLastLaunch;
}

+ (void)startSession
{
    [SentrySDK.currentHub startSession];
}

+ (void)endSession
{
    [SentrySDK.currentHub endSession];
}

/**
 * Install integrations and keeps ref in @c SentryHub.integrations
 */
+ (void)installIntegrations
{
    if (nil == [SentrySDK.currentHub getClient]) {
        // Gatekeeper
        return;
    }
    SentryOptions *options = [SentrySDK.currentHub getClient].options;
    for (NSString *integrationName in [SentrySDK.currentHub getClient].options.integrations) {
        Class integrationClass = NSClassFromString(integrationName);
        if (nil == integrationClass) {
            SENTRY_LOG_ERROR(@"[SentryHub doInstallIntegrations] "
                             @"couldn't find \"%@\" -> skipping.",
                integrationName);
            continue;
        } else if ([SentrySDK.currentHub isIntegrationInstalled:integrationClass]) {
            SENTRY_LOG_ERROR(
                @"[SentryHub doInstallIntegrations] already installed \"%@\" -> skipping.",
                integrationName);
            continue;
        }
        id<SentryIntegrationProtocol> integrationInstance = [[integrationClass alloc] init];
        BOOL shouldInstall = [integrationInstance installWithOptions:options];

        if (shouldInstall) {
            SENTRY_LOG_DEBUG(@"Integration installed: %@", integrationName);
            [SentrySDK.currentHub addInstalledIntegration:integrationInstance name:integrationName];
        }
    }
}

+ (void)reportFullyDisplayed
{
    [SentrySDK.currentHub reportFullyDisplayed];
}

+ (void)flush:(NSTimeInterval)timeout
{
    [SentrySDK.currentHub flush:timeout];
}

/**
 * Closes the SDK and uninstalls all the integrations.
 */
+ (void)close
{
    SENTRY_LOG_DEBUG(@"Starting to close SDK.");

    startTimestamp = nil;

    SentryHub *hub = SentrySDK.currentHub;
    [hub removeAllIntegrations];

    SENTRY_LOG_DEBUG(@"Uninstalled all integrations.");

#if SENTRY_HAS_UIKIT
    // force the AppStateManager to unsubscribe, see
    // https://github.com/getsentry/sentry-cocoa/issues/2455
    [[SentryDependencyContainer sharedInstance].appStateManager stopWithForce:YES];
#endif

    [hub close];
    [hub bindClient:nil];

    [SentrySDK setCurrentHub:nil];

    [SentryCrashWrapper.sharedInstance stopBinaryImageCache];
    [SentryDependencyContainer.sharedInstance.binaryImageCache stop];

#if TARGET_OS_IOS && SENTRY_HAS_UIKIT
    [SentryDependencyContainer.sharedInstance.uiDeviceWrapper stop];
#endif // TARGET_OS_IOS && SENTRY_HAS_UIKIT

    [SentryDependencyContainer reset];
    SENTRY_LOG_DEBUG(@"SDK closed!");
}

#ifndef __clang_analyzer__
// Code not to be analyzed
+ (void)crash
{
    int *p = 0;
    *p = 0;
}
#endif

@end

NS_ASSUME_NONNULL_END
