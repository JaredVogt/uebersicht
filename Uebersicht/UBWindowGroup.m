//
//  UBWindowGroup.m
//  Uebersicht
//
//  Created by Felix Hageloh on 05/10/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import "UBWindowGroup.h"
#import "UBWindow.h"

@implementation UBWindowGroup {
    BOOL interactionEnabled;
    NSURL* currentUrl;
    NSRect currentFrame;
    BOOL hasFrame;
}

@synthesize foreground;
@synthesize background;


- (id)initWithInteractionEnabled:(BOOL)enabled
{
    self = [super init];
    if (self) {
        interactionEnabled = enabled;
    }
    return self;
}

- (void)ensureLayerOfType:(UBWindowType)type
{
    // Gate by interaction mode. In interactive mode only Foreground and
    // Background exist; in non-interactive mode only Agnostic exists. Callers
    // that pass the wrong type for the current mode get a silent no-op so the
    // demand-computation code in UBWindowsController can stay simple.
    if (interactionEnabled && type == UBWindowTypeAgnostic) return;
    if (!interactionEnabled && type != UBWindowTypeAgnostic) return;

    if ([self windowForType:type]) return;

    UBWindow* window = [[UBWindow alloc] initWithWindowType:type];
    if (type == UBWindowTypeForeground) {
        foreground = window;
    } else {
        // Background and Agnostic both live in the `background` slot; the
        // group only ever has one of the two based on interaction mode.
        background = window;
    }

    if (hasFrame) [window setFrame:currentFrame display:YES];
    [window orderFront:self];
    if (currentUrl) [window loadUrl:currentUrl];
}

- (void)removeLayerOfType:(UBWindowType)type
{
    UBWindow* window = [self windowForType:type];
    if (!window) return;
    [window close];
    if (type == UBWindowTypeForeground) {
        foreground = nil;
    } else {
        background = nil;
    }
}

- (UBWindow*)windowForType:(UBWindowType)type
{
    return type == UBWindowTypeForeground ? foreground : background;
}

- (void)close
{
    [foreground close];
    [background close];
    foreground = nil;
    background = nil;
}

- (void)reload
{
    [foreground reload];
    [background reload];
}

- (void)loadUrl:(NSURL*)url
{
    currentUrl = url;
    [foreground loadUrl:url];
    [background loadUrl:url];
}

- (void)setFrame:(NSRect)frame display:(BOOL)flag
{
    currentFrame = frame;
    hasFrame = YES;
    [foreground setFrame:frame display:flag];
    [background setFrame:frame display:flag];
}

- (void)wallpaperChanged
{
    [foreground wallpaperChanged];
    [background wallpaperChanged];
}

- (void)workspaceChanged
{
    [foreground workspaceChanged];
    [background workspaceChanged];
}

@end
