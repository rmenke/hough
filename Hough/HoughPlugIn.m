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

typedef struct Line { NSUInteger r, theta; int32_t pixelCount; } Line;

static int _compare_cells(const void *a, const void *b) {
    int32_t x = ((const Line *)(a))->pixelCount;
    int32_t y = ((const Line *)(b))->pixelCount;

    return y - x;
}

static void _bufferReleaseCallback(const void* address, void* context) {
    free((void *)address);
}

@implementation HoughPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputThreshold, inputLineCount, outputStructure, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    static NSDictionary *propertyDictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propertyDictionary = @{
            @"inputImage": @{QCPortAttributeNameKey: @"Image"},
            @"inputThreshold": @{QCPortAttributeNameKey: @"Threshold", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(127), QCPortAttributeMinimumValueKey: @(0), QCPortAttributeMaximumValueKey: @(255)},
            @"inputLineCount": @{QCPortAttributeNameKey: @"Line Count", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(10), QCPortAttributeMinimumValueKey: @(1)},
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

#define NSLog(...) [context logMessage:__VA_ARGS__]

@implementation HoughPlugIn (Execution)

- (BOOL)startExecution:(id<QCPlugInContext>)context {
    _gray = CGColorSpaceCreateDeviceGray();
    return _gray != NULL;
}

- (void)stopExecution:(id<QCPlugInContext>)context {
    if (_gray) CGColorSpaceRelease(_gray);
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> inputImage = self.inputImage;

    if (inputImage == nil) {
        self.outputImage = nil;
        return YES;
    }

    NSUInteger threshold = self.inputThreshold;

    if (threshold > 255) threshold = 255;
    if (threshold < 1)   threshold = 1;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatI8 colorSpace:_gray forBounds:inputImage.imageBounds]) return NO;

    const void *data  = [inputImage bufferBaseAddress];
    size_t rowBytes   = [inputImage bufferBytesPerRow];
    NSUInteger width  = [inputImage bufferPixelsWide];
    NSUInteger height = [inputImage bufferPixelsHigh];

    if (width == 0 || height == 0) return NO;

    NSUInteger maxR = ceil(hypot(width, height));

    if (maxR == 0) return NO;

    NSMutableData *registers = [NSMutableData dataWithLength:maxR * 360 * sizeof(int32_t)];

    volatile int32_t (*writeRegister)[360] = (volatile int32_t (*)[360])(registers.mutableBytes);

    __block volatile int32_t max = -1;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger y = 0; y < height; ++y) {
        uint8_t *row = ((uint8_t *)data) + y * rowBytes;
        for (NSUInteger x = 0; x < width; ++x) {
            uint8_t *cell = row + x;
            if (*cell <= threshold) {
                dispatch_group_async(group, queue, ^{
                    for (NSUInteger theta = 0; theta < 360; ++theta) {
                        double tRadians = (double)(theta) * (M_PI / 180.0);
                        NSInteger r = floor(x * cos(tRadians) + y * sin(tRadians));
                        if (r >= 0 && r < maxR) {
                            int32_t count = OSAtomicIncrement32(&(writeRegister[r][theta]));
                            BOOL done;
                            do {
                                int32_t oldMax = max;
                                int32_t newMax = MAX(oldMax, count);
                                done = OSAtomicCompareAndSwap32(oldMax, newMax, &max);
                            } while (!done);
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    [inputImage unlockBufferRepresentation];

    const int32_t (*readRegister)[360] = (const int32_t (*)[360])(registers.bytes);

    const size_t count = self.inputLineCount;

    Line *lines = calloc(count * 2, sizeof(Line));

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(1);

    dispatch_apply(maxR, queue, ^(const size_t r) {
        Line local[count + 1]; memset(local, 0, sizeof(Line) * count);

        for (NSUInteger theta = 0; theta < 360; ++theta) {
            const int32_t pixelCount = readRegister[r][theta];

            if (pixelCount) {
                local[count].r = r;
                local[count].theta = theta;
                local[count].pixelCount = pixelCount;
                mergesort(local, count + 1, sizeof(Line), _compare_cells);
            }
        }

        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        memcpy(lines + count, local, sizeof(Line) * count);
        qsort(lines, count * 2, sizeof(Line), _compare_cells);

        dispatch_semaphore_signal(semaphore);
    });

    NSMutableArray *outputArray = [NSMutableArray array];

    for (int ix = 0; ix < count; ++ix) {
        [outputArray addObject:@{
            @"R": @(lines[ix].r),
            @"Theta": @(lines[ix].theta),
            @"PixelCount": @(lines[ix].pixelCount)
        }];
    }

    self.outputStructure = outputArray;

    free(lines);

    typedef int8_t QCPixel;

    NSUInteger outWidth = 360;
    NSUInteger outHeight = maxR;
    NSUInteger outRowBytes = outWidth * sizeof(QCPixel);
    outRowBytes += -outRowBytes & 15;
    void *outData = valloc(outHeight * outRowBytes);

    for (int r = 0; r < maxR; ++r) {
        QCPixel *outRow = (QCPixel *)(outData + r * outRowBytes);
        for (int theta = 0; theta < 360; ++theta) {
            outRow[theta] = 255 * (double)(readRegister[r][theta]) / (double)(max);
        }
    }

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatI8 pixelsWide:outWidth pixelsHigh:outHeight baseAddress:outData bytesPerRow:outRowBytes releaseCallback:&_bufferReleaseCallback releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];

    return YES;
}

@end
