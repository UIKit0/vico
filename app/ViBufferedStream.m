#include <sys/uio.h>
#include <unistd.h>
#include <vis.h>

#import "ViBufferedStream.h"
#include "logging.h"

void	 hexdump(const void *data, size_t len, const char *fmt, ...);

@implementation ViStreamBuffer

@synthesize ptr, left, length;

- (ViStreamBuffer *)initWithData:(NSData *)aData
{
	if ((self = [super init]) != nil) {
		data = aData;
		ptr = [data bytes];
		length = left = [data length];
	}
	return self;
}

- (ViStreamBuffer *)initWithBuffer:(const void *)buffer length:(NSUInteger)aLength
{
	if ((self = [super init]) != nil) {
		ptr = buffer;
		length = left = aLength;
	}
	return self;
}

- (void)setConsumed:(NSUInteger)size
{
	ptr += size;
	left -= size;
	DEBUG(@"consumed %lu bytes of buffer, %lu bytes left", size, left);
}

@end

#pragma mark -

@implementation ViBufferedStream

- (void)read
{
	DEBUG(@"reading on fd %d", fd_in);

	buflen = 0;
	ssize_t ret = read(fd_in, buffer, sizeof(buffer));
	if (ret <= 0) {
		if (ret == 0) {
			DEBUG(@"read EOF from fd %d", fd_in);
			if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
				[[self delegate] stream:self handleEvent:NSStreamEventEndEncountered];
		} else {
			DEBUG(@"read(%d) failed: %s", fd_in, strerror(errno));
			if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
				[[self delegate] stream:self handleEvent:NSStreamEventErrorOccurred];
		}
		[self shutdownRead];
	} else {
		DEBUG(@"read %zi bytes from fd %i", ret, fd_in);
#ifndef NO_DEBUG
		hexdump(buffer, ret, "read data:");
		char *vis = malloc(ret*4+1);
		strvisx(vis, buffer, ret, VIS_WHITE);
		DEBUG(@"read data: %s", vis);
		free(vis);
#endif
		buflen = ret;
		if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[self delegate] stream:self handleEvent:NSStreamEventHasBytesAvailable];
	}
}

- (void)drain:(NSUInteger)size
{
	ViStreamBuffer *buf;

	DEBUG(@"draining %lu bytes", size);

	while (size > 0 && (buf = [outputBuffers objectAtIndex:0]) != nil) {
		if (size >= buf.length) {
			size -= buf.length;
			[outputBuffers removeObjectAtIndex:0];
		} else {
			[buf setConsumed:size];
			break;
		}
	}
}

- (int)flush
{
	struct iovec	 iov[IOV_MAX];
	unsigned int	 i = 0;
	ssize_t		 n;
	NSUInteger tot = 0;

	for (ViStreamBuffer *buf in outputBuffers) {
		if (i >= IOV_MAX)
			break;
		iov[i].iov_base = (void *)buf.ptr;
		iov[i].iov_len = buf.left;
		tot += buf.left;
		i++;

#ifndef NO_DEBUG
		hexdump(buf.ptr, buf.left, "enqueueing buffer:");
#endif
	}

	if (tot == 0)
		return 0;

	DEBUG(@"flushing %i buffers, total %lu bytes", i, tot);

	if ((n = writev(fd_out, iov, i)) == -1) {
		int saved_errno = errno;
		DEBUG(@"writev failed with errno %s (%i, %i?)", strerror(saved_errno), saved_errno, EPIPE);
		if (saved_errno == EAGAIN || saved_errno == ENOBUFS ||
		    saved_errno == EINTR)	/* try later */
			return 0;
		else if (saved_errno == EPIPE)
			/* treat a broken pipe as connection closed; we might still have stuff to read */
			return -2;
		else
			return -1;
	}

	DEBUG(@"writev(%d) returned %zi", fd_out, n);

	if (n == 0) {			/* connection closed */
		errno = 0;
		return -2;
	}

	[self drain:n];

	if ([outputBuffers count] == 0)
		return 0;

	CFSocketCallBackType cbType = kCFSocketWriteCallBack;
	if (outputSocket == inputSocket)
		cbType |= kCFSocketReadCallBack;
	CFSocketEnableCallBacks(outputSocket, cbType);
	return 1;
}

