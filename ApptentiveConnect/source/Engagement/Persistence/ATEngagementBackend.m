//
//  ATEngagementBackend.m
//  ApptentiveConnect
//
//  Created by Peter Kamb on 8/21/13.
//  Copyright (c) 2013 Apptentive, Inc. All rights reserved.
//

#import "ATEngagementBackend.h"
#import "ATBackend.h"
#import "ATEngagementGetManifestTask.h"
#import "ATTaskQueue.h"
#import "ATInteraction.h"
#import "ATAppRatingFlow_Private.h"

NSString *const ATEngagementInstallDateKey = @"ATEngagementInstallDateKey";
NSString *const ATEngagementUpgradeDateKey = @"ATEngagementUpgradeDateKey";
NSString *const ATEngagementCodePointsInvokesTotalKey = @"ATEngagementCodePointsInvokesTotalKey";
NSString *const ATEngagementCodePointsInvokesVersionKey = @"ATEngagementCodePointsInvokesVersionKey";
NSString *const ATEngagementInteractionsInvokesTotalKey = @"ATEngagementInteractionsInvokesTotalKey";
NSString *const ATEngagementInteractionsInvokesVersionKey = @"ATEngagementInteractionsInvokesVersionKey";

NSString *const ATEngagementCachedInteractionsExpirationPreferenceKey = @"ATEngagementCachedInteractionsExpirationPreferenceKey";

@implementation ATEngagementBackend

+ (ATEngagementBackend *)sharedBackend {
	static ATEngagementBackend *sharedBackend = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedBackend = [[ATEngagementBackend alloc] init];
	});
	return sharedBackend;
}

