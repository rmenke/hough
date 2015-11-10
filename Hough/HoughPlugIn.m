//
//  HoughPlugIn.m
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

#import "HoughPlugIn.h"
#import "HoughUtility.h"

@import Darwin.C.tgmath;
@import Accelerate;
@import simd;

_Static_assert(sizeof(float) == 4, "floats should be 32-bit");

#define kQCPlugIn_Name          @"Hough"
#define kQCPlugIn_Description   @"Perform a Hough transformation on an image."

#define R @"R"
#define T @"θ"

#define QCLog(...) [context logMessage:__VA_ARGS__]

/*!
 * The following uses a power-of-two to make life easier for
 * <code>_sinpi()</code> and friends.  N/256 is always exact in
 * floating point.
 */
static const NSInteger kHoughPartsPerSemiturn = 256;

/*!
 * Hough space is periodic such that the value at
 * (r, ϴ) ≣ ((-1)ⁿ×r, ϴ+nπ) for all r, ϴ, and integers n.  This can be
 * determined by subsitution using the parametric form of the line
 * r = x cos(ϴ) + y sin(ϴ).  Rather than constructing a special
 * variant of the "max" morphological operator that understands this,
 * we simply extend the window of Hough space to include enough
 * duplicate registers to allow the normal "max" operation to work
 * correctly: namely, half the width of the kernel, rounded up. This
 * extra space is called the margin.
 */
static const NSInteger kHoughRasterMargin = 25;

void __buffer_release(const void *address, void *context) {
    free((void *)address);
}

FOUNDATION_STATIC_INLINE
void findIntercepts(const CGFloat r, const CGFloat semiturns, const CGFloat width, const CGFloat height, CGPoint *p1, CGPoint *p2) {
    const CGFloat sin_theta = __sinpi(semiturns), cos_theta = __cospi(semiturns);

    if (sin_theta == 0.0) {
        CGFloat x = r / cos_theta;
        p1->x = p2->x = x;
        p1->y = 0; p2->y = height;
    } else if (cos_theta == 0.0) {
        CGFloat y = r / sin_theta;
        p1->x = 0; p2->x = width;
        p1->y = p2->y = y;
    } else {
        CGFloat x0 = r / cos_theta;
        CGFloat y0 = r / sin_theta;
        CGFloat x1 = (r - height * sin_theta) / cos_theta;
        CGFloat y1 = (r - width * cos_theta) / sin_theta;

        if (0.0 <= x0 && x0 <= width) {
            p1->x = x0; p1->y = 0;
        } else if (0.0 <= y0 && y0 <= height) {
            p1->x = 0; p1->y = y0;
        } else if (0.0 <= x1 && x1 <= width) {
            p1->x = x1; p1->y = height;
        } else { // if (0.0 <= y1 && y1 <= height)
            p1->x = width; p1->y = y1;
        }

        if (0.0 <= y1 && y1 <= height) {
            p2->x = width; p2->y = y1;
        } else if (0.0 <= x1 && x1 <= width) {
            p2->x = x1; p2->y = height;
        } else if (0.0 <= y0 && y0 <= height) {
            p2->x = 0; p2->y = y0;
        } else { // if (0.0 <= x0 && x0 <= width)
            p2->x = x0; p2->y = 0;
        }
    }
}

@implementation HoughPlugIn {
    CGColorSpaceRef _gray, _bgra;
}

@dynamic inputImage, inputThreshold, inputAllowedSlant, outputStructure, outputImage;

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
            @"inputAllowedSlant": @{QCPortAttributeNameKey: @"Slant Tolerance", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(0.0), QCPortAttributeMinimumValueKey: @(0.0), QCPortAttributeMaximumValueKey: @(1.0)},
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
    if (!_gray) {
        QCLog(@"Could not create color space %@", kCGColorSpaceGenericGray);
        return NO;
    }

    _bgra = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    if (!_bgra) {
        QCLog(@"Could not create color space %@", kCGColorSpaceGenericRGB);
        return NO;
    }

    return YES;
}

