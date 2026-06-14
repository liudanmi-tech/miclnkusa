# 调试指南

## 连接服务器

```bash
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225
```

本地 `~/.ssh/google_compute_engine` 是 GCP 密钥，已配置好免密登录。

---

## 查看日志

```bash
# 实时追踪日志
tail -f ~/gemini-audio-service.log

# 过滤特定关键词
grep "ERROR\|WARNING" ~/gemini-audio-service.log | tail -50

# 查看某个 session 的完整日志
grep "session_id_前8位" ~/gemini-audio-service.log

# 查看音频上传流程
grep "\[upload\]\|\[分析\]\|\[声纹\]\|\[KG\]" ~/gemini-audio-service.log | tail -100

# 查看策略生成流程
grep "\[策略流程\]" ~/gemini-audio-service.log | tail -50
```

---

## 重启服务

```bash
# 查找进程
ps aux | grep main.py

# 杀掉旧进程
kill $(pgrep -f "python3 main.py")

# 重新启动（后台运行）
cd ~ && nohup python3 main.py >> gemini-audio-service.log 2>&1 &

# 确认启动成功
sleep 3 && curl http://localhost:8000/health
```

---

## 部署新代码

服务器上**没有 git**，通过 scp 直接覆盖：

```bash
# 从本地上传 main.py
scp -i ~/.ssh/google_compute_engine main.py liudan@34.74.150.225:~/main.py

# 上传后重启
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225 \
  "kill \$(pgrep -f 'python3 main.py') 2>/dev/null; sleep 1; cd ~ && nohup python3 main.py >> gemini-audio-service.log 2>&1 &"
```

---

## 测试接口

```bash
# 健康检查
curl http://34.74.150.225/health

# 测试 Gemini 连通
curl http://34.74.150.225/test-gemini

# 本地 Swagger UI（需 SSH 隧道）
ssh -i ~/.ssh/google_compute_engine -L 8000:localhost:8000 liudan@34.74.150.225
# 然后浏览器打开 http://localhost:8000/docs
```

---

## 数据库调试

```bash
# 通过 SSH 隧道连接 RDS（本地用 TablePlus/pgAdmin 连接）
ssh -i ~/.ssh/google_compute_engine -L 5432:rds-host:5432 liudan@34.74.150.225

# 常用查询
-- 查看最近 10 个 session 状态
SELECT id, status, analysis_stage, created_at FROM sessions ORDER BY created_at DESC LIMIT 10;

-- 查看某个 session 的策略分析结果
SELECT skill_cards, scene_category FROM strategy_analysis WHERE session_id = 'uuid';

-- 查看用户的 KG 人物
SELECT name, rel_type, intimacy, friction FROM kg_persons WHERE user_id = 'uuid';
```

---

## 环境变量检查

```bash
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225 "env | grep -E 'GEMINI|DATABASE|R2|JWT|OSS|PROXY|KLIPY'"
```

---

## 分析日志关键标记

| 标记 | 含义 |
|---|---|
| `[upload]` | 音频上传 handler |
| `[分析-xxxxx]` | Gemini 分析（xxxxx 为 session_id 前缀） |
| `[声纹]` | 说话人声纹匹配 |
| `[KG]` | Knowledge Graph 写入 |
| `[策略流程]` | 策略生成流程步骤 |
| `[节点3-emoji]` | 情绪头像生成 |
| `[meme]` | AI 助手梗图获取 |
| `[assistant]` | AI 助手对话 |

---

## 常用 grep 组合

```bash
# 某次上传的完整链路（替换 session_id 前8位）
grep "abc12345" ~/gemini-audio-service.log

# 所有失败的技能执行
grep "技能.*失败\|skill.*error" ~/gemini-audio-service.log -i | tail -20

# 查看 Gemini API 调用耗时
grep "耗时\|elapsed" ~/gemini-audio-service.log | tail -30

# 查看 R2/OSS 上传结果
grep "上传图片\|presigned\|OSS" ~/gemini-audio-service.log | tail -20
```
