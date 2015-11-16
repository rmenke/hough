//
//  ThresholdPlugIn.m
//  Hough
//
//  Created by Robert Menke on 11/16/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

#import "ThresholdPlugIn.h"

@import Accelerate.vImage;

#define	kQCPlugIn_Name				@"Threshold"
#define	kQCPlugIn_Description		@"Produce a bi-level image from a grayscale input"

static void buffer_release(const void *address, void *context) {
    free((void *)address);
}

@implementation ThresholdPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputThreshold, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    if ([key isEqualToString:@"inputImage"]) {
        return @{QCPortAttributeNameKey: @"Input Image"};
    } else if ([key isEqualToString:@"inputThreshold"]) {
        return @{QCPortAttributeNameKey: @"Threshold", QCPortAttributeDefaultValueKey: @(0.5), QCPortAttributeMinimumValueKey: @(0.0), QCPortAttributeMaximumValueKey: @(1.0)};
    } else if ([key isEqualToString:@"outputImage"]) {
        return @{QCPortAttributeNameKey: @"Output Image"};
    }

    return nil;
}

+ (QCPlugInExecutionMode)executionMode {
    return kQCPlugInExecutionModeProcessor;
}

+ (QCPlugInTimeMode)timeMode {
    return kQCPlugInTimeModeNone;
}

@end

#define QCLog(...) [context logMessage:__VA_ARGS__]

@implementation ThresholdPlugIn (Execution)

- (BOOL)startExecution:(id <QCPlugInContext>)context {
    _gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    if (_gray == NULL) {
        QCLog(@"Unable to allocate gray color space");
        return NO;
    }

    return YES;
}

- (void)stopExecution:(id <QCPlugInContext>)context {
    if (_gray) CGColorSpaceRelease(_gray);
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> inputImage = self.inputImage;

    if (inputImage == nil) {
        self.outputImage = nil;
        return YES;
    }

    CGFloat threshold = self.inputThreshold;

    vImage_Buffer buffer;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:[inputImage imageBounds]]) {
        QCLog(@"Unable to lock buffer representation");
        return NO;
    }

    buffer.height = [inputImage bufferPixelsHigh];
    buffer.width = [inputImage bufferPixelsWide];
    buffer.rowBytes = [inputImage bufferBytesPerRow];

    size_t size = buffer.height * buffer.rowBytes;
    buffer.data = valloc(size);

    if (buffer.data == NULL) {
        [inputImage unlockBufferRepresentation];
        QCLog(@"Unable to allocate %zu bytes of data", size);
        return NO;
    }

    memcpy(buffer.data, [inputImage bufferBaseAddress], size);

    [inputImage unlockBufferRepresentation];

    dispatch_apply(buffer.height, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t y) {
        float *row = buffer.data + buffer.rowBytes * y;
        for (size_t x = 0; x < buffer.width; ++x) {
            row[x] = row[x] > threshold ? 1.0 : 0.0;
        }
    });

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatIf pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:buffer_release releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];

    return YES;
}

@end
