//
//  HoughOutputImage.h
//  Hough
//
//  Created by Rob Menke on 8/31/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

@import Foundation;
@import Quartz.QuartzComposer;

@interface HoughOutputImage : NSObject<QCPlugInOutputImageProvider>

- (instancetype)initWithImage:(id<QCPlugInInputImageSource>)input;

@end
