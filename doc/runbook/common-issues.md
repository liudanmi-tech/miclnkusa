# 常见问题排查手册

## 1. 服务无响应 / 502 Bad Gateway

**现象：** iOS 请求返回 502，或 `/health` 无响应。

**排查步骤：**
```bash
# 1. 检查 FastAPI 进程是否存活
ssh liudan@34.74.150.225 "ps aux | grep main.py"

# 2. 查看最近日志
ssh liudan@34.74.150.225 "tail -100 ~/gemini-audio-service.log | grep -E 'ERROR|WARNING|started'"

# 3. 重启服务
ssh liudan@34.74.150.225 "cd ~ && nohup python3 main.py > /dev/null 2>&1 &"

# 4. 检查 Nginx
ssh liudan@34.74.150.225 "sudo nginx -t && sudo systemctl status nginx"
```

---

## 2. Gemini 分析超时 / 上传失败

**现象：** 音频上传后 session 长期停在 `processing`，或返回 500。

**常见原因：**
- Nginx 出站代理（`/secret-channel`）挂了
- Gemini 文件 API 上传超时（大文件 >20MB）
- GEMINI_API_KEY 配额耗尽

**排查：**
```bash
# 测试代理连通性
curl http://34.74.150.225/secret-channel -v 2>&1 | head -20

# 测试 Gemini 连通
curl http://34.74.150.225/test-gemini

# 查看分析日志
ssh liudan@34.74.150.225 "grep 'analyze\|Gemini\|ERROR' ~/gemini-audio-service.log | tail -50"
```

---

## 3. 图片不显示 / image_status 卡在 generating

**现象：** 策略分析完成但场景图片一直 loading。

**排查：**
```bash
# 查看图片生成日志
ssh liudan@34.74.150.225 "grep 'image\|R2\|OSS\|Imagen' ~/gemini-audio-service.log | tail -30"

# 检查 R2 配置是否生效（看启动日志）
ssh liudan@34.74.150.225 "grep 'OSS\|R2' ~/gemini-audio-service.log | head -10"
```

**常见原因：**
- R2 环境变量未配置（`USE_OSS` 回退为 false）
- Imagen 生成内容被 Gemini safety filter 拦截
- R2 Bucket 权限问题

---

## 4. 登录失败 / JWT 无效

**现象：** iOS 登录返回 401，或 token 突然失效。

**排查：**
- 检查服务器 `JWT_SECRET_KEY` 环境变量是否与之前一致（重启后若环境变量丢失，所有旧 token 失效）
- 检查 token 是否过期（默认有效期查看 `auth/jwt_handler.py`）

```bash
ssh liudan@34.74.150.225 "env | grep JWT"
```

---

## 5. 数据库连接失败

**现象：** 启动时报 `数据库初始化失败` 或请求返回 500。

**排查：**
```bash
# 查看启动日志中的 DB 错误
ssh liudan@34.74.150.225 "grep 'database\|Database\|asyncpg\|PostgreSQL' ~/gemini-audio-service.log | head -20"

# 检查 DATABASE_URL 环境变量
ssh liudan@34.74.150.225 "env | grep DATABASE"
```

**常见原因：**
- RDS 白名单未添加 GCP 服务器 IP（34.74.150.225）
- 连接池耗尽（高并发时），重启服务可临时解决
- asyncpg 版本兼容问题

---

## 6. 技能匹配结果为空

**现象：** 策略分析完成但 `skill_cards` 为空数组。

**排查：**
```bash
# 查看技能初始化是否成功（启动日志）
ssh liudan@34.74.150.225 "grep '技能\|skill' ~/gemini-audio-service.log | head -20"

# 检查 skills 表是否有数据
# 通过 /docs Swagger 调用 GET /api/v1/skills 查看
```

**常见原因：**
- 启动时技能初始化失败（`skills/` 目录未上传到服务器）
- 场景分类结果与技能 category 不匹配
- Gemini 返回的 JSON 解析失败

---

## 7. AI 助手 SSE 连接断开

**现象：** 对话时 loading 很久然后空白，或前几个字后断连。

**排查：**
- Nginx 默认有 proxy read timeout（通常 60s），Gemini 流式较慢时会超时
- 检查 Nginx 配置是否有 `proxy_read_timeout 300s` 和 `proxy_buffering off`

```bash
ssh liudan@34.74.150.225 "sudo cat /etc/nginx/sites-enabled/* | grep -E 'timeout|buffering'"
```
