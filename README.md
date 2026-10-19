# DirectVolumeTap

独立版「音量键 → 屏幕指定坐标点击」dylib。**注入即生效，自包含，不依赖任何设置页**。

把 dylib 注入哪个 App，就在哪个 App 生效。适合手动注入（如 roothide / rtool / 放进 App 的 Frameworks 目录），用来把物理音量键 / 蓝牙翻页器（只有音量 +/- 两个键）替代为点击屏幕指定坐标（例如小说翻页）。

## 机制

1. **三指长按** → 弹出设置覆盖层，点选两个坐标：
   - 第 1 个点 = **红点（音量+** 点击的位置）
   - 第 2 个点 = **绿点（音量-** 点击的位置）
   - 已满 2 点后再点会就近替换。默认坐标 = 屏幕中心上下两段（上红+、下绿-）。
2. **触发（唯一通道，v1.0.x 起真机验证）**：静音音频会话保持活跃 → KVO 监听 `AVAudioSession.outputVolume`，
   检测到变化 → 立即把音量钉回固定值（0.5）并触发点击/滑动。
   **这条链不依赖 SpringBoard 注入。**
3. **音量条抑制（可选增强）**：把同一个 dylib 也注入 SpringBoard → 钩 `SBVolumeControl` 的
   `handleVolumeButtonWithType:down:`，但**不吞键**：只按「App 前台心跳 + 用户偏好」持有 Apple 官方
   HUD 隐藏断言 `acquireVolumeHUDHiddenAssertionForReason:`，然后原样放行按键。
   音量照常变化 → KVO 照常触发映射；断言只负责音量条不弹。
4. **点击**：PTFakeMetaTouch 原生库（`fakeTouchId:AtPoint:withTouchPhase:`）模拟真实触摸。
5. **复位**：音量到顶/底自动拉回中间 0.3，防止按键失效。

> **v1.1.0 → v1.1.1 的重要修正**：v1.1.0 曾在 SpringBoard 侧吞键（音量数值不变），映射改由 Darwin
> 通知回传触发；真机实测该回传链一断映射全死（症状：只剩音量条隐藏，其他功能全无）。
> v1.1.1 起：**映射只走 KVO；SpringBoard 注入只决定音量条闪不闪**——注入失败、钩子装不上、
> 广播被沙盒拦，全部自动退化为 v1.0.x 行为（映射照常工作，最差只是音量条短暂闪烁）。

> 菜单底部会显示「系统级音量条抑制：已生效 / 未生效」（仅状态提示，不影响映射功能）。

## 构建产物

CI（GitHub Actions）编译产出 `DirectVolumeTap.dylib`（arm64 + arm64e，ldid 签名）。

## 使用方法

- **手动注入**：把 `DirectVolumeTap.dylib` 用 rtool / roothide 方式注入目标 App（如放进 `App/Frameworks` 并改名为 ellekit 认可的 dylib）。仅此一步即可获得完整映射功能。
- **音量条抑制（v1.1.1 可选）**：把同一个 dylib **同时** 注入 SpringBoard（放入 `DynamicLibraries/` 并在同名 `.plist` 的 Filter 里加 `com.apple.springboard`）。作用只有一个：前台按音量键时系统音量条不弹。不注入也能用。
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
