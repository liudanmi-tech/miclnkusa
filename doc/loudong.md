# 安全漏洞记录

> 记录已知但暂不紧急修复的安全问题，供下次版本迭代时处理。
> 最后更新：2026-06-05（含性能问题）

---

## 漏洞1 — Apple 订阅收据无签名验证

**风险级别：🟠 中（现在低，随用户增长升为中高）**
**修复紧急程度：下个版本修复，不需要今晚处理**

### 问题描述

后端 `_decode_jws_payload()` 函数只做了 base64 解码，没有验证 Apple 的加密签名（x5c 证书链）。这意味着任何人都可以构造一个格式正确的假 JWS，绕过付款直接开通 Pro。

代码位置：`server_code/main.py` ~5004行

```python
def _decode_jws_payload(jws_token: str) -> dict:
    # 只解码，不验签 ← 问题所在
    # TODO: 后续可加 x5c 证书链验证来完整校验 Apple 签名
    parts = jws_token.split('.')
    payload_bytes = base64.urlsafe_b64decode(parts[1] + padding)
    return json.loads(payload_bytes)
```

### 触发方式

攻击者需要：
1. 注册一个账号（免费）
2. 抓包一次真实请求，获取 API 地址和参数格式（10分钟）
3. 构造假 JWS：把合法的 bundleId + productId 写入 JSON，做 base64 编码，拼成 `header.payload.signature` 格式
4. 带登录 token 调用 `POST /api/v1/subscription/verify`

```python
# 攻击示例（10行 Python）
import base64, json, requests
payload = {
    "bundleId": "com.liudan.WorkSurvivalGuide",
    "productId": "com.miclnk.pro.yearly",
    "expiresDate": 9999999999999
}
fake_jws = "eyJhbGciOiJFUzI1NiJ9." + \
    base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=") + \
    ".fakesignature"
# 配上登录 token 直接调用接口即可
```

### 影响范围

- ✅ 只影响订阅收入（攻击者免费用 Pro）
- ✅ 不涉及其他用户数据泄露
- ✅ 不影响录音/档案/AI/图片等业务模块
- ❌ 每个账号可以无限次免费开通 Pro

### 修复方案

使用 Apple 官方公钥验证 JWS 签名（x5c 证书链验证）。Apple 有完整文档：
https://developer.apple.com/documentation/appstoreserverapi/jwstransactiondecodedpayload

修改位置：`server_code/main.py` `_decode_jws_payload()` 函数，加入证书链校验逻辑，一次性工作。

---

## 漏洞2 — fallback 信任模式（JWS 解析失败继续执行）

**风险级别：🟡 低（需配合漏洞1，正常业务不触发）**
**修复紧急程度：顺手修，修漏洞1时一并处理**

### 问题描述

`verify_subscription` 接口在 JWS 解码抛出异常时，不拒绝请求，而是静默记录日志后继续执行开通逻辑（"信任模式"）。

代码位置：`server_code/main.py` ~5068行

```python
except Exception as _e:
    logger.warning(f"JWS 解码失败，降级为信任模式: {_e}")
    # ← 没有 raise，继续执行，仍然开通 Pro
```

### 触发方式

发送格式错误的 JWS（非 `xxx.yyy.zzz` 格式，或 base64 非法），后端解析失败后走 fallback 通道，照样开通 Pro。

### 影响范围

与漏洞1相同，且需要知道接口格式。正常业务中 Apple 的 JWS 永远合法，此 fallback 在生产环境中从未触发过。

### 修复方案

```python
except Exception as _e:
    logger.warning(f"JWS 解码失败: {_e}")
    raise HTTPException(status_code=400, detail="Invalid JWS receipt")  # 加这一行
```

---

## 漏洞3 — 多步删除操作无数据库事务

**风险级别：🟡 低（需要服务器在特定时刻崩溃才触发）**
**修复紧急程度：不紧急，有空时修**

### 问题描述

删除一条 Session 时，后端依次执行 5 步 DELETE（kg_events → kg_skills → kg_goals → kg_persons → session），这 5 步没有包裹在同一个数据库事务中。如果服务器在第 3 步崩溃，前 2 步已删除但 session 本身还在，造成数据不一致（孤儿 KG 记录被删，但 session 和其他关联数据还在）。

代码位置：`server_code/main.py` ~2740-2785行

### 触发方式

服务器在多步删除过程中崩溃（断电、OOM kill、部署重启等），概率极低，但不为零。

### 影响范围

- 知识图谱数据可能出现孤儿记录或不完整删除
- 不影响用户登录、录音、档案、订阅等核心功能
- 不会丢失用户主数据

### 修复方案

```python
async with db.begin():
    await db.execute(delete(KgEvent).where(...))
    await db.execute(delete(KgSkill).where(...))
    await db.execute(delete(KgGoal).where(...))
    await db.execute(delete(KgPerson).where(...))
    await db.execute(delete(Session).where(...))
# 事务自动提交，任一步失败全部回滚
```

