//
//  AppDelegate.m
//  V2RayX
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import "AppDelegate.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "ConfigWindowController.h"
#import <SystemConfiguration/SystemConfiguration.h>

#define kV2RayXHelper @"/Library/Application Support/V2RayX/v2rayx_sysconf"
#define kSysconfVersion @"v2rayx_sysconf 1.0.0"
#define kV2RayXSettingVersion 2
#define nilCoalescing(a,b) ( (a != nil) ? (a) : (b) ) // equivalent to ?? operator in Swift

@interface AppDelegate () {
    GCDWebServer *webServer;
    ConfigWindowController *configWindowController;
    BOOL proxyIsOn;
    NSInteger proxyMode; // 0 = v2ray rules; 1 = pac; 2 = global
    NSInteger localPort;
    NSInteger httpPort;
    BOOL udpSupport;
    NSInteger selectedServerIndex;
    NSMutableArray *profiles;
    FSEventStreamRef fsEventStream;
    NSString* plistPath;
    NSString* pacPath;
    NSString* logDirPath;
    dispatch_queue_t taskQueue;
    
}

@end

@implementation AppDelegate

static AppDelegate *appDelegate;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // create a serial queue used for NSTask operations
    taskQueue = dispatch_queue_create("cenmrev.v2rayx.nstask", DISPATCH_QUEUE_SERIAL);
    
    if (![self installHelper]) {
        [[NSApplication sharedApplication] terminate:nil];// installation failed or stopped by user,
    };
    
    _statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [_statusBarItem setMenu:_statusBarMenu];
    [_statusBarItem setHighlightMode:YES];
    
    plistPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/cenmrev.v2rayx.v2ray-core.plist",NSHomeDirectory()];
    pacPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac/pac.js",NSHomeDirectory()];
    
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString *pacDir = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac", NSHomeDirectory()];
    //create application support directory and pac directory
    if (![fileManager fileExistsAtPath:pacDir]) {
        [fileManager createDirectoryAtPath:pacDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    //check if pac file exist
    if (![fileManager fileExistsAtPath:pacPath]) {
        NSString* simplePac = [[NSBundle mainBundle] pathForResource:@"simple" ofType:@"pac"];
        [fileManager copyItemAtPath:simplePac toPath:pacPath error:nil];
    }
    
    // Create Log Dir
    do {
        NSString* logDirName = [NSString stringWithFormat:@"cenmrev.v2rayx.log.%@",
                                [[NSUUID UUID] UUIDString]];
        logDirPath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), logDirName];
    } while ([fileManager fileExistsAtPath:logDirPath]);
    NSLog(@"%@", logDirPath);
    [fileManager createDirectoryAtPath:logDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/access.log", logDirPath] contents:nil attributes:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/error.log", logDirPath] contents:nil attributes:nil];
    
    // set up pac server
    __weak typeof(self) weakSelf = self;
    //http://stackoverflow.com/questions/14556605/capturing-self-strongly-in-this-block-is-likely-to-lead-to-a-retain-cycle
    webServer = [[GCDWebServer alloc] init];
    [webServer addHandlerForMethod:@"GET" path:@"/proxy.pac" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        return [GCDWebServerDataResponse responseWithData:[weakSelf pacData] contentType:@"application/x-ns-proxy-autoconfig"];
    }];
    NSNumber* setingVersion = [[NSUserDefaults standardUserDefaults] objectForKey:@"setingVersion"];
    if(setingVersion == nil || [setingVersion integerValue] != kV2RayXSettingVersion) {
        NSAlert *noServerAlert = [[NSAlert alloc] init];
        [noServerAlert setMessageText:@"If you are running V2RayX for the first time, ignore this message. \nSorry, unknown settings!\nAll V2RayX settings will be reset."];
        [noServerAlert runModal];
        [self writeDefaultSettings]; //explicitly write default settings to user defaults file
    }
    profiles = [[NSMutableArray alloc] init];
    [self configurationDidChange];
    [self monitorPAC:pacDir];
    appDelegate = self;
}

