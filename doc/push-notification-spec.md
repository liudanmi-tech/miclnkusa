# 个性化每日 Push 通知技术方案

> 目标：根据用户对话记录和记忆，每日推送千人千面的个性化通知，提升 App 留存与粘性。

---

## 一、产品定位

**不是营销推送，是"AI 好友的惦念"。**

用户收到的感觉是：*"它还记得我上次说的事"*，而不是 *"又是一条广告"*。

推送的唯一目的是**唤回当日未活跃的用户**。已活跃用户不推，推了反而烦。

---

## 二、目标市场与推送时间

### 目标时区

| 市场 | 时区 | UTC 偏移 | 备注 |
|------|------|---------|------|
| 美国东部（夏） | EDT | UTC-4 | 3月第2个周日 ~ 11月第1个周日 |
| 美国东部（冬） | EST | UTC-5 | 11月第1个周日 ~ 3月第2个周日 |
| 美国西部（夏） | PDT | UTC-7 | 同上 |
| 美国西部（冬） | PST | UTC-8 | 同上 |
| 新加坡 | SGT | UTC+8 | 全年固定，无夏令时 |

### 推送目标时间

**本地时间 20:00（晚 8 点）**：晚饭后、睡前 2 小时，情绪复盘的自然时段。

```
本地 20:00 对应 UTC：

新加坡  SGT (+8)  →  12:00 UTC
美东夏  EDT (-4)  →  00:00 UTC（次日）
美东冬  EST (-5)  →  01:00 UTC（次日）
美西夏  PDT (-7)  →  03:00 UTC（次日）
美西冬  PST (-8)  →  04:00 UTC（次日）
```

### Cron 配置

```bash
# /etc/cron.d/push-notifications
# 夏令时期间启用 EDT/PDT，冬令时切换时注释掉换另一行

# 美东夏令 EDT → 本地 20:00 = 00:00 UTC
0  0  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py EDT

# 美东冬令 EST → 本地 20:00 = 01:00 UTC（冬令时取消注释）
# 0  1  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py EST

# 美西夏令 PDT → 本地 20:00 = 03:00 UTC
0  3  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py PDT

# 美西冬令 PST → 本地 20:00 = 04:00 UTC（冬令时取消注释）
# 0  4  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py PST

# 新加坡 SGT → 本地 20:00 = 12:00 UTC（全年固定）
0  12 * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py SGT
```

夏令时切换（每年3月、11月）：将对应行注释/取消注释，1 分钟完成。

---

## 三、三种用户场景

### 场景判断逻辑

```
今天已打开 App（last_active_at::date = 今天）→ 跳过，不推送
今天未打开 App                               → 按 Tier 推送
```

**具体示例：**

```
周一聊天，周二 20:00 触发：
  last_active_at = 周一 → 不等于今天(周二) → 发送 ✅

周一聊天，周二下午 2 点打开过 App：
  last_active_at = 周二 14:00 → 等于今天(周二) → 跳过 ❌

每天都聊天的用户：
  last_active_at = 今天 → 跳过 ❌（日活用户无需推送）
```

### 场景 A：从未聊过（或 >30 天未聊）

- **Tier 4**，无任何个性化数据
- 使用 14 条预设模板轮换，2 周不重复
- 不调用 Gemini，节省成本

### 场景 B：聊过但当前沉默中

- **Tier 1/2/3**，根据上次对话距今时间判断
- 同一段对话记录，用 5 个不同角度切入，每天换一个，不重复
- 调用 Gemini 生成个性化文案

### 场景 C：今日已活跃

- 直接跳过，不推送
- 适用于每天都用 App 的用户

---

## 四、Tier 分级与角度系统

### Tier 判断

| Tier | 条件 | 文案来源 |
|------|------|---------|
| 1 | 距上次对话 ≤ 48 小时 | Gemini 生成 |
| 2 | 距上次对话 7 天内 | Gemini 生成 |
| 3 | 距上次对话 30 天内 | Gemini 生成 |
| 4 | 从未对话 / >30 天 | 模板池轮换 |

