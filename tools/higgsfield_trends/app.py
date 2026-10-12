"""
Higgsfield 热门镜头雷达 —— 服务 + 页面

运行：uvicorn app:app --port 8100   然后打开 http://localhost:8100
"""
import asyncio
import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import analyzer
from analyzer import analyze, estimate_cost, prescreen, shortlist
from archive import VIDEO_DIR, archive
from scraper import DEFAULT_URLS, scrape

BASE = Path(__file__).parent
DATA_FILE = BASE / "data" / "results.json"
DATA_FILE.parent.mkdir(exist_ok=True)

app = FastAPI(title="Higgsfield 热门镜头雷达")
VIDEO_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/videos", StaticFiles(directory=VIDEO_DIR), name="videos")
state = {"running": False, "logs": [], "started_at": None, "finished_at": None}


def log(msg: str):
    print(msg, flush=True)
    state["logs"] = (state["logs"] + [f"{time.strftime('%H:%M:%S')} {msg}"])[-200:]


class RunRequest(BaseModel):
    urls: list[str] | None = None
    top_n: int = 30         # 社区热门镜头：初筛后入围看片的条数
    top_presets: int = 15   # 官方运镜预设：初筛后入围看片的个数
    save_videos: bool = True


async def _job(req: RunRequest):
    try:
        items = await scrape(req.urls or DEFAULT_URLS, log=log)
        analyzer.usage.update(cost=0.0, calls=0)
        await prescreen(items, log=log)
        community = shortlist([i for i in items if i["kind"] == "community"], req.top_n)
        presets = shortlist([i for i in items if i["kind"] == "preset"], req.top_presets)
        picked = community + presets
        log(f"共抓到 {len(items)} 条，入围社区热门 {len(community)} 条 + 官方运镜预设 {len(presets)} 个，"
            f"预计看片花费约 ${estimate_cost(len(picked))}")
        if req.save_videos:
            await archive(picked, log=log)
        analyzed = await analyze(picked, top_n=len(picked), log=log)
        log(f"本次实际花费 ${analyzer.usage['cost']:.4f}（{analyzer.usage['calls']} 次模型调用）")
        DATA_FILE.write_text(json.dumps({
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "sources": req.urls or DEFAULT_URLS,
            "total_scraped": len(items),
            "cost_usd": round(analyzer.usage["cost"], 4),
            "items": analyzed,
            # 未入围的候选也保留（只有初筛分），方便回看
            "candidates": [{k: i.get(k) for k in ("kind", "id", "title", "prompt", "preset", "views", "likes",
                                                   "popularity", "prescreen", "page_url", "video_url")}
                           for i in items if i not in picked],
        }, ensure_ascii=False, indent=2))
        log("完成 ✅")
    except Exception as e:
        log(f"任务失败: {e!r}")
    finally:
        state["running"] = False
        state["finished_at"] = time.time()


@app.post("/api/run")
async def run(req: RunRequest):
    if state["running"]:
        raise HTTPException(409, "已有任务在运行")
    state.update(running=True, logs=[], started_at=time.time(), finished_at=None)
    asyncio.create_task(_job(req))
    return {"ok": True}


@app.get("/api/status")
def status():
    engine = ("Gemini" if os.getenv("GEMINI_API_KEY")
              else "OpenRouter" if os.getenv("OPENROUTER_API_KEY") else "OpenRouter（网络密钥）或规则兜底")
    return {**state, "engine": engine, "default_urls": DEFAULT_URLS}


@app.get("/api/shots")
def shots(min_score: int = 0):
    if not DATA_FILE.exists():
        return {"items": [], "generated_at": None}
    data = json.loads(DATA_FILE.read_text())
    data["items"] = [i for i in data["items"]
                     if (i.get("analysis") or {}).get("audience_score", 0) >= min_score]
    return data


@app.get("/")
def index():
    return FileResponse(BASE / "static" / "index.html")