---

## 漏洞4 — IDOR：Profile 查询缺少 user_id 过滤

**风险级别：🟢 极低（攻击路径极窄，已评估决定暂不修复）**
**修复紧急程度：暂不修复（2026-06-05 评估）**

### 问题描述

两处通过 `speaker_mapping` 查询 Profile 的代码，没有加 `user_id` 过滤：

- `server_code/main.py` ~3561行（KG C 钩子）
- `server_code/main.py` ~3758行（classify-scene 接口）

### 触发方式

攻击者需要将其他用户的 Profile UUID 注入自己的 `speaker_mapping`（需要利用另一个未知漏洞才能做到），才能触发跨用户 Profile 查询。正常业务流程中 `speaker_mapping` 只包含当前用户自己的 Profile。

### 影响范围

仅能读取其他用户档案的**姓名和关系类型**（如"领导"），不暴露照片、手机号等核心数据，且读取结果不会直接返回给攻击者（仅用于内部 KG 写入和技能匹配）。

### 不修复理由

实际攻击路径需要两步漏洞叠加，且数据暴露面极小，正常业务完全不受影响。

---

---

## 性能问题1 — 技能库 catalog 接口每次都查数据库

**风险级别：🟢 极低（当前用户量下无感知，10万DAU以上才需处理）**
**修复紧急程度：暂不修复（2026-06-05 评估）**

### 问题描述

用户每次冷启动 App 进入技能页，后端 `/api/v1/skills/catalog` 接口都会查一次 `user_skill_preferences` 表（读取用户勾选了哪些技能）。技能内容本身（名称/描述/封面）已有 5 分钟内存缓存，但用户偏好这部分每次都打数据库，没有缓存。

iOS 端 `SkillsViewModel` 有会话内去重（`hasLoaded` 标志），但 App 重启后重置，无 UserDefaults 持久化缓存。

代码位置：
- 后端：`server_code/skills.py` `get_skills_catalog()` 函数，`select UserSkillPreference` 查询
- iOS：`WorkSurvivalGuide/ViewModels/SkillsViewModel.swift` `loadCatalog()`

### 触发方式

用户冷启动 App → 进入技能页 = 触发 1 次 DB 查询。每日请求数 ≈ DAU × 每日进入技能页次数。

### 影响范围

- 现阶段（百~千 DAU）：**完全无影响**，数据库轻松处理
- 1万 DAU：约 2 万次/天（0.23 次/秒），仍无压力
- 10万 DAU：开始需要优化

不影响数据正确性，只是重复查询，不会出现数据错误。

### 修复方案（供未来参考）

**方案 A（最小改动，1行后端代码）**：给响应加 `Cache-Control: private, max-age=60`，让 iOS 的 HTTP 缓存协议生效，60 秒内冷启动不重复请求。

**方案 B（iOS 端持久化缓存）**：仿照 `ImageStyleRepository` 的做法，冷启动先展示 UserDefaults 缓存，后台静默刷新。

---

## 优先级汇总

| # | 问题 | 风险 | 何时修 |
|---|---|---|---|
| 1 | Apple JWS 无签名验证 | 🟠 中 | **下个版本（高优先）** |
| 2 | JWS fallback 信任模式 | 🟡 低 | 随漏洞1一起修 |
| 3 | 多步删除无事务 | 🟡 低 | 有空时修 |
| 4 | Profile IDOR | 🟢 极低 | 暂不修复 |
| 5 | 技能库 catalog 每次查 DB | 🟢 极低 | 10万DAU以上再处理 |
| 6 | 图片代理接口 Cache-Control: public 写错 | 🟢 极低 | 有空顺手改 |

---

## 性能问题2 — 图片代理接口 Cache-Control 响应头写错

**风险级别：🟢 极低（当前无 CDN 在 API 前面，无实际影响）**
**修复紧急程度：暂不修复（2026-06-05 评估）**

### 问题描述

`/api/v1/images/{session_id}/{image_index}` 接口需要 JWT 鉴权才能访问（私有内容），但响应头写的是 `Cache-Control: public, max-age=3600`。`public` 表示允许 CDN / 代理服务器缓存，与"需要鉴权的私有内容"语义矛盾，正确写法应为 `private`。

代码位置：`server_code/main.py` ~4308 行

```python
headers={"Cache-Control": "public, max-age=3600"}  # ← 应改为 private
```

### 触发方式

当前服务器前面没有 CDN，不会触发。若未来在 API 前加 CDN（如 Cloudflare），可能导致某个用户的图片被 CDN 缓存后，通过相同 URL 被其他人取到（实际路径含 UUID，可能性极低）。

### 影响范围

- 不影响当前功能
- 不影响图片权限控制（每次请求仍需 JWT）
- 只有在 API 前加 CDN 后才有实际风险

### 修复方案

```python
headers={"Cache-Control": "private, max-age=3600"}
```

一行改动，无其他影响。
