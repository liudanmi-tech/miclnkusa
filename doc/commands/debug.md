# /debug — 线上问题调试

当遇到线上 bug 时，按以下流程排查。

## 第一步：收集现场信息

```bash
# 1. 查看最近错误日志
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225 \
  "grep 'ERROR' ~/gemini-audio-service.log | tail -30"

# 2. 查看服务状态
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225 \
  "ps aux | grep main.py && curl -s http://localhost:8000/health"

# 3. 如果有 session_id，查看该 session 的完整日志
ssh -i ~/.ssh/google_compute_engine liudan@34.74.150.225 \
  "grep '<session_id前8位>' ~/gemini-audio-service.log"
```

## 第二步：告诉我以下信息

1. **现象**：什么操作触发了问题？（上传音频？查看策略？AI 对话？）
2. **错误信息**：iOS 端报什么错？HTTP 状态码是什么？
3. **日志片段**：上面命令的输出结果
4. **session_id**：（如果有）

## 第三步：我会帮你

- 定位到 `main.py` 中具体出错的行
- 分析根因（Gemini 超时？DB 查询？JSON 解析失败？）
- 给出修复方案和上传命令

## 快速参考

| 问题类型 | 看哪个日志标记 |
|---|---|
| 上传/分析失败 | `[upload]` `[分析-]` |
| 声纹匹配异常 | `[声纹]` |
| 策略生成问题 | `[策略流程]` |
| 图片不显示 | `[节点3-emoji]` `OSS` `R2` |
| AI 助手异常 | `[assistant]` `[KG]` |
| 数据库问题 | `asyncpg` `database` `connection` |

详细排查步骤见 [docs/runbook/common-issues.md](../runbook/common-issues.md)
