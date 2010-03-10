/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

#import "TiSocketTCPProxy.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netdb.h>
#include <CFNetwork/CFSocketStream.h>

#pragma mark Forward declarations

// Size of the read buffer; ideally should be a multiple of 1024 (1k), up to 4096 (4k, page size)
const NSUInteger bufferSize = 4096;

// TODO: Add host information for better error reporting
typedef struct {
    CFReadStreamRef inputStream;
    CFWriteStreamRef outputStream;
	
	NSMutableArray* writeBuffer;
    NSUInteger bufferPos;
} SocketStreams;

void handleSocketConnection(CFSocketRef socket, CFSocketCallBackType type,
							CFDataRef address, const void* data, void* info);

void handleReadData(CFReadStreamRef input, 
                    CFStreamEventType event, 
                    void* info);
void handleWriteData(CFWriteStreamRef input, 
                     CFStreamEventType event, 
                     void* info);

const CFOptionFlags readStreamEventFlags = 
	kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered | kCFStreamEventOpenCompleted;

const CFOptionFlags writeStreamEventFlags =
    kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred | kCFStreamEventOpenCompleted;

@implementation TiSocketTCPProxy

#pragma mark Macros

#define VALID [[self isValid:nil] boolValue]

#pragma mark Private


-(void)toggleActiveSocket:(int)remoteSocket
{
    activeSockets ^= remoteSocket;
}

-(void)closeRemoteSocket:(CFSocketNativeHandle)remoteSocket
{
    NSNumber* remoteSocketObject = [NSNumber numberWithInt:remoteSocket];
    NSData* socketStreamsObject = [remoteSocketDictionary objectForKey:remoteSocketObject];
    SocketStreams* streams = (SocketStreams*)[socketStreamsObject bytes];
    
    if (streams->inputStream) {
        if (!(CFReadStreamGetStatus(streams->inputStream) == kCFStreamStatusClosed)) {
            CFReadStreamClose(streams->inputStream);
        }
        CFRelease(streams->inputStream);
    }
    if (streams->outputStream) {
        if (!(CFWriteStreamGetStatus(streams->outputStream) == kCFStreamStatusClosed)) {
            CFWriteStreamClose(streams->outputStream);
        }
        CFRelease(streams->outputStream);
    }
    
    if ([streams->writeBuffer count] > 0) {
        [self toggleActiveSocket:remoteSocket];
    }
    
    [streams->writeBuffer release];
    
    // close(remoteSocket); Should be closed by closing the streams.
    [remoteSocketDictionary removeObjectForKey:remoteSocketObject];
}

-(CFDataRef)createAddressData
{
    struct sockaddr_in address;
    
    memset(&address, 0, sizeof(address)); // THIS is the finnicky bit: sockaddr_in needs to have 8 bytes of 0 at the end to be compatible with sockaddr
    address.sin_len = sizeof(address);
    address.sin_port = htons(port);
    address.sin_family = AF_INET;
    
    if ([hostName isEqual:INADDR_ANY_token]) {
        address.sin_addr.s_addr = htonl(INADDR_ANY);
    }
    else {
        struct hostent *host;
        host = gethostbyname([hostName cStringUsingEncoding:[NSString defaultCStringEncoding]]); 
        if (host == NULL) {
            if (socket) {
                CFSocketInvalidate(socket);
                CFRelease(socket);
                socket = NULL;
            }
            
            [self throwException:[NSString stringWithFormat:@"Couldn't resolve host %@: %d", hostName, h_errno]
                       subreason:nil
                        location:CODELOCATION];
        }
        memcpy(&address.sin_addr.s_addr, host->h_addr_list[0], host->h_length);
    }
    
    return CFDataCreate(kCFAllocatorDefault,
                        (UInt8*)&address,
                        sizeof(address));
}

-(void)configureSocketForHandle:(CFSocketNativeHandle)fd
{
    if (socket) {
        return; // Socket already configured, either by listener or previous action
    }
    
    socket = CFSocketCreateWithNative(NULL,
                                      fd,
                                      kCFSocketNoCallBack,
                                      NULL,
                                      NULL);
    
    CFSocketSetSocketFlags(socket, CFSocketGetSocketFlags(socket) & ~kCFSocketCloseOnInvalidate);
}

