// The models write Markdown. Showing the raw ** ** markers looks broken, so
// this renders enough of it to read comfortably — headings, bullets, bold,
// italic, inline code and fenced code. Not a Markdown implementation; just the
// parts that turn up in an answer.

#import "MacVega.h"

static void MVAppendInline(NSMutableAttributedString *out, NSString *src, NSDictionary *base) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\*\\*(.+?)\\*\\*|(?<![\\*\\w])\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)|`([^`]+)`"
              options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    });
    NSFont *body = base[NSFontAttributeName];
    NSFontManager *fm = [NSFontManager sharedFontManager];
    __block NSUInteger last = 0;
    [re enumerateMatchesInString:src options:0 range:NSMakeRange(0, src.length)
                     usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m.range.location > last)
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:[src substringWithRange:NSMakeRange(last, m.range.location - last)]
                    attributes:base]];
        NSMutableDictionary *a = [base mutableCopy];
        NSString *inner;
        if ([m rangeAtIndex:1].location != NSNotFound) {
            inner = [src substringWithRange:[m rangeAtIndex:1]];
            a[NSFontAttributeName] = [fm convertFont:body toHaveTrait:NSBoldFontMask];
        } else if ([m rangeAtIndex:2].location != NSNotFound) {
            inner = [src substringWithRange:[m rangeAtIndex:2]];
            a[NSFontAttributeName] = [fm convertFont:body toHaveTrait:NSItalicFontMask];
        } else {
            inner = [src substringWithRange:[m rangeAtIndex:3]];
            a[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:body.pointSize - 1
                                                                 weight:NSFontWeightRegular];
            a[NSForegroundColorAttributeName] = [NSColor systemPinkColor];
        }
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:inner attributes:a]];
        last = m.range.location + m.range.length;
    }];
    if (last < src.length)
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:[src substringFromIndex:last] attributes:base]];
}

NSAttributedString *MVRenderMarkdown(NSString *src, CGFloat bodySize) {
    NSFont *body = [NSFont systemFontOfSize:bodySize];
    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSColor *fg = [NSColor labelColor];
    NSDictionary *plain = @{NSFontAttributeName: body, NSForegroundColorAttributeName: fg};
    NSMutableAttributedString *out = [NSMutableAttributedString new];

    NSArray<NSString *> *lines = [src componentsSeparatedByString:@"\n"];
    BOOL inFence = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        NSString *nl = (i + 1 < lines.count) ? @"\n" : @"";

        if ([trimmed hasPrefix:@"```"]) { inFence = !inFence; continue; }
        if (inFence) {
            NSDictionary *code = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:bodySize - 1
                                                                 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: fg};
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:[line stringByAppendingString:nl] attributes:code]];
            continue;
        }
        if ([trimmed hasPrefix:@"---"] && trimmed.length >= 3 &&
            [[trimmed stringByReplacingOccurrencesOfString:@"-" withString:@""] length] == 0) {
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:[@"————————" stringByAppendingString:nl]
                    attributes:@{NSFontAttributeName: body,
                                 NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}]];
            continue;
        }

        NSUInteger hashes = 0;
        while (hashes < trimmed.length && [trimmed characterAtIndex:hashes] == '#') hashes++;
        if (hashes > 0 && hashes <= 4 && hashes < trimmed.length &&
            [trimmed characterAtIndex:hashes] == ' ') {
            CGFloat size = bodySize + (hashes == 1 ? 5 : hashes == 2 ? 3 : 1);
            NSDictionary *h = @{
                NSFontAttributeName: [fm convertFont:[NSFont systemFontOfSize:size]
                                         toHaveTrait:NSBoldFontMask],
                NSForegroundColorAttributeName: fg};
            NSMutableAttributedString *hl = [NSMutableAttributedString new];
            MVAppendInline(hl, [trimmed substringFromIndex:hashes + 1], h);
            [hl appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:h]];
            [out appendAttributedString:hl];
            continue;
        }

        // Bullets: keep the indent, swap the marker for something that reads better.
        NSString *rendered = line;
        NSRange dash = [line rangeOfString:@"^(\\s*)[-*+] " options:NSRegularExpressionSearch];
        if (dash.location == 0) {
            NSString *indent = [line substringWithRange:NSMakeRange(0, dash.length - 2)];
            rendered = [NSString stringWithFormat:@"%@•  %@", indent,
                        [line substringFromIndex:dash.length]];
        }
        NSMutableAttributedString *ln = [NSMutableAttributedString new];
        MVAppendInline(ln, rendered, plain);
        [ln appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:plain]];
        [out appendAttributedString:ln];
    }
    return out;
}
