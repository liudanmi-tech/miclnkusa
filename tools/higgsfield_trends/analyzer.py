"""
镜头筛选 + 拍法描述

分析引擎（按优先级）：
1. GEMINI_API_KEY：直连 Gemini 看片
2. OpenRouter：OPENROUTER_API_KEY 环境变量，或云端环境「网络密钥」自动注入的 Authorization 头
3. 都不可用：关键词规则打分 + 运镜词典生成描述（粗略，只作兜底）
"""
import asyncio
import base64
import json
import os

import httpx

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemini-2.5-flash")  # 需支持视频输入
OPENROUTER_URL = "https://openrouter.ai/api/v1"
MAX_VIDEO_BYTES = 18 * 1024 * 1024  # inline 上传上限约 20MB

AUDIENCE = "35 岁以下的北美女性（Gen Z + 年轻 Millennial，TikTok / Instagram Reels / Pinterest 重度用户）"

PROMPT = f"""你是短视频增长与电影摄影专家。目标受众：{AUDIENCE}。
下面是一条来自 Higgsfield AI 平台的热门视频（附元数据）。请看片后只输出 JSON，字段：
{{
  "audience_score": 0-100 的整数，越适合目标受众越高（考虑：审美、题材如美妆/穿搭/生活方式/恋爱/宠物/旅行/健身/自我成长、情绪共鸣、在 TikTok/Reels 的传播潜力；暴力、恐怖、硬核科技、男性向题材扣分）,
  "audience_reason": "一句话说明为什么适合/不适合",
  "shot_name": "这个镜头的通用叫法（中文 + 英文术语，如 推轨变焦 Dolly Zoom）",
  "camera_movement": "运镜描述：起幅→运动方式→落幅，速度节奏",
  "framing_lens": "景别、焦段感、机位高度",
  "lighting_color": "光线与色调",
  "subject_action": "主体在做什么",
  "how_to_make_ai": "在 Higgsfield 里怎么做出来：用哪个预设/模型、上传什么样的首帧图、英文 prompt 模板（可直接复制）",
  "how_to_make_real": "用手机/稳定器实拍怎么复刻：器材、走位、剪辑要点",
  "hook": "前 1-2 秒的钩子是什么",
  "tags": ["3-6 个英文标签"]
}}
元数据：
"""

# ---------- 兜底规则 ----------
POS = {"fashion": 8, "outfit": 8, "makeup": 9, "beauty": 9, "skincare": 9, "hair": 6, "girl": 6, "woman": 6,
       "she ": 4, "her ": 4, "dress": 6, "romantic": 7, "love": 5, "couple": 6, "wedding": 7, "aesthetic": 7,
       "cozy": 6, "coffee": 5, "cafe": 5, "travel": 6, "beach": 6, "sunset": 6, "pet": 6, "cat": 6, "dog": 6,
       "puppy": 7, "kitten": 7, "flower": 5, "pink": 5, "yoga": 6, "fitness": 5, "dance": 6, "y2k": 7,
       "vlog": 5, "selfie": 6, "glow": 5, "nail": 6, "jewelry": 6, "princess": 6, "anime": 3, "influencer": 6}
NEG = {"gun": -10, "war": -10, "blood": -12, "horror": -8, "zombie": -8, "monster": -5, "car chase": -5,
       "explosion": -6, "soldier": -8, "robot": -3, "mech": -5, "skull": -6}