- (void) writeDefaultSettings {
    // from https://www.v2ray.com/chapter_02/05_transport.html
    NSDictionary *defaultSettings =
    @{
      @"setingVersion": [NSNumber numberWithInteger:kV2RayXSettingVersion],
      @"proxyIsOn": [NSNumber numberWithBool:NO],
      @"proxyMode": [NSNumber numberWithInteger:0],
      @"selectedServerIndex": [NSNumber numberWithInteger:0],
      @"localPort": [NSNumber numberWithInteger:1081],
      @"udpSupport": [NSNumber numberWithBool:NO],
      @"shareOverLan": [NSNumber numberWithBool:NO],
      @"dns": @"localhost",
      @"useTLS": [NSNumber numberWithBool:NO],
      @"tlsSettings": @{
              @"allowInsecure": [NSNumber numberWithBool:NO],
              @"serverName": @""
              },
      @"mux": @{
              @"concurrency": @8,
              @"enabled": [NSNumber numberWithBool:NO],
      },
      @"profiles":@[
                    @{
                        @"address": @"v2ray.cool",
                        @"port": @10086,
                        @"alterId": @64,
                        @"userId": @"23ad6b10-8d1a-40f7-8ad0-e3e35cd38297",
                        @"network": @0,
                        @"security": @0,
                        @"remark": @"test server"
                        }
                    ],
      @"transportSettings":
          @{
              @"kcpSettings":
                  @{@"mtu": @1350,
                    @"tti": @50,
                    @"uplinkCapacity": @5,
                    @"downlinkCapacity": @20,
                    @"readBufferSize": @2,
                    @"writeBufferSize": @1,
                    @"congestion":[NSNumber numberWithBool:false],
                    @"header":@{@"type":@"none"}
                    },
              @"tcpSettings":
                  @{@"connectionReuse": [NSNumber numberWithBool:true],
                    @"header":@{@"type":@"none"}
                    },
              @"wsSettings": @{
                      @"connectionReuse": [NSNumber numberWithBool:true],
                      @"path": @""
                      }
              }
    };
    for (NSString* key in [defaultSettings allKeys]) {
        [[NSUserDefaults standardUserDefaults] setObject:defaultSettings[key] forKey:key];
    }
}

- (NSData*) pacData {
    return [NSData dataWithContentsOfFile:pacPath];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    //unload v2ray
    runCommandLine(@"/bin/launchctl", @[@"unload", plistPath]);
    NSLog(@"V2RayX quiting, V2Ray core unloaded.");
    //remove log file
    [[NSFileManager defaultManager] removeItemAtPath:logDirPath error:nil];
    //turn off proxy
    if (proxyIsOn && proxyMode != 3) {
        proxyIsOn = NO;
        [self updateSystemProxy];//close system proxy
    }
}

- (IBAction)showHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.v2ray.com"]];
}

- (IBAction)enableProxy:(id)sender {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:!proxyIsOn] forKey:@"proxyIsOn"];
    [self configurationDidChange];
}

- (IBAction)chooseV2rayRules:(id)sender {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInteger:0] forKey:@"proxyMode"];
    [self configurationDidChange];
}

- (IBAction)choosePacMode:(id)sender {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInteger:1] forKey:@"proxyMode"];
    [self configurationDidChange];
}

- (IBAction)chooseGlobalMode:(id)sender {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInteger:2] forKey:@"proxyMode"];
    [self configurationDidChange];
}

- (IBAction)chooseManualMode:(id)sender {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInteger:3] forKey:@"proxyMode"];
    [self configurationDidChange];
}

