//
//  MaximaPlugIn.h
//  Maxima
//
//  Created by Robert Menke on 11/30/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

#import <Quartz/Quartz.h>

@interface MaximaPlugIn : QCPlugIn

@property (readonly) id<QCPlugInInputImageSource> inputImage;
/*! Additional pixels that were added to the width of the image to prevent false positives at the edges of the raster. */
@property (readonly) NSUInteger inputMargin;
/*! The maximum intensity that will be rejected by the filter as background. */
@property (readonly) CGFloat inputThreshold;

@property (strong) id<QCPlugInOutputImageProvider> outputImage;

@end
