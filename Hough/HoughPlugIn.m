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
@import simd;

#define kQCPlugIn_Name          @"Hough"
#define kQCPlugIn_Description   @"Perform a Hough transformation on an image."

#define PER_SEMITURN 180

void __buffer_release(const void *address, void *context) {
    free((void *)address);
}

FOUNDATION_STATIC_INLINE
NSValue *up(NSValue *v) {
    const NSPoint p = v.pointValue;
    return [NSValue valueWithPoint:NSMakePoint(p.x, p.y - 1)];
}

FOUNDATION_STATIC_INLINE
NSValue *down(NSValue *v) {
    const NSPoint p = v.pointValue;
    return [NSValue valueWithPoint:NSMakePoint(p.x, p.y + 1)];
}

FOUNDATION_STATIC_INLINE
NSValue *left(NSValue *v) {
    const NSPoint p = v.pointValue;
    return [NSValue valueWithPoint:NSMakePoint(p.x - 1, p.y)];
}

FOUNDATION_STATIC_INLINE
NSValue *right(NSValue *v) {
    const NSPoint p = v.pointValue;
    return [NSValue valueWithPoint:NSMakePoint(p.x + 1, p.y)];
}

void clusterPoint(NSValue *p, NSMutableSet<NSValue *> *set, NSMutableDictionary<NSValue *, NSNumber *> *lines) {
    if ([lines objectForKey:p]) {
        [lines removeObjectForKey:p];
        [set addObject:p];

        clusterPoint(up(p), set, lines);
        clusterPoint(down(p), set, lines);
        clusterPoint(left(p), set, lines);
        clusterPoint(right(p), set, lines);
    }
}

NSDictionary<NSSet<NSValue *> *, NSNumber *> *cluster(NSMutableDictionary<NSValue *, NSNumber *> *lines) {
    NSValue  *value = [[lines keyEnumerator] nextObject];
    NSNumber *count = lines[value];

    NSMutableSet<NSValue *> *key = [NSMutableSet setWithObject:value];
    clusterPoint(value, key, lines);

    return @{key: count};
}

FOUNDATION_STATIC_INLINE
void findIntercepts(const CGFloat r, const CGFloat theta, const CGFloat width, const CGFloat height, CGPoint *p1, CGPoint *p2) {
    CGFloat sin_theta, cos_theta;
    __sincospi(theta / PER_SEMITURN, &sin_theta, &cos_theta);

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
        } else if (0.0 <= y1 && y1 <= height) {
            p1->x = width; p1->y = y1;
        }

        if (0.0 <= y1 && y1 <= height) {
            p2->x = width; p2->y = y1;
        } else if (0.0 <= x1 && x1 <= width) {
            p2->x = x1; p2->y = height;
        } else if (0.0 <= y0 && y0 <= height) {
            p2->x = 0; p2->y = y0;
        } else if (0.0 <= x0 && x0 <= width) {
            p2->x = x0; p2->y = 0;
        }
    }
}