- (id)init {
	if ((self = [super init])) {
		codePointInteractions = [[NSMutableDictionary alloc] init];
		
		NSDictionary *defaults = @{ATEngagementInstallDateKey : [NSDate date],
							 ATEngagementUpgradeDateKey : [NSDate date],
							 ATEngagementCodePointsInvokesTotalKey : @{},
							 ATEngagementCodePointsInvokesVersionKey : @{},
							 ATEngagementInteractionsInvokesTotalKey : @{},
							 ATEngagementInteractionsInvokesVersionKey : @{}};
		[[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
		
		NSFileManager *fm = [NSFileManager defaultManager];
		if ([fm fileExistsAtPath:[ATEngagementBackend cachedEngagementStoragePath]]) {
			@try {
				NSDictionary *archivedInteractions = [NSKeyedUnarchiver unarchiveObjectWithFile:[ATEngagementBackend cachedEngagementStoragePath]];
				[codePointInteractions addEntriesFromDictionary:archivedInteractions];
			} @catch (NSException *exception) {
				ATLogError(@"Unable to unarchive engagement: %@", exception);
			}
		}
	}
	return self;
}

- (void)dealloc {
	[codePointInteractions release], codePointInteractions = nil;
	[super dealloc];
}

- (void)checkForEngagementManifest {
	if ([self shouldRetrieveNewEngagementManifest]) {
		ATEngagementGetManifestTask *task = [[ATEngagementGetManifestTask alloc] init];
		[[ATTaskQueue sharedTaskQueue] addTask:task];
		[task release], task = nil;
	}
}

- (BOOL)shouldRetrieveNewEngagementManifest {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	NSDate *expiration = [defaults objectForKey:ATEngagementCachedInteractionsExpirationPreferenceKey];
	if (expiration) {
		NSDate *now = [NSDate date];
		NSComparisonResult comparison = [expiration compare:now];
		if (comparison == NSOrderedSame || comparison == NSOrderedAscending) {
			return YES;
		} else {
			NSFileManager *fm = [NSFileManager defaultManager];
			if (![fm fileExistsAtPath:[ATEngagementBackend cachedEngagementStoragePath]]) {
				// If no file, check anyway.
				return YES;
			}
			return NO;
		}
	} else {
		return YES;
	}
}

- (void)didReceiveNewCodePointInteractions:(NSDictionary *)receivedCodePointInteractions maxAge:(NSTimeInterval)expiresMaxAge {
	@synchronized(self) {
		[NSKeyedArchiver archiveRootObject:receivedCodePointInteractions toFile:[ATEngagementBackend cachedEngagementStoragePath]];
		// Store expiration.
		if (expiresMaxAge > 0) {
			NSDate *date = [NSDate dateWithTimeInterval:expiresMaxAge sinceDate:[NSDate date]];
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			[defaults setObject:date forKey:ATEngagementCachedInteractionsExpirationPreferenceKey];
			[defaults synchronize];
		}
		
		[codePointInteractions removeAllObjects];
		[codePointInteractions addEntriesFromDictionary:receivedCodePointInteractions];
	}
}

+ (NSString *)cachedEngagementStoragePath {
	return [[[ATBackend sharedBackend] supportDirectoryPath] stringByAppendingPathComponent:@"cachedinteractions.objects"];
}

- (NSArray *)interactionsForCodePoint:(NSString *)codePoint {
	return [codePointInteractions objectForKey:codePoint];
}

- (ATInteraction *)interactionForCodePoint:(NSString *)codePoint {
	NSArray *interactions = [self interactionsForCodePoint:codePoint];
	for (ATInteraction *interaction in interactions) {
		if ([interaction criteriaAreMetForCodePoint:codePoint]) {
			return interaction;
		}
	}
	return nil;
}


- (NSDictionary *)usageDataForInteraction:(ATInteraction *)interaction
							  atCodePoint:(NSString *)codePoint
						 daysSinceInstall:(NSNumber *)daysSinceInstall
						 daysSinceUpgrade:(NSNumber *)daysSinceUpgrade
					   applicationVersion:(NSString *)applicationVersion
					codePointInvokesTotal:(NSNumber *)codePointInvokesTotal
				  codePointInvokesVersion:(NSNumber *)codePointInvokesVersion
				  interactionInvokesTotal:(NSNumber *)interactionInvokesTotal
				interactionInvokesVersion:(NSNumber *)interactionInvokesVersion {
	
	NSDictionary *data = @{@"days_since_install": daysSinceInstall,
						@"days_since_upgrade" : daysSinceUpgrade,
						@"application_version" : applicationVersion,
						[NSString stringWithFormat:@"code_point_%@_invokes_total", codePoint] : codePointInvokesTotal,
						[NSString stringWithFormat:@"code_point_%@_invokes_version", codePoint] : codePointInvokesVersion,
						[NSString stringWithFormat:@"interactions_%@_invokes_total", interaction.identifier] : interactionInvokesTotal,
						[NSString stringWithFormat:@"interactions_%@_invokes_version", interaction.identifier] : interactionInvokesVersion};
	return data;
}

- (NSDictionary *)usageDataForInteraction:(ATInteraction *)interaction atCodePoint:(NSString *)codePoint {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	NSDate *installDate = [defaults objectForKey:ATEngagementInstallDateKey];
	NSDate *upgradeDate = [defaults objectForKey:ATEngagementUpgradeDateKey];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];	
	NSNumber *daysSinceInstall = @([[calendar components:NSDayCalendarUnit fromDate:installDate toDate:[NSDate date] options:0] day] + 1);
	NSNumber *daysSinceUpgrade = @([[calendar components:NSDayCalendarUnit fromDate:upgradeDate toDate:[NSDate date] options:0] day] + 1);
	[calendar release];
	
	NSString *applicationVersion = [defaults objectForKey:ATAppRatingFlowLastUsedVersionKey];
	NSNumber *codepointInvokesTotal = [[defaults objectForKey:ATEngagementCodePointsInvokesTotalKey] objectForKey:codePoint] ?: @0;
	NSNumber *codepointInvokesVersion = [[defaults objectForKey:ATEngagementCodePointsInvokesVersionKey] objectForKey:codePoint] ?: @0;
	NSNumber *interactionInvokesTotal = [[defaults objectForKey:ATEngagementInteractionsInvokesTotalKey] objectForKey:interaction.identifier] ?: @0;
	NSNumber *interactionInvokesVersion = [[defaults objectForKey:ATEngagementInteractionsInvokesVersionKey] objectForKey:interaction.identifier] ?: @0;
	
	NSDictionary *data = [self usageDataForInteraction:interaction
										   atCodePoint:codePoint
									  daysSinceInstall:daysSinceInstall 
									  daysSinceUpgrade:daysSinceUpgrade
									applicationVersion:applicationVersion
								 codePointInvokesTotal:codepointInvokesTotal
							   codePointInvokesVersion:codepointInvokesVersion
							   interactionInvokesTotal:interactionInvokesTotal
							 interactionInvokesVersion:interactionInvokesVersion];
	return data;
}

- (void)codePointWasEngaged:(NSString *)codePoint {
	NSMutableDictionary *codePointsInvokesTotal = [[[NSUserDefaults standardUserDefaults] objectForKey:ATEngagementCodePointsInvokesTotalKey] mutableCopy];
	NSNumber *codePointInvokesTotal = [codePointsInvokesTotal objectForKey:codePoint] ?: @0;
	codePointInvokesTotal = @(codePointInvokesTotal.intValue + 1);
	[codePointsInvokesTotal setObject:codePointInvokesTotal forKey:codePoint];
	[[NSUserDefaults standardUserDefaults] setObject:codePointsInvokesTotal forKey:ATEngagementCodePointsInvokesTotalKey];
	
	NSMutableDictionary *codePointsInvokesVersion = [[[NSUserDefaults standardUserDefaults] objectForKey:ATEngagementCodePointsInvokesVersionKey] mutableCopy];
	NSNumber *codePointInvokesVersion = [codePointsInvokesVersion objectForKey:codePoint] ?: @0;
	codePointInvokesVersion = @(codePointInvokesVersion.intValue + 1);
	[codePointsInvokesVersion setObject:codePointInvokesVersion forKey:codePoint];
	[[NSUserDefaults standardUserDefaults] setObject:codePointsInvokesVersion forKey:ATEngagementCodePointsInvokesVersionKey];
}

- (void)interactionWasEngaged:(ATInteraction *)interaction {
	NSMutableDictionary *interactionsInvokesTotal = [[[NSUserDefaults standardUserDefaults] objectForKey:ATEngagementInteractionsInvokesTotalKey] mutableCopy];
	NSNumber *interactionInvokesTotal = [interactionsInvokesTotal objectForKey:interaction.identifier] ?: @0;
	interactionInvokesTotal = @(interactionInvokesTotal.intValue + 1);
	[interactionsInvokesTotal setObject:interactionInvokesTotal forKey:interaction.identifier];
	[[NSUserDefaults standardUserDefaults] setObject:interactionsInvokesTotal forKey:ATEngagementInteractionsInvokesTotalKey];
	
	NSMutableDictionary *interactionsInvokesVersion = [[[NSUserDefaults standardUserDefaults] objectForKey:ATEngagementInteractionsInvokesVersionKey] mutableCopy];
	NSNumber *interactionInvokesVersion = [interactionsInvokesVersion objectForKey:interaction.identifier] ?: @0;
	interactionInvokesVersion = @(interactionInvokesVersion.intValue +1);
	[interactionsInvokesVersion setObject:interactionInvokesVersion forKey:interaction.identifier];
	[[NSUserDefaults standardUserDefaults] setObject:interactionsInvokesVersion forKey:ATEngagementInteractionsInvokesVersionKey];
}

@end
