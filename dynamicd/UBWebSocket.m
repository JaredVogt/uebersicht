//
//  UBWebSocket.m
//
//
//  Created by Felix Hageloh on 24/1/16.
//
//

#import "UBWebSocket.h"

@interface UBWebSocket () <NSURLSessionWebSocketDelegate>
@end

@implementation UBWebSocket {
    NSMutableArray* listeners;
    NSMutableArray* queuedMessages;
    NSURLSession* session;
    NSURLSessionWebSocketTask* task;
    NSURL* url;
    BOOL isOpen;
}


+ (id)sharedSocket {
    static UBWebSocket* sharedSocket = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedSocket = [[self alloc] init];
    });
    return sharedSocket;
}

- (id)init {

    if (self = [super init]) {
        listeners = [[NSMutableArray alloc] init];
        queuedMessages = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)send:(id)message
{
    if (task && isOpen) {
        [self sendNow:message];
    } else {
        [queuedMessages addObject: message];
    }
}

- (void)sendNow:(id)message
{
    NSURLSessionWebSocketMessage* wsMessage;
    if ([message isKindOfClass:[NSData class]]) {
        wsMessage = [[NSURLSessionWebSocketMessage alloc] initWithData:message];
    } else {
        wsMessage = [[NSURLSessionWebSocketMessage alloc] initWithString:message];
    }
    [task sendMessage:wsMessage completionHandler:^(NSError* error) {
        // Send failures surface through the receive handler / didClose,
        // which trigger a reconnect.
    }];
}

- (void)listen:(void (^)(id))listener
{
    [listeners addObject:listener];
}

- (void)open:(NSURL*)aUrl
{
    if (task) {
        return;
    }

    url = aUrl;
    isOpen = NO;
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"dynamicd" forHTTPHeaderField:@"Origin"];
    session = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
        delegate:self
        delegateQueue:[NSOperationQueue mainQueue]
    ];
    task = [session webSocketTaskWithRequest:request];
    [self receiveNext];
    [task resume];
}

- (void)close
{
    if (task) {
        [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        task = nil;
        [session invalidateAndCancel];
        session = nil;
        url = nil;
        isOpen = NO;
    }
}

- (void)reopen
{
    NSURL* lastUrl = url;
    [self close];
    if (lastUrl) {
        [self open:lastUrl];
    }
}

- (void)receiveNext
{
    NSURLSessionWebSocketTask* current = task;
    __weak UBWebSocket* weakSelf = self;
    [current receiveMessageWithCompletionHandler:^(
        NSURLSessionWebSocketMessage* message,
        NSError* error
    ) {
        UBWebSocket* strongSelf = weakSelf;
        if (!strongSelf || current != strongSelf->task) {
            return;
        }

        if (error) {
            [strongSelf
                performSelector:@selector(reopen)
                withObject:nil
                afterDelay: 0.1
            ];
            return;
        }

        id payload = message.type == NSURLSessionWebSocketMessageTypeString
            ? (id)message.string
            : (id)message.data;
        for (void (^listener)(id) in strongSelf->listeners) {
            listener(payload);
        }

        [strongSelf receiveNext];
    }];
}

- (void)URLSession:(NSURLSession *)aSession
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol
{
    isOpen = YES;

    NSArray* pending = [queuedMessages copy];
    [queuedMessages removeAllObjects];
    for (id message in pending) {
        [self sendNow:message];
    }
}

- (void)URLSession:(NSURLSession *)aSession
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
   didCloseWithCode:(NSURLSessionWebSocketCloseCode)code
             reason:(NSData *)reason
{
    [self
        performSelector:@selector(reopen)
        withObject:nil
        afterDelay: 0.1
    ];
}

@end
