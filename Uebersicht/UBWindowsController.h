//
//  UBWindowsController.h
//  Uebersicht
//
//  Created by Felix Hageloh on 30/09/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class UBWidgetsStore;

NS_ASSUME_NONNULL_BEGIN

@interface UBWindowsController : NSObject


- (void)updateWindows:(NSDictionary*)screens
              baseUrl:(NSURL*)baseUrl
   interactionEnabled:(Boolean)interactionEnabled
         forceRefresh:(Boolean)forceRefresh;

// Recomputes, for every live screen, which layers (Foreground/Background, or
// Agnostic in non-interactive mode) actually host a visible widget and
// creates/tears down per-screen webviews accordingly. Call after any change
// that could affect per-screen layer demand: widget add/remove, settings
// change, screen add/remove. Safe to over-call — it's a no-op when demand
// is unchanged.
- (void)refreshLayerDemand:(UBWidgetsStore*)store;

- (void)reloadAll;
- (void)closeAll;
- (void)workspaceChanged;
- (void)wallpaperChanged;
- (void)showDebugConsolesForScreen:(NSNumber*)screenId;
- (NSScreen*)getNSScreen:(NSNumber*)screenId;

@end

NS_ASSUME_NONNULL_END
