//
//  LaunchKit.m
//  Pods
//
//  Created by Cluster Labs, Inc. on 1/13/15.
//
//

#import "LaunchKit.h"

#import "LKAnalytics.h"
#import "LKAPIClient.h"
#import "LKBundlesManager.h"
#import "LKLog.h"
#define DEBUG_DESTROY_BUNDLE_CACHE_ON_START 0

static NSTimeInterval const DEFAULT_TRACKING_INTERVAL = 30.0;
static NSTimeInterval const MIN_TRACKING_INTERVAL = 5.0;

static BOOL USE_LOCAL_LAUNCHKIT_SERVER = NO;
static NSString* const BASE_API_URL_REMOTE = @"https://api.launchkit.io/";
static NSString* const BASE_API_URL_LOCAL = @"http://localhost:9101/";

@interface LaunchKit ()

@property (copy, nonatomic) NSString *apiToken;

/** Long-lived, persistent dictionary that is sent up with API requests. */
@property (copy, nonatomic) NSDictionary *sessionParameters;

@property (copy, nonatomic) NSDictionary *configurationParameters;

@property (strong, nonatomic) LKAPIClient *apiClient;
@property (strong, nonatomic) NSTimer *trackingTimer;
@property (assign, nonatomic) NSTimeInterval trackingInterval;

// Analytics
@property (strong, nonatomic) LKAnalytics *analytics;

// Bundles Manager
@property (strong, nonatomic) LKBundlesManager *bundlesManager;

@end

@implementation LaunchKit

static LaunchKit *_sharedInstance;

+ (nonnull instancetype)launchWithToken:(nonnull NSString *)apiToken
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[LaunchKit alloc] initWithToken:apiToken];
    });
    return _sharedInstance;
}


+ (nonnull instancetype)sharedInstance
{
    if (_sharedInstance == nil) {
        LKLogWarning(@"sharedInstance called before +launchWithToken:");
    }
    return _sharedInstance;
}


- (nonnull instancetype)initWithToken:(NSString *)apiToken
{
    self = [super init];
    if (self) {
        LKLog(@"Creating LaunchKit...");
        if (apiToken == nil) {
            apiToken = @"";
        }
        if (apiToken.length == 0) {
            LKLogError(@"Invalid or empty api token. Please get one from https://launchkit.io/tokens for your team.");
        }
        self.apiToken = apiToken;

        self.apiClient = [[LKAPIClient alloc] init];
        if (USE_LOCAL_LAUNCHKIT_SERVER) {
            self.apiClient.serverURL = BASE_API_URL_LOCAL;
        } else {
            self.apiClient.serverURL = BASE_API_URL_REMOTE;
        }
        self.apiClient.apiToken = self.apiToken;

        self.bundlesManager = [[LKBundlesManager alloc] initWithAPIClient:self.apiClient];

        self.trackingInterval = DEFAULT_TRACKING_INTERVAL;

        self.sessionParameters = @{};
        self.configurationParameters = @{};
        [self retrieveSessionFromArchiveIfAvailable];

        // Update some local settings from known session_parameter variables
        BOOL shouldReportScreens = YES;
        BOOL shouldReportTaps = YES;
        id rawReportScreens = self.sessionParameters[@"report_screens"];
        if ([rawReportScreens isKindOfClass:[NSNumber class]]) {
            shouldReportScreens = [rawReportScreens boolValue];
        }
        id rawReportTaps = self.sessionParameters[@"report_taps"];
        if ([rawReportTaps isKindOfClass:[NSNumber class]]) {
            shouldReportTaps = [rawReportTaps boolValue];
        }

        self.analytics = [[LKAnalytics alloc] initWithAPIClient:self.apiClient
                                                screenReporting:shouldReportScreens
                                            tapReportingEnabled:shouldReportTaps];

        id rawTrackingInterval = self.sessionParameters[@"track_interval"];
        if ([rawTrackingInterval isKindOfClass:[NSNumber class]]) {
            self.trackingInterval = MAX([rawTrackingInterval doubleValue], MIN_TRACKING_INTERVAL);
            if (self.trackingInterval != [rawTrackingInterval doubleValue]) {
                // Our session parameter value is not the same as the value we'll use, so update
                // the session parameter
                NSMutableDictionary *newSessionParameters = [self.sessionParameters mutableCopy];
                newSessionParameters[@"track_interval"] = @(self.trackingInterval);
                self.sessionParameters = newSessionParameters;
            }
        }

        [self createListeners];

#if DEBUG_DESTROY_BUNDLE_CACHE_ON_START
        [LKBundlesManager deleteBundlesCacheDirectory];
#endif

        [self.bundlesManager rebuildLocalBundlesMap];
        [self.bundlesManager retrieveAndCacheAvailableRemoteBundlesWithCompletion:^(NSError *error) {
            if (error) {
                LKLogWarning(@"Received error downloading and caching remote bundles: %@", error);
            } else {
                LKLog(@"Remote bundles downloaded and cached.");
            }
        }];
    }
    return self;
}

