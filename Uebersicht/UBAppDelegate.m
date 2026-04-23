//
//  UBAppDelegate.m
//  Uebersicht
//
//  Created by Felix Hageloh on 20/9/13.
//  Copyright (c) 2013 Felix Hageloh.
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import "UBAppDelegate.h"
#import "UBWindow.h"
#import "UBScreensController.h"
#import "UBWidgetsController.h"
#import "UBWidgetsStore.h"
#import "Uebersicht-Swift.h"
#import "UBWindowsController.h"

int const PORT = 41416;

@implementation UBAppDelegate {
    NSStatusItem* statusBarItem;
    UBWidgetServerBridge* widgetServer;
    UBPreferencesController* preferences;
    UBScreensController* screensController;
    UBWindowsController* windowsController;
    BOOL shuttingDown;
    BOOL keepServerAlive;
    UBWidgetsStore* widgetsStore;
    UBWidgetsController* widgetsController;
    BOOL needsRefresh;
    UInt16 boundPort;
    UBStatusBarMenuBuilder* statusBarMenuBuilder;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    needsRefresh = YES;
    statusBarMenuBuilder = [UBStatusBarMenuBuilder buildForDelegate:self];
    self.statusBarMenu = statusBarMenuBuilder.menu;
    statusBarItem = [self addStatusItemToMenu: self.statusBarMenu];
    preferences = [[UBPreferencesController alloc] init];

    widgetsStore = [[UBWidgetsStore alloc] init];

    screensController = [[UBScreensController alloc]
        initWithChangeListener:self
    ];
    
    windowsController = [[UBWindowsController alloc] init];
    
    widgetsController = [[UBWidgetsController alloc]
        initWithMenu: self.statusBarMenu
        widgets: widgetsStore
        screens: screensController
        preferences: preferences
    ];
    [widgetsStore onChange: ^(NSDictionary* widgets) {
        [self->widgetsController render];
    }];
    
    // make sure notifcations always show
    NSUserNotificationCenter* unc = [NSUserNotificationCenter
        defaultUserNotificationCenter
    ];
    unc.delegate = self;
    

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(wakeFromSleep:)
        name: NSWorkspaceDidWakeNotification
        object: nil
    ];
    
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(workspaceChanged:)
        name: NSWorkspaceActiveSpaceDidChangeNotification
        object: nil
    ];
    
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(loginSessionBecameActive:)
        name: NSWorkspaceSessionDidBecomeActiveNotification
        object: nil
    ];
 
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(loginSessionResigned:)
        name: NSWorkspaceSessionDidResignActiveNotification
        object: nil
    ];
    
    // start server and load webview
    [self startUp];

    [self listenToWallpaperChanges];
}

- (void)startUp
{
    NSLog(@"starting in-process widget server");

    shuttingDown = NO;
    keepServerAlive = YES;
    widgetServer = [[UBWidgetServerBridge alloc]
        initWithWidgetDirectory: preferences.widgetDir
        settingsDirectory: [self getPreferencesDir]
        loginShell: [[NSUserDefaults standardUserDefaults] boolForKey:@"loginShell"]
    ];

    [widgetServer
        startOnReady: ^(UInt16 port) {
            self->boundPort = port;
            [[UBWebSocket sharedSocket] open:[self serverUrl:@"ws"]];
            [self->widgetServer fetchStateWithCompletion:^(NSDictionary* state) {
                [self->widgetsStore reset:state];
                [self->screensController syncScreens];
            }];
        }
        onExit: ^(NSString* _Nullable reason) {
            if (reason) NSLog(@"widget server startup failed: %@", reason);
            if (!self->shuttingDown) {
                [self shutdown];
            }
            if (self->keepServerAlive) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(),
                    ^{ [self startUp]; }
                );
            }
        }
    ];
}

- (void)shutdown:(Boolean)keepAlive
{
    if (shuttingDown) {
        return;
    }
    shuttingDown = YES;

    keepServerAlive = keepAlive;
    [windowsController closeAll];
    [[UBWebSocket sharedSocket] close];
    [widgetServer stop];
    widgetServer = nil;
}

- (void)shutdown
{
    [self shutdown:false];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    keepServerAlive = NO;
    [widgetServer stop];
    [[NSStatusBar systemStatusBar] removeStatusItem:statusBarItem];
}

- (NSStatusItem*)addStatusItemToMenu:(NSMenu*)aMenu
{
    NSStatusBar*  bar = [NSStatusBar systemStatusBar];
    NSStatusItem* item;

    item = [bar statusItemWithLength: NSSquareStatusItemLength];
    
    NSImage *image = [[NSBundle mainBundle] imageForResource:@"status-icon"];
    [image setTemplate:YES];
    [item.button setImage: image];
    [item setMenu:aMenu];
    [item setEnabled:YES];

    return item;
}