- (IBAction)showConfigWindow:(id)sender {
    if (configWindowController) {
        [configWindowController close];
    }
    configWindowController =[[ConfigWindowController alloc] initWithWindowNibName:@"ConfigWindow"];
    configWindowController.delegate = self;
    [configWindowController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
    [configWindowController.window makeKeyAndOrderFront:nil];
}

- (IBAction)editPac:(id)sender {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:pacPath]]];
}

- (void)updateMenus {
    if (proxyIsOn) {
        [_v2rayStatusItem setTitle:@"V2Ray: On"];
        [_enabelV2rayItem setTitle:@"Stop V2Ray"];
        NSImage *icon = [NSImage imageNamed:@"statusBarIcon"];
        [icon setTemplate:YES];
        [_statusBarItem setImage:icon];
    } else {
        [_v2rayStatusItem setTitle:@"V2Ray: Off"];
        [_enabelV2rayItem setTitle:@"Start V2Ray"];
        [_statusBarItem setImage:[NSImage imageNamed:@"statusBarIcon_disabled"]];
        NSLog(@"icon updated");
    }
    [_v2rayRulesItem setState:proxyMode == 0];
    [_pacModeItem setState:proxyMode == 1];
    [_globalModeItem setState:proxyMode == 2];
    [_manualModeItem setState:proxyMode == 3];
    
}

- (void)updateServerMenuList {
    [_serverListMenu removeAllItems];
    if ([profiles count] == 0) {
        [_serverListMenu addItem:[[NSMenuItem alloc] initWithTitle:@"no available servers, please add server profiles through config window." action:nil keyEquivalent:@""]];
    } else {
        int i = 0;
        for (ServerProfile *p in profiles) {
            NSString *itemTitle;
            if (![[p remark]isEqualToString:@""]) {
                itemTitle = [p remark];
            } else {
                itemTitle = [NSString stringWithFormat:@"%@:%@",[p address], [p port]];
            }
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            newItem.state = i == selectedServerIndex?1:0;
            [_serverListMenu addItem:newItem];
            i++;
        }
    }
    [_serversItem setSubmenu:_serverListMenu];
}

- (void)switchServer:(id)sender {
    selectedServerIndex = [sender tag];
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInteger:selectedServerIndex] forKey:@"selectedServerIndex"];
    [self configurationDidChange];
}

- (void)readDefaults {
    NSDictionary *defaultsDic = [self readDefaultsAsDictionary];
    proxyIsOn = [defaultsDic[@"proxyState"] boolValue];
    proxyMode = [defaultsDic[@"proxyMode"] integerValue];
    localPort = [defaultsDic[@"localPort"] integerValue];
    httpPort = [defaultsDic[@"httpPort"] integerValue];
    udpSupport = [defaultsDic[@"udpSupport"] integerValue];
    [profiles removeAllObjects];
    profiles = defaultsDic[@"profiles"];
    selectedServerIndex = [defaultsDic[@"selectedServerIndex"] integerValue];
    NSLog(@"read %ld profiles, selected No.%ld", [profiles count] , selectedServerIndex);
}