static void
fd_write(CFSocketRef s,
	 CFSocketCallBackType callbackType,
	 CFDataRef address,
	 const void *data,
	 void *info)
{
	ViBufferedStream *stream = info;

	int ret = [stream flush];
	if (ret == 0) { /* all output buffers flushed to socket */
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[stream delegate] stream:stream handleEvent:NSStreamEventHasSpaceAvailable];
	} else if (ret == -1) {
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[stream delegate] stream:stream handleEvent:NSStreamEventErrorOccurred];
		[stream shutdownWrite];
	} else if (ret == -2) {
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)]) {
			/*
			 * We got a broken pipe on the write stream. If we have different sockets
			 * for read and write, generate a special write-end event, otherwise we
			 * use a regular EOF event. The write-end event allows us to keep reading
			 * data buffered in the socket (ie, not yet received by the application).
			 *
			 * The usecase is when filtering through a non-filter like 'ls'.
			 */
			if ([stream bidirectional])
				[[stream delegate] stream:stream handleEvent:NSStreamEventEndEncountered];
			else
				[[stream delegate] stream:stream handleEvent:ViStreamEventWriteEndEncountered];
		}
		[stream shutdownWrite];
	}
}

static void
fd_read(CFSocketRef s,
	CFSocketCallBackType callbackType,
	CFDataRef address,
	const void *data,
	void *info)
{
	if (callbackType == kCFSocketWriteCallBack)
		fd_write(s, callbackType, address, data, info);
	else {
		ViBufferedStream *stream = info;
		[stream read];
	}
}

/* Returns YES if one bidirectional socket is in use, NO if two unidirectional sockets (a pipe pair) is used. */
- (BOOL)bidirectional
{
	return (inputSocket == outputSocket);
}

- (id)initWithReadDescriptor:(int)read_fd
	     writeDescriptor:(int)write_fd
		    priority:(int)prio
{
	DEBUG(@"init with read fd %d, write fd %d", read_fd, write_fd);

	if ((self = [super init]) != nil) {
		fd_in = read_fd;
		fd_out = write_fd;

		outputBuffers = [NSMutableArray array];

		int flags;
		if (fd_in != -1) {
			if ((flags = fcntl(fd_in, F_GETFL, 0)) == -1) {
				INFO(@"fcntl(%i, F_GETFL): %s", fd_in, strerror(errno));
				return nil;
			}
			if (fcntl(fd_in, F_SETFL, flags | O_NONBLOCK) == -1) {
				INFO(@"fcntl(%i, F_SETFL): %s", fd_in, strerror(errno));
				return nil;
			}

			bzero(&inputContext, sizeof(inputContext));
			inputContext.info = self; /* user data passed to the callbacks */

			CFSocketCallBackType cbType = kCFSocketReadCallBack;
			if (fd_out == fd_in) {
				/* bidirectional socket, we read and write on the same socket */
				cbType |= kCFSocketWriteCallBack;
			}
			inputSocket = CFSocketCreateWithNative(
				kCFAllocatorDefault,
				fd_in,
				cbType,
				fd_read,
				&inputContext);
			if (inputSocket == NULL) {
				INFO(@"failed to create input CFSocket of fd %i", fd_in);
				return nil;
			}
			CFSocketSetSocketFlags(inputSocket, kCFSocketAutomaticallyReenableReadCallBack);
			inputSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, inputSocket, prio);

			CFSocketEnableCallBacks(inputSocket, kCFSocketReadCallBack);
		}

		if (fd_out != -1) {
			if (fd_out == fd_in) {
				/* bidirectional socket */
				outputSocket = inputSocket;
			} else {
				/* unidirectional socket, we read and write on different sockets */
				if ((flags = fcntl(fd_out, F_GETFL, 0)) == -1) {
					INFO(@"fcntl(%i, F_GETFL): %s", fd_out, strerror(errno));
					return nil;
				}
				if (fcntl(fd_out, F_SETFL, flags | O_NONBLOCK) == -1) {
					INFO(@"fcntl(%i, F_SETFL): %s", fd_out, strerror(errno));
					return nil;
				}

				bzero(&outputContext, sizeof(outputContext));
				outputContext.info = self; /* user data passed to the callbacks */

				outputSocket = CFSocketCreateWithNative(
					kCFAllocatorDefault,
					fd_out,
					kCFSocketWriteCallBack,
					fd_write,
					&outputContext);
				if (outputSocket == NULL) {
					INFO(@"failed to create output CFSocket of fd %i", fd_out);
					return nil;
				}
				CFSocketSetSocketFlags(outputSocket, 0);
				outputSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, outputSocket, prio);
			}
		}
	}
	return self;
}

+ (id)streamWithTask:(NSTask *)task
{
	return [[ViBufferedStream alloc] initWithTask:task];
}

- (id)initWithTask:(NSTask *)task
{
	id stdout = [task standardOutput];
	int fdin, fdout;
	if ([stdout isKindOfClass:[NSPipe class]])
		fdin = [[stdout fileHandleForReading] fileDescriptor];
	else if ([stdout isKindOfClass:[NSFileHandle class]])
		fdin = [stdout fileDescriptor];
	else
		return nil;

	id stdin = [task standardInput];
	if ([stdin isKindOfClass:[NSPipe class]])
		fdout = [[stdin fileHandleForWriting] fileDescriptor];
	else if ([stdin isKindOfClass:[NSFileHandle class]])
		fdout = [stdin fileDescriptor];
	else
		return nil;

	return [self initWithReadDescriptor:fdin
			    writeDescriptor:fdout
				   priority:5];
}

