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
from pydantic import BaseModel

from analyzer import analyze
from scraper import DEFAULT_URLS, scrape

BASE = Path(__file__).parent
DATA_FILE = BASE / "data" / "results.json"
DATA_FILE.parent.mkdir(exist_ok=True)

app = FastAPI(title="Higgsfield 热门镜头雷达")
state = {"running": False, "logs": [], "started_at": None, "finished_at": None}


def log(msg: str):
    print(msg, flush=True)
    state["logs"] = (state["logs"] + [f"{time.strftime('%H:%M:%S')} {msg}"])[-200:]


class RunRequest(BaseModel):
    urls: list[str] | None = None
    scrolls: int = 8
    top_n: int = 40


async def _job(req: RunRequest):
    try:
        items = await scrape(req.urls or DEFAULT_URLS, scrolls=req.scrolls, log=log)
        log(f"共抓到 {len(items)} 条去重视频，取热度前 {req.top_n} 条做分析")
        analyzed = await analyze(items, top_n=req.top_n, log=log)
        DATA_FILE.write_text(json.dumps({
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "sources": req.urls or DEFAULT_URLS,
            "total_scraped": len(items),
            "items": analyzed,
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
    return {**state, "has_gemini": bool(os.getenv("GEMINI_API_KEY")), "default_urls": DEFAULT_URLS}


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
