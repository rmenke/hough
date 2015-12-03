//
//  HoughPlugIn.h
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import Quartz;

@interface HoughPlugIn : QCPlugIn

/*! The input image to process. */
@property (readonly) id<QCPlugInInputImageSource> inputImage;
/*! Additional pixels to add to the Hough space raster. */
@property (readonly) NSUInteger inputMargin;

/*! The Hough space raster. */
@property (retain) id<QCPlugInOutputImageProvider> outputImage;
/*! The maximum value assigned in the output raster. */
@property (assign) NSUInteger outputMax;

@end
