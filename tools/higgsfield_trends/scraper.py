"""
Higgsfield 热门镜头抓取器

思路：Higgsfield 是 SPA，页面数据来自内部 JSON 接口（接口路径不公开、随时可能改）。
所以不硬编码接口，而是用无头浏览器打开页面并滚动，监听所有 JSON 响应，
递归找出"带视频地址的对象"，再从 DOM 里补充可点击的详情链接。
"""
import asyncio
import json
import math
import os
import re
from typing import Any
from urllib.parse import urljoin

from playwright.async_api import async_playwright

DEFAULT_URLS = [
    "https://higgsfield.ai/community",            # Explore / Shots / Originals
    "https://higgsfield.ai/viral",                # 热门特效 / 电影感预设
    "https://higgsfield.ai/ai-influencer",        # Trending motions（取自正在爆的视频）
    "https://higgsfield.ai/seedance-2-community",
    "https://higgsfield.ai/marketing-studio-community",
]

VIDEO_RE = re.compile(r"\.(mp4|webm|mov|m3u8)(\?|$)", re.I)
SOCIAL_RE = re.compile(r"https?://(?:www\.|vm\.|m\.)?(tiktok\.com|instagram\.com|youtube\.com|youtu\.be|x\.com|twitter\.com|pinterest\.com)/[^\s\"'<>]+", re.I)

KEYS_TITLE = ("title", "name", "preset_name", "motion_name", "display_name", "label")
KEYS_PROMPT = ("prompt", "description", "caption", "text", "input_prompt")
KEYS_LIKES = ("likes", "like_count", "likes_count", "likesCount", "likeCount", "favorites", "favorite_count", "hearts", "reactions")
KEYS_VIEWS = ("views", "view_count", "views_count", "viewsCount", "viewCount", "plays", "play_count")
KEYS_USES = ("uses", "use_count", "usage_count", "usageCount", "generations", "generations_count", "remix_count", "remixes")
KEYS_THUMB = ("thumbnail", "thumbnail_url", "thumbnailUrl", "poster", "preview_image", "cover", "image_url")
KEYS_AUTHOR = ("username", "author", "user_name", "creator", "handle", "user", "owner")
KEYS_PRESET = ("motion", "preset", "camera_motion", "motion_id", "preset_id", "effect", "template", "model")
KEYS_PAGE = ("url", "share_url", "shareUrl", "permalink", "link", "page_url", "slug")
KEYS_SOURCE = ("source_url", "sourceUrl", "original_url", "originalUrl", "reference_url", "referenceUrl",
               "reference_video", "reference_video_url", "source_video", "source_video_url", "original_video")


def _first(d: dict, keys, depth: int = 0) -> Any:
    """取第一个非空字段；本层没有就往嵌套 dict（如 media / stats）里找两层。"""
    for k in keys:
        v = d.get(k)
        if v not in (None, "", [], {}):
            return v
    if depth < 2:
        for v in d.values():
            if isinstance(v, dict) and (r := _first(v, keys, depth + 1)) is not None:
                return r
    return None


def _num(v) -> int:
    if isinstance(v, bool):
        return 0
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, dict):  # e.g. {"count": 12}
        return _num(_first(v, ("count", "total", "value")))
    if isinstance(v, str) and re.fullmatch(r"[\d.,]+[kKmM]?", v.strip()):
        s = v.strip().replace(",", "")
        mult = {"k": 1e3, "m": 1e6}.get(s[-1].lower(), 1)
        return int(float(s.rstrip("kKmM")) * mult)
    return 0


def _text(v) -> str:
    if isinstance(v, str):
        return v
    if isinstance(v, dict):
        return str(_first(v, ("username", "handle") + KEYS_TITLE + ("id",)) or "")
    return "" if v is None else str(v)


def _find_video_url(d: dict, depth: int = 0) -> str | None:
    """对象内（只进嵌套 dict，不进列表）的视频地址，如 {"media": {"video": {"url": "..."}}}。"""
    for v in d.values():
        if isinstance(v, str) and v.startswith("http") and VIDEO_RE.search(v):
            return v
    if depth < 3:
        for v in d.values():
            if isinstance(v, dict) and (u := _find_video_url(v, depth + 1)):
                return u
    return None


def _is_content(d: dict) -> bool:
    return any(k in d for k in ("id", "uuid", "slug") + KEYS_TITLE + KEYS_PROMPT)


def _social_links(d: dict) -> list[str]:
    blob = json.dumps(d, ensure_ascii=False)[:20000]
    return sorted(set(m.group(0).rstrip("\\,.)") for m in SOCIAL_RE.finditer(blob)))


