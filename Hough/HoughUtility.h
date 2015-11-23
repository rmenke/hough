//
//  HoughUtility.h
//  Hough
//
//  Created by Robert Menke on 11/2/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import Quartz;
@import Accelerate.vImage;
@import simd;

/**
 * @abstract Extract the centroid from a cluster.
 *
 * @discussion This function makes a number of assumptions about the
 *   clusters in the buffer:
 *   <ul>
 *     <li>That the edge of the cluster is convex; and</li>
 *     <li>That the pixels in the rows above and in the current row to the left
 *       of (r, ϴ) have already been examined.</li>
 *   </ul>
 *
 * The function will scan forward until the end of the current row of
 * pixels with <code>value</code>.  Each pixel will be added to the
 * current cluster before being set to zero.  The row index is then
 * advanced.  If the pixel under the start of the previous pixel row
 * has <code>value</code>, scan backwards until a pixel without
 * <code>value</code> is found.  Scan forward until <code>value</code>
 * is found or the end of the previous pixel row is reached.  If the
 * pixel was found, repeat; otherwise, exit.
 */
vector_double2 clusterCenter(id<QCPlugInContext> context, const vImage_Buffer *buffer, NSUInteger r, NSUInteger t, float value);