### 5 个切入角度（Tier 1/2）

同一段对话记录，每天换一个角度，5 天不重复：

| 角度 | hook_type | 风格 | 示例标题 |
|------|-----------|------|---------|
| 跟进事件 | followup | 好奇+关心 | "那件事后来怎样了？" |
| 情绪关怀 | emotion | 温柔+陪伴 | "心情有没有好一点？" |
| 换个视角 | perspective | 启发+平静 | "换个角度想想那件事" |
| 行动引导 | action | 鼓励+务实 | "如果要做一件事..." |
| 深度反思 | reflection | 沉静+智慧 | "回头再看，有新感受吗？" |

**角度选择规则：**
- 有新 session（和上次推送依据的不同）→ 重置为 `followup`
- 同一 session 继续 → 依次选未用过的角度
- 5 个全用完 → 重新从头循环

### 3 个角度（Tier 3）

| 角度 | hook_type | 说明 |
|------|-----------|------|
| 记忆引用 | memory_ref | 模糊引用历史经历，让用户感到被记得 |
| 鼓励表达 | encouragement | 鼓励用户说出当下状态 |
| 思考引导 | challenge | 提一个让用户思考的小问题 |

### 14 条冷启动模板（Tier 4）

```python
COLD_TEMPLATES = [
    {"day": 1,  "title": "今天工作顺利吗？",           "body": "职场上有什么卡住的地方，说出来或许就通了"},
    {"day": 2,  "title": "最近有什么烦心事吗？",       "body": "不管大事小事，说出来会轻松很多"},
    {"day": 3,  "title": "和同事相处还好吗？",         "body": "人与人之间的摩擦，往往值得聊聊"},
    {"day": 4,  "title": "今天心情怎么样？",           "body": "好的坏的都可以讲，这里不会评判你"},
    {"day": 5,  "title": "最近睡得好吗？",             "body": "睡不好往往是心里有事，聊聊？"},
    {"day": 6,  "title": "有什么话想说却没地方说？",   "body": "找不到人说的时候，这里随时在"},
    {"day": 7,  "title": "和家人的关系还好吗？",       "body": "亲密关系里的小摩擦，聊出来更容易看清楚"},
    {"day": 8,  "title": "这周过得怎么样？",           "body": "回顾一下，也许有些事值得再想想"},
    {"day": 9,  "title": "最近有让你开心的事吗？",     "body": "好消息也值得被记录下来"},
    {"day": 10, "title": "有没有一件事一直拖着没做？", "body": "说出来，可能就是迈出第一步"},
    {"day": 11, "title": "下周有什么让你担心的事？",   "body": "提前说出来，会比你想的好处理"},
    {"day": 12, "title": "最近有没有让你委屈的事？",   "body": "委屈憋着会很难受，这里可以说"},
    {"day": 13, "title": "有没有一个人你最近想多了解？","body": "关系里的困惑，说出来会更清晰"},
    {"day": 14, "title": "今天想聊什么都可以",         "body": "不需要主题，随便说说就好"},
]
```

轮换逻辑：查该用户历史已发的模板序号，从未发过的里随机选；14 条全发完后重新循环。

---

## 五、数据库 Schema