-(void)handleError:(NSStream*)stream
{
    NSError* error = [stream streamError];
    NSString* event = ([stream isKindOfClass:[NSInputStream class]]) ? @"readError" : @"writeError";
    
    [stream close];
    
    [configureCondition lock];
    [configureCondition signal];
    [configureCondition unlock];
    
    [self fireEvent:event
         withObject:[NSDictionary dictionaryWithObjectsAndKeys:[error localizedDescription], @"error", 
                     [NSNumber numberWithInt:[error code]], @"code", 
                     nil]];
}

-(CFSocketNativeHandle)getHandleFromStream:(NSStream*)stream
{
    CFSocketNativeHandle remoteSocket;
    CFDataRef remoteSocketData;
    
    if ([stream isKindOfClass:[NSInputStream class]]) {
        remoteSocketData = (CFDataRef)CFReadStreamCopyProperty((CFReadStreamRef)stream, kCFStreamPropertySocketNativeHandle);
    }
    else {
        remoteSocketData = (CFDataRef)CFWriteStreamCopyProperty((CFWriteStreamRef)stream, kCFStreamPropertySocketNativeHandle);
    }
    
	if (remoteSocketData == NULL) {
		return -1;
	}
    
    CFDataGetBytes(remoteSocketData, CFRangeMake(0, CFDataGetLength(remoteSocketData)), (UInt8*)&remoteSocket);
    CFRelease(remoteSocketData);
    
    return remoteSocket;
}

-(void)initializeReadStream:(NSInputStream*)input
{
    CFSocketNativeHandle remoteSocket = [self getHandleFromStream:input];
    if (remoteSocket == -1) {
        [self handleError:input];
        return;
    }
    
    SocketStreams* streams = 
    (SocketStreams*)[[remoteSocketDictionary objectForKey:[NSNumber numberWithInt:remoteSocket]] bytes];
    
    if (!streams) {
        streams = (SocketStreams*)malloc(sizeof(SocketStreams));
        streams->outputStream = NULL;
        streams->writeBuffer = nil;
        
        [remoteSocketDictionary setObject:[NSData dataWithBytesNoCopy:streams length:sizeof(SocketStreams)]
                                   forKey:[NSNumber numberWithInt:remoteSocket]];
    }
    
    streams->inputStream = (CFReadStreamRef)input;
    
    CFReadStreamSetProperty((CFReadStreamRef)input, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    [self configureSocketForHandle:remoteSocket];
    
    if (mode && WRITE_MODE) {
        if (streams->outputStream) {
            [configureCondition lock];
            [configureCondition signal];
            [configureCondition unlock];
        }
    }
    else {
        [configureCondition lock];
        [configureCondition signal];
        [configureCondition unlock];
    }
}

-(void)initializeWriteStream:(NSOutputStream*)output
{
    CFSocketNativeHandle remoteSocket = [self getHandleFromStream:output];
    if (remoteSocket == -1) {
        [self handleError:output];
        return;
    }
    
    SocketStreams* streams = 
    (SocketStreams*)[[remoteSocketDictionary objectForKey:[NSNumber numberWithInt:remoteSocket]] bytes];
    
    if (!streams) {
        streams = (SocketStreams*)malloc(sizeof(SocketStreams));
        streams->inputStream = NULL;
        streams->writeBuffer = nil;
        
        [remoteSocketDictionary setObject:[NSData dataWithBytesNoCopy:streams length:sizeof(SocketStreams)]
                                   forKey:[NSNumber numberWithInt:remoteSocket]];
    }
    
    streams->outputStream = (CFWriteStreamRef)output;
    streams->writeBuffer = [[NSMutableArray alloc] init];
    streams->bufferPos = 0;
    
    CFWriteStreamSetProperty((CFWriteStreamRef)output, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    [self configureSocketForHandle:remoteSocket];   
    
    if (mode && READ_MODE) {
        if (streams->inputStream) {
            [configureCondition lock];
            [configureCondition signal];
            [configureCondition unlock];
        }
    }
    else {
        [configureCondition lock];
        [configureCondition signal];
        [configureCondition unlock];
    }
}

-(void)readFromStream:(NSInputStream*)input
{ 
    [readLock lock];
    
    CFSocketNativeHandle remoteSocket = [self getHandleFromStream:input];
    if (remoteSocket == -1) {
        [self handleError:input];
        [readLock unlock];
        return;
    }
    
    BOOL read = NO;
    // We can't just use -[NSInputStream getBuffer:length:] because the input stream is secretly
    // based on sockets, according to the CFReadStream it comes from.
    while ([input hasBytesAvailable]) {
        uint8_t* buffer = (uint8_t*)malloc(bufferSize * sizeof(uint8_t));
        NSInteger bytesRead = [input read:buffer maxLength:bufferSize];

        // Not clear whether the failure condition is 0 or -1 bytes read from documentation
        if (bytesRead == 0 || bytesRead == -1) {
            [self handleError:input];
            [readLock unlock];
            return;
        }
        NSData* data = [NSData dataWithBytes:buffer length:bytesRead];
        [readBuffer addObject:data];
        
        free(buffer);
        read = YES;
    }
    
    [readLock unlock];

    if (read) {
        [self fireEvent:@"newData" withObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:remoteSocket] 
                                                                          forKey:@"from"]];
    }
}

