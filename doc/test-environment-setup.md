# 测试环境搭建方案（细化版）

> 创建日期：2026-06-05
> **最后更新：2026-06-05（测试环境已完成搭建，更新实际配置值）**
> 生产服务器：34.74.150.225 | 测试服务器：34.74.255.48

---

## 一、环境对比总览

| 配置项 | 生产环境（34.74.150.225） | 测试环境（34.74.255.48） |
|---|---|---|
| **服务器 IP** | `34.74.150.225` | `34.74.255.48` |
| **域名** | `api.yohomie.art`（Nginx 绑定） | 无域名，直接用 IP |
| **iOS API 地址** | `https://api.yohomie.art/api/v1` | `http://34.74.255.48/api/v1` |
| **服务目录** | `/opt/gemini-audio-service/` | `/opt/gemini-audio-service/` |
| **systemd 服务名** | `gemini-audio.service` | `gemini-audio.service` |
| **数据库** | 本机 PostgreSQL，DB：`gemini_audio_db` | 本机独立 PostgreSQL，DB：`gemini_audio_db_test` ✅ |
| **R2 Bucket** | `micink-assets`（正式数据） | `micink-assets-test` ✅（已创建，数据隔离） |
| **Gemini API Key** | 生产 Key | 与生产共用同一个 Key ✅ |
| **JWT_SECRET_KEY** | 生产专用密钥 | `test-secret-2026-ceshi`（已配置）✅ |
| **Nginx 代理** | `/secret-channel → generativelanguage.googleapis.com` | 相同配置（GCP 美区可直连 Google）✅ |

---

## 二、服务器环境变量（.env）对比

### 测试服务器（34.74.255.48）与生产的实际差异项

> `.env` 路径：`/opt/gemini-audio-service/.env`

```env
# ── 数据库（独立测试库）──────────────────────────
DATABASE_URL=postgresql+asyncpg://zhoudabao888:<密码>@127.0.0.1:5432/gemini_audio_db_test
# 注意：注释里写的"阿里云 RDS"是过时备注，实际是本机 PostgreSQL（127.0.0.1）

# ── R2（独立测试 Bucket）─────────────────────────
R2_BUCKET_NAME=micink-assets-test
# R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT_URL 与生产相同

# ── JWT（与生产不同，防止 token 跨环境通用）────────
JWT_SECRET_KEY=test-secret-2026-ceshi

# ── Gemini（共用生产 Key）────────────────────────
GEMINI_API_KEY=<与生产相同的 Key>
```

---

## 三、数据库状态（已完成）✅

### 实际执行记录（2026-06-05）

```bash
# 1. 创建测试数据库
sudo -u postgres psql -c "CREATE DATABASE gemini_audio_db_test;"

# 2. 授权给应用用户
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE gemini_audio_db_test TO zhoudabao888;"
sudo -u postgres psql gemini_audio_db_test -c "GRANT ALL ON SCHEMA public TO zhoudabao888;"

# 3. 重启服务，FastAPI 自动建表
sudo systemctl restart gemini-audio.service
```

### 当前状态

```
15 张表已全部自动创建（Owner: zhoudabao888）：
analysis_results / custom_skills / kg_event_persons / kg_events
kg_goals / kg_persons / kg_skills / profiles / sessions
skill_executions / skills / strategy_analysis
user_skill_preferences / users / verification_codes
```

### 日后如需从生产导入数据

```bash
# 在生产服导出
ssh liudanmi@34.74.150.225
pg_dump -U postgres gemini_audio_db > /tmp/prod_backup.sql

# 传到测试服并导入
scp liudanmi@34.74.150.225:/tmp/prod_backup.sql /tmp/
ssh liudanmi@34.74.255.48
sudo -u postgres psql gemini_audio_db_test < /tmp/prod_backup.sql
```

---

## 四、Cloudflare R2 测试 Bucket（已创建）✅

- **Bucket 名称**：`micink-assets-test`
- **访问凭证**：与生产 Bucket 共用同一套 R2 API Token
- **Cloudflare Dashboard**：R2 → 存储桶 → `micink-assets-test`

### Bucket 目录结构

```
micink-assets-test/
├── sessions/{user_id}/{session_id}/original.m4a   ← 测试录音
├── sessions/{user_id}/{session_id}/images/{n}.png ← 测试场景图
└── emotion_avatars/{style}/{category}.png          ← 情绪头像（待从生产复制）
```

> **待办**：emotion_avatars 是系统静态资源，首次使用时如图片 404，需从生产 Bucket 手动复制一份到测试 Bucket。

---

## 五、Gemini API Key

| 项目 | 生产 | 测试 |
|---|---|---|
| **Key** | 生产 Gemini API Key | **共用生产 Key** ✅ |
| **配额风险** | 1,500 次/天免费额度 | 测试用量 < 50 次/天，无影响 |
| **升级时机** | 破 200 DAU 时 | 压测时再申请独立 Key |

### Nginx 代理连通性（测试服已验证）

两台服务器均为 GCP 美区，可直连 `generativelanguage.googleapis.com`，无需额外代理配置。

---

## 六、iOS 切换到测试环境（方案二已实现）✅

> 详细操作见：[ios客户端正式测试环境切换文档.md](./ios客户端正式测试环境切换文档.md)

### 实现位置

`Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/Shared/AppConfig.swift` 第 53–72 行

### 切换方式（只改一个字）

```swift
var useTestServer: Bool {
    #if DEBUG
    return false  // ← 改这里：false = 生产，true = 测试服
    #else
    return false  // Release 包硬编码，永远走生产，禁止修改
    #endif
}
```

| 目标环境 | 改法 |
|---|---|
| 生产（`api.yohomie.art`） | `return false` |
| 测试（`34.74.255.48`） | `return true` |

**安全保障**：Release 包（App Store 提交）物理锁死 `false`，忘记改回来也不影响线上。

---

## 七、服务管理命令（测试服）

```bash
# SSH 进入测试服
ssh liudanmi@34.74.255.48

# 查看服务状态
sudo systemctl status gemini-audio.service

# 重启服务（改完 .env 后执行）
sudo systemctl restart gemini-audio.service

# 查看最新日志
sudo journalctl -u gemini-audio.service -n 30 --no-pager

# 验证数据库表
sudo -u postgres psql gemini_audio_db_test -c "\dt"
```

---

## 八、验证 Checklist

```
✅ 测试服 PostgreSQL 已启动，数据库 gemini_audio_db_test 已创建
✅ 15 张表已自动创建完成
✅ 测试服 .env 已修改（DATABASE_URL / R2_BUCKET_NAME / JWT_SECRET_KEY / GEMINI_API_KEY）
✅ R2 测试 Bucket micink-assets-test 已创建
✅ FastAPI 服务已启动（systemd gemini-audio.service，Application startup complete）
✅ GCP 美区直连 Google，无需代理
✅ iOS AppConfig.swift 已实现测试服开关（useTestServer，默认 false 走生产）
□ Info.plist 添加 34.74.255.48 HTTP 例外（首次用 iOS 连测试服时操作）
□ 注册测试账号 → 上传录音 → 验证全流程跑通
□ emotion_avatars 从生产 Bucket 复制到测试 Bucket（首次图片 404 时操作）
```

---

## 九、恢复 / 注意事项

- 测试服持续运行，不需要关闭，下次直接用
- 测试账号和生产账号完全隔离（不同 JWT 密钥，不同数据库，不同 R2 Bucket）
- iOS Release 包永远走生产，无需担心误上线