- (void)dealloc
{
    [self destroyListeners];
}

- (void)setDebugMode:(BOOL)debugMode
{
    _debugMode = debugMode;
    LKLOG_ENABLED = _debugMode;
    self.bundlesManager.debugMode = debugMode;
}

- (void)setVerboseLogging:(BOOL)verboseLogging
{
    _verboseLogging = verboseLogging;
    self.bundlesManager.verboseLogging = verboseLogging;
}

- (void)createListeners
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    // App Lifecycle events
    [center addObserver:self
               selector:@selector(applicationWillTerminate:)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    /*
    [center addObserver:self
               selector:@selector(applicationWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
     */

    [self.analytics createListeners];
}


- (void)destroyListeners
{
    [self.analytics destroyListeners];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Session Parameters

- (void)setSessionParameters:(NSDictionary *)sessionParameters
{
    _sessionParameters = sessionParameters;
    self.apiClient.sessionParameters = sessionParameters;
}

#pragma mark - Tracking

- (void)beginTracking
{
    LKLog(@"Starting Tracking");
    [self stopTracking];
    // Fire it the first time immediately
    [self trackingTimerFired];
    self.trackingTimer = [NSTimer scheduledTimerWithTimeInterval:self.trackingInterval
                                                          target:self
                                                        selector:@selector(trackingTimerFired)
                                                        userInfo:nil
                                                         repeats:YES];
    if ([self.trackingTimer respondsToSelector:@selector(setTolerance:)]) {
        self.trackingTimer.tolerance = self.trackingInterval * 0.1; // Allow 10% tolerance
    }
}

- (void)stopTracking
{
    if (self.trackingTimer.isValid) {
        LKLog(@"Stopping Tracking");
        [self.trackingTimer invalidate];
    }
    self.trackingTimer = nil;
}

- (void)trackingTimerFired
{
    [self trackProperties:nil];
}

- (void)trackProperties:(NSDictionary *)properties
{
    if (self.verboseLogging) {
        LKLog(@"Tracking: %@", properties);
    }

    NSMutableDictionary *propertiesToInclude = [NSMutableDictionary dictionaryWithCapacity:2];
    if (properties != nil) {
        [propertiesToInclude addEntriesFromDictionary:properties];
    }
    [propertiesToInclude addEntriesFromDictionary:self.analytics.trackableProperties];
    [self.analytics clearTrackableProperties];

    __weak LaunchKit *_weakSelf = self;
    [self.apiClient trackProperties:propertiesToInclude withSuccessBlock:^(NSDictionary *responseDict) {
        if (_weakSelf.verboseLogging) {
            LKLog(@"Tracking response: %@", responseDict);
        }
        NSArray *todos = responseDict[@"do"];
        for (NSDictionary *todo in todos) {
            NSString *command = todo[@"command"];
            NSDictionary *args = todo[@"args"];
            [self handleCommand:command withArgs:args];
        }
        NSDictionary *config = responseDict[@"config"];
        if (config != nil && ![config isEqualToDictionary:self.configurationParameters]) {
            self.configurationParameters = [config copy];
        }
    } errorBlock:^(NSError *error) {
        LKLog(@"Error tracking properties: %@", error);
    }];
}

#pragma mark - Handling Commands from LaunchKit server

- (void)handleCommand:(NSString *)command withArgs:(NSDictionary *)args
{
    if ([command isEqualToString:@"set-session"]) {
        NSString *key = args[@"name"];
        id value = args[@"value"];
        if ([key isEqualToString:@"report_screens"]) {
            [self.analytics updateReportingScreens:[value boolValue]];
        } else if ([key isEqualToString:@"report_taps"]) {
            [self.analytics updateReportingTaps:[value boolValue]];
        } else if ([key isEqual:@"track_interval"]) {
            // Clamp the value we're saving to reflect what will actually be
            // set in our client
            value = @(MAX([value doubleValue], MIN_TRACKING_INTERVAL));
            [self updateTrackingInterval:[value doubleValue]];
        }

        NSMutableDictionary *updatedSessionParams = [self.sessionParameters mutableCopy];
        if ([value isKindOfClass:[NSNull class]]) {
            [updatedSessionParams removeObjectForKey:key];
        } else {
            updatedSessionParams[key] = value;
        }
        // Triggers an update
        self.sessionParameters = updatedSessionParams;
        [self archiveSession];
    } else if ([command isEqualToString:@"log"]) {
        // Log sent from remote server.
        LKLog(@"%@ - %@", [args[@"level"] uppercaseString], args[@"message"]);
    }
}

- (void) updateTrackingInterval:(NSTimeInterval)newInterval
{
    newInterval = MAX(newInterval, MIN_TRACKING_INTERVAL);
    if (self.trackingInterval == newInterval) {
        return;
    }
    self.trackingInterval = newInterval;

    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    if (state == UIApplicationStateActive) {
        [self beginTracking];
    }

    if (self.verboseLogging) {
        LKLog(@"Tracking timer interval changed to %.1f via remote command", self.trackingInterval);
    }
}

#pragma mark - Application Lifecycle Events

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self archiveSession];
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    // Flush any tracked data
    [self trackProperties:nil];

    [self stopTracking];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self beginTracking];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self archiveSession];
}