@implementation HoughPlugIn {
    CGColorSpaceRef _gray, _bgra;
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
    if (!_gray) return NO;

    _bgra = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    if (!_bgra) return NO;

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

    const NSInteger margin   = 25;

    const NSInteger minTheta = - margin;
    const NSInteger maxTheta = PER_SEMITURN + margin;

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
        free(buffer.data);
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

    vImage_Buffer maxima;

    if ((error = vImageBuffer_Init(&maxima, rangeR, PER_SEMITURN, 32, kvImageNoFlags)) != kvImageNoError) {
        [context logMessage:@"vImageBuffer_Init: error = %zd", error];
        free(buffer.data);
        return NO;
    }

    NSUInteger kernelSize = margin * 2 - 1;
    float kernel[kernelSize * kernelSize];
    memset(kernel, 0, sizeof(kernel));

    if ((error = vImageDilate_PlanarF(&buffer, &maxima, margin, 0, kernel, kernelSize, kernelSize, kvImageNoFlags)) != kvImageNoError) {
        [context logMessage:@"vImageDilate_PlanarF: error = %zd", error];
        free(maxima.data);
        free(buffer.data);
        return NO;
    }

    NSMutableDictionary<NSValue *, NSNumber *> *lines = [NSMutableDictionary dictionary];

    for (NSInteger r = 0; r < rangeR; ++r) {
        Float32 * const srcRow = buffer.data + buffer.rowBytes * r;
        Float32 * const maxRow = maxima.data + maxima.rowBytes * r;

        for (NSInteger theta = 0; theta < PER_SEMITURN; ++theta) {
            CGPoint p1, p2;
            findIntercepts(r, theta, width, height, &p1, &p2);
            CGFloat length = hypot(p1.x - p2.x, p1.y - p2.y);

            if (srcRow[theta - minTheta] == maxRow[theta] && maxRow[theta] > (0.8 * length)) {
                NSValue *key = [NSValue valueWithPoint:NSMakePoint(r - biasR, theta)];
                lines[key] = @(maxRow[theta]);
            }
        }
    }

    free(buffer.data);
    free(maxima.data);

    NSMutableDictionary<NSSet<NSValue *> *, NSNumber *> *clusters = [NSMutableDictionary dictionary];

    while ([lines count]) {
        [clusters addEntriesFromDictionary:cluster(lines)];
    }

    [lines removeAllObjects];

    for (NSSet *cluster in clusters) {
        NSUInteger count = cluster.count;
        vector_double2 centroid = 0;

        for (NSValue *value in cluster) {
            NSPoint p = value.pointValue;
            centroid += vector2(p.x, p.y);
        }

        centroid /= count;

        [lines setObject:clusters[cluster] forKey:[NSValue valueWithPoint:NSMakePoint(centroid.x, centroid.y)]];
    }

    if (![inputImage lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatBGRA8 colorSpace:_bgra forBounds:inputImage.imageBounds]) return NO;

    buffer.width    = [inputImage bufferPixelsWide];
    buffer.height   = [inputImage bufferPixelsHigh];
    buffer.rowBytes = [inputImage bufferBytesPerRow];
    buffer.data     = valloc(buffer.height * buffer.rowBytes);

    if (buffer.data == NULL) {
        [context logMessage:@"Memory allocation failure"];
        return NO;
    }

    memcpy(buffer.data, [inputImage bufferBaseAddress], buffer.height * buffer.rowBytes);

    [inputImage unlockBufferRepresentation];

    CGContextRef ctx = CGBitmapContextCreate(buffer.data, buffer.width, buffer.height, 8, buffer.rowBytes, _bgra, kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
    if (ctx == NULL) {
        free(buffer.data);
        [context logMessage:@"CGBitmapContextCreate failed"];
        return NO;
    }

    CGContextTranslateCTM(ctx, 0, buffer.height);
    CGContextScaleCTM(ctx, 1, -1);

    CGContextSetRGBStrokeColor(ctx, 1, 0, 0, 1);

    for (NSValue *line in lines) {
        if (lines[line].integerValue < 10) continue;

        NSPoint p = line.pointValue;

        CGFloat r = p.x;
        CGFloat theta = p.y;

        CGPoint p1, p2;

        const CGFloat height = buffer.height;
        const CGFloat width  = buffer.width;

        findIntercepts(r, theta, width, height, &p1, &p2);

        CGContextMoveToPoint(ctx, p1.x, p1.y);
        CGContextAddLineToPoint(ctx, p2.x, p2.y);
    }

    CGContextStrokePath(ctx);

    CGContextRelease(ctx);

    self.outputImage = [context outputImageProviderFromBufferWithPixelFormat:QCPlugInPixelFormatBGRA8 pixelsWide:buffer.width pixelsHigh:buffer.height baseAddress:buffer.data bytesPerRow:buffer.rowBytes releaseCallback:__buffer_release releaseContext:NULL colorSpace:_bgra shouldColorMatch:YES];

    self.outputStructure = nil;

    return YES;
}

@end
