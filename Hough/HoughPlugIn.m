//
//  HoughPlugIn.m
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

#import "HoughPlugIn.h"

@import Darwin.C.tgmath;
@import Accelerate;

#define	kQCPlugIn_Name			@"Hough"
#define	kQCPlugIn_Description   @"Perform a Hough transformation on an image."

@implementation HoughPlugIn
@dynamic inputImage, inputThreshold;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    static NSDictionary *propertyDictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propertyDictionary = @{
            @"inputImage": @{QCPortAttributeNameKey: @"Image", QCPortAttributeTypeKey: QCPortTypeImage},
            @"inputThreshold": @{QCPortAttributeNameKey: @"Threshold", QCPortAttributeTypeKey: QCPortTypeString, QCPortAttributeDefaultValueKey: @(127), QCPortAttributeMinimumValueKey: @(0), QCPortAttributeMaximumValueKey: @(255)}
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
    NSUInteger threshold = self.inputThreshold;

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    if (gray == NULL) return NO;

    if (![image lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatI8
                                             colorSpace:gray forBounds:image.imageBounds]) {
        CGColorSpaceRelease(gray);
        return NO;
    }

    const void *data = [image bufferBaseAddress];
    size_t rowBytes = [image bufferBytesPerRow];
    NSUInteger width = [image bufferPixelsWide];
    NSUInteger height = [image bufferPixelsHigh];

    NSUInteger maxR = ceil(hypot(width, height));

    volatile int32_t __block *registers = calloc(maxR, sizeof(int32_t[360]));

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger y = 0; y < height; ++y) {
        uint8_t *row = ((uint8_t *)data) + y * rowBytes;
        for (NSUInteger x = 0; x < width; ++x) {
            uint8_t *cell = row + x;
            if (*cell > threshold) {
                dispatch_group_async(group, queue, ^{
                    for (NSUInteger theta = 0; theta < 360; ++theta) {
                        double tRadians = (double)theta * M_PI / 180.0;
                        NSInteger r = floor(x * cos(tRadians) + y * sin(tRadians));
                        if (r >= 0 && r < maxR) {
                            OSAtomicIncrement32(registers + (theta + r * 360));
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    // TODO: Analyze the registers, find the line segments

    free((void *)registers);

    CGColorSpaceRelease(gray);

    return YES;
}

@end
