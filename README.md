# DirectVolumeTap

独立版「音量键 → 屏幕指定坐标点击」dylib。**注入即生效，自包含，不依赖任何设置页**。

把 dylib 注入哪个 App，就在哪个 App 生效。适合手动注入（如 roothide / rtool / 放进 App 的 Frameworks 目录），用来把物理音量键 / 蓝牙翻页器（只有音量 +/- 两个键）替代为点击屏幕指定坐标（例如小说翻页）。

## 机制

1. **三指长按** → 弹出设置覆盖层，点选两个坐标：
   - 第 1 个点 = **红点（音量+** 点击的位置）
   - 第 2 个点 = **绿点（音量-** 点击的位置）
   - 已满 2 点后再点会就近替换。默认坐标 = 屏幕中心上下两段（上红+、下绿-）。
2. **触发**（v1.1.0 起双通道，自动选择）：
   - **系统级（推荐）**：额外把本 dylib 注入 SpringBoard → 钩 `SBVolumeControl` 的音量键，
     在源头吞掉：**音量数值不变、音量 HUD 不弹**；按键经 Darwin 通知广播给 App 执行点击/滑动。
     只有本 App 在前台时才吞键，其余场景音量键完全放行（系统原生行为）。
   - **兼容（仅注入 App）**：静音音频会话保持活跃 → KVO 监听 `AVAudioSession.outputVolume`，
     检测到变化后立即把音量钉回固定值（v1.0.x 原逻辑，作为兜底始终保留）。
3. **点击**：PTFakeMetaTouch 原生库（`fakeTouchId:AtPoint:withTouchPhase:`）模拟真实触摸。
4. **复位**：音量到顶/底自动拉回中间 0.3，防止按键失效（仅兼容通道需要）。

> 菜单底部会显示「系统级拦截：已生效 / 未生效」。未生效 = SpringBoard 没注入或该方法在当前
> iOS 不存在，自动回到兼容模式，行为与旧版一致。

## 构建产物

CI（GitHub Actions）编译产出 `DirectVolumeTap.dylib`（arm64 + arm64e，ldid 签名）。

## 使用方法

- **手动注入**：把 `DirectVolumeTap.dylib` 用 rtool / roothide 方式注入目标 App（如放进 `App/Frameworks` 并改名为 ellekit 认可的 dylib）。
- **系统级拦截（v1.1.0 推荐，可选）**：把同一个 dylib 同时注入 SpringBoard（如放入 `DynamicLibraries/` 并在同名 `.plist` 的 Filter 里加 `com.apple.springboard`），即可获得「音量不变 + HUD 不弹」的系统级效果；不注入也能用（自动回退兼容模式）。
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
