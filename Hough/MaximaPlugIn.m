//
//  MaximaPlugIn.m
//  Maxima
//
//  Created by Robert Menke on 11/30/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import Accelerate;

#import "MaximaPlugIn.h"

#define	kQCPlugIn_Name				@"Maxima"
#define	kQCPlugIn_Description		@"Identify hot spots in an image (local maxima of intensity)"

@implementation MaximaPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputMargin, inputThreshold, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    if ([key isEqualToString:@"inputImage"]) {
        return @{QCPortAttributeNameKey:@"Image"};
    } else if ([key isEqualToString:@"inputMargin"]) {
        return @{QCPortAttributeNameKey:@"Margin", QCPortAttributeMinimumValueKey:@(0), QCPortAttributeDefaultValueKey:@(50)};
    } else if ([key isEqualToString:@"inputThreshold"]) {
        return @{QCPortAttributeNameKey:@"Threshold", QCPortAttributeMinimumValueKey:@(0.0), QCPortAttributeMaximumValueKey:@(1.0), QCPortAttributeDefaultValueKey:@(0.1)};
    } else if ([key isEqualToString:@"outputImage"]) {
        return @{QCPortAttributeNameKey:@"Image"};
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

@implementation MaximaPlugIn (Execution)

- (BOOL)startExecution:(id <QCPlugInContext>)context {
    if (_gray == nil) {
        _gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    }

    return _gray != NULL;
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> image = self.inputImage;

    const NSUInteger margin = self.inputMargin;
    const CGFloat threshold = self.inputThreshold;

    vImage_Error error;
    vImage_Buffer buffer, maxima = { .data = NULL };

    if (![image lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:[image imageBounds]]) {
        return NO;
    }

    @try {
        buffer.width = [image bufferPixelsWide];
        buffer.height = [image bufferPixelsHigh];
        buffer.rowBytes = [image bufferBytesPerRow];
        buffer.data = (void *)[image bufferBaseAddress];

        if (buffer.width <= 2 * margin) {
            return NO;
        }

        if ((error = vImageBuffer_Init(&maxima, buffer.height, buffer.width - 2 * margin, 32, kvImageNoFlags)) != kvImageNoError) {
            NSLog(@"vImageBuffer_Init: error = %zd", error);
            return NO;
        }

        size_t kernelSize = 2 * margin + 1;

        if ((error = vImageMax_PlanarF(&buffer, &maxima, NULL, margin, 0, kernelSize, kernelSize, kvImageNoFlags)) != kvImageNoError) {
            NSLog(@"vImageBuffer_Init: error = %zd", error);
            return NO;
        }

        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_apply(maxima.height, queue, ^(size_t row) {
            const float * const srcRow = buffer.data + (row * buffer.rowBytes) + (margin * sizeof(float));
            float * const maxRow = maxima.data + (row * maxima.rowBytes);
            for (int column = 0; column < maxima.width; ++column) {
                if (srcRow[column] <= threshold || srcRow[column] != maxRow[column]) {
                    maxRow[column] = 0.0f;
                }
            }
        });

        self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatIf pixelsWide:maxima.width pixelsHigh:maxima.height baseAddress:maxima.data bytesPerRow:maxima.rowBytes releaseCallback:(void (*)(const void *, void *))(free) releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];
        maxima.data = NULL;
    }
    @finally {
        if (maxima.data) free(maxima.data);
        [image unlockBufferRepresentation];
    }

	return YES;
}

- (void)stopExecution:(id <QCPlugInContext>)context {
    if (_gray) CGColorSpaceRelease(_gray);
}

@end
