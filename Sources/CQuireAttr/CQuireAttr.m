#import "CQuireAttr.h"

id QAUniqueAttributes(id attributes) {
    NSAttributedString *probe = [[NSAttributedString alloc] initWithString:@"x" attributes:(NSDictionary *)attributes];
    return [probe attributesAtIndex:0 effectiveRange:NULL];
}

void QAAppendRun(NSMutableAttributedString *target, id str, id uniquedAttributes) {
    NSString *s = (NSString *)str;
    NSUInteger loc = target.length;
    NSUInteger len = s.length;
    if (len == 0) return;
    [target replaceCharactersInRange:NSMakeRange(loc, 0) withString:s];
    [target setAttributes:(NSDictionary *)uniquedAttributes range:NSMakeRange(loc, len)];
}

void QAAppendRunWithExtra(NSMutableAttributedString *target, id str, id uniquedAttributes, NSAttributedStringKey extraKey, id extraValue) {
    NSString *s = (NSString *)str;
    NSUInteger loc = target.length;
    NSUInteger len = s.length;
    if (len == 0) return;
    [target replaceCharactersInRange:NSMakeRange(loc, 0) withString:s];
    NSRange r = NSMakeRange(loc, len);
    [target setAttributes:(NSDictionary *)uniquedAttributes range:r];
    [target addAttribute:extraKey value:extraValue range:r];
}

void QASetRunAttributes(NSMutableAttributedString *target, id uniquedAttributes, NSUInteger location, NSUInteger length) {
    if (length == 0) return;
    [target setAttributes:(NSDictionary *)uniquedAttributes range:NSMakeRange(location, length)];
}
