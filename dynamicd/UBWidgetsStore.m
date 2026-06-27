//
//  UBWidgetsStore.m
//  
//
//  Created by Felix Hageloh on 26/1/16.
//
//

#import "UBWidgetsStore.h"
#import "UBListener.h"


@implementation UBWidgetsStore {
    UBListener* listener;
    NSMutableDictionary* widgets;
    NSMutableDictionary* settings;
    NSMutableDictionary* screenTargets;
    void (^changeHandler)(NSDictionary*);
    NSDictionary* defaultSettings;
}

- (id)init
{
    self = [super init];

    
    if (self) {
        widgets = [[NSMutableDictionary alloc] init];
        settings = [[NSMutableDictionary alloc] init];
        screenTargets = [[NSMutableDictionary alloc] init];
        listener = [[UBListener alloc] init];
        
        defaultSettings = @{
            @"showOnAllScreens": @YES,
            @"showOnSelectedScreens": @NO,
            @"hidden": @NO,
            @"screens": @[]
        };
        
        [listener on:@"WIDGET_ADDED" do:^(NSDictionary* data) {
            [self addWidget:data];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SETTINGS_CHANGED" do:^(NSDictionary* details) {
            self->settings[details[@"id"]] = [[NSMutableDictionary alloc]
                initWithDictionary:details[@"settings"]
            ];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_REMOVED" do:^(NSString* widgetId) {
            if (self->widgets[widgetId]) {
                [self removeWidget:widgetId];
                [self notifyChange];
            }
        }];
        
        [listener on:@"WIDGET_SET_TO_SELECTED_SCREENS" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"showOnAllScreens": @NO,
                @"showOnSelectedScreens": @YES,
                @"showOnMainScreen": @NO,
                @"hidden": @NO,
                @"userModified": @YES,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_ALL_SCREENS" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"showOnAllScreens": @YES,
                @"showOnSelectedScreens": @NO,
                @"showOnMainScreen": @NO,
                @"hidden": @NO,
                @"screens": @[],
                @"userModified": @YES,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_MAIN_SCREEN" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"showOnAllScreens": @NO,
                @"showOnSelectedScreens": @NO,
                @"showOnMainScreen": @YES,
                @"hidden": @NO,
                @"screens": @[],
                @"userModified": @YES,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_HIDE" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"hidden": @YES,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_SHOW" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"hidden": @NO,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_BACKGROUND" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"inBackground": @YES,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_SET_TO_FOREGROUND" do:^(NSString* widgetId) {
            [self updateSettings:widgetId withPatch:@{
                @"inBackground": @NO,
            }];
            [self notifyChange];
        }];
        
        [listener on:@"SCREEN_SELECTED_FOR_WIDGET" do:^(NSDictionary* data) {
            [self selectScreen:data[@"screenId"] forWidget:data[@"id"]];
            [self notifyChange];
        }];
        
        [listener on:@"SCREEN_DESELECTED_FOR_WIDGET" do:^(NSDictionary* data) {
            [self deselectScreen:data[@"screenId"] forWidget:data[@"id"]];
            [self notifyChange];
        }];
        
        [listener on:@"WIDGET_DECLARES_SCREEN" do:^(NSDictionary* data) {
            NSString* target = data[@"target"];
            if ([target isKindOfClass:[NSString class]] && target.length > 0) {
                self->screenTargets[data[@"id"]] = target;
            } else {
                [self->screenTargets removeObjectForKey:data[@"id"]];
            }
            [self notifyChange];
        }];

        [listener on:@"SCREENS_DID_CHANGE" do:^(NSDictionary* data) {
            [self notifyChange];;
        }];
    }
    
    return self;
}

- (void)onChange:(void (^)(NSDictionary*))aChangeHandler
{
    changeHandler = aChangeHandler;
}

- (void)reset:(NSDictionary*)state
{
    widgets = [(NSDictionary*)state[@"widgets"] mutableCopy];
    settings = [(NSDictionary*)state[@"settings"] mutableCopy];
    [self notifyChange];
}

- (NSDictionary*)get:(NSString*)widgetId
{
    NSMutableDictionary* widget;
    
    if (widgets[widgetId]) {
        widget = [[NSMutableDictionary alloc]
            initWithDictionary:widgets[widgetId]
        ];
        
        widget[@"settings"] = settings[widgetId];
    }
    
    return widget;
}

- (NSDictionary*)getSettings:(NSString*)widgetId
{
    return widgets[widgetId] ? settings[widgetId] : NULL;
}

- (NSString*)screenTargetFor:(NSString*)widgetId
{
    return widgets[widgetId] ? screenTargets[widgetId] : nil;
}

- (NSArray*)sortedWidgets
{
    return [widgets.allKeys
        sortedArrayUsingSelector:@selector(compare:)
    ];;
}

- (void)notifyChange
{
    if (changeHandler) {
        changeHandler(widgets);
    }
}


- (NSDictionary*)addWidget:(NSDictionary*)widget
{
    widgets[widget[@"id"]] = widget;
    
    if (!settings[widget[@"id"]]) {
        settings[widget[@"id"]] = [[NSMutableDictionary alloc]
            initWithDictionary:defaultSettings
        ];
    }
    
    return widget;
}

- (void)updateSettings:(NSString*)widgetId withPatch:(NSDictionary*)patch
{
    if (!settings[widgetId]) {
        settings[widgetId] = [[NSMutableDictionary alloc]
            initWithDictionary:defaultSettings
        ];
    }
    
    [settings[widgetId] addEntriesFromDictionary:patch];
}

- (void)removeWidget:(NSString*)widgetId
{
    [widgets removeObjectForKey:widgetId];
}

- (void)selectScreen:(NSNumber*)screenId forWidget:(NSString*)widgetId
{
    NSArray* screens = settings[widgetId][@"screens"];

    if (![screens containsObject:screenId]) {
        settings[widgetId][@"screens"] = [screens arrayByAddingObject:screenId];
    }
    settings[widgetId][@"userModified"] = @YES;
}

- (void)deselectScreen:(NSNumber*)screenId forWidget:(NSString*)widgetId
{
    NSArray* screens = settings[widgetId][@"screens"];
    NSPredicate *withoutScreen = [NSPredicate
        predicateWithBlock: ^BOOL(id s, NSDictionary * _) {
            return ![s isEqualToNumber:screenId];
        }
    ];

    settings[widgetId][@"screens"] = [screens
        filteredArrayUsingPredicate: withoutScreen
    ];
    settings[widgetId][@"userModified"] = @YES;
}


@end
