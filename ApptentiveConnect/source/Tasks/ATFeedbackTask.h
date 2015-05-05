//
//  ATFeedbackTask.h
//  ApptentiveConnect
//
//  Created by Andrew Wooster on 3/20/11.
//  Copyright 2011 Apptentive, Inc.. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "ATTask.h"
#import "ATAPIRequest.h"

@class ATFeedback;

@interface ATFeedbackTask : ATTask <ATAPIRequestDelegate>
@property (nonatomic, strong) ATFeedback *feedback;

@end
