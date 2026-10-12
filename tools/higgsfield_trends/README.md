# Higgsfield 热门镜头雷达

抓取 Higgsfield 上的热门视频/镜头 → 按「35 岁以下北美女性」筛选打分 → 拆解拍法（AI 做法 + 实拍复刻）→ 给出原视频位置。
带网页，独立运行，与 App 后端无关。

## 运行

```bash
cd tools/higgsfield_trends
pip install -r requirements.txt
playwright install chromium          # 或设置 CHROMIUM_PATH 指向本机 Chrome/Chromium
export OPENROUTER_API_KEY=...        # 或 GEMINI_API_KEY；云端环境可改用「网络密钥」注入；都没有则规则兜底
uvicorn app:app --port 8100
```

打开 http://localhost:8100 ，点「开始抓取 + 分析」。结果存在 `data/results.json`。

需要能直接访问 higgsfield.ai 的网络（国内机器要挂代理：`HTTPS_PROXY=...`）。

## 原理

1. **抓取**（`scraper.py`）：Playwright 打开下列页面并滚动加载，监听页面发出的所有 JSON 响应，递归找出「带视频地址的对象」，
   提取标题、prompt、预设名、点赞/播放/使用次数、作者、缩略图；再从 DOM 里补充每条视频的详情页链接。
   不依赖 Higgsfield 的私有接口路径，页面改版后大概率仍可用。
   - `/community`（Explore / Shots / Originals）
   - `/viral`（热门特效和电影感预设）
   - `/ai-influencer`（Trending motions，取自正在爆的视频）
   - `/seedance-2-community`、`/marketing-studio-community`
2. **热度**：`2·log(点赞) + log(播放) + 1.5·log(使用次数)`，再加上在热门 feed 中的位置分。
3. **筛选 + 拍法**（`analyzer.py`）：取热度前 N 条，下载视频交给模型看片（Gemini 直连，或 OpenRouter 上的 google/gemini-2.5-flash，可用 OPENROUTER_MODEL 换），输出受众匹配分（0-100）、理由、镜头名、
   运镜、景别、光色、钩子、Higgsfield 做法（含可复制的英文 prompt）和手机实拍复刻方法。
4. **原视频在哪**：每张卡片会给出
   - Higgsfield 原帖（详情页）
   - 原视频文件（mp4 直链）
   - 参考源视频 / TikTok、Instagram 等外链（数据里有才显示，例如 Trending motion 取材的原始爆款）
   - 来源页面

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/run` | 开始任务，body：`{"urls": [...], "scrolls": 8, "top_n": 40}`，都可省略 |
| GET | `/api/status` | 任务状态和日志 |
| GET | `/api/shots?min_score=60` | 结果，按受众分过滤 |
