# DirectVolumeTap

独立版「音量键 → 屏幕指定坐标点击」dylib。**注入即生效，自包含，不依赖任何设置页**。

把 dylib 注入哪个 App，就在哪个 App 生效。适合手动注入（如 roothide / rtool / 放进 App 的 Frameworks 目录），用来把物理音量键 / 蓝牙翻页器（只有音量 +/- 两个键）替代为点击屏幕指定坐标（例如小说翻页）。

> **版本状态（2026-10-19）**
> - **v1.0.16（修正版）= 推荐使用**：在 v1.0.16 原有功能（滑动设置页「已录 N 点」提示）基础上，
>   修复了 v1.0.15 引入、v1.0.16 沿用的致命回归——`KeepAudioSessionActive` 中
>   `[session setActive:YES]` 与 `[player play]` 被误塞进 `if (err)` 分支，正常情况
>   （err==nil）下音频会话永不激活 → `outputVolume` KVO 不触发 → 映射全失效。
>   已还原为 v1.0.14 的无条件激活逻辑（v1.0.14 为你实测可用的基线）。
> - **v1.0.15（修正版）= 同样可用**：不含滑动「已录 N 点」提示 UI，其余与 v1.0.16 修正版一致
>   （音频激活回归已同样修好）。若不需要滑动录制 UI 可用此版。
> - v1.0.14 = 最早确认可用的稳定基线（无滑动提示 UI）。
> - **原始 v1.0.15 / v1.0.16（修前）= 请勿使用**：含上述音频激活回归，映射不生效。
> - v1.1.0 / v1.1.1 = 已废弃的 SpringBoard 系统级实验，真机实测映射失效，源码保留在
>   git tag `v1.1.0` / `v1.1.1` 备查。
> - **结论：只注入目标 App，不要注入 SpringBoard。**

## 机制

1. **三指长按** → 弹出设置覆盖层，点选两个坐标：
   - 第 1 个点 = **红点（音量+** 点击的位置）
   - 第 2 个点 = **绿点（音量-** 点击的位置）
   - 已满 2 点后再点会就近替换。默认坐标 = 屏幕中心上下两段（上红+、下绿-）。
2. **触发**：音量键（物理/蓝牙翻页器）→ 静音音频会话保持活跃 → KVO 监听 `AVAudioSession.outputVolume`。
3. **点击**：PTFakeMetaTouch 原生库（`fakeTouchId:AtPoint:withTouchPhase:`）模拟真实触摸。
4. **复位**：音量到顶/底自动拉回中间 0.3，防止按键失效。

## 构建产物

CI（GitHub Actions）编译产出 `DirectVolumeTap.dylib`（arm64 + arm64e，ldid 签名）。

## 使用方法

- **手动注入**：把 `DirectVolumeTap.dylib` 用 rtool / roothide 方式注入目标 App（如放进 `App/Frameworks` 并改名为 ellekit 认可的 dylib）。
- **注入所有 App（可选）**：如果想自动注入所有 App，可把 dylib 放到 `DynamicLibraries/` 并加一个同名 `.plist` 指定 Filter，例如：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Filter</key>
  <dict>
    <key>Bundles</key>
    <array><string>com.apple.UIKit</string></array>
  </dict>
</dict>
</plist>
```

注入后打开目标 App，**三指长按设置坐标**，然后按音量键即可。

## 依赖

- iOS 15+
- 越狱环境（ellekit / roothide 可注入 dylib）
- 点击依赖 PTFakeTouch 原生源码（本仓库 `ptftouch/`）
