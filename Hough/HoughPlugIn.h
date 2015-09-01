//
//  HoughPlugIn.h
//  Hough
//
//  Created by Rob Menke on 8/15/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

#import <Quartz/Quartz.h>

@interface HoughPlugIn : QCPlugIn

@property (assign) id<QCPlugInInputImageSource> inputImage;
@property (retain) id<QCPlugInOutputImageProvider> outputImage;

@end
