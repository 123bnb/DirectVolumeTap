# DirectVolumeTap

独立版「音量键 → 屏幕指定坐标点击」dylib。**注入即生效，自包含，不依赖任何设置页**。

把 dylib 注入哪个 App，就在哪个 App 生效。适合手动注入（如 roothide / rtool / 放进 App 的 Frameworks 目录），用来把物理音量键 / 蓝牙翻页器（只有音量 +/- 两个键）替代为点击屏幕指定坐标（例如小说翻页）。

> **版本状态（2026-10-20）**
> - **v1.0.21 = 推荐使用**：连滑重做（同方向门控：起滑即锁方向；窗口期反方向按键完全无视；
>   连滑中按反方向立即断连滑；连滑阈值 3→5；新增「连滑」总开关，默认开），
>   并按用户要求彻底移除调试日志（LogDVT / Documents/DVT.log 不再存在）。
> - v1.0.20 及以前：保留调试日志文件化输出；连滑不认方向（按反方向也能连滑）、阈值 3，已淘汰。
> - v1.0.18 = 音量机制基线：无静音循环保活（仅前台激活音频会话、退后台停用）+ 徘徊 1/16。
> - **结论：只注入目标 App，不要注入 SpringBoard。**

## 机制

1. **三指长按** → 弹出设置覆盖层，点选两个坐标：
   - 第 1 个点 = **红点（音量+** 点击的位置）
   - 第 2 个点 = **绿点（音量-** 点击的位置）
   - 已满 2 点后再点会就近替换。默认坐标 = 屏幕中心上下两段（上红+、下绿-）。
2. **触发**：音量键（物理/蓝牙翻页器）→ KVO 监听 `AVAudioSession.outputVolume`（v1.0.18 起仅前台激活音频会话，不再播放静音；退后台即停用，不干预其他 App 的音量）。
3. **点击**：PTFakeMetaTouch 原生库（`fakeTouchId:AtPoint:withTouchPhase:`）模拟真实触摸。
4. **音量策略**（v1.0.18）：启动/进前台对齐 1/16，之后随按键真实移动，超过 12/16 或触底弹回 1/16（徘徊，不钉死）。
5. **连滑**（滑动模式，v1.0.21 重做）：起滑即锁方向；回放窗口期内同方向连按 5 次进入连滑
   （第 4 次提示「再按一次进入连滑」）；连滑中按同方向无动作、按反方向立即断连滑；
   总开关在菜单「连滑」行（位于点击设置与回放速率之间，默认开）。

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
