//
//  ATURLConnection.m
//
//  Created by Andrew Wooster on 12/14/08.
//  Copyright 2008 Apptentive, Inc.. All rights reserved.
//

#import "ATURLConnection.h"
#import "ATURLConnection_Private.h"
#import "ATUtilities.h"

@interface ATURLConnection ()
- (void)cacheDataIfNeeded;
@end


@implementation ATURLConnection {
	NSMutableURLRequest *request;
	NSString *statusLine;
	NSDictionary *responseHeaders;
	NSMutableData *data;
	NSMutableDictionary *headers;
	NSString *HTTPMethod;
	NSData *HTTPBody;
	NSInputStream *HTTPBodyStream;
}

@synthesize targetURL;
@synthesize delegate;
@synthesize connection;
@synthesize executing;
@synthesize finished;
@synthesize cancelled;
@synthesize failed;
@synthesize timeoutInterval;
@synthesize credential;
@synthesize statusCode;
@synthesize failedAuthentication;
@synthesize connectionError;
@synthesize percentComplete;
@synthesize expiresMaxAge;

- (id)initWithURL:(NSURL *)url {
	return [self initWithURL:url delegate:nil];
}

- (id)initWithURL:(NSURL *)url delegate:(id)aDelegate {
	if ((self = [super init])) {
		targetURL = [url copy];
		delegate = aDelegate;
		data = [[NSMutableData alloc] init];
		finished = NO;
		executing = NO;
		failed = NO;
		failedAuthentication = NO;
		timeoutInterval = 10.0;
		
		headers = [[NSMutableDictionary alloc] init];
		HTTPMethod = nil;
		
		statusCode = 0;
		percentComplete = 0.0f;
		return self;
	}
	return nil;
}

- (BOOL)isExecuting {
	return self.executing;
}

- (BOOL)isFinished {
	return self.finished;
}

- (BOOL)isCancelled {
	return self.cancelled;
}

- (NSDictionary *)headers {
	return headers;
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
	[headers setValue:value forKey:field];
}

- (void)removeHTTPHeaderField:(NSString *)field {
	if ([headers objectForKey:field]) {
		[headers removeObjectForKey:field];
	}
}

- (void)setHTTPMethod:(NSString *)method {
	if (HTTPMethod != method) {
		HTTPMethod = method;
	}
}

- (void)setHTTPBody:(NSData *)body {
	if (HTTPBody != body) {
		HTTPBody = body;
	}
}

- (void)setHTTPBodyStream:(NSInputStream *)stream {
	if (HTTPBodyStream != stream) {
		HTTPBodyStream = stream;
	}
}

- (void)start {
	@synchronized (self) {
		@autoreleasepool {
			do { // once
				if ([self isCancelled]) {
					self.finished = YES;
					break;
				}
				if ([self isFinished]) {
					break;
				}
				if (request) {
					request = nil;
				}
				request = [[NSMutableURLRequest alloc] initWithURL:self.targetURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:timeoutInterval];
				for (NSString *key in headers) {
					[request setValue:[headers objectForKey:key] forHTTPHeaderField:key];
				}
				if (HTTPMethod) {
					[request setHTTPMethod:HTTPMethod];
				}
				if (HTTPBody) {
					[request setHTTPBody:HTTPBody];
				} else if (HTTPBodyStream) {
					[request setHTTPBodyStream:HTTPBodyStream];
				}
				self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
				[self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
				[self.connection start];
				self.executing = YES;
			} while (NO);
		}
	}
}

- (NSString *)statusLine {
	return statusLine;
}

- (NSDictionary *)responseHeaders {
	return responseHeaders;
}

- (NSData *)responseData {
	return data;
}

#pragma mark Delegate Methods
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
	@synchronized (self) {
		[data setLength:0];
		if (response ) {
			if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
				if (statusLine) {
					statusLine = nil;
				}
				// Not linking CF networking, so we'll use the localized version of the status line.
				statusLine = [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode];
				statusCode = response.statusCode;
			} else {
				statusCode = 200;
			}
			
			if (responseHeaders) {
				responseHeaders = nil;
			}
			responseHeaders = [[response allHeaderFields] copy];
			NSString *cacheControlHeader = [responseHeaders valueForKey:@"Cache-Control"];
			if (cacheControlHeader) {
				expiresMaxAge = [ATUtilities maxAgeFromCacheControlHeader:cacheControlHeader];
			} else {
				expiresMaxAge = 0;
			}
		}
	}
}
- (void)connection:(NSURLConnection *)aConnection didFailWithError:(NSError *)error {
	@synchronized (self) {
		self.failed = YES;
		self.finished = YES;
		self.executing = NO;
		if (error) {
			self.connectionError = error;
		}
		if (delegate && [delegate respondsToSelector:@selector(connectionFailed:)]){
			[delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:YES];
		} else {
			ATLogError(@"Orphaned connection. No delegate or nonresponsive delegate.");
		}
	}
}

