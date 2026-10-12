"""
Higgsfield 热门镜头抓取器

两类"镜头"：
1. 社区热门镜头（kind=community）：用户发布的视频作品，带播放/点赞、完整 prompt、模型参数。
   数据来自 fnf-api-gw.higgsfield.ai/fnf/publications/community/...（无需登录）。
   接口的 model 参数会随新模型上线变化，所以先用无头浏览器打开各社区页，记录页面实际请求的 feed，
   再用 httpx 按 cursor 翻页拉全。详情页：https://higgsfield.ai/publications/{publication.id}
2. 官方运镜预设（kind=preset）：/viral 页的 Motion 预设（kling_motion / seedance_motion 等），
   服务端渲染，带 schema.org VideoObject。没有播放数，按页面展示顺序（官方热门排序）排名。
   详情页：https://higgsfield.ai/motion/{id}
"""
import asyncio
import html as htmllib
import json
import math
import os
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx
from playwright.async_api import async_playwright

SITE = "https://higgsfield.ai"
API = "https://fnf-api-gw.higgsfield.ai/fnf"

# 打开这些页面以发现社区视频 feed（页面请求了哪个 model 就抓哪个）
COMMUNITY_PAGES = [
    f"{SITE}/community/generations",   # Community → Shots
    f"{SITE}/seedance-2-community",
    f"{SITE}/seedance-2-5-community",
    f"{SITE}/seedance-4k-community",
    f"{SITE}/soul-cinema-community",
    f"{SITE}/sora-trends",
]
# 即使页面没发出请求也一定抓的 feed
SEED_FEEDS = [
    f"{API}/publications/community/trending?size=50&type=video",
    f"{API}/publications/community/approved?size=50&model=seedance_2_0&approved=true",
    f"{API}/publications/community/approved?size=50&model=seedance_2_5&approved=true",
]
PRESET_PAGES = [f"{SITE}/viral"]

DEFAULT_URLS = COMMUNITY_PAGES + PRESET_PAGES
HEADERS = {"Origin": SITE, "Referer": SITE + "/",
           "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                         "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"}
SOCIAL = {"tiktok_handle": "https://www.tiktok.com/@{}", "instagram_handle": "https://www.instagram.com/{}",
          "youtube_handle": "https://www.youtube.com/@{}", "twitter_handle": "https://x.com/{}"}


# ---------- 社区作品 ----------
def parse_publication(it: dict, found_on: str) -> dict | None:
    pub, results = it.get("publication") or {}, it.get("results") or {}
    raw, small = results.get("raw") or {}, results.get("min") or {}
    if raw.get("type") != "video" or not pub.get("id"):
        return None
    params, profile = it.get("params") or {}, it.get("profile") or {}
    username = profile.get("username") or ""
    socials = [tpl.format(profile[k].lstrip("@")) for k, tpl in SOCIAL.items() if profile.get(k)]
    return {
        "kind": "community",
        "id": pub["id"],
        "title": "",
        "prompt": (params.get("prompt") or "")[:3000],
        "preset": it.get("job_set_type") or params.get("model") or "",
        "params": {k: params.get(k) for k in ("duration", "aspect_ratio", "resolution", "multi_shots",
                                              "speedramp", "genre", "mode") if params.get(k) not in (None, "")},
        "author": username,
        "author_url": f"{SITE}/profile/{username}" if username else None,
        "likes": int(pub.get("likes_count") or 0),
        "views": int(pub.get("views_count") or 0),
        "uses": 0,
        "video_url": raw.get("url"),
        "analysis_video_url": small.get("url") or raw.get("url"),
        "thumbnail": raw.get("thumbnail_url") or small.get("thumbnail_url"),
        "page_url": f"{SITE}/publications/{pub['id']}",
        "source_video": None,
        "social_links": socials,
        "found_on": found_on,
        "published_at": it.get("published_at"),
    }


def _set_query(url: str, **kv) -> str:
    parts = urlsplit(url)
    q = dict(parse_qsl(parts.query))
    for k, v in kv.items():
        if v is None:
            q.pop(k, None)
        else:
            q[k] = str(v)
    return urlunsplit(parts._replace(query=urlencode(q)))


async def _discover_feeds(pages: list[str], log) -> dict[str, str]:
    """打开社区页，记录页面请求的视频 feed。返回 {feed_url(去掉 cursor): 来源页}。"""
    feeds: dict[str, str] = {}
    async with async_playwright() as p:
        # CHROMIUM_PATH：使用本机已有的 Chromium，而不是 playwright install 下载的那份
        browser = await p.chromium.launch(executable_path=os.getenv("CHROMIUM_PATH") or None)
        ctx = await browser.new_context(viewport={"width": 1440, "height": 900}, locale="en-US",
                                        user_agent=HEADERS["User-Agent"])
        for url in pages:
            page = await ctx.new_page()

            def on_request(req, _url=url):
                if "/publications/community/" in req.url and "type=image" not in req.url:
                    feeds.setdefault(_set_query(req.url, cursor=None, size=50), _url)
            page.on("request", on_request)
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=60000)
                await page.wait_for_timeout(4000)
                await page.mouse.wheel(0, 3000)
                await page.wait_for_timeout(1500)
            except Exception as e:
                log(f"[discover] {url} 打开失败: {e}")
            await page.close()
        await browser.close()
    return feeds


