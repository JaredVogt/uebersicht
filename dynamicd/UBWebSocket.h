//
//  UBWebSocket.h
//
//
//  Created by Felix Hageloh on 24/1/16.
//
//

#import <Foundation/Foundation.h>

@interface UBWebSocket : NSObject

+ (id)sharedSocket;
- (void)open:(NSURL*)aUrl;
- (void)close;
- (void)send:(id)message;
- (void)listen:(void (^)(id))listener;

@end
