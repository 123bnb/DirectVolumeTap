// Compat.h — PTFakeTouch 原生源码兼容宏
// 原生 PTFakeMetaTouch.m 使用了 DLog 宏但工程里未定义，这里统一补齐。
#ifndef DLog
#define DLog(...) NSLog(__VA_ARGS__)
#endif
