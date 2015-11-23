//
//  HoughPlugIn.h
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import Quartz;

@interface HoughPlugIn : QCPlugIn

@property (readonly) id<QCPlugInInputImageSource> inputImage;
@property (readonly) CGFloat inputAllowedSlant;
@property (readonly) CGFloat inputMinWidth, inputMinHeight;

@property (retain) id<QCPlugInOutputImageProvider> outputImage;
@property (retain) NSArray *outputStructure;

@end
