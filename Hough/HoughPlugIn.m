//
//  HoughPlugIn.m
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

#import "HoughPlugIn.h"
#import "HoughUtility.h"

@import Darwin.C.tgmath;
@import Accelerate;
@import simd;

_Static_assert(sizeof(float) == 4, "floats should be 32-bit");

#define kQCPlugIn_Name          @"Hough"
#define kQCPlugIn_Description   @"Perform a Hough transformation on an image."

#define R @"r"
#define T @"θ"
#define C @"#"

#define QCLog(...) [context logMessage:__VA_ARGS__]

#if CGFLOAT_IS_DOUBLE
#define cgFloatValue doubleValue
#else
#define cgFloatValue floatValue
#endif

/*!
 * The following uses a power-of-two to make life easier for
 * <code>_sinpi()</code> and friends.  N/256 is always exact in
 * floating point.
 */
static const NSInteger kHoughPartsPerSemiturn = 256;

void __buffer_release(const void *address, void *context) {
    free((void *)address);
}

@implementation HoughPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputMargin, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    if ([key isEqualToString:@"inputImage"]) {
        return @{QCPortAttributeNameKey: @"Image"};
    } else if ([key isEqualToString:@"inputMargin"]) {
        return @{QCPortAttributeNameKey: @"Margin", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(0.5), QCPortAttributeMinimumValueKey: @(0.0), QCPortAttributeMaximumValueKey: @(2.0)};
    } else if ([key isEqualToString:@"outputImage"]) {
        return @{QCPortAttributeNameKey: @"Image"};
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

@implementation HoughPlugIn (Execution)

- (BOOL)startExecution:(id<QCPlugInContext>)context {
    _gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    if (!_gray) {
        QCLog(@"Could not create color space %@", kCGColorSpaceGenericGray);
        return NO;
    }

    return YES;
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

    /*!
     * Hough space is periodic such that the value at
     * (r, ϴ) ≣ ((-1)ⁿ×r, ϴ+nπ) for all r, ϴ, and integers n.  This can be
     * determined by substitution using the parametric form of the line
     * r = x·cos(ϴ) + y·sin(ϴ).  Rather than constructing a special
     * variant of the "max" morphological operator that understands this,
     * we simply extend the window of Hough space to include enough
     * duplicate registers to allow the normal "max" operation to work
     * correctly: namely, half the width of the kernel, rounded up. This
     * extra space is called the margin.  The input margin is measured in
     * semiturns.
     */
    const NSInteger rasterMargin = self.inputMargin * kHoughPartsPerSemiturn;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:inputImage.imageBounds]) return NO;

    const void *data  = [inputImage bufferBaseAddress];
    size_t rowBytes   = [inputImage bufferBytesPerRow];
    NSUInteger width  = [inputImage bufferPixelsWide];
    NSUInteger height = [inputImage bufferPixelsHigh];

    if (width == 0 || height == 0) {
        self.outputImage = nil;
        return YES;
    }

    // r ∈ [0, maxR)
    const NSInteger maxR = ceil(hypot(width, height));

    // θ ∈ [-margin, 2 + margin) [in semiturns]
    const NSUInteger bufferWidth = 2 * (kHoughPartsPerSemiturn + rasterMargin);

    vImage_Buffer buffer;
    vImage_Error error;

    if ((error = vImageBuffer_Init(&buffer, maxR, bufferWidth, 32, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageBuffer_Init: error = %zd", error);
        return NO;
    }

    memset(buffer.data, 0, buffer.rowBytes * buffer.height);

    __block volatile int32_t maxRegister = 0;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger y = 0; y < height; ++y) {
        float *row = (float *)(data + y * rowBytes);
        for (NSUInteger x = 0; x < width; ++x) {
            if (row[x] < 0.5) {
                dispatch_group_async(group, queue, ^{
                    for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
                        const CGFloat semiturns = (CGFloat)(theta - rasterMargin) / (CGFloat)(kHoughPartsPerSemiturn);
                        const CGFloat sin_theta = __sinpi(semiturns), cos_theta = __cospi(semiturns);

                        NSInteger r = lround(x * cos_theta + y * sin_theta);

                        if (0 <= r && r < maxR) {
                            volatile int32_t *cell = buffer.data + (buffer.rowBytes * r) + (theta * sizeof(int32_t));
                            int32_t count = OSAtomicIncrement32(cell);
                            BOOL done;
                            do {
                                int32_t oldMax = maxRegister;
                                done = (oldMax >= count) || OSAtomicCompareAndSwap32(oldMax, count, &maxRegister);
                            } while (!done);
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    [inputImage unlockBufferRepresentation];

    // Accessing maxRegister is an expensive operation because it is marked volatile.
    // By this point, its volatility is no longer necessary.
    uint32_t maxValue = maxRegister;

    if (maxValue == 0) {
        self.outputImage = nil;
        return YES;
    }

    maxValue--;
    maxValue |= maxValue >> 1;
    maxValue |= maxValue >> 2;
    maxValue |= maxValue >> 4;
    maxValue |= maxValue >> 8;
    maxValue |= maxValue >> 16;
    maxValue++;

    const float scaleFactor = maxValue;

    dispatch_apply(buffer.height, queue, ^(size_t r) {
        float * const row = buffer.data + buffer.rowBytes * r;
        for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
            float * const cell = row + theta;
            *cell = *(int32_t *)(cell) / scaleFactor;
        }
    });

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatIf pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];

    return YES;
}

@end