```sql
-- users 表新增字段
ALTER TABLE users
  ADD COLUMN apns_device_token   VARCHAR(512),
  ADD COLUMN notification_opt_in BOOLEAN DEFAULT TRUE,
  ADD COLUMN timezone            VARCHAR(64) DEFAULT 'America/New_York',
  ADD COLUMN last_active_at      TIMESTAMP;

-- 新增 notification_log 表
CREATE TABLE notification_log (
    id               SERIAL PRIMARY KEY,
    user_id          INTEGER REFERENCES users(id),
    sent_at          TIMESTAMP NOT NULL,
    tier             INTEGER NOT NULL,        -- 1/2/3/4
    hook_type        VARCHAR(50) NOT NULL,    -- followup/emotion/perspective/action/reflection/memory_ref/encouragement/challenge/generic_N
    hook_index       INTEGER,                 -- Tier 4 模板序号 1-14
    title            VARCHAR(100),
    body             VARCHAR(200),
    ref_session_id   VARCHAR(100),            -- 生成依据的 session id
    ref_session_date DATE,                    -- 生成依据的 session 日期
    opened           BOOLEAN DEFAULT FALSE,
    opened_at        TIMESTAMP,
    created_at       TIMESTAMP DEFAULT NOW()
);

CREATE INDEX ON notification_log (user_id, sent_at DESC);
```

---

## 六、服务端文件结构

```
server_code/
├── api/
│   └── notifications.py          ← 新增：device token 注册、点击追踪接口
├── services/
│   └── notification_service.py   ← 新增：核心逻辑（Tier判断、角度选择、Gemini、APNs）
├── scripts/
│   └── daily_notifications.py    ← 新增：cron 入口脚本
└── main.py                       ← 修改：引入 router + last_active_at 中间件
```

---

## 七、核心服务端代码

### `scripts/daily_notifications.py`

```python
import sys, asyncio
from services.notification_service import process_batch

BUCKET_TIMEZONES = {
    "EDT": ["America/New_York", "America/Toronto", "America/Detroit",
            "America/Indiana/Indianapolis"],
    "EST": ["America/New_York", "America/Toronto", "America/Detroit",
            "America/Indiana/Indianapolis"],
    "PDT": ["America/Los_Angeles", "America/Vancouver", "America/Seattle",
            "America/Phoenix"],
    "PST": ["America/Los_Angeles", "America/Vancouver", "America/Seattle",
            "America/Phoenix"],
    "SGT": ["Asia/Singapore"],
}

if __name__ == "__main__":
    bucket = sys.argv[1]
    asyncio.run(process_batch(BUCKET_TIMEZONES[bucket]))
```

### `services/notification_service.py`（核心逻辑）

#### 筛选目标用户

```python
async def get_eligible_users(timezones: list[str]) -> list:
    return await db.fetch("""
        SELECT u.*
        FROM users u
        LEFT JOIN notification_log nl
            ON nl.user_id = u.id
            AND nl.sent_at::date = CURRENT_DATE
        WHERE u.timezone            = ANY(:tzs)
          AND u.apns_device_token  IS NOT NULL
          AND u.notification_opt_in = TRUE
          AND nl.id IS NULL                          -- 今日未发过
          AND (
              u.last_active_at IS NULL               -- 从未打开过
              OR u.last_active_at::date < CURRENT_DATE  -- 今天还没打开
          )
    """, tzs=timezones)
```

#### Tier 判断

```python
async def build_user_context(user_id: int) -> dict:
    now      = datetime.utcnow()
    sessions = await db.fetch("""
        SELECT id, card_title, mood_state, emotion_type, skill_tags, created_at
        FROM sessions
        WHERE user_id = :uid AND session_type = 'chat' AND card_title IS NOT NULL
        ORDER BY created_at DESC LIMIT 5
    """, uid=user_id)

    if not sessions:
        return {"tier": 4, "ref_session": None}

    latest = sessions[0]
    age    = now - latest.created_at

    if   age <= timedelta(hours=48): tier = 1
    elif age <= timedelta(days=7):   tier = 2
    elif age <= timedelta(days=30):  tier = 3
    else:                            tier = 4

    return {"tier": tier, "ref_session": latest,
            "ref_session_date": latest.created_at.date()}
```

#### 角度选择（防重复）

