//
//  ZetaAuthoized.m
//  ZetaWatch
//
//  Created by cbreak on 17.12.31.
//  Copyright © 2017 the-color-black.net. All rights reserved.
//

#import "ZetaAuthorization.h"

#import "ZetaAuthorizationHelperProtocol.h"

#import "CommonAuthorization.h"

#include <ServiceManagement/ServiceManagement.h>

#include <dispatch/dispatch.h>

static const uint32_t maxRetries = 4;

@interface ZetaAuthorization ()
{
	AuthorizationRef _authRef;
}

@property (atomic, copy, readwrite) NSData * authorization;
@property (atomic, strong, readwrite) NSXPCConnection * helperToolConnection;

@end

@implementation ZetaAuthorization

-(void)connectToAuthorization
{
	// Create our connection to the authorization system.
	//
	// If we can't create an authorization reference then the app is not going
	// to be able to do anything requiring authorization. Generally this only
	// happens when you launch the app in some wacky, and typically unsupported,
	// way. We continue with self->_authRef as NULL, which will cause all
	// authorized operations to fail.

	AuthorizationExternalForm extForm = {};
	OSStatus err = AuthorizationCreate(NULL, NULL, 0, &self->_authRef);
	if (err == errAuthorizationSuccess)
	{
		err = AuthorizationMakeExternalForm(self->_authRef, &extForm);
	}
	if (err == errAuthorizationSuccess)
	{
		self.authorization = [[NSData alloc] initWithBytes:&extForm length:sizeof(extForm)];
	}

	// If we successfully connected to Authorization Services, add definitions
	// for our default rights (unless they're already in the database).

	if (self->_authRef)
	{
		[CommonAuthorization setupAuthorizationRights:self->_authRef];
	}
}

-(void)install
{
	// Install the helper tool into the system location. As of 10.12 this is
	// /Library/LaunchDaemons/<TOOL> and /Library/PrivilegedHelperTools/<TOOL>
	Boolean success = NO;
	CFErrorRef error = nil;

	success = SMJobBless(kSMDomainSystemLaunchd,
						 CFSTR("net.the-color-black.ZetaAuthorizationHelper"),
						 self->_authRef, &error);

	if (success)
	{
	}
	else
	{
		NSLog(@"Error installing helper tool: %@\n", error);
		CFRelease(error);
	}
}

- (void)connectToHelperTool
{
	assert([NSThread isMainThread]);
	if (self.helperToolConnection == nil)
	{
		self.helperToolConnection = [[NSXPCConnection alloc] initWithMachServiceName:kHelperToolMachServiceName options:NSXPCConnectionPrivileged];
		self.helperToolConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ZetaAuthorizationHelperProtocol)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
		// We can ignore the retain cycle warning because a) the retain taken by the
		// invalidation handler block is released by us setting it to nil when the block
		// actually runs, and b) the retain taken by the block passed to -addOperationWithBlock:
		// will be released when that operation completes and the operation itself is deallocated
		// (notably self does not have a reference to the NSBlockOperation).
		self.helperToolConnection.invalidationHandler = ^{
			// If the connection gets invalidated then, on the main thread, nil out our
			// reference to it.  This ensures that we attempt to rebuild it the next time around.
			self.helperToolConnection.invalidationHandler = nil;
			[[NSOperationQueue mainQueue] addOperationWithBlock:^{
				self.helperToolConnection = nil;
			}];
		};
#pragma clang diagnostic pop
		[self.helperToolConnection resume];
	}
}

- (void)executeWhenConnected:(void(^)(NSError * error, id proxy))task
{
	[self executeWhenConnected:task failures:0];
}

- (void)executeWhenConnected:(void(^)(NSError * error, id proxy))task failures:(uint32_t)failCount;
{
	// Ensure that there's a helper tool connection in place.
	[self connectToHelperTool];
	id proxy = [self.helperToolConnection remoteObjectProxyWithErrorHandler:
		^(NSError * proxyError)
	{
		if (failCount >= maxRetries)
		{
			task(proxyError, nil);
		}
		else
		{
			dispatch_async(dispatch_get_main_queue(), ^(){
				// Install if there's a proxy error
				[self install];
				[self executeWhenConnected:task failures:failCount+1];
			});
		}
	}];

	[proxy getVersionWithReply:^(NSError * error, NSString * helperVersion)
	 {
		 // Install if there's no valid helper version (because of error)
		 if (error)
		 {
			 if (failCount >= maxRetries)
			 {
				 task(error, nil);
				 return;
			 }
			 dispatch_async(dispatch_get_main_queue(), ^(){
				 // Install if there's a proxy error
				 [self install];
				 [self executeWhenConnected:task failures:failCount+1];
			 });
			 return;
		 }
		 NSString * localVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
		 // Install if the versions don't match exactly
		 if (![localVersion isEqualToString:helperVersion])
		 {
			 if (failCount >= maxRetries)
			 {
				 task([NSError errorWithDomain:@"ZetaError" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"AgentVersionMismatch"}], nil);
				 return;
			 }
			 dispatch_async(dispatch_get_main_queue(), ^(){
				 // Install if there's a proxy error
				 [self install];
				 [self executeWhenConnected:task failures:failCount+1];
			 });
			 return;
		 }
		 // Run the actual task
		 id proxy = [self.helperToolConnection remoteObjectProxyWithErrorHandler:
					   ^(NSError * proxyError)
		   {
			   if (proxyError)
			   {
				   if (failCount >= maxRetries)
				   {
					   task(error, nil);
				   }
				   else
				   {
					   dispatch_async(dispatch_get_main_queue(), ^(){
						   [self executeWhenConnected:task failures:failCount+1];
					   });
				   }
			   }
		   }];
		 task(nil, proxy);
	 }];
}

- (void)getVersionWithReply:(void (^)(NSError * error, NSString *))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error, nil);
		 else
			 [proxy getVersionWithReply:reply];
	 }];
}

- (void)importPools:(NSDictionary *)importData
		  withReply:(void(^)(NSError * error))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error);
		 else
			 [proxy importPools:importData authorization:self.authorization withReply:reply];
	 }];
}

- (void)mountFilesystems:(NSDictionary *)mountData
			   withReply:(void(^)(NSError * error))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error);
		 else
			 [proxy mountFilesystems:mountData authorization:self.authorization withReply:reply];
	 }];
}

- (void)unmountFilesystems:(NSDictionary *)mountData
			   withReply:(void(^)(NSError * error))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error);
		 else
			 [proxy unmountFilesystems:mountData authorization:self.authorization withReply:reply];
	 }];
}

- (void)loadKeyForFilesystem:(NSDictionary *)data
					withReply:(void(^)(NSError * error))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error);
		 else
			 [proxy loadKeyForFilesystem:data authorization:self.authorization withReply:reply];
	 }];
}

- (void)scrubPool:(NSDictionary *)poolData
		withReply:(void(^)(NSError * error))reply
{
	[self executeWhenConnected:^(NSError * error, id proxy)
	 {
		 if (error)
			 reply(error);
		 else
			 [proxy scrubPool:poolData authorization:self.authorization withReply:reply];
	 }];
}

@end