- (NSDictionary*)readDefaultsAsDictionary {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *dProxyState = nilCoalescing([defaults objectForKey:@"proxyIsOn"], [NSNumber numberWithBool:NO]); //turn on proxy as default
    NSNumber *dMode = nilCoalescing([defaults objectForKey:@"proxyMode"], @0); // use v2ray rules as defualt mode
    NSNumber* dLocalPort = nilCoalescing([defaults objectForKey:@"localPort"], @1081);//use 1081 as default local port
    NSNumber* dHttpPort = nilCoalescing([defaults objectForKey:@"httpPort"], @8001); //use 8001 as default local http port
    NSNumber* dUdpSupport = nilCoalescing([defaults objectForKey:@"udpSupport"], [NSNumber numberWithBool:NO]);// do not support udp as default
    NSNumber* dShareOverLan = nilCoalescing([defaults objectForKey:@"shareOverLan"], [NSNumber numberWithBool:NO]); //do not share over lan as default
    NSString *dDnsString = nilCoalescing([defaults objectForKey:@"dns"], @"");
    NSMutableArray *dProfilesInPlist = [defaults objectForKey:@"profiles"];
    NSMutableArray *dProfiles = [[NSMutableArray alloc] init];
    NSNumber *dServerIndex;
    if ([dProfilesInPlist isKindOfClass:[NSArray class]] && [dProfilesInPlist count] > 0) {
        for (NSDictionary *aProfile in dProfilesInPlist) {
            
            ServerProfile *newProfile = [[ServerProfile alloc] init];
            newProfile.address = nilCoalescing(aProfile[@"address"], @"");
            newProfile.port = nilCoalescing(aProfile[@"port"], @10086);
            newProfile.userId = nilCoalescing(aProfile[@"userId"], @"");
            newProfile.alterId = nilCoalescing(aProfile[@"alterId"], @0);
            newProfile.remark = nilCoalescing(aProfile[@"remark"], @"");
            newProfile.network = nilCoalescing(aProfile[@"network"], @0);
            newProfile.security = nilCoalescing(aProfile[@"security"], @0);
            [dProfiles addObject:newProfile];
        }
        dServerIndex = [defaults objectForKey:@"selectedServerIndex"];
        if ([dServerIndex integerValue] <= 0 || [dServerIndex integerValue] >= [dProfiles count]) {
            // "<= 0" also includes the case where dServerIndex is nil
            dServerIndex = [NSNumber numberWithInteger:0]; // treate illeagle selectedServerIndex value
        }
    } else {
        dServerIndex = [NSNumber numberWithInteger:-1];
    }
    //return @[dProxyState,dMode,dLocalPort,dUdpSupport,dProfiles,dServerIndex];
    return @{@"proxyState": dProxyState,
             @"proxyMode": dMode,
             @"localPort": dLocalPort,
             @"httpPort": dHttpPort,
             @"udpSupport": dUdpSupport,
             @"shareOverLan": dShareOverLan,
             @"profiles": dProfiles,
             @"selectedServerIndex": dServerIndex,
             @"dns":dDnsString};
}


-(void)unloadV2ray {
    dispatch_async(taskQueue, ^{
        runCommandLine(@"/bin/launchctl", @[@"unload", plistPath]);
        NSLog(@"V2Ray core unloaded.");
    });
}

-(BOOL)loadV2ray {
    NSString *configPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/config.json",NSHomeDirectory()];
    printf("proxy mode is %ld\n", (long)proxyMode);
    NSDictionary *configDic = [[profiles objectAtIndex:selectedServerIndex] v2rayConfigWithRules:proxyMode == 0];
    NSData* v2rayJSONconfig = [NSJSONSerialization dataWithJSONObject:configDic options:NSJSONWritingPrettyPrinted error:nil];
    [v2rayJSONconfig writeToFile:configPath atomically:NO];
    [self generateLaunchdPlist:plistPath];
    dispatch_async(taskQueue, ^{
        runCommandLine(@"/bin/launchctl",  @[@"load", plistPath]);
        NSLog(@"V2Ray core loaded at port: %ld.", localPort);
    });
    return YES;
}

-(void)generateLaunchdPlist:(NSString*)path {
    NSString* v2rayPath = [NSString stringWithFormat:@"%@/v2ray", [[NSBundle mainBundle] resourcePath]];
    NSString *configPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/config.json",NSHomeDirectory()];
    NSDictionary *runPlistDic = [[NSDictionary alloc] initWithObjects:@[@"v2rayproject.v2rayx.v2ray-core", @[v2rayPath, @"-config", configPath], [NSNumber numberWithBool:YES]] forKeys:@[@"Label", @"ProgramArguments", @"RunAtLoad"]];
    [runPlistDic writeToFile:path atomically:NO];
}