#pragma mark - User Info

- (void) setUserIdentifier:(nullable NSString *)userIdentifier email:(nullable NSString *)userEmail name:(nullable NSString *)userName
{
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"command"] = @"set-user";
    // Setting these values to empty string essentially is removing them, as far as API is concerned.
    params[@"unique_id"] = (userIdentifier) ? userIdentifier : @"";
    params[@"email"] = (userEmail) ? userEmail : @"";
    params[@"name"] = (userName) ? userName : @"";
    [self trackProperties:params];
}

#pragma mark - Saving/Persisting our Session

- (void)archiveSession
{
    NSString *filePath = [self sessionArchiveFilePath];
    BOOL success = [NSKeyedArchiver archiveRootObject:self.sessionParameters toFile:filePath];
    if (!success) {
        LKLogError(@"Could not archive session parameters");
    }
}

- (void)retrieveSessionFromArchiveIfAvailable
{
    NSString *oldFilePath = [self oldSessionArchiveFilePath];
    NSString *filePath = [self sessionArchiveFilePath];

    // Migration: Move it from (app/Library/) to (app/Library/Application Support/launchkit/)
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:oldFilePath]) {
        NSString *filePathParent = [filePath stringByDeletingLastPathComponent];
        NSError *createFolderError = nil;
        [fileManager createDirectoryAtPath:filePathParent
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&createFolderError];
        if (createFolderError != nil) {
            LKLogWarning(@"Couldn't create folder at: %@", filePathParent);
        }
        // Move it to the new location
        NSError *moveSessionFileError = nil;
        [fileManager moveItemAtPath:oldFilePath
                             toPath:filePath
                              error:&moveSessionFileError];
        if (moveSessionFileError != nil) {
            if ([moveSessionFileError.domain isEqualToString:@"NSCocoaErrorDomain"] &&
                moveSessionFileError.code == 516) {
                // The file already exists, so we should already be using that file. Just delete this one.
                NSError *deleteOldSessionFileError = nil;
                [fileManager removeItemAtPath:oldFilePath error:&deleteOldSessionFileError];
            } else {
                LKLogWarning(@"Unable to move launchkit session file to new location: %@", moveSessionFileError);
            }
        }
    }

    // Load session from 'filePath'
    id unarchivedObject = nil;
    if (filePath) {
        unarchivedObject = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
    }

    if ([unarchivedObject isKindOfClass:[NSDictionary class]]) {
        self.sessionParameters = (NSDictionary *)unarchivedObject;
    } else {
        self.sessionParameters = @{};
    }
}

- (NSString *)oldSessionArchiveFilePath
{
    if (!self.apiToken) {
        return nil;
    }
    // Separate by apiToken
    NSString *filename = [NSString stringWithFormat:@"launchkit_%@_%@.plist", self.apiToken, @"session"];
    return [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject]
            stringByAppendingPathComponent:filename];
}


- (NSString *)sessionArchiveFilePath
{
    if (!self.apiToken) {
        return nil;
    }
    // Separate by apiToken
    NSString *filename = [NSString stringWithFormat:@"launchkit_%@_%@.plist", self.apiToken, @"session"];
    NSString *appSupportDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).lastObject;
    NSString *launchKitDir = [appSupportDir stringByAppendingPathComponent:@"launchkit"];
    return [launchKitDir stringByAppendingPathComponent:filename];
}


#pragma mark - Debugging (for LaunchKit developers :D)


+ (void)useLocalLaunchKitServer:(BOOL)useLocalLaunchKitServer
{
    NSAssert(_sharedInstance == nil, @"An instance of LaunchKit already has been created. You can only configure whether to use a local server before you have created the shared instance");
    USE_LOCAL_LAUNCHKIT_SERVER = useLocalLaunchKitServer;
}

@end