- (NSURL*)getPreferencesDir
{
    NSArray* urls = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask
    ];
    
    return [urls[0]
        URLByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]
                        isDirectory:YES
    ];
}

- (NSURL*)serverUrl:(NSString*)protocol
{
    UInt16 port = boundPort ? boundPort : PORT;
    // trailing slash required for load policy in UBWindow
    return [NSURL
        URLWithString:[NSString
            stringWithFormat:@"%@://127.0.0.1:%d/", protocol, port
        ]
    ];
}


#
#pragma mark Screen Handling
#

- (void)screensChanged:(NSDictionary*)screens
{
    if (widgetsController) {
        [windowsController
            updateWindows:screens
            baseUrl: [self serverUrl: @"http"]
            interactionEnabled: preferences.enableInteraction
            forceRefresh: needsRefresh
        ];
        needsRefresh = NO;
    }
}

#
# pragma mark received actions
#


- (void)widgetDirDidChange
{
    [self shutdown:true];
}

- (void)loginShellDidChange
{
    [self shutdown:true];
}

- (void)interactionDidChange
{
    [windowsController closeAll];
    needsRefresh = YES;
    [screensController syncScreens];
}

- (IBAction)showPreferences:(id)sender
{
    [preferences showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [preferences.window makeKeyAndOrderFront:self];
}

- (IBAction)openWidgetDir:(id)sender
{
    [[NSWorkspace sharedWorkspace]openURL:preferences.widgetDir];
}

- (IBAction)visitWidgetGallery:(id)sender
{
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"http://tracesof.net/uebersicht-widgets/"]
    ];
}

- (IBAction)refreshWidgets:(id)sender
{
    needsRefresh = YES;
    [screensController syncScreens];
}

- (IBAction)showDebugConsole:(id)sender
{
    NSNumber* currentScreen = [[NSScreen mainScreen]
        deviceDescription
    ][@"NSScreenNumber"];
    
    [windowsController showDebugConsolesForScreen:currentScreen];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification
{
    return YES;
}

- (void)wakeFromSleep:(NSNotification *)notification
{
    [windowsController reloadAll];
}

- (void)workspaceChanged:(NSNotification *)notification
{
    [windowsController workspaceChanged];
}

- (void)wallpaperChanged:(NSNotification *)notification
{
    [windowsController wallpaperChanged];
}

- (void)loginSessionBecameActive:(NSNotification *)notification
{
    [self startUp];
}

- (void)loginSessionResigned:(NSNotification *)notification
{
    [self shutdown];
}


- (void)listenToWallpaperChanges
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory,
        NSUserDomainMask,
        YES
    );
    
    CFStringRef path = (__bridge CFStringRef)[paths[0]
        stringByAppendingPathComponent:@"/Application Support/Dock/"
    ];
    
    FSEventStreamContext context = {
        0,
        (__bridge void *)(self), NULL, NULL, NULL
    };
    FSEventStreamRef stream;
    
    stream = FSEventStreamCreate(
        NULL,
        &wallpaperSettingsChanged,
        &context,
        CFArrayCreate(NULL, (const void **)&path, 1, NULL),
        kFSEventStreamEventIdSinceNow,
        0,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
    );
    
    FSEventStreamScheduleWithRunLoop(
        stream,
        CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode
    );
    FSEventStreamStart(stream);

}

void wallpaperSettingsChanged(
    ConstFSEventStreamRef streamRef,
    void *this,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
)
{
    CFStringRef path;
    CFArrayRef  paths = eventPaths;

    for (int i=0; i < numEvents; i++) {
        path = CFArrayGetValueAtIndex(paths, i);
        if (CFStringFindWithOptions(path, CFSTR("desktoppicture.db"),
                                    CFRangeMake(0,CFStringGetLength(path)),
                                    kCFCompareCaseInsensitive,
                                    NULL) == true) {
            UBAppDelegate* delegate = (__bridge UBAppDelegate*)this;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{ [delegate wallpaperChanged:nil]; }
            );
        }
    }
}

#
# pragma mark script support
#

- (NSArray*)getWidgets
{
   return [widgetsController widgetsForScripting];
}

- (BOOL)application:(NSApplication *)sender delegateHandlesKey:(NSString *)key
{
    return [key isEqualToString:@"widgets"];
}

- (void)reloadWidget:(NSString*)widgetId
{
    [widgetsController reloadWidget:widgetId];
}

@end