- (void)open
{
	INFO(@"%s", "open?");
}

- (void)shutdownWrite
{
	if (outputSource) {
		DEBUG(@"shutting down write pipe %d", fd_out);
		if ([outputBuffers count] > 0)
			INFO(@"fd %i has %lu non-flushed buffers pending", fd_out, [outputBuffers count]);
		CFSocketInvalidate(outputSocket); /* also removes the source from run loops */
		CFRelease(outputSocket);
		CFRelease(outputSource);
		outputSocket = NULL;
		outputSource = NULL;
		fd_out = -1;
	}
	/*
	 * If outputSource is NULL, we either have already closed the write socket,
	 * or we have a bidirectional socket. XXX: should we call shutdown(2) if
	 * full-duplex bidirectional socket?
	 */
}

- (void)shutdownRead
{
	if (inputSource) {
		DEBUG(@"shutting down read pipe %d", fd_in);
		CFSocketInvalidate(inputSocket); /* also removes the source from run loops */
		if (outputSocket == inputSocket) {
			/*
                         * XXX: this also shuts down the write part for
                         * full-duplex bidirectional sockets.
			 */
			outputSocket = NULL;
			fd_out = -1;
		}
		CFRelease(inputSocket);
		CFRelease(inputSource);
		inputSocket = NULL;
		inputSource = NULL;
		fd_in = -1;
	}
}

- (void)close
{
	[self shutdownRead];
	[self shutdownWrite];
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
	DEBUG(@"adding to mode %@", mode);
	if (inputSource)
		CFRunLoopAddSource([aRunLoop getCFRunLoop], inputSource, (CFStringRef)mode);
	if (outputSource)
		CFRunLoopAddSource([aRunLoop getCFRunLoop], outputSource, (CFStringRef)mode);
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
	DEBUG(@"removing from mode %@", mode);
	if (inputSource)
		CFRunLoopRemoveSource([aRunLoop getCFRunLoop], inputSource, (CFStringRef)mode);
	if (outputSource)
		CFRunLoopRemoveSource([aRunLoop getCFRunLoop], outputSource, (CFStringRef)mode);
}

- (BOOL)getBuffer:(const void **)buf length:(NSUInteger *)len
{
	*buf = buffer;
	*len = buflen;
	return YES;
}

- (NSData *)data
{
	return [NSData dataWithBytes:buffer length:buflen];
}

- (BOOL)hasBytesAvailable
{
	return buflen > 0;
}

- (BOOL)hasSpaceAvailable
{
	return YES;
}

- (void)write:(const void *)buf length:(NSUInteger)length
{
	if (outputSocket && length > 0) {
		DEBUG(@"enqueueing %lu bytes on fd %i", length, CFSocketGetNative(outputSocket));
		[outputBuffers addObject:[[ViStreamBuffer alloc] initWithBuffer:buf length:length]];

		CFSocketCallBackType cbType = kCFSocketWriteCallBack;
		if (outputSocket == inputSocket)
			cbType |= kCFSocketReadCallBack;
		CFSocketEnableCallBacks(outputSocket, cbType);
	}
}

- (void)writeData:(NSData *)data
{
	if (outputSocket && [data length] > 0) {
		DEBUG(@"enqueueing %lu bytes on fd %i", [data length], CFSocketGetNative(outputSocket));
		[outputBuffers addObject:[[ViStreamBuffer alloc] initWithData:data]];

		CFSocketCallBackType cbType = kCFSocketWriteCallBack;
		if (outputSocket == inputSocket)
			cbType |= kCFSocketReadCallBack;
		CFSocketEnableCallBacks(outputSocket, cbType);
	}
}

- (void)setDelegate:(id<NSStreamDelegate>)aDelegate
{
	delegate = aDelegate;
}

- (id<NSStreamDelegate>)delegate
{
	return delegate;
}

- (id)propertyForKey:(NSString *)key
{
	DEBUG(@"key is %@", key);
	return nil;
}

- (BOOL)setProperty:(id)property forKey:(NSString *)key
{
	DEBUG(@"key is %@", key);
	return NO;
}

- (NSStreamStatus)streamStatus
{
	DEBUG(@"returning %d", NSStreamStatusOpen);
	return NSStreamStatusOpen;
}

- (NSError *)streamError
{
	DEBUG(@"%s", "returning nil");
	return nil;
}

@end
