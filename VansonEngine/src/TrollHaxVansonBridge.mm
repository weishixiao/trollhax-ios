// TrollHax VansonEngine 桥接辅助
//
// 目的：绕开 Swift ↔ ObjC 枚举/方法名的导入猜谜。
//
// 起因：VMMemoryEngine 的 -readStringAtAddress:encoding:maxBytes: / -writeStringAtAddress:
// 需要传 VMStringEncoding（NS_ENUM）。Swift 侧对这类枚举的导入名依赖前缀剥离规则
// 与工具链版本，直接写 .utf8 / VMStringEncodingUTF8 / .UTF8 都容易踩坑。
// 这里用 C 函数把「UTF-8」这个常量包死，Swift 只调用普通函数，不碰枚举名。

#import <Foundation/Foundation.h>
#import "VMMemoryEngine.h"

/// UTF-8 编码常量（0），供 Swift 侧传入 encoding 参数
VMStringEncoding TrollHaxVansonUTF8Encoding(void) {
    return VMStringEncodingUTF8;
}
