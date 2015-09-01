//
//  HoughPlugIn.m
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

#import "HoughPlugIn.h"
#import "HoughOutputImage.h"

@import Accelerate;

#define	kQCPlugIn_Name			@"Hough"
#define	kQCPlugIn_Description   @"Perform a Hough transformation on an image."

@implementation HoughPlugIn

@dynamic inputImage, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    static NSDictionary *propertyDictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propertyDictionary = @{
            @"inputImage": @{QCPortAttributeNameKey: @"Image", QCPortAttributeTypeKey: QCPortTypeImage},
            @"outputImage": @{QCPortAttributeNameKey: @"Image", QCPortAttributeTypeKey: QCPortTypeString}
        };
    });

    return propertyDictionary[key];
}

+ (QCPlugInExecutionMode)executionMode {
	return kQCPlugInExecutionModeProcessor;
}

+ (QCPlugInTimeMode)timeMode {
	return kQCPlugInTimeModeNone;
}

@end

@implementation HoughPlugIn (Execution)

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> image = self.inputImage;
    self.outputImage = [[HoughOutputImage alloc] initWithImage:image];
    
    return YES;
}

@end
