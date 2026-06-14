# /review — 代码审查

请对我指定的代码进行审查，重点检查以下几点：

## 检查项

### 1. Gemini 调用
- Prompt 是否有 JSON 格式要求？是否有解析失败的容错处理？
- 是否有超时保护（`asyncio.wait_for` 或 try/except）？
- safety_settings 是否已设置（防止内容被拦截导致空响应）？
- Gemini 文件是否在 finally 块中删除（`genai.delete_file`）？

### 2. 数据库操作
- 异步函数中是否使用了 `await db.execute()` 而非同步调用？
- 写操作后是否有 `await db.commit()`？
- 是否处理了 `scalar_one_or_none()` 返回 None 的情况？
- 长事务是否会阻塞连接池？

### 3. 接口安全
- 需要认证的接口是否有 `Depends(get_current_user_id)`？
- 涉及用户数据的查询是否加了 `user_id` 过滤（防止越权）？
- 文件上传是否校验了文件类型和大小？

### 4. 异步/并发
- 耗时操作（Gemini、OSS）是否用了 `asyncio.to_thread` 或已是 async？
- fire-and-forget 任务是否用了 `asyncio.create_task`（不能直接 await）？
- SSE 生成器中是否有 try/except 防止中途异常导致连接挂起？

### 5. 错误处理
- 是否有适当的 logger.error + traceback？
- 返回给用户的错误信息是否友好（不暴露内部细节）？
- Session status 在失败时是否更新为 `failed`？

## 使用方式

```
/review
请审查 POST /api/v1/audio/upload 的声纹匹配部分（main.py 约 2094-2180 行）
```
