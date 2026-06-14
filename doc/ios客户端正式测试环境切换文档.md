# iOS 客户端 正式 / 测试环境切换文档

> 创建日期：2026-06-05
> 适用项目：WorkSurvivalGuide iOS App

---

## 一、切换文件位置

```
Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/Shared/AppConfig.swift
```

---

## 二、每次切换只改一个字

打开 `AppConfig.swift`，找到 `useTestServer` 属性（大约第 53 行）：

```swift
var useTestServer: Bool {
    #if DEBUG
    return false  // ← 只改这里
    #else
    return false  // Release 包硬编码，禁止修改此行
    #endif
}
```

| 想连哪里 | 把 return 改成 | API 地址 |
|---|---|---|
| **生产环境**（正式用户） | `return false` | `https://api.yohomie.art/api/v1` |
| **测试环境**（34.74.255.48） | `return true` | `http://34.74.255.48/api/v1` |

改完后在 Xcode 重新 **Build & Run** 即生效。

---

## 三、安全保障（为什么不怕忘记改回来）

```swift
#else
return false  // Release 包硬编码，禁止修改此行
#endif
```

- 这行 `return false` 对应 **Release 编译**（即提交 App Store 的包）
- **无论你 DEBUG 块里写的是 true 还是 false**，Release 包永远走生产
- 就算你测试完忘了把 `true` 改回 `false`，提交 App Store 也不会出问题
- 完全不依赖你记不记得

---

## 四、Info.plist 配置（允许 HTTP 访问测试服）

测试服 34.74.255.48 目前使用 HTTP（非 HTTPS），需要在 Xcode 的 Info.plist 添加例外，否则 iOS 会拒绝请求。

### 操作步骤

1. 在 Xcode 左侧找到 `Info.plist`，右键 → Open As → Source Code
2. 在 `<dict>` 标签内添加以下内容：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>34.74.255.48</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

> **说明**：这只对 `34.74.255.48` 开放 HTTP 例外，不影响其他所有域名的 HTTPS 要求，App Store 审核不会因此拒绝。

---

## 五、完整切换步骤

### 切换到测试环境

1. 打开 `AppConfig.swift`
2. 将 `#if DEBUG` 块内改为 `return true`
3. Xcode → Build & Run（连接真机或模拟器）
4. 注册新的测试账号（不要用正式账号，数据完全隔离）

### 切换回生产环境

1. 打开 `AppConfig.swift`
2. 将 `#if DEBUG` 块内改回 `return false`
3. Xcode → Build & Run

---

## 六、测试环境信息速查

| 项目 | 值 |
|---|---|
| 测试服 IP | `34.74.255.48` |
| 测试服 API | `http://34.74.255.48/api/v1` |
| 测试数据库 | `gemini_audio_db_test`（独立，不影响生产） |
| 测试 R2 Bucket | `micink-assets-test`（独立，不影响生产） |
| JWT 密钥 | 与生产不同（测试账号 token 在生产服无效） |

---

## 七、注意事项

- 测试环境账号和生产环境账号**完全隔离**，不要用正式账号登录测试服
- 测试服上传的录音、生成的图片存在 `micink-assets-test`，不会污染正式数据
- Release 包（TestFlight / App Store）永远走生产，无需担心
