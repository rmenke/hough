//
//  ThresholdPlugIn.h
//  Hough
//
//  Created by Robert Menke on 11/16/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import Quartz;

@interface ThresholdPlugIn : QCPlugIn

@property (readonly) id<QCPlugInInputImageSource> inputImage;
@property (readonly) CGFloat inputThreshold;

@property (retain) id<QCPlugInOutputImageProvider> outputImage;

@end