```python
HOOK_ORDER_T1_T2 = ["followup", "emotion", "perspective", "action", "reflection"]
HOOK_ORDER_T3    = ["memory_ref", "encouragement", "challenge"]

async def pick_next_hook(user_id: int, tier: int) -> str:
    recent = await db.fetch("""
        SELECT hook_type FROM notification_log
        WHERE user_id = :uid ORDER BY sent_at DESC LIMIT 5
    """, uid=user_id)

    used      = {r.hook_type for r in recent}
    pool      = HOOK_ORDER_T1_T2 if tier <= 2 else HOOK_ORDER_T3
    available = [h for h in pool if h not in used]

    if not available:
        available = pool   # 全部用完，重新循环

    return available[0]
```

#### 单用户完整处理流程

```python
async def process_one_user(user):
    context = await build_user_context(user.id)
    tier    = context["tier"]

    # Tier 4：模板轮换，不调 AI
    if tier == 4:
        template = pick_cold_template(user.id)
        copy = {
            "title":    template["title"],
            "body":     template["body"],
            "tier":     4,
            "hook_type": f"generic_{template['day']}",
            "hook_index": template["day"],
            "ref_session_id": None,
        }

    # Tier 1/2/3：选角度，调 Gemini
    else:
        ref_session = context["ref_session"]
        last_log    = await get_last_notification_log(user.id)

        # 有新 session → 重置角度从 followup 开始
        session_changed = (
            last_log is None or
            last_log.ref_session_id != str(ref_session.id)
        )
        hook_type = "followup" if session_changed else await pick_next_hook(user.id, tier)

        copy = await generate_copy(context, hook_type)
        copy["ref_session_id"] = str(ref_session.id)

    # 发送 APNs
    ok = await send_apns(
        token   = user.apns_device_token,
        title   = copy["title"],
        body    = copy["body"],
        payload = {"action": "open_chat"},
        sandbox = user.apns_sandbox
    )

    # 写日志
    if ok:
        await db.execute("""
            INSERT INTO notification_log
              (user_id, sent_at, tier, hook_type, hook_index,
               title, body, ref_session_id, ref_session_date)
            VALUES
              (:uid, NOW(), :tier, :hook, :hidx,
               :title, :body, :ref_id, :ref_date)
        """, {
            "uid": user.id,       "tier": copy["tier"],
            "hook": copy["hook_type"], "hidx": copy.get("hook_index"),
            "title": copy["title"],    "body": copy["body"],
            "ref_id": copy.get("ref_session_id"),
            "ref_date": context.get("ref_session_date"),
        })
```

#### Gemini 文案生成

```python
HOOK_INSTRUCTIONS = {
    "followup":     "围绕「事件结果跟进」，语气：好奇+关心",
    "emotion":      "围绕「用户情绪后续变化」，语气：温柔+陪伴",
    "perspective":  "围绕「换一个角度看同一件事」，语气：启发+平静",
    "action":       "围绕「做一件小事改变现状」，语气：鼓励+务实",
    "reflection":   "围绕「时间过去后的新感受」，语气：沉静+智慧",
    "memory_ref":   "模糊引用用户历史经历，语气：温暖+被记得",
    "encouragement":"鼓励用户表达当下状态，语气：温暖+开放",
    "challenge":    "提一个让用户思考的小问题，语气：好奇+轻松",
}

async def generate_copy(context: dict, hook_type: str) -> dict:
    ref    = context["ref_session"]
    prompt = f"""
用户最近的对话记录：
主题：{ref.card_title}
情绪：{ref.mood_state}（{ref.emotion_type}）
发生在：{hours_ago(ref.created_at)} 小时前

生成角度：{HOOK_INSTRUCTIONS[hook_type]}

输出 JSON（不要有其他内容）：
{{"title": "≤15字", "body": "≤35字"}}

规则：
- 不出现人名、公司名、具体地名
- 口吻像好友发微信，不像 App 推送通知
- 不用感叹号
"""
    resp = await gemini.generate(prompt, model="gemini-2.5-flash-lite")
    data = json.loads(resp)
    return {"title": data["title"], "body": data["body"],
            "tier": context["tier"], "hook_type": hook_type}
```

#### APNs HTTP/2 发送

