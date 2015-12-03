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

static inline int32_t roundUpToPowerOfTwo(int32_t x) {
    NSCAssert(x > 0, @"arg must be positive, is %" PRId32, x);

    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x += 1;

    NSCAssert((x & (x - 1)) == 0, @"result should be a power of two, is %" PRId32, x);

    return x;
}

/*!
 * @abstract Conversion factor from semiturns (π㎭ or 180°) to a
 *   smaller value based on a power of two.
 * @discussion Using a power-of-two makes life easier for
 *   <code>__sinpi()</code> and friends.  N/256 is always exact in
 *   floating point and directly computable with the half-angle
 *   formulae.
 */
static const NSInteger kHoughPartsPerSemiturn = 256;

/*
 * This is dangerously non-portable, but works since we are allowed to
 * ignore superfluous parameters and 'const' in C99 is only a compiler
 * hint.
 */
static const QCPlugInBufferReleaseCallback __buffer_release = (void *)(free);

@implementation HoughPlugIn {
    CGColorSpaceRef _gray;
}

@dynamic inputImage, inputMargin, outputImage, outputMax;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    if ([key isEqualToString:@"inputImage"]) {
        return @{QCPortAttributeNameKey:@"Image"};
    } else if ([key isEqualToString:@"inputMargin"]) {
        return @{QCPortAttributeNameKey:@"Margin", QCPortAttributeDefaultValueKey:@(50), QCPortAttributeMaximumValueKey:@(100)};
    } else if ([key isEqualToString:@"outputImage"]) {
        return @{QCPortAttributeNameKey:@"Image"};
    } else if ([key isEqualToString:@"outputMax"]) {
        return @{QCPortAttributeNameKey:@"Maximum", QCPortAttributeMinimumValueKey:@(1)};
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
     * @abstract The additional width (in parts) to add to the Hough space.
     *
     * @discussion Hough space is periodic such that the value at
     *   (r, ϴ) = ((-1)ⁿ×r, ϴ+nπ) for all r, ϴ, and integers n.  This
     *   can be determined by substitution using the parametric form
     *   of the line r = x·cos(ϴ) + y·sin(ϴ).  Rather than
     *   constructing a special variant of the "max" morphological
     *   operator that understands this, we simply extend the window
     *   of Hough space to include enough duplicate registers to allow
     *   the normal "max" operation to work correctly.
     */
    const NSInteger rasterMargin = self.inputMargin;

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

    // θ ∈ [-margin, 2 + margin)
    const NSUInteger bufferWidth = 2 * (kHoughPartsPerSemiturn + rasterMargin);

    vImage_Buffer buffer;
    vImage_Error error;

    if ((error = vImageBuffer_Init(&buffer, maxR, bufferWidth, 32, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageBuffer_Init: error = %zd", error);
        return NO;
    }

    memset(buffer.data, 0, buffer.rowBytes * buffer.height);

    // Cannot be zero, because this value is used as a scaling factor.
    __block volatile int32_t volatileMaximum = 1;

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
                            volatile int32_t *cell = buffer.data + buffer.rowBytes * r + sizeof(int32_t) * theta;
                            int32_t count = OSAtomicIncrement32(cell);
                            BOOL done;
                            do {
                                int32_t oldMaximum = volatileMaximum;
                                if (!(done = oldMaximum >= count)) {
                                    done = OSAtomicCompareAndSwap32(oldMaximum, count, &volatileMaximum);
                                }
                            } while (!done);
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    [inputImage unlockBufferRepresentation];

    const CGFloat scale = roundUpToPowerOfTwo(volatileMaximum);

    typedef union {
        float f; int32_t i;
    } Cell;

    _Static_assert(sizeof(Cell) == 4, "Cells should be 32-bit");

    dispatch_apply(buffer.height, queue, ^(size_t r) {
        Cell * const row = buffer.data + buffer.rowBytes * r;
        for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
            Cell * const cell = row + theta;
            cell->f = cell->i / scale;
        }
    });

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatIf pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_gray shouldColorMatch:NO];
    self.outputMax = scale;

    return YES;
}

@end
