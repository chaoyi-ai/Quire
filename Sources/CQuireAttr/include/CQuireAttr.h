#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 属性字符串构建的 ObjC 直通层。
///
/// 动机（见 docs/DESIGN.md ADR-11）：Swift 侧 `NSAttributedString(string:attributes:)` 每次都要把
/// `[Key: Any]` 桥接成 NSDictionary 再做 uniquing 哈希，实测 1.5 µs/run；用预先 uniqued 的
/// NSAttributeDictionary + replaceCharacters/setAttributes 走 ObjC 只要 0.25 µs/run（6×）。
/// 1 MB Markdown ≈ 20 万 run，这是 300 ms 与 50 ms 的差别。

/// 把普通字典变成 Foundation 内部 uniqued 的属性字典（可反复用于 QAAppendRun）。参数/返回都是 NSDictionary。
id QAUniqueAttributes(id attributes);

/// 追加一个 run：`str` 为 NSString，`uniquedAttributes` 为 QAUniqueAttributes 的返回值。
void QAAppendRun(NSMutableAttributedString *target, id str, id uniquedAttributes);

/// 追加一个 run 并覆盖其中一个属性（如链接 URL），避免为每个链接单独 unique 一份字典。
void QAAppendRunWithExtra(NSMutableAttributedString *target, id str, id uniquedAttributes, NSAttributedStringKey extraKey, id extraValue);

/// 在已追加的文本上按范围覆盖属性（用于代码高亮：先整段 plain，再按 token 顺序从左到右 set）。
void QASetRunAttributes(NSMutableAttributedString *target, id uniquedAttributes, NSUInteger location, NSUInteger length);

NS_ASSUME_NONNULL_END
