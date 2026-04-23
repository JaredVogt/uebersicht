//
//  UBWindowGroup.h
//  Uebersicht
//
//  Created by Felix Hageloh on 05/10/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "UBWindow.h"

NS_ASSUME_NONNULL_BEGIN

@interface UBWindowGroup : NSObject

// Either or both of these may be nil — window creation is lazy and driven by
// `ensureLayerOfType:`. `background` holds either a Background layer (when
// interaction is enabled) or an Agnostic layer (when it isn't); a given group
// has at most one of the two.
@property (readonly, strong, nullable) UBWindow* foreground;
@property (readonly, strong, nullable) UBWindow* background;

- (id)initWithInteractionEnabled:(BOOL)interactionEnabled;
- (void)loadUrl:(NSURL*)Url;
- (void)reload;
- (void)close;
- (void)setFrame:(NSRect)frame display:(BOOL)flag;
- (void)workspaceChanged;
- (void)wallpaperChanged;

// Lazily allocates the requested layer if absent, and applies the group's
// most-recent `setFrame:` + `loadUrl:` state to it. No-op if the layer
// already exists or doesn't apply in the current interaction mode
// (Foreground/Background require interaction; Agnostic requires it off).
- (void)ensureLayerOfType:(UBWindowType)type;

// Tears down the layer if present. Safe to call for any type.
- (void)removeLayerOfType:(UBWindowType)type;

@end

NS_ASSUME_NONNULL_END
