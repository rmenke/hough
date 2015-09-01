//
//  HoughOutputImage.m
//  Hough
//
//  Created by Rob Menke on 8/31/15.
//  Copyright (c) 2015 Rob Menke. All rights reserved.
//

#import "HoughOutputImage.h"

@import Accelerate;

@interface HoughOutputImage ()

@property (retain) id<QCPlugInInputImageSource> image;

@end

@implementation HoughOutputImage

- (instancetype)initWithImage:(id<QCPlugInInputImageSource>)input {
    self = [super init];
    if (self) {
        self.image = input;
    }
    return self;
}

- (NSRect)imageBounds {
    return self.image.imageBounds;
}

- (CGColorSpaceRef)imageColorSpace {
    return self.image.imageColorSpace;
}

- (NSArray *)supportedBufferPixelFormats {
    return [NSArray arrayWithObjects:QCPlugInPixelFormatI8, QCPlugInPixelFormatIf, nil];
}

- (BOOL)renderToBuffer:(void *)baseAddress withBytesPerRow:(NSUInteger)rowBytes pixelFormat:(NSString *)format forBounds:(NSRect)bounds {
    
    vImage_Buffer inBuffer;
    vImage_Buffer outBuffer;
    
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    if (gray == NULL) return NO;
    
    if (![self.image lockBufferRepresentationWithPixelFormat:QCPlugInPixelFormatI8 colorSpace:gray forBounds:self.image.imageBounds]) return NO;
    
    inBuffer.data = (void *)[self.image bufferBaseAddress];
    inBuffer.rowBytes = [self.image bufferBytesPerRow];
    inBuffer.width = [self.image bufferPixelsWide];
    inBuffer.height = [self.image bufferPixelsHigh];
    
    vImage_CGImageFormat inFormat = {
        .bitsPerComponent = 8, .bitsPerPixel = 8, .colorSpace = gray,
        .bitmapInfo = 0, .decode = NULL, .renderingIntent = kCGRenderingIntentDefault
    };
    
    outBuffer.data = baseAddress;
    outBuffer.rowBytes = rowBytes;
    outBuffer.width = inBuffer.width;
    outBuffer.height = inBuffer.height;
    
    vImage_CGImageFormat outFormat = {
        .colorSpace = gray, .bitmapInfo = 0,
        .decode = NULL, .renderingIntent = kCGRenderingIntentDefault
    };
    
    if ([format isEqualToString:QCPlugInPixelFormatI8]) {
        outFormat.bitsPerPixel = outFormat.bitsPerComponent = 8;
    } else if ([format isEqualToString:QCPlugInPixelFormatIf]) {
        outFormat.bitsPerPixel = outFormat.bitsPerComponent = 8 * sizeof(float);
    }
    
    vImage_Error error;
    
    vImageConverterRef converter = vImageConverter_CreateWithCGImageFormat(&inFormat, &outFormat, NULL, kvImagePrintDiagnosticsToConsole, &error);

    if (converter != NULL) {
        error = vImageConvert_AnyToAny(converter, &inBuffer, &outBuffer, NULL, 0);
        if (error != kvImageNoError) {
            NSLog(@"error = %zd", error);
        }
        vImageConverter_Release(converter);
    }
    
    CGColorSpaceRelease(gray);
    
    [self.image unlockBufferRepresentation];
    
    return YES;
}

@end