- (void)stopExecution:(id<QCPlugInContext>)context {
    if (_bgra) CGColorSpaceRelease(_bgra);
    if (_gray) CGColorSpaceRelease(_gray);
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments {
    id<QCPlugInInputImageSource> inputImage = self.inputImage;

    if (inputImage == nil) {
        self.outputImage = nil;
        self.outputStructure = @[];
        return YES;
    }

    CGFloat threshold = self.inputThreshold;

    if (threshold > 1) threshold = 1;
    if (threshold < 0) threshold = 0;

    // allowedSlant ∈ [0, 0.25]
    const CGFloat allowedSlant = self.inputAllowedSlant / 4.0;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:inputImage.imageBounds]) return NO;

    const void *data  = [inputImage bufferBaseAddress];
    size_t rowBytes   = [inputImage bufferBytesPerRow];
    NSUInteger width  = [inputImage bufferPixelsWide];
    NSUInteger height = [inputImage bufferPixelsHigh];

    if (width == 0 || height == 0) return NO;

    // r ∈ [-biasR, biasR]
    NSInteger biasR = ceil(hypot(width, height));

    const NSUInteger bufferWidth = kHoughPartsPerSemiturn + 2 * kHoughRasterMargin;

    vImage_Buffer buffer;
    vImage_Error error;

    if ((error = vImageBuffer_Init(&buffer, 2 * biasR + 1, bufferWidth, 32, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageBuffer_Init: error = %zd", error);
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
                    for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
                        const CGFloat semiturns = (CGFloat)(theta - kHoughRasterMargin) / (CGFloat)(kHoughPartsPerSemiturn);
                        const CGFloat sin_theta = __sinpi(semiturns), cos_theta = __cospi(semiturns);

                        NSInteger r = lround(x * cos_theta + y * sin_theta);

                        if (r >= -biasR && r <= +biasR) {
                            volatile int32_t *cell = buffer.data + (buffer.rowBytes * (r + biasR)) + (theta * sizeof(int32_t));
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
        free(buffer.data);
        self.outputImage = nil;
        self.outputStructure = @[];
        return YES;
    }

    [inputImage unlockBufferRepresentation];

    dispatch_apply(buffer.height, queue, ^(size_t r) {
        float * const row = buffer.data + buffer.rowBytes * r;
        for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
            float * const cell = row + theta;
            *cell = *(int32_t *)(cell);
        }
    });

    vImage_Buffer maxima;

    if ((error = vImageBuffer_Init(&maxima, buffer.height, kHoughPartsPerSemiturn, 32, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageBuffer_Init: error = %zd", error);
        free(buffer.data);
        return NO;
    }

    NSUInteger kernelSize = kHoughRasterMargin * 2 - 1;

    if ((error = vImageMax_PlanarF(&buffer, &maxima, NULL, kHoughRasterMargin, 0, kernelSize, kernelSize, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageMax_PlanarF: error = %zd", error);
        free(maxima.data);
        free(buffer.data);
        return NO;
    }

    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *horizontal = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *vertical   = [NSMutableArray array];

    // The coordinate translation in the buffer.
    const vector_double2 offset = { biasR, kHoughRasterMargin };
    const vector_double2 scale  = { 1.0, kHoughPartsPerSemiturn };

    for (NSInteger r = 0; r < buffer.height; ++r) {
        float * const srcRow = buffer.data + (buffer.rowBytes * r) + (kHoughRasterMargin * sizeof(float));
        float * const maxRow = maxima.data + (maxima.rowBytes * r);

        for (NSInteger theta = 0; theta < kHoughPartsPerSemiturn; ++theta) {
            const float value = srcRow[theta];
            if (maxRow[theta] == value && value > 10.0) {
                vector_double2 cluster = clusterCenter(context, &buffer, r, theta + kHoughRasterMargin, value);
                cluster -= offset;
                cluster /= scale;

                // Cluster is outside of the ROI. Its mirror image
                // will be in the ROI, so do not count it twice.
                if (cluster.y < 0.0 || cluster.y >= 1.0) continue;

                // semiturnsFromHorizontal ∈ [0, 0.5]
                const double semiturnsFromHorizontal = fabs(fmod(cluster.y, 1.0) - 0.5);

                NSDictionary * const line = @{R:@(cluster.x), T:@(cluster.y)};

                if (semiturnsFromHorizontal <= allowedSlant) { // near horizontal
                    [horizontal addObject:line];
                } else if (semiturnsFromHorizontal >= 0.5 - allowedSlant) { // near vertical
                    [vertical addObject:line];
                }
            }
        }
    }

    free(buffer.data);
    free(maxima.data);

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatBGRA8 colorSpace:_bgra forBounds:inputImage.imageBounds]) return NO;

    buffer.width    = [inputImage bufferPixelsWide];
    buffer.height   = [inputImage bufferPixelsHigh];
    buffer.rowBytes = [inputImage bufferBytesPerRow];
    buffer.data     = valloc(buffer.height * buffer.rowBytes);

    if (buffer.data == NULL) {
        QCLog(@"Memory allocation failure");
        return NO;
    }

    memcpy(buffer.data, [inputImage bufferBaseAddress], buffer.height * buffer.rowBytes);

    [inputImage unlockBufferRepresentation];

    CGContextRef ctx = CGBitmapContextCreate(buffer.data, buffer.width, buffer.height, 8, buffer.rowBytes, _bgra, kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
    if (ctx == NULL) {
        free(buffer.data);
        QCLog(@"CGBitmapContextCreate failed");
        return NO;
    }

    CGContextTranslateCTM(ctx, 0, buffer.height);
    CGContextScaleCTM(ctx, 1, -1);

    CGContextSetRGBStrokeColor(ctx, 1, 0, 0, 1);

    NSArray *lines = [[NSArray arrayWithArray:horizontal] arrayByAddingObjectsFromArray:vertical];

    for (NSDictionary<NSString *, NSNumber *> *line in lines) {
        CGFloat r = line[R].doubleValue;
        CGFloat semiturns = line[T].doubleValue;

        CGPoint p1, p2;

        const CGFloat height = buffer.height;
        const CGFloat width  = buffer.width;

        findIntercepts(r, semiturns, width, height, &p1, &p2);

        CGContextMoveToPoint(ctx, p1.x, p1.y);
        CGContextAddLineToPoint(ctx, p2.x, p2.y);
    }

    CGContextStrokePath(ctx);

    CGContextRelease(ctx);

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatBGRA8 pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_bgra shouldColorMatch:YES];

    self.outputStructure = lines;

    return YES;
}

@end