```python
# 依赖：pip install httpx[http2] PyJWT
import httpx, jwt, time

async def send_apns(token: str, title: str, body: str,
                    payload: dict, sandbox: bool = False) -> bool:
    host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"

    apns_jwt = jwt.encode(
        {"iss": APNS_TEAM_ID, "iat": int(time.time())},
        APNS_P8_KEY,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID}
    )

    body_payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
        },
        **payload
    }

    async with httpx.AsyncClient(http2=True) as client:
        resp = await client.post(
            f"https://{host}/3/device/{token}",
            json=body_payload,
            headers={
                "authorization": f"bearer {apns_jwt}",
                "apns-topic":     APNS_BUNDLE_ID,
                "apns-push-type": "alert",
                "apns-priority":  "5",
            },
            timeout=10,
        )

    # Token 失效（用户卸载 App）→ 清除
    if resp.status_code == 410:
        await db.execute(
            "UPDATE users SET apns_device_token = NULL WHERE apns_device_token = :t",
            {"t": token}
        )
        return False

    return resp.status_code == 200
```

### `api/notifications.py`（新增接口）

```python
# POST /api/v1/device/token  — iOS 注册/更新 device token
@router.post("/device/token")
async def register_device_token(body: DeviceTokenRequest,
                                 user=Depends(get_current_user),
                                 db=Depends(get_db)):
    await db.execute("""
        UPDATE users
        SET apns_device_token = :token,
            timezone          = :tz,
            apns_sandbox      = :sandbox
        WHERE id = :uid
    """, {"token": body.device_token, "tz": body.timezone,
          "sandbox": body.sandbox,    "uid": user.id})
    return {"ok": True}


# POST /api/v1/notification/opened  — 用户点击通知后记录
@router.post("/notification/opened")
async def notification_opened(body: NotificationOpenedRequest,
                               user=Depends(get_current_user),
                               db=Depends(get_db)):
    await db.execute("""
        UPDATE notification_log
        SET opened = TRUE, opened_at = NOW()
        WHERE id = :nid AND user_id = :uid
    """, {"nid": body.notification_log_id, "uid": user.id})
    return {"ok": True}
```

### `main.py` 改动

```python
# 1. 引入新路由
from api.notifications import router as notifications_router
app.include_router(notifications_router, prefix="/api/v1")

# 2. 中间件：每次认证请求更新 last_active_at（用于跳过今日活跃用户）
@app.middleware("http")
async def track_last_active(request: Request, call_next):
    response = await call_next(request)
    uid = getattr(request.state, "user_id", None)
    if uid:
        await db.execute(
            "UPDATE users SET last_active_at = NOW() WHERE id = :uid",
            {"uid": uid}
        )
    return response
```

---

## 八、iOS 端改动

### `WorkSurvivalGuideApp.swift`

```swift
@main
struct WorkSurvivalGuideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { requestPushPermission() }
        }
    }

    private func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // APNs 返回 device token → 上传服务端
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await NetworkManager.shared.registerDeviceToken(token) }
    }

    // 用户点击通知
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let nid = info["notification_log_id"] as? Int {
            try? await NetworkManager.shared.trackNotificationOpened(id: nid)
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("PushNotificationTapped"),
                object: nil
            )
        }
    }
}
```

### `NetworkManager.swift` 新增方法

```swift
// 注册 device token（含时区信息）
func registerDeviceToken(_ token: String) async throws {
    try await post("/api/v1/device/token", body: [
        "device_token": token,
        "timezone":     TimeZone.current.identifier,  // "America/New_York" / "Asia/Singapore"
        "sandbox":      AppConfig.shared.useTestServer
    ])
}

// 记录通知点击
func trackNotificationOpened(id: Int) async throws {
    try await post("/api/v1/notification/opened",
                   body: ["notification_log_id": id])
}
```

### `ContentView.swift` 监听点击路由

