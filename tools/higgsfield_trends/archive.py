"""
视频存档：把入围镜头的原始 mp4 存下来，防止 Higgsfield 链接失效。

- 默认存本地 data/videos/，页面通过 /videos/ 播放
- 配了 R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT_URL / R2_BUCKET_NAME / R2_PUBLIC_URL
  （与 App 后端 .env 同名）时，同时上传到 Cloudflare R2 的 higgsfield_trends/ 目录
"""
import asyncio
import os
import re
from pathlib import Path

import httpx

VIDEO_DIR = Path(os.getenv("VIDEO_DIR") or Path(__file__).parent / "data" / "videos")
R2_PREFIX = "higgsfield_trends"


def _r2_client():
    keys = ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ENDPOINT_URL", "R2_BUCKET_NAME", "R2_PUBLIC_URL")
    if not all(os.getenv(k) for k in keys):
        return None
    import boto3
    return boto3.client("s3", endpoint_url=os.getenv("R2_ENDPOINT_URL"),
                        aws_access_key_id=os.getenv("R2_ACCESS_KEY_ID"),
                        aws_secret_access_key=os.getenv("R2_SECRET_ACCESS_KEY"), region_name="auto")


def _filename(it: dict) -> str:
    return f"{it['kind']}_{re.sub(r'[^0-9A-Za-z_-]', '', it['id'])[:64]}.mp4"


async def archive(items: list[dict], log=print, concurrency: int = 6) -> None:
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    r2 = _r2_client()
    sem = asyncio.Semaphore(concurrency)
    total = [0]

    async with httpx.AsyncClient(follow_redirects=True, timeout=120) as http:
        async def one(it):
            path = VIDEO_DIR / _filename(it)
            async with sem:
                try:
                    if not path.exists():
                        tmp = path.with_suffix(".part")
                        async with http.stream("GET", it["video_url"]) as r:
                            r.raise_for_status()
                            with open(tmp, "wb") as f:
                                async for chunk in r.aiter_bytes():
                                    f.write(chunk)
                        tmp.rename(path)
                    total[0] += path.stat().st_size
                    it["archived_local"] = f"/videos/{path.name}"
                    if r2:
                        key = f"{R2_PREFIX}/{path.name}"
                        await asyncio.to_thread(r2.upload_file, str(path), os.getenv("R2_BUCKET_NAME"), key,
                                                ExtraArgs={"ContentType": "video/mp4"})
                        it["archived_r2"] = f"{os.getenv('R2_PUBLIC_URL').rstrip('/')}/{key}"
                except Exception as e:
                    log(f"[archive] {it['id']} 存档失败: {e}")

        await asyncio.gather(*(one(it) for it in items))
    log(f"[archive] 已存档 {sum(1 for i in items if i.get('archived_local'))}/{len(items)} 个视频，"
        f"共 {total[0] / 1e6:.0f} MB → {VIDEO_DIR}{'，并上传 R2' if r2 else ''}")