async def _pull_feed(http: httpx.AsyncClient, feed: str, found_on: str, limit: int, log) -> list[dict]:
    out, cursor = [], None
    while len(out) < limit:
        url = _set_query(feed, size=50, cursor=cursor)
        try:
            r = await http.get(url, timeout=30)
            r.raise_for_status()
            body = r.json()
        except Exception as e:
            log(f"[feed] {feed} 失败: {e}")
            break
        for it in body.get("items") or []:
            if (x := parse_publication(it, found_on)):
                out.append(x)
        cursor = body.get("cursor") or body.get("next_cursor")
        if not body.get("has_more") or not cursor or not body.get("items"):
            break
    return out


# ---------- 官方运镜预设 ----------
LD_RE = re.compile(r'<script type="application/ld\+json">(.*?)</script>', re.S)
MOTION_LINK_RE = re.compile(r'<a href="/motion/([0-9a-f-]{36})"><span class="sr-only">View (.*?)</span>')


async def _pull_presets(http: httpx.AsyncClient, url: str, log) -> list[dict]:
    try:
        r = await http.get(url, timeout=30)
        r.raise_for_status()
    except Exception as e:
        log(f"[preset] {url} 失败: {e}")
        return []
    page = r.text
    links = {htmllib.unescape(name): mid for mid, name in MOTION_LINK_RE.findall(page)}
    out, seen = [], set()
    for raw in LD_RE.findall(page):
        try:
            o = json.loads(htmllib.unescape(raw))
        except Exception:
            continue
        if o.get("@type") != "VideoObject" or not o.get("contentUrl") or o["contentUrl"] in seen:
            continue
        seen.add(o["contentUrl"])
        name = o.get("name") or ""
        mid = links.get(name)
        engine = re.search(r"/([a-z0-9_]+)_motion/", o["contentUrl"])
        thumbs = o.get("thumbnailUrl") or []
        out.append({
            "kind": "preset", "id": mid or o["contentUrl"], "title": name,
            "prompt": o.get("description") or "", "preset": name,
            "params": {"engine": engine.group(1) if engine else "", "duration": o.get("duration")},
            "author": "Higgsfield", "author_url": None, "likes": 0, "views": 0, "uses": 0,
            "video_url": o["contentUrl"], "analysis_video_url": o["contentUrl"],
            "thumbnail": thumbs[0] if isinstance(thumbs, list) and thumbs else thumbs or None,
            "page_url": f"{SITE}/motion/{mid}" if mid else url,
            "source_video": None, "social_links": [], "found_on": url,
            "published_at": o.get("uploadDate"), "feed_rank": len(out),
        })
    return out


# ---------- 汇总 ----------
def popularity(it: dict) -> float:
    if it["kind"] == "preset":  # 无计数，按官方热门页顺序：第 1 名 10 分，逐步递减
        return round(10 / (1 + it["feed_rank"] / 8), 3)
    return round(math.log10(1 + it["views"]) + 2 * math.log10(1 + it["likes"]), 3)


async def scrape(urls: list[str] | None = None, per_feed: int = 300, log=print, **_) -> list[dict]:
    urls = urls or DEFAULT_URLS
    preset_pages = [u for u in urls if u.rstrip("/").endswith("/viral")]
    community_pages = [u for u in urls if u not in preset_pages]

    feeds = {f: f"{SITE}/community/generations" for f in SEED_FEEDS}
    if community_pages:
        feeds.update(await _discover_feeds(community_pages, log))
    log(f"[scrape] 视频 feed {len(feeds)} 个")

    items: list[dict] = []
    async with httpx.AsyncClient(headers=HEADERS, follow_redirects=True) as http:
        results = await asyncio.gather(*(_pull_feed(http, f, src, per_feed, log) for f, src in feeds.items()))
        for f, res in zip(feeds, results):
            log(f"[feed] {f.replace(API, '')}: {len(res)} 条")
            items += res
        for u in preset_pages:
            res = await _pull_presets(http, u, log)
            log(f"[preset] {u}: {len(res)} 个运镜预设")
            items += res

    merged: dict[str, dict] = {}
    for it in items:  # 同一作品会出现在多个 feed
        merged.setdefault(it["kind"] + it["id"], it)
    result = list(merged.values())
    for it in result:
        it.setdefault("feed_rank", 0)
        it["popularity"] = popularity(it)
    result.sort(key=lambda x: x["popularity"], reverse=True)
    return result