void runCommandLine(NSString* launchPath, NSArray* arguments) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:launchPath];
    [task setArguments:arguments];
    NSPipe *stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];
    NSPipe *stderrpipe = [NSPipe pipe];
    [task setStandardError:stderrpipe];
    NSFileHandle *file;
    file = [stdoutpipe fileHandleForReading];
    [task launch];
    NSData *data;
    data = [file readDataToEndOfFile];
    NSString *string;
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
    file = [stderrpipe fileHandleForReading];
    data = [file readDataToEndOfFile];
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
}

-(void)updateSystemProxy {
    NSArray *arguments;
    if (proxyIsOn) {
        if (proxyMode == 1) { // pac mode
            // close system proxy first to refresh pac file
            if (![webServer isRunning]) {
                [webServer startWithPort:8070 bonjourName:nil];
            }
            runCommandLine(kV2RayXHelper, @[@"off"]);
            arguments = @[@"auto"];
        } else {
            if ([webServer isRunning]) {
                [webServer stop];
            }
            if (proxyMode == 3) { // manual mode
                arguments = [self currentProxySetByMe] ? @[@"off"] : @[@"-v"];
            } else { // global mode and rule mode
                arguments = @[@"global", [NSString stringWithFormat:@"%ld", localPort]];
            }
        }
    } else {
        arguments = [NSArray arrayWithObjects:@"off", nil];
        if ([webServer isRunning]) {
            [webServer stop];
        }
    }
    runCommandLine(kV2RayXHelper,arguments);
    NSLog(@"system proxy state:%@,%ld",proxyIsOn?@"on":@"off", (long)proxyMode);
}

-(BOOL)currentProxySetByMe {
    SCPreferencesRef prefRef = SCPreferencesCreate(nil, CFSTR("V2RayX"), nil);
    NSDictionary* sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    //NSLog(@"%@", sets);
    for (NSString *key in [sets allKeys]) {
        NSMutableDictionary *dict = [sets objectForKey:key];
        NSString *hardware = [dict valueForKeyPath:@"Interface.Hardware"];
        if ([hardware isEqualToString:@"AirPort"] || [hardware isEqualToString:@"Wi-Fi"] || [hardware isEqualToString:@"Ethernet"]) {
            NSDictionary* proxy = dict[(NSString*)kSCEntNetProxies];
            BOOL autoProxy = [proxy[(NSString*) kCFNetworkProxiesProxyAutoConfigURLString] isEqualToString:@"http://127.0.0.1:8070/proxy.pac"];
            BOOL autoProxyEnabled = [proxy[(NSString*) kCFNetworkProxiesProxyAutoConfigEnable] boolValue];
            BOOL socksProxy = [proxy[(NSString*) kCFNetworkProxiesSOCKSProxy] isEqualToString:@"127.0.0.1"];
            BOOL socksPort = [proxy[(NSString*) kCFNetworkProxiesSOCKSPort] integerValue] == localPort;
            BOOL socksProxyEnabled = [proxy[(NSString*) kCFNetworkProxiesSOCKSEnable] boolValue];
            if ((autoProxyEnabled && autoProxy) || (socksProxyEnabled && socksPort && socksProxy) ) {
                continue;
            } else {
                NSLog(@"Device %@ is not set by me", key);
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)installHelper {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:kV2RayXHelper] || ![self isSysconfVersionOK]) {
        NSAlert *installAlert = [[NSAlert alloc] init];
        [installAlert addButtonWithTitle:@"Install"];
        [installAlert addButtonWithTitle:@"Quit"];
        [installAlert setMessageText:@"V2RayX needs to install a small tool to /Library/Application Support/V2RayX/ with administrator privileges to set system proxy quickly.\nOtherwise you need to type in the administrator password every time you change system proxy through V2RayX."];
        if ([installAlert runModal] == NSAlertFirstButtonReturn) {
            NSLog(@"start install");
            NSString *helperPath = [NSString stringWithFormat:@"%@/%@", [[NSBundle mainBundle] resourcePath], @"install_helper.sh"];
            NSLog(@"run install script: %@", helperPath);
            NSDictionary *error;
            NSString *script = [NSString stringWithFormat:@"do shell script \"bash %@\" with administrator privileges", helperPath];
            NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:script];
            if ([appleScript executeAndReturnError:&error]) {
                NSLog(@"installation success");
                return YES;
            } else {
                NSLog(@"installation failure");
                //unknown failure
                return NO;
            }
        } else {
            // stopped by user
            return NO;
        }
    } else {
        // helper already installed
        return YES;
    }
}