-(void)writeToStream:(NSOutputStream*)output
{
    [writeLock lock];
    
    CFSocketNativeHandle remoteSocket = [self getHandleFromStream:output];
    if (remoteSocket == -1) {
        [self handleError:output];
        [writeLock unlock];
        return;
    }
    
    SocketStreams* streams = 
    (SocketStreams*)[[remoteSocketDictionary objectForKey:[NSNumber numberWithInt:remoteSocket]] bytes];
    if ([streams->writeBuffer count] == 0) {
        [writeLock unlock];
        return;
    }
    
    do {
        NSInteger wroteBytes = 0;
        NSData* data = [streams->writeBuffer objectAtIndex:0];
        
        const uint8_t* startPos = (const uint8_t*)[data bytes] + streams->bufferPos;
        NSUInteger length = [data length] - streams->bufferPos;
        
        wroteBytes = [output write:startPos maxLength:length];
        
        if (wroteBytes == -1) {
            [self handleError:output];
            
            break;
        }
        
        if (wroteBytes != length) {
            streams->bufferPos += wroteBytes;
        }
        else {
            [streams->writeBuffer removeObjectAtIndex:0];
            streams->bufferPos = 0;
        }
    } while ([output hasSpaceAvailable] && 
             streams->bufferPos == 0 && 
             [streams->writeBuffer count] > 0);
    
    [writeLock unlock];
}

#pragma mark Public

-(id)init
{
    if (self = [super init]) {
        socket = NULL;
        remoteSocketDictionary = [[NSMutableDictionary alloc] init];
        
        readBuffer = [[NSMutableArray alloc] init];
        
        readLock = [[NSRecursiveLock alloc] init];
        writeLock = [[NSRecursiveLock alloc] init];
        configureCondition = [[NSCondition alloc] init];
        
        mode = READ_WRITE_MODE;
        activeSockets = 0;
    }
    
    return self;
}

-(void)dealloc
{
    if (VALID) {
        [self close:nil];
    }
    
    [hostName release];
    [readBuffer release];
    [remoteSocketDictionary release];
	[readLock release];
	[writeLock release];
    [configureCondition release];
	
    [super dealloc];
}

-(NSNumber*)mode
{
    return [NSNumber numberWithInt:mode];
}

-(void)setMode:(NSNumber*)mode_
{
    switch ([mode_ intValue]) {
        case READ_MODE:
        case WRITE_MODE:
        case READ_WRITE_MODE:
            mode = (SocketMode)[mode_ intValue];
            break;
        default:
            [self throwException:TiExceptionRangeError 
                       subreason:@"Invalid socket mode" 
                        location:CODELOCATION];
            break;
    }
}

-(NSString*)hostName
{
    return hostName;
}

-(void)setHostName:(NSString*)hostName_
{
    if (hostName == hostName_) {
        return;
    }
    [hostName release];
    hostName = [hostName_ retain];
}

-(NSNumber*)port
{
    return [NSNumber numberWithInt:port];
}

-(void)setPort:(NSNumber*)port_
{
    port = [port_ intValue];
}

