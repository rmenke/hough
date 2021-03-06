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

@implementation HoughPlugIn {
    CGColorSpaceRef _gray, _bgra;
}

@dynamic inputImage, inputAllowedSlant, inputMinWidth, inputMinHeight, outputStructure, outputImage;

+ (NSDictionary *)attributes {
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key {
    static NSDictionary *propertyDictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propertyDictionary = @{
            @"inputImage": @{QCPortAttributeNameKey: @"Image"},
            @"inputAllowedSlant": @{QCPortAttributeNameKey: @"Slant Tolerance", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(0.0), QCPortAttributeMinimumValueKey: @(0.0), QCPortAttributeMaximumValueKey: @(1.0)},
            @"inputMinWidth": @{QCPortAttributeNameKey: @"Min Width", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(50.0), QCPortAttributeMinimumValueKey: @(0.0)},
            @"inputMinHeight": @{QCPortAttributeNameKey: @"Min Height", QCPortAttributeTypeKey: QCPortTypeNumber, QCPortAttributeDefaultValueKey: @(50.0), QCPortAttributeMinimumValueKey: @(0.0)},
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

- (void)orderAndFilterLines:(NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *)lines {
    NSUInteger max = [[lines valueForKeyPath:@"@max.#"] unsignedIntegerValue];
    [lines filterUsingPredicate:[NSPredicate predicateWithFormat:@"SELF['#'] >= 0.9 * %lu", max]];
    [lines sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:R ascending:YES]]];
}

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

    // allowedSlant ∈ [0, 0.25]
    const CGFloat allowedSlant = self.inputAllowedSlant / 4.0;

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatIf colorSpace:_gray forBounds:inputImage.imageBounds]) return NO;

    const void *data  = [inputImage bufferBaseAddress];
    size_t rowBytes   = [inputImage bufferBytesPerRow];
    NSUInteger width  = [inputImage bufferPixelsWide];
    NSUInteger height = [inputImage bufferPixelsHigh];

    if (width == 0 || height == 0) return NO;

    // r ∈ [0, maxR)
    const NSInteger maxR = ceil(hypot(width, height));

    const NSUInteger bufferWidth = 2 * (kHoughPartsPerSemiturn + kHoughRasterMargin);

    vImage_Buffer buffer;
    vImage_Error error;

    if ((error = vImageBuffer_Init(&buffer, maxR, bufferWidth, 32, kvImageNoFlags)) != kvImageNoError) {
        QCLog(@"vImageBuffer_Init: error = %zd", error);
        return NO;
    }

    memset(buffer.data, 0, buffer.rowBytes * buffer.height);

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger y = 0; y < height; ++y) {
        float *row = (float *)(data + y * rowBytes);
        for (NSUInteger x = 0; x < width; ++x) {
            float *cell = row + x;
            if (*cell < 0.5) {
                dispatch_group_async(group, queue, ^{
                    for (NSInteger theta = 0; theta < bufferWidth; ++theta) {
                        const CGFloat semiturns = (CGFloat)(theta - kHoughRasterMargin) / (CGFloat)(kHoughPartsPerSemiturn);
                        const CGFloat sin_theta = __sinpi(semiturns), cos_theta = __cospi(semiturns);

                        NSInteger r = lround(x * cos_theta + y * sin_theta);

                        if (0 <= r && r < maxR) {
                            volatile int32_t *cell = buffer.data + (buffer.rowBytes * r) + (theta * sizeof(int32_t));
                            OSAtomicIncrement32(cell);
                        }
                    }
                });
            }
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

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
    const vector_double2 offset = { 0, kHoughRasterMargin };
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
                if (cluster.y < 0.0 || cluster.y >= 2.0) continue;

                // semiturnsFromHorizontal ∈ [0, 0.5]
                const double semiturnsFromHorizontal = fabs(fmod(cluster.y, 1.0) - 0.5);

                NSDictionary * const line = @{R:@(cluster.x), T:@(cluster.y), C:@(value)};

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

    [self orderAndFilterLines:horizontal];
    [self orderAndFilterLines:vertical];

    NSMutableArray<NSValue *> *rects = [NSMutableArray array];

    const NSInteger minWidth = self.inputMinWidth;
    const NSInteger minHeight = self.inputMinHeight;

    for (int x = 1; x < vertical.count; ++x) {
        CGFloat left = vertical[x - 1][R].cgFloatValue;
        CGFloat right = vertical[x][R].cgFloatValue;

        for (int y = 1; y < horizontal.count; ++y) {
            CGFloat top = horizontal[y - 1][R].cgFloatValue;
            CGFloat bottom = horizontal[y][R].cgFloatValue;

            CGRect r = CGRectMake(left, top, right - left, bottom - top);

            if (CGRectGetWidth(r) >= minWidth && CGRectGetHeight(r) >= minHeight) {
                [rects addObject:[NSValue valueWithRect:NSRectFromCGRect(r)]];
            }
        }
    }

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

    for (NSValue *rect in rects) {
        NSRect r = rect.rectValue;
        CGContextAddRect(ctx, NSRectToCGRect(r));
    }

    CGContextStrokePath(ctx);

    CGContextRelease(ctx);

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatBGRA8 pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_bgra shouldColorMatch:YES];

    self.outputStructure = rects;

    return YES;
}

@end