def extract_items(payload: Any, found_on: str, out: list, depth: int = 0) -> None:
    if depth > 12:
        return
    if isinstance(payload, list):
        for i, x in enumerate(payload):
            extract_items(x, found_on, out, depth + 1)
        return
    if not isinstance(payload, dict):
        return
    video = _find_video_url(payload)
    is_item = bool(video) and (_is_content(payload) or any(
        isinstance(v, str) and VIDEO_RE.search(v) for v in payload.values()))
    if is_item:
        page = _first(payload, KEYS_PAGE)
        if isinstance(page, str) and not page.startswith("http"):
            page = None  # slug 的拼接规则未知，交给 DOM 链接补
        source = _first(payload, KEYS_SOURCE)
        out.append({
            "id": str(payload.get("id") or payload.get("uuid") or video),
            "title": _text(_first(payload, KEYS_TITLE)),
            "prompt": _text(_first(payload, KEYS_PROMPT))[:1500],
            "preset": _text(_first(payload, KEYS_PRESET)),
            "author": _text(_first(payload, KEYS_AUTHOR)),
            "likes": _num(_first(payload, KEYS_LIKES)),
            "views": _num(_first(payload, KEYS_VIEWS)),
            "uses": _num(_first(payload, KEYS_USES)),
            "video_url": video,
            "thumbnail": _text(_first(payload, KEYS_THUMB)) or None,
            "page_url": page,
            "source_video": source if isinstance(source, str) else None,
            "social_links": _social_links(payload),
            "found_on": found_on,
            "feed_rank": len(out),
        })
    for v in payload.values():
        # 已识别为作品的对象，不再把它内部的 {"video": {...}} 当成独立作品
        if isinstance(v, list) or (isinstance(v, dict) and not is_item):
            extract_items(v, found_on, out, depth + 1)


DOM_JS = """
() => Array.from(document.querySelectorAll('video')).map(v => {
  const src = v.currentSrc || v.src || (v.querySelector('source') || {}).src || '';
  const a = v.closest('a');
  const card = v.closest('a, article, li, [class*=card], [class*=Card]') || v.parentElement;
  return {src, poster: v.poster || '', href: a ? a.href : '',
          text: card ? card.innerText.slice(0, 300) : ''};
})
"""


def popularity(it: dict) -> float:
    s = 2.0 * math.log1p(it["likes"]) + math.log1p(it["views"]) + 1.5 * math.log1p(it["uses"])
    # 没有计数时，用在热门 feed 中的位置兜底（越靠前越热）
    return round(s + 3.0 / (1 + it["feed_rank"] / 10), 3)


async def scrape(urls: list[str] | None = None, scrolls: int = 8, headless: bool = True,
                 log=print) -> list[dict]:
    urls = urls or DEFAULT_URLS
    items: list[dict] = []
    async with async_playwright() as p:
        # CHROMIUM_PATH：使用本机已有的 Chromium，而不是 playwright install 下载的那份
        browser = await p.chromium.launch(headless=headless,
                                          executable_path=os.getenv("CHROMIUM_PATH") or None)
        ctx = await browser.new_context(
            viewport={"width": 1440, "height": 900}, locale="en-US",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
        for url in urls:
            page = await ctx.new_page()
            per_page: list[dict] = []
            pending: list[asyncio.Task] = []

            async def on_response(resp, _url=url):
                if "json" not in (resp.headers.get("content-type") or ""):
                    return
                try:
                    extract_items(await resp.json(), _url, per_page)
                except Exception:
                    pass

            page.on("response", lambda r: pending.append(asyncio.ensure_future(on_response(r))))
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=60000)
                await page.wait_for_timeout(3000)
                for _ in range(scrolls):
                    await page.mouse.wheel(0, 2500)
                    await page.wait_for_timeout(1200)
                # Next.js 等框架会把首屏数据内嵌在页面里
                for sel in ("script#__NEXT_DATA__", "script[type='application/json']"):
                    for el in await page.query_selector_all(sel):
                        try:
                            extract_items(json.loads(await el.inner_text()), url, per_page)
                        except Exception:
                            pass
                dom = await page.evaluate(DOM_JS)
            except Exception as e:
                log(f"[scrape] {url} 失败: {e}")
                dom = []
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)

            by_src = {d["src"]: d for d in dom if d["src"]}
            for it in per_page:
                d = by_src.pop(it["video_url"], None)
                if d and d["href"] and not it["page_url"]:
                    it["page_url"] = d["href"]
            # 接口里没抓到、但页面上展示的视频
            for d in by_src.values():
                if not d["src"].startswith("http"):
                    continue
                per_page.append({
                    "id": d["src"], "title": d["text"].split("\n")[0][:120], "prompt": d["text"],
                    "preset": "", "author": "", "likes": 0, "views": 0, "uses": 0,
                    "video_url": d["src"], "thumbnail": d["poster"] or None,
                    "page_url": d["href"] or None, "source_video": None, "social_links": [],
                    "found_on": url, "feed_rank": len(per_page)})
            log(f"[scrape] {url}: {len(per_page)} 条")
            items.extend(per_page)
            await page.close()
        await browser.close()

    # 去重（同一视频可能出现在多个接口里），保留信息最全的那条
    merged: dict[str, dict] = {}
    for it in items:
        key = it["video_url"].split("?")[0]
        old = merged.get(key)
        if old is None:
            merged[key] = it
            continue
        for k, v in it.items():
            if k == "feed_rank":
                old[k] = min(old[k], v)
            elif k in ("likes", "views", "uses"):
                old[k] = max(old[k], v)
            elif k == "social_links":
                old[k] = sorted(set(old[k]) | set(v))
            elif not old.get(k) and v:
                old[k] = v
    result = list(merged.values())
    for it in result:
        it["popularity"] = popularity(it)
    result.sort(key=lambda x: x["popularity"], reverse=True)
    return result