- (BOOL)isSysconfVersionOK {
    NSTask *task;
    task = [[NSTask alloc] init];
    [task setLaunchPath:kV2RayXHelper];
    
    NSArray *args;
    args = [NSArray arrayWithObjects:@"-v", nil];
    [task setArguments: args];
    
    NSPipe *pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *fd;
    fd = [pipe fileHandleForReading];
    
    [task launch];
    
    NSData *data;
    data = [fd readDataToEndOfFile];
    
    NSString *str;
    str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (![str isEqualToString:kSysconfVersion]) {
        return NO;
    }
    return YES;
}

-(void)configurationDidChange {
    [self unloadV2ray];
    [self readDefaults];
    if (proxyIsOn) {
        if (selectedServerIndex >= 0 && selectedServerIndex < [profiles count]) {
            [self loadV2ray];
        } else {
            proxyIsOn = NO;
            [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:NO] forKey:@"proxyIsOn"];
            NSAlert *noServerAlert = [[NSAlert alloc] init];
            [noServerAlert setMessageText:@"No available Server Profiles!"];
            [noServerAlert runModal];
            NSLog(@"V2Ray core loaded failed: no avalibale servers.");
        }
    }
    [self updateSystemProxy];
    [self updateMenus];
    [self updateServerMenuList];
}

- (void)monitorPAC:(NSString *)filePath {
    if (fsEventStream) {
        return;
    }
    CFStringRef mypath = (__bridge CFStringRef)(filePath);
    CFArrayRef pathsToWatch = CFArrayCreate(NULL, (const void **)&mypath, 1, NULL);
    void *callbackInfo = NULL; // could put stream-specific data here.
    CFAbsoluteTime latency = 3.0; /* Latency in seconds */
    
    /* Create the stream, passing in a callback */
    fsEventStream = FSEventStreamCreate(NULL,
                                        &onPACChange,
                                        callbackInfo,
                                        pathsToWatch,
                                        kFSEventStreamEventIdSinceNow, /* Or a previous event ID */
                                        latency,
                                        kFSEventStreamCreateFlagNone /* Flags explained in reference */
                                        );
    FSEventStreamScheduleWithRunLoop(fsEventStream, [[NSRunLoop mainRunLoop] getCFRunLoop], (__bridge CFStringRef)NSDefaultRunLoopMode);
    FSEventStreamStart(fsEventStream);
}

- (IBAction)copyExportCmd:(id)sender {
    [[NSPasteboard generalPasteboard] clearContents];
    NSString* command = [NSString stringWithFormat:@"export http_proxy=\"http://127.0.0.1:%ld\"; export HTTP_PROXY=\"http://127.0.0.1:%ld\"; export https_proxy=\"http://127.0.0.1:%ld\"; export HTTPS_PROXY=\"http://127.0.0.1:%ld\"", httpPort, httpPort, httpPort, httpPort];
    [[NSPasteboard generalPasteboard] setString:command forType:NSStringPboardType];
}

void onPACChange(
                 ConstFSEventStreamRef streamRef,
                 void *clientCallBackInfo,
                 size_t numEvents,
                 void *eventPaths,
                 const FSEventStreamEventFlags eventFlags[],
                 const FSEventStreamEventId eventIds[])
{
    //NSLog(@"pac changed");
    [appDelegate updateSystemProxy];
}

@end
