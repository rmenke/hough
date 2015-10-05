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

#define kQCPlugIn_Name          @"Hough"
#define kQCPlugIn_Description   @"Perform a Hough transformation on an image."

#define PER_SEMITURN 180

typedef struct Line { NSUInteger r, theta; int32_t pixelCount; } Line;

int _line_compare(const void *a, const void *b) {
    return ((Line *)b)->pixelCount - ((Line *)a)->pixelCount;
}

void __buffer_release(const void *address, void *context) {
    free((void *)address);
}

@implementation HoughPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputThreshold, outputStructure, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    static NSDictionary *propertyDictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propertyDictionary = @{
            @"inputImage": @{QCPortAttributeNameKey: @"Image"},
            @"inputThreshold": @{QCPortAttributeNameKey: @"Threshold", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(0.5), QCPortAttributeMinimumValueKey: @(0.0), QCPortAttributeMaximumValueKey: @(1.0)},
            @"outputStructure": @{QCPortAttributeNameKey: @"Line Info", QCPortAttributeTypeKey: QCPortTypeStructure},
            @"outputImage": @{QCPortAttributeNameKey: @"Output"}
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

- (BOOL)startExecution:(id<QCPlugInContext>)context {
    _gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    return _gray != NULL;
}

- (void)stopExecution:(id<QCPlugInContext>)context {
    if (_gray) CGColorSpaceRelease(_gray);
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> inputImage = self.inputImage;

    if (inputImage == nil) {
        self.outputImage = nil;
        self.outputStructure = @[];
        return YES;
    }

    float threshold = self.inputThreshold;

    if (threshold > 1) threshold = 1;
    if (threshold < 0) threshold = 0;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:inputImage.imageBounds]) return NO;

    const void *data  = [inputImage bufferBaseAddress];
    size_t rowBytes   = [inputImage bufferBytesPerRow];
    NSUInteger width  = [inputImage bufferPixelsWide];
    NSUInteger height = [inputImage bufferPixelsHigh];

    if (width == 0 || height == 0) return NO;

    NSInteger biasR = ceil(hypot(width, height));

    const NSInteger minTheta = 0;
    const NSInteger maxTheta = PER_SEMITURN;

    NSInteger rangeR     = 2 * biasR + 1;
    NSInteger rangeTheta = maxTheta - minTheta;

    vImage_Buffer buffer;
    vImage_Error error;

    if ((error = vImageBuffer_Init(&buffer, rangeR, rangeTheta, 32, kvImageNoFlags)) != kvImageNoError) {
        [context logMessage:@"vImageBuffer_Init: error = %zd", error];
        return NO;
    }

    memset(buffer.data, 0, buffer.rowBytes * buffer.height);

    __block volatile int32_t max = 0;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger y = 0; y < height; ++y) {
        float *row = (float *)(data + y * rowBytes);
        for (NSUInteger x = 0; x < width; ++x) {
            float *cell = row + x;
            if (*cell <= threshold) {
                dispatch_group_async(group, queue, ^{
                    for (NSInteger theta = minTheta; theta < maxTheta; ++theta) {
                        const CGFloat semiturns = theta / (CGFloat)(PER_SEMITURN);

                        CGFloat sin_theta, cos_theta;
                        __sincospi(semiturns, &sin_theta, &cos_theta);

                        NSInteger r = lround(x * cos_theta + y * sin_theta);

                        if (r >= -biasR && r <= +biasR) {
                            volatile int32_t *cell = buffer.data + (buffer.rowBytes * (r + biasR));
                            cell += theta - minTheta;
                            int32_t count = OSAtomicIncrement32(cell);
                            BOOL done = NO;
                            do {
                                int32_t oldMax = max;
                                done = (count <= oldMax) || OSAtomicCompareAndSwap32(oldMax, count, &max);
                            } while (!done);
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (max == 0) {
        self.outputImage = nil;
        self.outputStructure = @[];
        return YES;
    }

    [inputImage unlockBufferRepresentation];

    dispatch_apply(rangeR, queue, ^(size_t r) {
        Float32 * const row = buffer.data + buffer.rowBytes * r;
        for (NSInteger theta = 0; theta < rangeTheta; ++theta) {
            Float32 * const cell = row + theta;
            *cell = *(int32_t *)(cell);
        }
    });

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatIf pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];

    self.outputStructure = @[];

    return YES;
}

@end
