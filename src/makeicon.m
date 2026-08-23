// Renders a simple app icon set and compiles it to AppIcon.icns
#import <Cocoa/Cocoa.h>
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *out = [NSString stringWithUTF8String:argv[1]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *set = [out stringByAppendingPathComponent:@"AppIcon.iconset"];
    [fm createDirectoryAtPath:set withIntermediateDirectories:YES attributes:nil error:nil];
    int sizes[] = {16,32,64,128,256,512,1024};
    for (int i = 0; i < 7; i++) {
        int s = sizes[i];
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(s,s)];
        [img lockFocus];
        NSRect r = NSMakeRect(0,0,s,s);
        // rounded dark slate tile
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, s*0.06, s*0.06)
                                                           xRadius:s*0.20 yRadius:s*0.20];
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.13 green:0.15 blue:0.20 alpha:1]
                                                        endingColor:[NSColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1]];
        [grad drawInBezierPath:bg angle:-90];
        // speech bubble in AMD-ish red
        CGFloat w = s*0.52, h = s*0.36, x = (s-w)/2, y = s*0.40;
        NSBezierPath *b = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,y,w,h) xRadius:h*0.30 yRadius:h*0.30];
        NSBezierPath *tail = [NSBezierPath bezierPath];
        [tail moveToPoint:NSMakePoint(x+w*0.24, y+h*0.06)];
        [tail lineToPoint:NSMakePoint(x+w*0.18, y-h*0.26)];
        [tail lineToPoint:NSMakePoint(x+w*0.52, y+h*0.06)];
        [tail closePath];
        [[NSColor colorWithRed:0.85 green:0.18 blue:0.18 alpha:1] setFill];
        [b fill]; [tail fill];
        // three dots
        [[NSColor whiteColor] setFill];
        for (int k = 0; k < 3; k++) {
            CGFloat d = s*0.055, gap = w*0.24;
            NSRect dot = NSMakeRect(x + w*0.26 + k*gap - d/2, y + h/2 - d/2, d, d);
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
        [img unlockFocus];
        NSData *tiff = [img TIFFRepresentation];
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        [rep setSize:NSMakeSize(s,s)];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *nm = [NSString stringWithFormat:@"icon_%dx%d.png", s, s];
        [png writeToFile:[set stringByAppendingPathComponent:nm] atomically:YES];
        if (s > 16) {
            NSString *nm2 = [NSString stringWithFormat:@"icon_%dx%d@2x.png", s/2, s/2];
            [png writeToFile:[set stringByAppendingPathComponent:nm2] atomically:YES];
        }
    }
    return 0;
} }