MOVES = {
    "dolly zoom": ("推轨变焦 Dolly Zoom", "镜头后退同时变焦推进，主体大小不变、背景透视被拉伸，制造眩晕/顿悟感",
                   "稳定器后退 + 手机变焦逐渐推进（或后期 scale 反向补偿）"),
    "crash zoom": ("急推 Crash Zoom", "极快地变焦冲向主体脸部，常配音效卡点",
                   "手机 1x→3x 快速切换，或后期 0.2 秒内 scale 100%→180% 加运动模糊"),
    "bullet time": ("子弹时间 Bullet Time", "时间几乎凝固，镜头环绕主体旋转",
                    "主体定格不动，手持稳定器绕人走半圈，后期降速"),
    "orbit": ("环绕 Orbit / 360", "镜头围绕主体做圆周运动，主体保持在画面中心",
              "稳定器锁定跟随模式，绕主体走圈，保持等距"),
    "fpv": ("FPV 穿越 FPV Drone", "第一人称高速俯冲/穿越，速度感强", "FPV 无人机，或广角手持快速前冲 + 后期加速"),
    "crane": ("摇臂升降 Crane", "镜头垂直升起/下降揭示场景", "稳定器由低到高举起，配合缓慢后仰"),
    "whip pan": ("甩镜 Whip Pan", "快速横甩带动态模糊，常用作转场", "手机快速横甩，下一段从同方向甩入，剪辑点在模糊处"),
    "snorricam": ("身体固定 Snorricam", "相机固定在人身上，人物不动背景晃动", "自拍杆/胸前支架对准脸，边走边拍"),
    "tracking": ("跟拍 Tracking", "镜头与主体平行同速移动", "稳定器侧向平移跟随走路的主体"),
    "dolly in": ("推镜 Dolly In", "镜头平稳前推靠近主体，强调情绪", "稳定器匀速前推，避免变焦"),
    "dolly out": ("拉镜 Dolly Out", "镜头后退揭示环境", "稳定器匀速后拉"),
    "zoom": ("变焦 Zoom", "镜头焦距变化推进/拉远", "手机平滑变焦或后期缩放"),
    "handheld": ("手持 Handheld", "轻微晃动的纪实感", "手机手持，保持呼吸感的晃动"),
}


def heuristic(it: dict) -> dict:
    blob = " ".join(str(it.get(k) or "") for k in ("title", "prompt", "preset")).lower() + " "
    score = 50 + sum(v for k, v in POS.items() if k in blob) + sum(v for k, v in NEG.items() if k in blob)
    score = max(0, min(100, score))
    move = next((v for k, v in MOVES.items() if k in blob), None)
    name, desc, real = move or ("未识别（需看片）", "元数据中没有运镜关键词，建议配置 GEMINI_API_KEY 让模型看片分析", "—")
    return {
        "audience_score": score,
        "audience_reason": "规则打分（关键词匹配），仅供参考",
        "shot_name": name, "camera_movement": desc, "framing_lens": "", "lighting_color": "",
        "subject_action": (it.get("prompt") or "")[:200],
        "how_to_make_ai": f"Higgsfield 选择预设「{it.get('preset') or name}」，上传首帧人像图，prompt 参考原作："
                          f"{(it.get('prompt') or '（原作未公开 prompt）')[:300]}",
        "how_to_make_real": real, "hook": "", "tags": [], "analyzed_by": "heuristic",
    }


# ---------- Gemini ----------
def _meta(it: dict) -> dict:
    kind = "Higgsfield 官方运镜预设（用户可一键套用）" if it.get("kind") == "preset" else "社区用户作品"
    return {"类型": kind, "名称": it.get("title"), "创作者 prompt / 描述": it.get("prompt"),
            "模型/预设": it.get("preset"), "参数": it.get("params"),
            "播放": it.get("views"), "点赞": it.get("likes")}


async def _download(client: httpx.AsyncClient, url: str) -> bytes | None:
    if ".m3u8" in url:
        return None
    try:
        async with client.stream("GET", url, timeout=60) as r:
            if r.status_code != 200:
                return None
            buf = bytearray()
            async for chunk in r.aiter_bytes():
                buf.extend(chunk)
                if len(buf) > MAX_VIDEO_BYTES:
                    return None
            return bytes(buf)
    except Exception:
        return None


