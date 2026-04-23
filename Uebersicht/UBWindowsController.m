//
//  UBWindowsController.m
//  Uebersicht
//
//  Created by Felix Hageloh on 30/09/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import "UBWindowsController.h"
#import "UBWindowGroup.h"

@import WebKit;

@implementation UBWindowsController {
    NSMutableDictionary* windows;
}

- (id)init
{
    self = [super init];
    if (self) {
        windows = [[NSMutableDictionary alloc] initWithCapacity:42];
    }
    return self;
}


- (void)updateWindows:(NSDictionary*)screens
              baseUrl:(NSURL*)baseUrl
   interactionEnabled:(Boolean)interactionEnabled
         forceRefresh:(Boolean)forceRefresh
{
    NSMutableArray* obsoleteScreens = [[windows allKeys] mutableCopy];
    UBWindowGroup* windowGroup;
    
    for(NSNumber* screenId in screens) {
        if (![windows objectForKey:screenId]) {
            windowGroup = [[UBWindowGroup alloc]
                initWithInteractionEnabled: interactionEnabled
            ];
            [windows setObject:windowGroup forKey:screenId];
            [windowGroup loadUrl: [self screenUrl:screenId baseUrl:baseUrl]];
        } else {
            windowGroup = windows[screenId];
            if (forceRefresh) {
                [windowGroup reload];
            }
        }
        
        [windowGroup setFrame:[self screenRect:screenId] display:YES];
        [obsoleteScreens removeObject:screenId];
    }
    
    for (NSNumber* screenId in obsoleteScreens) {
        [windows[screenId] close];
        [windows removeObjectForKey:screenId];
    }
    
    NSLog(@"using %lu screens", (unsigned long)[windows count]);
}

- (NSRect)screenRect:(NSNumber*)screenId
{
    NSScreen* screen = [self getNSScreen:screenId];
    
    CGFloat auxiliaryHeight = screen.auxiliaryTopLeftArea.size.height;
    CGFloat windowHeight = screen.visibleFrame.size.height +
        (screen.visibleFrame.origin.y - screen.frame.origin.y);
    
    // If the remaining visible height is exactly the auxiliaryHeight, the menu
    // bar is hidden. There seems to be no other way to dedect this reliably
    if (screen.frame.size.height - windowHeight == auxiliaryHeight) {
        windowHeight = windowHeight + auxiliaryHeight;
    }

    return NSMakeRect(
        screen.frame.origin.x,
        screen.frame.origin.y,
        screen.frame.size.width,
        windowHeight
    );
}

- (NSScreen*)getNSScreen:(NSNumber*)screenId
{
    for (NSScreen* screen in [NSScreen screens]) {
        if ([screen deviceDescription][@"NSScreenNumber"] == screenId) {
            return screen;
        }
    };
    
    return nil;
}

- (void)reloadAll
{
    for (NSNumber* screenId in windows) {
        UBWindowGroup* window = windows[screenId];
        [window reload];
    }
}

- (void)closeAll
{
    for (UBWindowGroup* window in [windows allValues]) {
        [window close];
    }
    [windows removeAllObjects];
}


- (void)showDebugConsolesForScreen:(NSNumber*)screenId
{
    NSWindow* window;
    window = [(UBWindowGroup*)windows[screenId] foreground];
    if (window) [self showDebugConsoleForWindow: window];
    
    window = [(UBWindowGroup*)windows[screenId] background];
    if (window) [self showDebugConsoleForWindow: window];
}

- (void)showDebugConsoleForWindow:(NSWindow*)window
{
    // macOS 13.3+: `WKWebView.isInspectable` replaces every `WKInspectorRef`
    // dance we used to do through private WebKit headers. Widgets already
    // have `isInspectable = YES` set in `WidgetWebView.init`, so the inspector
    // is reachable from Safari's Develop menu: Develop → [This Mac] → <widget>.
    // We launch Safari and activate it so the user only has one click left.
    NSURL* safari = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:@"com.apple.Safari"
    ];
    if (safari) {
        NSWorkspaceOpenConfiguration* cfg = [NSWorkspaceOpenConfiguration configuration];
        cfg.activates = YES;
        [[NSWorkspace sharedWorkspace]
            openApplicationAtURL:safari
            configuration:cfg
            completionHandler:nil
        ];
    }
}

- (void)workspaceChanged
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] workspaceChanged];
    }
}

- (void)wallpaperChanged
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] wallpaperChanged];
    }
}

- (NSURL*)screenUrl:(NSNumber*)screenId baseUrl:(NSURL*)baseUrl
{
    return [baseUrl
        URLByAppendingPathComponent:[NSString
            stringWithFormat:@"%@",
            screenId
        ]
    ];
}

@end
