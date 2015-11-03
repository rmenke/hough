//
//  HoughUtility.c
//  Hough
//
//  Created by Robert Menke on 11/2/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

#import "HoughUtility.h"

vector_double2 clusterCenter(id<QCPlugInContext> context, vImage_Buffer *buffer, NSUInteger r, NSUInteger t, float value) {
    vector_double2 centroid = { 0, 0 };
    NSUInteger pixelCount = 0;

    float *srcRow = buffer->data + buffer->rowBytes * r;

    do {
        NSCAssert(r < buffer->height, @"r ∈ [0, height)");
        NSCAssert(t < buffer->width, @"t ∈ [0, width)");
        NSCAssert(srcRow[t] == value, @"v(t) = maxima");
        NSCAssert((t == 0) || (srcRow[t - 1] != value), @"t = 0 or v(t-1) ≠ maxima");

        NSUInteger start = t, end = t + 1;

        while (end < buffer->width && srcRow[end] == value) ++end;

        for (t = start; t < end; ++t) {
            srcRow[t] = 0.0;
            centroid.x += r;
            centroid.y += t;
            ++pixelCount;
        }

        if (++r >= buffer->height) break;

        srcRow = buffer->data + buffer->rowBytes * r;

        if (srcRow[start] == value) {
            for (t = start; t > 0 && srcRow[t-1] == value; --t);
        } else {
            for (t = start + 1; t < end && srcRow[t] != value; ++t);
            if (t == end) break;
        }
    } while (true);

    return centroid / (double)(pixelCount);
}