async def _gemini_one(genai_client, http: httpx.AsyncClient, it: dict) -> dict:
    from google.genai import types
    meta = _meta(it)
    parts = []
    data = await _download(http, it.get("analysis_video_url") or it["video_url"])
    if data:
        mime = "video/webm" if ".webm" in it["video_url"] else "video/mp4"
        parts.append(types.Part.from_bytes(data=data, mime_type=mime))
    parts.append(PROMPT + json.dumps(meta, ensure_ascii=False)
                 + ("" if data else "\n（视频无法下载，请仅根据元数据推断，并在 audience_reason 注明）"))
    resp = await genai_client.aio.models.generate_content(
        model=GEMINI_MODEL, contents=parts,
        config=types.GenerateContentConfig(response_mime_type="application/json", temperature=0.4))
    out = json.loads(resp.text)
    if isinstance(out, list):
        out = out[0]
    out["audience_score"] = int(out.get("audience_score") or 0)
    out["analyzed_by"] = f"{GEMINI_MODEL}{'+video' if data else '+metadata'}"
    return out


# ---------- OpenRouter ----------
def _or_headers() -> dict:
    # 没有环境变量时不带 Authorization，由网络代理按「网络密钥」注入
    key = os.getenv("OPENROUTER_API_KEY")
    return {"Authorization": f"Bearer {key}"} if key else {}


async def _openrouter_ok(http: httpx.AsyncClient) -> bool:
    try:
        r = await http.get(f"{OPENROUTER_URL}/key", headers=_or_headers(), timeout=20)
        return r.status_code == 200
    except Exception:
        return False


def _parse_json(text: str) -> dict:
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`").removeprefix("json").strip()
    out = json.loads(text[text.find("{"): text.rfind("}") + 1])
    return out[0] if isinstance(out, list) else out


async def _openrouter_one(http: httpx.AsyncClient, it: dict) -> dict:
    meta = _meta(it)
    data = await _download(http, it.get("analysis_video_url") or it["video_url"])
    text = PROMPT + json.dumps(meta, ensure_ascii=False)

    async def ask(with_video: bool) -> httpx.Response:
        content = [{"type": "text", "text": text if with_video else
                    text + "\n（视频无法提供，请仅根据元数据推断，并在 audience_reason 注明）"}]
        if with_video:
            mime = "video/webm" if ".webm" in it["video_url"] else "video/mp4"
            content.append({"type": "video_url", "video_url": {
                "url": f"data:{mime};base64,{base64.b64encode(data).decode()}"}})
        return await http.post(f"{OPENROUTER_URL}/chat/completions", headers=_or_headers(), timeout=180, json={
            "model": OPENROUTER_MODEL, "temperature": 0.4,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "user", "content": content}]})

    used_video = bool(data)
    r = await ask(used_video)
    if used_video and r.status_code in (400, 413, 415, 422):  # 模型/路由不接受视频，退回只看元数据
        used_video = False
        r = await ask(False)
    r.raise_for_status()
    out = _parse_json(r.json()["choices"][0]["message"]["content"])
    out["audience_score"] = int(out.get("audience_score") or 0)
    out["analyzed_by"] = f"openrouter:{OPENROUTER_MODEL}{'+video' if used_video else '+metadata'}"
    return out


async def analyze(items: list[dict], top_n: int = 40, concurrency: int = 4, log=print) -> list[dict]:
    targets = items[:top_n]
    async with httpx.AsyncClient(follow_redirects=True) as http:
        if os.getenv("GEMINI_API_KEY"):
            from google import genai
            genai_client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
            one = lambda it: _gemini_one(genai_client, http, it)
            log(f"[analyze] 引擎：Gemini {GEMINI_MODEL}")
        elif await _openrouter_ok(http):
            one = lambda it: _openrouter_one(http, it)
            log(f"[analyze] 引擎：OpenRouter {OPENROUTER_MODEL}")
        else:
            log("[analyze] 没有可用的 Gemini / OpenRouter key，使用规则兜底")
            for it in targets:
                it["analysis"] = heuristic(it)
            return targets

        sem = asyncio.Semaphore(concurrency)

        async def run(i, it):
            async with sem:
                try:
                    it["analysis"] = await one(it)
                except Exception as e:
                    log(f"[analyze] #{i} 模型分析失败，改用规则: {e}")
                    it["analysis"] = heuristic(it)
                log(f"[analyze] {i + 1}/{len(targets)} 完成")
        await asyncio.gather(*(run(i, it) for i, it in enumerate(targets)))
    return targets
