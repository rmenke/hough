//
//  HoughTest.m
//  HoughTest
//
//  Created by Robert Menke on 11/2/15.
//  Copyright © 2015 Rob Menke. All rights reserved.
//

@import XCTest;
@import Foundation;
@import Quartz;
@import Accelerate;
@import simd;
@import Darwin.POSIX.dlfcn;

#import "HoughUtility.h"

@interface HoughTest : XCTestCase

@end

@implementation HoughTest

- (void)setUp {
    [super setUp];

    NSBundle *testBundle = [NSBundle bundleWithIdentifier:@"com.the-wabe.HoughTest"];
    NSString *plugInsPath = [testBundle.builtInPlugInsPath stringByAppendingPathComponent:@"Hough.plugin"];
    NSBundle *plugInBundle = [NSBundle bundleWithPath:plugInsPath];

    NSError *error;
    XCTAssert([plugInBundle loadAndReturnError:&error], @"error: %@", error);
}

- (void)tearDown {
    [super tearDown];
}

- (void)testLoading {
    Class HoughPlugIn = NSClassFromString(@"HoughPlugIn");
    XCTAssertNotEqual(HoughPlugIn.class, Nil);

    XCTAssert([HoughPlugIn isSubclassOfClass:QCPlugIn.class]);
}

- (void)testClustering1 {
    const float tolerance = FLT_EPSILON;

    float raster[] = {
        0, 0, 0, 0, 0,
        0, 0, 1, 1, 1,
        0, 1, 1, 1, 0,
        1, 1, 1, 0, 0,
        0, 0, 0, 1, 1
    };

    vImage_Buffer buffer = {
        .data = raster, .width = 5, .height = 5, .rowBytes = sizeof(float) * 5
    };

    vector_double2 expected = { 2, 2 };
    vector_double2 actual = clusterCenter(nil, &buffer, 1, 2, 1.0f);

    XCTAssertEqualWithAccuracy(expected.x, actual.x, tolerance);
    XCTAssertEqualWithAccuracy(expected.y, actual.y, tolerance);

    XCTAssertEqualWithAccuracy(raster[0], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[1], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[2], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[3], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[4], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[5], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[6], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[7], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[8], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[9], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[10], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[11], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[12], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[13], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[14], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[15], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[16], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[17], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[18], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[19], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[20], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[21], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[22], 0.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[23], 1.0f, tolerance);
    XCTAssertEqualWithAccuracy(raster[24], 1.0f, tolerance);
}

- (void)testClustering2 {
    const float tolerance = FLT_EPSILON;

    float raster[] = {
        0, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
        0, 0, 1, 1, 1,
        1, 1, 1, 0, 0,
        0, 0, 1, 1, 1
    };

    vImage_Buffer buffer = {
        .data = raster, .width = 5, .height = 5, .rowBytes = sizeof(float) * 5
    };

    vector_double2 expected = { 3.0, (7.0 / 3.0) };
    vector_double2 actual = clusterCenter(nil, &buffer, 2, 2, 1.0f);

    XCTAssertEqualWithAccuracy(expected.x, actual.x, tolerance);
    XCTAssertEqualWithAccuracy(expected.y, actual.y, tolerance);

    for (int i = 0; i < 25; ++i) {
        XCTAssertEqualWithAccuracy(raster[i], 0.0f, tolerance);
    }
}

@end
