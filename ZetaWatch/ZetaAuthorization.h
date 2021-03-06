//
//  ZetaAuthoized.h
//  ZetaWatch
//
//  Created by cbreak on 17.12.31.
//  Copyright © 2017 the-color-black.net. All rights reserved.
//

#import <Foundation/Foundation.h>

/*!
 This class wraps privileged operations that require authorization.

 This is heavily based on apple's EvenBetterAuthorizationSample
 https://developer.apple.com/library/content/samplecode/EvenBetterAuthorizationSample/Introduction/Intro.html
 */
@interface ZetaAuthorization : NSObject

//! Call this after the program finished starting
-(void)connectToAuthorization;

//! Internal function to force install the helper tool
-(void)install;

- (void)importPools:(NSDictionary *)importData
		  withReply:(void(^)(NSError * error))reply;

- (void)mountFilesystems:(NSDictionary *)mountData
			   withReply:(void(^)(NSError * error))reply;

- (void)unmountFilesystems:(NSDictionary *)mountData
				 withReply:(void(^)(NSError * error))reply;

- (void)loadKeyForFilesystem:(NSDictionary *)mountData
				 withReply:(void(^)(NSError * error))reply;

- (void)scrubPool:(NSDictionary *)poolData
		withReply:(void(^)(NSError * error))reply;

- (void)executeWhenConnected:(void(^)(NSError * error, id proxy))task;
- (void)executeWhenConnected:(void(^)(NSError * error, id proxy))task failures:(uint32_t)failCount;

@end
