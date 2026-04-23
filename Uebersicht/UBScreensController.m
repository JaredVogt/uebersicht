//
//  UBScreensMenuController.m
//  
//
//  Created by Felix Hageloh on 8/11/15.
//
//

#import "UBScreensController.h"
#import "UBScreenChangeListener.h"
#import "Uebersicht-Swift.h"

int const MAX_DISPLAYS = 42;

@implementation UBScreensController {
    id listener;
    UBDispatcher* dispatcher;
}

@synthesize screens;
@synthesize sortedScreens;

- (id)initWithChangeListener:(id<UBScreenChangeListener>)target;
{
    self = [super init];
    if (self) {
        screens = [[NSMutableDictionary alloc] initWithCapacity:MAX_DISPLAYS];
        listener = target;
        dispatcher = [[UBDispatcher alloc] init];
        
        [[NSNotificationCenter defaultCenter]
            addObserver: self
            selector: @selector(handleScreenChange:)
            name: NSApplicationDidChangeScreenParametersNotification
            object: nil
        ];
    }
    
    return self;
}


- (void)updateScreens
{
    NSString *name;
    NSMutableDictionary *nameList = [[NSMutableDictionary alloc]
        initWithCapacity:MAX_DISPLAYS
    ];
    
    [screens removeAllObjects];
    NSMutableArray *ids = [[NSMutableArray alloc] 
        initWithCapacity: [NSScreen screens].count
    ];
    
    int i = 0;
    NSNumber* screenId;
    for(NSScreen* screen in [NSScreen screens]) {
        screenId = [screen deviceDescription][@"NSScreenNumber"];
        name = [screen localizedName];
        if (!name)
            name = [NSString stringWithFormat:@"Display %i", i];
        
        NSNumber *count;
        if ((count = nameList[name])) {
            nameList[name] = [NSNumber numberWithInt:count.intValue+1];
            name = [name stringByAppendingString:[NSString
                stringWithFormat:@" (%i)", count.intValue+1]
            ];
        } else {
            nameList[name] = [NSNumber numberWithInt:1];
        }
    
        screens[screenId] = name;
        [ids addObject: screenId];
        
        i++;
    }
    
    sortedScreens = ids;
    
    [dispatcher
        dispatch: @"SCREENS_DID_CHANGE"
        withPayload: sortedScreens
    ];
}

- (void)handleScreenChange:(id)sender
{
    // Coalesce rapid-fire NSApplicationDidChangeScreenParametersNotification
    // posts (hot-plugging a display can fire it 3–4 times) — one
    // syncScreens per runloop tick is enough.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncScreens];
    });
}

- (void)syncScreens
{
    [self updateScreens];
    [listener screensChanged:screens];
}


- (NSInteger)indexOfScreenMenuItems:(NSMenu*)menu
{
    return [menu indexOfItem:[menu itemWithTitle:@"Check for Updates..."]] + 2;
}

@end