```swift
.onReceive(NotificationCenter.default.publisher(for:
    NSNotification.Name("PushNotificationTapped"))) { _ in
    // 打开 AI Chat 新建 session（复用现有逻辑）
    recordingViewModel.createChatSession()
}
```

---

## 九、APNs 环境变量（服务端 .env）

```bash
APNS_KEY_ID=XXXXXXXXXX               # App Store Connect → Keys → Key ID
APNS_TEAM_ID=XXXXXXXXXX              # Apple Developer → Membership → Team ID
APNS_BUNDLE_ID=com.miclnk.pro
APNS_P8_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
```

---

## 十、所有场景行为汇总

| 用户状态 | Tier | 角度/模板 | 文案来源 | 是否发送 |
|---------|------|----------|---------|---------|
| 今日已打开 App | — | — | — | ❌ 跳过 |
| 今日已发过推送 | — | — | — | ❌ 跳过 |
| 无 device token | — | — | — | ❌ 跳过 |
| 从未聊过 / >30天未聊 | 4 | generic_1~14 轮换 | 模板，不调 AI | ✅ 发送 |
| 7~30天前聊过，今日未开 | 3 | memory/encourage/challenge 轮换 | Gemini | ✅ 发送 |
| 48h~7天前聊过，今日未开 | 2 | followup→emotion→perspective→action→reflection | Gemini | ✅ 发送 |
| 48h内聊过（新 session），今日未开 | 1 | 重置为 followup | Gemini | ✅ 发送 |

---

## 十一、对现有模块的影响

| 文件 | 改动内容 | 影响程度 |
|------|---------|---------|
| `database/models.py` | User 加4字段；新增 NotificationLog ORM | 中 |
| `main.py` | 引入 notifications router；加 last_active_at 中间件 | 低 |
| `WorkSurvivalGuideApp.swift` | 加推送权限请求 + AppDelegate 代理 | 中 |
| `NetworkManager.swift` | 新增 registerDeviceToken / trackNotificationOpened | 低 |
| `ContentView.swift` | 监听 PushNotificationTapped → createChatSession | 低 |
| `api/assistant.py` | 不改动 | 无 |
| `ChatAIAssistantView.swift` | 不改动 | 无 |
| `scene_image_generator.py` | 不改动 | 无 |

**新增文件：**
- `server_code/api/notifications.py`
- `server_code/services/notification_service.py`
- `server_code/scripts/daily_notifications.py`

---

## 十二、成本估算

```
假设日活用户 1000 人，Tier 分布估算：

Tier 1（48h内有对话）  约 20% = 200人 → 200次 Gemini 调用
Tier 2（7天内有对话）  约 30% = 300人 → 300次 Gemini 调用
Tier 3/4（更早/无数据）约 50% = 500人 → 0次（模板）

每次 Gemini 调用 input ~200 tokens，output ~50 tokens
使用 gemini-2.5-flash-lite：约 $0.0001/次
500次/天 × $0.0001 = $0.05/天 ≈ $1.5/月

成本可忽略不计。
```

---

## 十三、分阶段实施

```
Phase 1 — 链路打通（无 AI）
  ① DB 迁移（users 新增字段 + notification_log 表）
  ② iOS 推送权限 + device token 上传
  ③ POST /api/v1/device/token 接口
  ④ notification_service.py 基础版（send_apns + Tier 4 模板）
  ⑤ 手动触发脚本，验证 APNs 到达

Phase 2 — AI 个性化
  ⑥ build_user_context() + Tier 判断
  ⑦ pick_next_hook() 角度轮换
  ⑧ Gemini generate_copy() 接入（Tier 1/2/3）
  ⑨ Cron 定时任务上线

Phase 3 — 数据闭环
  ⑩ 通知点击追踪（/notification/opened）
  ⑪ ContentView 深链路由
  ⑫ last_active_at 中间件上线（跳过今日活跃用户）
  ⑬ 分析 CTR by Tier / hook_type，迭代文案
```
