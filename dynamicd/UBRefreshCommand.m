//
//  UBRefreshCommand.m
//  dynamicd
//
//  Created by Felix Hageloh on 2/1/17.
//  Copyright © 2017 tracesOf. All rights reserved.
//

#import "UBRefreshCommand.h"
#import "UBAppDelegate.h"

@implementation UBRefreshCommand

-(id)performDefaultImplementation
{
    [(UBAppDelegate*)[NSApp delegate] refreshWidgets:self];
    return nil;
}

@end
