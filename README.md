# Hough Transform for Quartz Composer

The goal of this project is threefold:

1. Produce a Quartz Composer plugin that can recognize and isolate orthogonal rectangles in an arbitrary bitmap, such as the panels in a comic page.
2. Produce an Automator workflow that can take a series of images and produce an [EPUB Region-Based Navigation](http://www.idpf.org/epub/renditions/region-nav/) with [Fixed Layout](http://www.idpf.org/epub/301/spec/epub-publications.html#sec-package-metadata-fxl) document for each page.
3. Produce an Automator workflow that takes the output of the previous step and the image to assemble a comic eBook from individual page images.

Step #1 will most likely generate SVG files as intermediate outputs.
Step #2 will most likely use XSLT to convert the subset of SVG outputted by step #1 into navigation documents.
Step #3 will most likely rely on naming conventions to associate images with their region navigation documents.

None of this is novel or original; it is more an excuse to fool around with Hough.