-(NSNumber*)dataAvailable:(id)unused
{
    // Unfortunately, this rather intensive operation is necessary...
    [readLock lock];
    int count = [readBuffer count];
    [readLock unlock];
    return [NSNumber numberWithBool:(count != 0)];
}

-(NSNumber*)hasActiveSockets:(id)unused
{
    return [NSNumber numberWithInt:activeSockets];
}

-(NSNumber*)isValid:(id)unused
{
    if (socket) {
        return [NSNumber numberWithBool:CFSocketIsValid(socket)];
    }
    return [NSNumber numberWithBool:false];
}

-(void)listen:(id)unused
{
    if (VALID) {
        [self throwException:@"Socket already opened"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    if (hostName == nil) {
        [self throwException:@"Host is null"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    CFSocketContext socketContext;
    socketContext.version = 0;
    socketContext.info = self;
    socketContext.retain = NULL;
    socketContext.release = NULL;
    socketContext.copyDescription = NULL;
    
    // SocketContext is copied
    socket = CFSocketCreate(kCFAllocatorDefault,
							PF_INET,
							SOCK_STREAM,
							IPPROTO_TCP,
							kCFSocketAcceptCallBack,
							handleSocketConnection,
							&socketContext);
    
    if (!socket) {
        [self throwException:[NSString stringWithFormat:@"Failed to create socket: %d", errno]
                   subreason:nil
                    location:CODELOCATION];
    }
    
    CFDataRef addressData = (CFDataRef)[self createAddressData];
    
    CFSocketError sockError = CFSocketSetAddress(socket,
												 addressData);
    switch (sockError) {
        case kCFSocketError: {
            CFSocketInvalidate(socket);
            CFRelease(socket);
            socket = NULL;
    
            CFRelease(addressData);
            
            [self throwException:[NSString stringWithFormat:@"Failed to connect to %@:%d: %d", hostName, port, errno]
                       subreason:nil
                        location:CODELOCATION];
            break;
		}
	}
    
    CFRelease(addressData);
    
    //[self performSelectorInBackground:@selector(runSocket) withObject:nil];
    
    CFRunLoopSourceRef socketRunLoop = CFSocketCreateRunLoopSource(kCFAllocatorDefault,
                                                                   socket,
                                                                   1);
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       socketRunLoop,
                       kCFRunLoopCommonModes);
    CFRelease(socketRunLoop); 
}

-(void)connect:(id)unused
{
    if (VALID) {
        [self throwException:@"Socket already opened"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    if (hostName == nil) {
        [self throwException:@"Host is null"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    CFSocketSignature signature;
    signature.protocolFamily = PF_INET;
    signature.socketType = SOCK_STREAM;
    signature.protocol = IPPROTO_TCP;
    signature.address = [self createAddressData]; // Follows create rule; clean up later
    
    
    CFReadStreamRef inputStream;
    CFWriteStreamRef outputStream;
    
    CFStreamCreatePairWithPeerSocketSignature(NULL, 
                                              &signature, 
                                              (mode & READ_MODE) ? &inputStream : NULL, 
                                              (mode & WRITE_MODE) ? &outputStream : NULL);
    
    CFStreamClientContext context;
    context.version = 0;
    context.info = self;
    context.retain = NULL;
    context.release = NULL;
    context.copyDescription = NULL;
    
    // TODO: Do we catch errors in the stream opening because the stream FD will be NULL in the callback?
    if (mode & READ_MODE) {
        CFReadStreamSetClient(inputStream, readStreamEventFlags | kCFStreamEventOpenCompleted, handleReadData, &context);
        CFReadStreamScheduleWithRunLoop(inputStream, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFReadStreamOpen(inputStream);
    }
    
    if (mode & WRITE_MODE) {
        CFWriteStreamSetClient(outputStream, writeStreamEventFlags | kCFStreamEventOpenCompleted, handleWriteData, &context);
        CFWriteStreamScheduleWithRunLoop(outputStream, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFWriteStreamOpen(outputStream);
    }
    
    CFRelease(signature.address);
    
    if (!VALID &&
        !(inputStream && (CFReadStreamGetStatus(inputStream) == kCFStreamStatusError)) &&
        !(outputStream && (CFWriteStreamGetStatus(outputStream) == kCFStreamStatusError))) {
        
        [configureCondition lock];
        [configureCondition wait];
        [configureCondition unlock];
    }
}

-(void)close:(id)unused
{
    if (!VALID) {
        [self throwException:@"Socket is not open"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    NSEnumerator* keys = [[remoteSocketDictionary allKeys] objectEnumerator];
    id remoteSocketObject;
    
    // Shut down all of the streams and remote connections
    while ((remoteSocketObject = [keys nextObject])) {
        CFSocketNativeHandle remoteSocket = [remoteSocketObject intValue];
        [self closeRemoteSocket:remoteSocket];
    }
    [readBuffer removeAllObjects];
    
    if (socket) {
        CFSocketInvalidate(socket);
        CFRelease(socket);
    }
    
    socket = NULL;
}

-(TiBlob*)read:(id)unused
{
    if (!(mode & READ_MODE)) {
        [self throwException:@"Socket does not support reading"
                   subreason:nil
                    location:CODELOCATION];
    }
    else if (!VALID) {
        [self throwException:@"Socket is not open"
                   subreason:nil
                    location:CODELOCATION];
    }

    [readLock lock];
    
    TiBlob* dataBlob = nil;
    if ([[self dataAvailable:nil] boolValue]) {
        dataBlob = [[[TiBlob alloc] initWithData:[readBuffer objectAtIndex:0] 
                                        mimetype:@"application/octet-stream"] autorelease];
        [readBuffer removeObjectAtIndex:0];
    }
    
    [readLock unlock];
    
	return dataBlob;
}

-(void)write:(id)args;
{
    if (!(mode & WRITE_MODE)) {
        [self throwException:@"Socket does not support writing"
                   subreason:nil
                    location:CODELOCATION];
    }
    else if (!VALID) {
        [self throwException:@"Socket is invalid"
                   subreason:nil
                    location:CODELOCATION];
    }
    
    NSData* data = nil;
    
    id arg = [args objectAtIndex:0];
    if ([arg isKindOfClass:[TiBlob class]]) {
        data = [arg data];
    }
    else if ([arg isKindOfClass:[NSString class]]) {
        data = [NSData dataWithBytes:[arg UTF8String] length:[arg length]+1];
    }
    else {
        NSString* errorStr = [NSString stringWithFormat:@"expected: %@ or %@, was: %@", [TiBlob class], [NSString class], [arg class]];
        THROW_INVALID_ARG(errorStr)
    }
    
    NSNumber* key = nil;    
    if ([args count] > 1) {
        ENSURE_CLASS([args objectAtIndex:1], [NSNumber class])
        key = [args objectAtIndex:1];
    }
    
    [writeLock lock];

    if (key) {
        NSData* streamData = [remoteSocketDictionary objectForKey:key];
        if (streamData == nil) {
            [self throwException:[NSString stringWithFormat:@"Invalid socket descriptor (%@)", key]
                       subreason:nil
                        location:CODELOCATION];
        }
        
        SocketStreams* streams = (SocketStreams*)[streamData bytes];
        
        // TODO: This might result in very odd situations where when two sockets are being configured, one "beats out" the other, which is the one being waited on.
        // One way to handle this would be to have a canWriteCondition associated with each stream...
        // And what about the odd situation in which one stream configures but then there's an error?
        // This extremely strange corner case COULD happen if the socket is disconnected in the middle of a configure.
        if (streams->writeBuffer == nil) {
            [configureCondition lock];
            [configureCondition wait];
            [configureCondition unlock];
        }
        
        [streams->writeBuffer addObject:data];
        [self toggleActiveSocket:[key intValue]];
        
        if (CFWriteStreamCanAcceptBytes(streams->outputStream)) {
            [self writeToStream:(NSOutputStream*)(streams->outputStream)];
        }        
    }
    else {
        NSEnumerator* keyEnum = [[remoteSocketDictionary allKeys] objectEnumerator];
        
        while ((key = [keyEnum nextObject])) {
            NSData* streamData = [remoteSocketDictionary objectForKey:key];
            SocketStreams* streams = (SocketStreams*)[streamData bytes];
            
            // TODO: This might result in very odd situations where when two sockets are being configured, one "beats out" the other, which is the one being waited on.
            // One way to handle this would be to have a canWriteCondition associated with each stream...
            // And what about the odd situation in which one stream configures but then there's an error?
            // This extremely strange corner case COULD happen if the socket is disconnected in the middle of a configure.
            if (streams->writeBuffer == nil) {
                [configureCondition lock];
                [configureCondition wait];
                [configureCondition unlock];
            }
            
            [streams->writeBuffer addObject:data];
            [self toggleActiveSocket:[key intValue]];
            
            if (CFWriteStreamCanAcceptBytes(streams->outputStream)) {
                [self writeToStream:(NSOutputStream*)(streams->outputStream)];
            }
        }
    }
    
    [writeLock unlock];
}

@end


#pragma mark CFSocket/CFStream data handling

void handleSocketConnection(CFSocketRef socket, CFSocketCallBackType type, 
							CFDataRef address, const void* data, void* info) {
    switch (type) {
        case kCFSocketAcceptCallBack: {
            TiSocketTCPProxy* hostSocket = (TiSocketTCPProxy*)info;
			CFSocketNativeHandle sock = *(CFSocketNativeHandle*)data;
			
            CFReadStreamRef inputStream;
            CFWriteStreamRef outputStream;
            
            SocketMode mode = (SocketMode)[[hostSocket mode] intValue];
            CFStreamCreatePairWithSocket(kCFAllocatorDefault,
                                         sock,
                                         (mode & READ_MODE) ? &inputStream : NULL,
                                         (mode & WRITE_MODE) ? &outputStream : NULL);
            
			CFStreamClientContext context;
			context.version = 0;
			context.info = hostSocket;
			context.retain = NULL;
			context.release = NULL;
			context.copyDescription = NULL;
			
            if (mode & READ_MODE) {
                CFReadStreamSetClient(inputStream, readStreamEventFlags, handleReadData, &context);
                CFReadStreamScheduleWithRunLoop(inputStream, CFRunLoopGetMain(), kCFRunLoopCommonModes);
                CFReadStreamOpen(inputStream);
            }
        
            if (mode & WRITE_MODE) {
                CFWriteStreamSetClient(outputStream, writeStreamEventFlags, handleWriteData, &context);
                CFWriteStreamScheduleWithRunLoop(outputStream, CFRunLoopGetMain(), kCFRunLoopCommonModes);
                CFWriteStreamOpen(outputStream);
            }
            
            break;
        }
    }
}


void handleReadData(CFReadStreamRef input,
					CFStreamEventType event,
					void* info)
{
    TiSocketTCPProxy* hostSocket = (TiSocketTCPProxy*)info;
    
	switch (event) {
        case kCFStreamEventOpenCompleted: {
            [hostSocket initializeReadStream:(NSInputStream*)input];
            break;
        }
		case kCFStreamEventEndEncountered: {
            CFSocketNativeHandle remoteSocket = [hostSocket getHandleFromStream:(NSInputStream*)input];
            if (remoteSocket != -1) {
                [hostSocket closeRemoteSocket:remoteSocket];
            }
			break;
		}
        // There's not very much information you can get out of an error like this, other than
        // that it occurred.  It's not recoverable without the direct stream information, most likely.
		case kCFStreamEventErrorOccurred: {
            [hostSocket handleError:(NSInputStream*)input];
			break;
		}
		// This event is NOT necessarily fired until all current available data has been read.  Gotta clear that buffer first!
		case kCFStreamEventHasBytesAvailable: {
            [hostSocket readFromStream:(NSInputStream*)input];
			break;
		}
	}
}

void handleWriteData(CFWriteStreamRef output,
                     CFStreamEventType event,
                     void* info)
{
    TiSocketTCPProxy* hostSocket = (TiSocketTCPProxy*)info;
    
    switch (event) {
        case kCFStreamEventOpenCompleted: {
            [hostSocket initializeWriteStream:(NSOutputStream*)output];
            break;
        }
		case kCFStreamEventErrorOccurred: {
            [hostSocket handleError:(NSOutputStream*)output];
			break;
		}
		case kCFStreamEventCanAcceptBytes: {
            [hostSocket writeToStream:(NSOutputStream*)output];
            break;
		}
	}
}