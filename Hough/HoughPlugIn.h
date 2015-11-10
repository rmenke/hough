//
//  HoughPlugIn.h
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

@import Quartz;

@interface HoughPlugIn : QCPlugIn

@property (readonly) id<QCPlugInInputImageSource> inputImage;
@property (readonly) CGFloat inputThreshold;
@property (readonly) CGFloat inputAllowedSlant;

@property (retain) id<QCPlugInOutputImageProvider> outputImage;
@property (retain) NSArray *outputStructure;

@end