- (void)connection:(NSURLConnection *)aConnection didReceiveData:(NSData *)someData {
	@synchronized (self) {
		[data appendData:someData];
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)aConnection {
	@synchronized (self) {
		if (data && !failed) {
			if (delegate != nil && ![self isCancelled]) {
				self.percentComplete = 1.0f;
				[self cacheDataIfNeeded];
				if (delegate && [delegate respondsToSelector:@selector(connectionFinishedSuccessfully:)]){
					[delegate performSelectorOnMainThread:@selector(connectionFinishedSuccessfully:) withObject:self waitUntilDone:YES];
				} else {
					ATLogError(@"Orphaned connection. No delegate or nonresponsive delegate.");
				}
			}
			data = nil;
		} else if (delegate && ![self isCancelled]) {
			if (delegate && [delegate respondsToSelector:@selector(connectionFailed:)]){
				[delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:YES];
			} else {
				ATLogError(@"Orphaned connection. No delegate or nonresponsive delegate.");
			}
		}
		self.executing = NO;
		self.finished = YES;
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	@synchronized (self) {
		if (credential && [challenge previousFailureCount] == 0) {
			[[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
		} else {
			failedAuthentication = YES;
			[[challenge sender] cancelAuthenticationChallenge:challenge];
		}
	}
}

- (void)connection:(NSURLConnection *)connection didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	@synchronized (self) {
		self.failed = YES;
		self.finished = YES;
		self.executing = NO;
		failedAuthentication = YES;
		if (delegate && [delegate respondsToSelector:@selector(connectionFailed:)]){
			[delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:YES];
		} else {
			ATLogError(@"Orphaned connection. No delegate or nonresponsive delegate.");
		}
	}
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
	if (delegate && [delegate respondsToSelector:@selector(connectionDidProgress:)]) {
		self.percentComplete = ((float)totalBytesWritten)/((float) totalBytesExpectedToWrite);
		[delegate performSelectorOnMainThread:@selector(connectionDidProgress:) withObject:self waitUntilDone:YES];
	} else {
		ATLogError(@"Orphaned connection. No delegate or nonresponsive delegate.");
	}
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)aConnection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
	// See: http://blackpixel.com/blog/1659/caching-and-nsurlconnection/
	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)[cachedResponse response];
	NSURLRequest *r = nil;
#if TARGET_OS_IPHONE
	if ([aConnection respondsToSelector:@selector(currentRequest)]) {
		r = [aConnection currentRequest];
	}
#endif
#if TARGET_OS_MAC
	if (request) {
		r = request;
	}
#endif
	if (r != nil && [r cachePolicy] == NSURLRequestUseProtocolCachePolicy) {
		if (responseHeaders) {
			responseHeaders = nil;
		}
		responseHeaders = [httpResponse allHeaderFields];
		NSString *cacheControlHeader = [responseHeaders valueForKey:@"Cache-Control"];
		NSString *expiresHeader = [responseHeaders valueForKey:@"Expires"];
		if ((cacheControlHeader == nil) && (expiresHeader == nil)) {
			return nil;
		}
	}
	return cachedResponse;
}

- (NSURLRequest *)connection:(NSURLConnection *)inConnection willSendRequest:(NSURLRequest *)inRequest redirectResponse: (NSURLResponse *)inRedirectResponse {
	if (inRedirectResponse) {
		NSMutableURLRequest *r = [request mutableCopy];
		[r setURL:[inRequest URL]];
		return r;
	} else {
		return inRequest;
	}
}

- (void)setExecuting:(BOOL)isExecuting {
	[self willChangeValueForKey:@"isExecuting"];
	executing = isExecuting;
	[self didChangeValueForKey:@"isExecuting"];
}

- (void)setFinished:(BOOL)isFinished {
	[self willChangeValueForKey:@"isFinished"];
	finished = isFinished;
	[self didChangeValueForKey:@"isFinished"];
}

- (void)cacheDataIfNeeded {
	
}

- (NSString *)requestAsString {
	NSMutableString *result = [NSMutableString string];
	[result appendFormat:@"%@ %@\n", HTTPMethod ? HTTPMethod : @"GET", [targetURL absoluteURL]];
	for (NSString *key in headers) {
		NSString *value = [headers valueForKey:key];
		[result appendFormat:@"%@: %@\n", key, value];
	}
	[result appendString:@"\n\n"];
	if (HTTPBody) {
		NSString *a = [[NSString alloc] initWithData:HTTPBody encoding:NSUTF8StringEncoding];
		if (a) {
			[result appendString:a];
		} else {
			[result appendFormat:@"<Data of length:%ld>", (long)[HTTPBody length]];
		}
	} else if (HTTPBodyStream) {
		[result appendString:@"<NSInputStream>"];
	}
	return result;
}

- (NSString *)responseAsString {
	NSMutableString *result = [NSMutableString string];
	[result appendFormat:@"%ld %@\n", (long)[self statusCode], [self statusLine]];
	NSDictionary *allHeaders = [self responseHeaders];
	for (NSString *key in allHeaders) {
		[result appendFormat:@"%@: %@\n", key, allHeaders[key]];
	}
	[result appendString:@"\n\n"];
	NSString *responseString = [[NSString alloc] initWithData:[self responseData] encoding:NSUTF8StringEncoding];
	if (responseString != nil) {
		[result appendString:responseString];
	} else {
		[result appendString:@"<NO RESPONSE BODY>"];
	}
	responseString = nil;
	return result;
}
@end

@implementation ATURLConnection (Private)
- (void)cancel {
	@synchronized (self) {
		if (self.finished) {
			return;
		}
		delegate = nil;
		if (connection) {
			[connection cancel];
		}
		self.executing = NO;
		cancelled = YES;
	}
}
@end
