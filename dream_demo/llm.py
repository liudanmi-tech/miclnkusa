import base64
import io
import json
import os
import re

import httpx
from dotenv import load_dotenv
from PIL import Image, ImageDraw

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

if os.getenv("DREAM_MOCK") == "1":
    PROVIDER = "mock"
elif os.getenv("OPENROUTER_API_KEY"):
    PROVIDER = "openrouter"
elif os.getenv("GEMINI_API_KEY"):
    PROVIDER = "gemini"
else:
    PROVIDER = "mock"
MOCK = PROVIDER == "mock"

_DEFAULTS = {
    "openrouter": ("google/gemini-2.5-flash", "google/gemini-2.5-flash-image"),
    "gemini": ("gemini-2.5-flash", "gemini-3.1-flash-image-preview"),
    "mock": ("mock", "mock"),
}
TEXT_MODEL = os.getenv("DREAM_TEXT_MODEL", _DEFAULTS[PROVIDER][0])
IMAGE_MODEL = os.getenv("DREAM_IMAGE_MODEL", _DEFAULTS[PROVIDER][1])

STYLE = "温暖的手绘漫画风格，柔和水彩上色，略带胶片颗粒感，像一本回忆绘本"

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_client = None
if PROVIDER == "gemini":
    from google import genai
    from google.genai import types

    _client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])


# parts 是 str（文字）和 bytes（JPEG 图片）混排的列表，两个后端各自转换格式

def _parse_json(text: str) -> dict:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.S)
        if not m:
            raise RuntimeError(f"模型没有返回 JSON：{text[:200]}")
        return json.loads(m.group(0))


async def _json_call(parts: list, temperature: float = 0.4) -> dict:
    if PROVIDER == "openrouter":
        msg = await _openrouter(TEXT_MODEL, parts, temperature=temperature,
                                response_format={"type": "json_object"})
        return _parse_json(msg.get("content") or "")
    resp = await _client.aio.models.generate_content(
        model=TEXT_MODEL, contents=_gemini_parts(parts),
        config=types.GenerateContentConfig(response_mime_type="application/json", temperature=temperature),
    )
    return _parse_json(resp.text or "")


async def _image_call(parts: list) -> bytes:
    if PROVIDER == "openrouter":
        msg = await _openrouter(IMAGE_MODEL, parts, modalities=["image", "text"],
                                image_config={"aspect_ratio": "4:3"})
        for img in msg.get("images") or []:
            url = (img.get("image_url") or {}).get("url", "")
            if url.startswith("data:"):
                return base64.b64decode(url.split(",", 1)[1])
        raise RuntimeError("生图模型没有返回图片（可能被安全策略拦截）")
    resp = await _client.aio.models.generate_content(
        model=IMAGE_MODEL, contents=_gemini_parts(parts),
        config=types.GenerateContentConfig(
            response_modalities=["TEXT", "IMAGE"],
            image_config=types.ImageConfig(aspect_ratio="4:3"),
        ),
    )
    for cand in resp.candidates or []:
        for part in (cand.content.parts if cand.content else []) or []:
            if part.inline_data and part.inline_data.data:
                return part.inline_data.data
    raise RuntimeError("生图模型没有返回图片（可能被安全策略拦截）")


def _gemini_parts(parts):
    return [types.Part.from_bytes(data=p, mime_type="image/jpeg") if isinstance(p, bytes) else p for p in parts]


async def _openrouter(model: str, parts: list, **extra) -> dict:
    content = []
    for p in parts:
        if isinstance(p, bytes):
            url = "data:image/jpeg;base64," + base64.b64encode(p).decode()
            content.append({"type": "image_url", "image_url": {"url": url}})
        else:
            content.append({"type": "text", "text": p})
    body = {"model": model, "messages": [{"role": "user", "content": content}], **extra}
    headers = {"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "X-Title": "dream_demo"}
    async with httpx.AsyncClient(timeout=180) as client:
        r = await client.post(OPENROUTER_URL, json=body, headers=headers)
    if r.status_code != 200:
        raise RuntimeError(f"OpenRouter {r.status_code}：{r.text[:300]}")
    data = r.json()
    if data.get("error"):
        raise RuntimeError(f"OpenRouter 错误：{data['error']}")
    return data["choices"][0]["message"]


# ---------- 1. 照片解析 ----------

VISION_PROMPT = """你是一个照片解析服务。下面是同一次出行的一组照片，已按时间排序，每张前面标了编号。
请输出 JSON，严格遵守以下规则：
- 不做人脸识别，不描述五官，不猜测任何人的真实身份。
- 每个人只描述外观：穿着、配饰、发型发色、大致身高、正在做的动作。
- 同一天的照片里人通常穿同一身衣服：按外观把不同照片里的人归成"可能是同一个人"，给同一个 person_key（A、B、C…），并给出把握程度 confidence(0-1)。换了衣服的人把握要低。
- 每张照片最多框 8 个人，只框画面里清晰可辨的人；背景里很小的人群不框。prominent 表示这个人是不是画面主体之一。
- box 用 [ymin, xmin, ymax, xmax]，坐标归一化到 0-1000。
- 同一地点的照片，place 必须用完全相同的名称（如"景区入口""索道站""山顶观景台""山下饭馆"）。
- activity 只能取：group_photo, queue, cable_car, hiking, photo_scenery, picnic, dining, playing, sightseeing, resting, shopping, other。
- mood_guess.primary / secondary 只能取：belonging, freedom, nostalgia, excitement, warmth, relief。
- era_pack 用"地区_年代"的形式，如 cn_north_2010s，依据服饰、手机相机、汽车、招牌判断。

输出格式：
{
  "photos": [{
    "id": "p1", "place": "山顶观景台", "landmark": "光明顶",
    "weather": "晴", "light": "正午", "season": "秋", "crowd": "拥挤",
    "activity": "photo_scenery", "emotion": "兴奋", "emotion_score": 0.8,
    "era_clues": ["智能手机", "冲锋衣"], "relation_cues": ["A 和 B 搭着肩"],
    "people": [{"person_key": "A", "box": [120, 300, 900, 450], "appearance": "红色冲锋衣、运动帽、在比剪刀手", "prominent": true}]
  }],
  "people_groups": [{"person_key": "A", "appearance": "红色冲锋衣、运动帽", "short": "穿红色冲锋衣的人", "confidence": 0.9}],
  "safety": {"minor_possible": false, "nudity": false},
  "era_pack": "cn_north_2010s",
  "mood_guess": {"primary": "belonging", "secondary": "freedom"}
}"""


async def analyze_photos(photos: list[tuple[str, str | None, bytes]]) -> dict:
    """photos: [(id, 拍摄时间或 None, jpeg)]"""
    if MOCK:
        return _mock_vision(photos)
    parts: list = [VISION_PROMPT]
    for pid, t, data in photos:
        parts.append(f"照片 {pid}（拍摄时间：{t or '未知'}）：")
        parts.append(data)
    return await _json_call(parts, temperature=0.2)


# ---------- 2. 回答 → 结构化更新 ----------

EXTRACT_PROMPT = """你是"造梦师"的记录员。造梦师正在陪用户回忆一组照片里的那一天。
根据【当前问题】和【用户回答】，把回答拆成结构化更新。规则：
- 只记录用户亲口说出的内容，不要编造。没有提到的字段留空或省略。
- persona_updates 的 id 必须是已有人物组的 id（g1、g2…）。如果当前问题是在问某个人物是谁，把名字/外号写进 name，关系写进 relation。
- 如果回答填补了某个空白（gap1…），在 beat_updates 里写 fill_gap 为该空白的 id，并给出 t(HH:MM，可估计)、scene(简短地点名)、activity、detail、who(人物组 id 列表)。
- 如果回答是在补充已有节拍的细节，写 beat_id 和 detail。
- emotion：primary 只能取 belonging, freedom, nostalgia, excitement, warmth, relief；trigger 是一个可以做触发物的具体瞬间；key_line 是当时说过/喊过的一句原话；scene 是触发物发生的地点名。
- new_exits：用户提到但不在这一天里的地方（比如"回去后在宿舍看照片"里的"大学宿舍"）。
- mentioned：用户提到的人名和地点。
- follow_up：如果回答里有一个值得追问、能让情感更具体的细节（比如提到"喊了一声"但没说喊了什么），写一个简短自然的追问，否则留空。
- user_wants_stop：用户表示"就这样吧/差不多了/开始吧"时为 true。

输出格式：
{
  "persona_updates": [{"id": "g1", "name": "", "relation": "", "personality": "", "catchphrase": "", "shared_memory": ""}],
  "beat_updates": [{"fill_gap": "gap1", "t": "11:30", "scene": "半山小店", "activity": "shopping", "detail": "阿美和老板砍价砍了半天", "who": ["g2"]}],
  "emotion": {"primary": "", "trigger": "", "key_line": "", "scene": ""},
  "environment": {"weather": "", "sensory": "", "time": ""},
  "new_exits": [{"label": "", "reason": ""}],
  "mentioned": [],
  "follow_up": "",
  "user_wants_stop": false
}"""


async def extract_updates(context: dict, question: dict, answer: str) -> dict:
    if MOCK:
        return _mock_extract(context, question, answer)
    parts = [
        EXTRACT_PROMPT,
        "【当前已知】\n" + json.dumps(context, ensure_ascii=False),
        "【当前问题】\n" + json.dumps({k: question.get(k) for k in ("kind", "text", "target")}, ensure_ascii=False),
        "【用户回答】\n" + answer,
    ]
    return await _json_call(parts, temperature=0.2)


# ---------- 3. 首映分镜 / 心声 / 物件 / 初始记忆 ----------

STORY_PROMPT = """你是造梦师。根据梦境规格和记忆复原剧本，为这个梦境写首映分镜和静止状态的内容。规则：
- 首映 8-12 格，按时间顺序，节奏按情绪弧线安排，在触发物那一格达到高点（peak 是这一格的下标，从 0 开始），最后一格停在封面那一刻。
- 每格写 scene、who（人物名）、caption（旁白，一句话，克制、具体、有画面感）、line（这一格的台词，可空）。关键台词必须原样使用，不要改写。
- 用户亲口说过的事实一定要出现；推测的部分要轻描淡写。
- monologues：封面那一刻，每个主要人物和"我"的一句内心独白，符合各自性格。
- objects：封面场景里 2-3 个可以点开的关键物件（如相机、门票、一瓶水），detail 尽量用用户讲过的细节。
- memories：每个人物从自己的视角记得的 1-2 件事。
- 印象人物不能被写成小偷、骗子或受侮辱的对象，不写任何性内容。
输出格式：
{
  "panels": [{"scene": "", "who": [""], "caption": "", "line": ""}],
  "peak": 0,
  "moment": "封面那一刻的画面描述，一句话，用于生图",
  "monologues": [{"id": "g1", "name": "", "text": ""}],
  "objects": [{"name": "", "detail": ""}],
  "memories": [{"id": "g1", "name": "", "items": [""]}]
}"""


async def write_storyboard(spec: dict, script: dict) -> dict:
    if MOCK:
        return _mock_story(spec, script)
    parts = [STORY_PROMPT, "【梦境规格】\n" + json.dumps(spec, ensure_ascii=False),
             "【记忆复原剧本】\n" + json.dumps(script, ensure_ascii=False)]
    return await _json_call(parts, temperature=0.7)


# ---------- 4. 生图：背景 → 画格 ----------

async def generate_background(photo: bytes, scene_name: str, env: dict, era: str) -> bytes:
    if MOCK:
        return _mock_image(f"BACKGROUND · {scene_name}", (90, 140, 190))
    prompt = (
        f"以这张照片为参考，重绘「{scene_name}」的场景背景。去掉画面中所有的人，"
        f"保留地形、建筑、地标、构图和光线。{STYLE}。"
        f"天气：{env.get('weather') or '照片中的天气'}，光线：{env.get('light') or '照片中的光线'}。"
        f"年代感：{era}。画面中不要出现任何人物和文字。横构图 4:3。"
    )
    return await _image_call([prompt, photo])


async def generate_panel(background: bytes, moment: str, characters: list[dict], protected: bool) -> bytes:
    if MOCK:
        return _mock_image("PANEL · " + ", ".join(c["id"] for c in characters), (200, 140, 90))
    people = "\n".join(
        f"{n}. {c['name']}：{c['appearance']}" + (f"，性格{c['personality']}" if c.get("personality") else "")
        for n, c in enumerate(characters, 1)
    )
    face_rule = "所有人物画成 Q 版简笔小人，" if protected else ""
    prompt = (
        f"在这张背景图上画出这一刻：{moment}\n"
        f"画面中的人物（{face_rule}脸部只用简洁的通用漫画脸，不要画写实人脸；让人靠衣服、配饰、发型和动作被认出来）：\n"
        f"{people}\n"
        f"保持背景不变，人物自然地站在地面上，比例合理。{STYLE}。不要出现文字、对话框和水印。"
    )
    return await _image_call([prompt, background])


# ---------- 无 key 时的模拟数据 ----------

_MOCK_PEOPLE = [
    ("A", "红色冲锋衣、运动帽、在比剪刀手", "穿红色冲锋衣的人"),
    ("B", "白色卫衣、马尾辫、背双肩包", "扎马尾背双肩包的人"),
    ("C", "黑色夹克、眼镜、挂着单反", "戴眼镜挂单反的人"),
    ("D", "黄色连帽衫、短发", "穿黄色连帽衫的人"),
]
_MOCK_PLACES = ["景区入口", "索道站", "山顶观景台", "山下饭馆"]
_MOCK_ACTS = ["group_photo", "queue", "photo_scenery", "dining"]


def _mock_vision(photos):
    n = len(photos)
    out = []
    for i, (pid, _t, _d) in enumerate(photos):
        slot = min(3, i * 4 // max(1, n))
        count = 4 if slot in (0, 2, 3) else 2
        people = []
        for k in range(count):
            key, app, _ = _MOCK_PEOPLE[k]
            x0 = 80 + k * 220
            people.append({"person_key": key, "box": [250, x0, 950, x0 + 180], "appearance": app, "prominent": True})
        out.append({
            "id": pid, "place": _MOCK_PLACES[slot], "landmark": "光明顶" if slot == 2 else "",
            "weather": "晴", "light": "上午" if slot < 2 else "傍晚", "season": "秋", "crowd": "拥挤",
            "activity": _MOCK_ACTS[slot], "emotion": "兴奋", "emotion_score": 0.9 if slot == 2 else 0.6,
            "era_clues": ["智能手机"], "relation_cues": [], "people": people,
        })
    return {
        "photos": out,
        "people_groups": [{"person_key": k, "appearance": a, "short": s, "confidence": 0.85} for k, a, s in _MOCK_PEOPLE],
        "safety": {"minor_possible": False, "nudity": False},
        "era_pack": "cn_north_2010s",
        "mood_guess": {"primary": "belonging", "secondary": "freedom"},
    }


def _quoted(text):
    m = re.search(r"[“\"「](.+?)[”\"」]", text)
    return m.group(1) if m else ""


def _mock_extract(context, question, answer):
    kind, target = question.get("kind"), question.get("target")
    upd: dict = {"persona_updates": [], "beat_updates": [], "emotion": {}, "environment": {},
                 "new_exits": [], "mentioned": [], "follow_up": "", "user_wants_stop": False}
    line = _quoted(answer)
    if kind == "label":
        bits = [b for b in re.split(r"[，,。；;]", answer) if b.strip()]
        upd["persona_updates"].append({"id": target, "name": bits[0].strip() if bits else answer,
                                       "relation": bits[1].strip() if len(bits) > 1 else "",
                                       "catchphrase": line})
    elif kind == "person_trait":
        upd["persona_updates"].append({"id": target, "personality": answer, "catchphrase": line})
    elif kind == "person_memory":
        upd["persona_updates"].append({"id": target, "shared_memory": answer})
    elif kind == "gap":
        m = re.search(r"在(.{2,6}?)(买|吃|喝|看|休息|，|。)", answer)
        upd["beat_updates"].append({"fill_gap": target, "scene": m.group(1) if m else "途中",
                                    "activity": "shopping" if "买" in answer else "other", "detail": answer})
    elif kind in ("emotion", "follow_up", "offer_start"):
        upd["emotion"] = {"trigger": answer if kind == "emotion" else "", "key_line": line}
        if kind == "emotion" and not line:
            upd["follow_up"] = "当时有人说了什么话吗？你还记得原话吗？"
    elif kind == "sensory":
        upd["environment"] = {"sensory": answer}
    elif kind == "time":
        upd["environment"] = {"time": answer}
    for g in context.get("people", []):
        if g.get("name") and g["name"] in answer:
            upd["mentioned"].append(g["name"])
    if "宿舍" in answer:
        upd["new_exits"].append({"label": "大学宿舍", "reason": "用户提到了宿舍"})
    upd["user_wants_stop"] = any(w in answer for w in ("就这样吧", "差不多了"))
    return upd


def _mock_story(spec, script):
    panels = []
    for a in script["anchors"]:
        panels.append({"scene": a["scene"], "who": ["大家"], "caption": a["event"],
                       "line": (a.get("key_line") or {}).get("text", "")})
    peak = next((i for i, a in enumerate(script["anchors"]) if a.get("hook")), max(0, len(panels) - 1))
    panels.append({"scene": spec["cover"]["scene"], "who": ["大家"], "caption": "画面停在了这一刻。", "line": ""})
    chars = spec["characters"]
    return {
        "panels": panels, "peak": peak,
        "moment": f"大家在{spec['cover']['scene']}站成一排",
        "monologues": [{"id": c["id"], "name": c["name"], "text": f"（模拟）{c['name']}在想：以后就难凑齐了。"} for c in chars],
        "objects": [{"name": "相机", "detail": "（模拟）那天拍了很多张合影。"}],
        "memories": [{"id": c["id"], "name": c["name"], "items": [f"（模拟）{c['name']}记得{spec['cover']['scene']}"]} for c in chars],
    }


def _mock_image(label, color):
    img = Image.new("RGB", (1024, 768), color)
    d = ImageDraw.Draw(img)
    for y in range(768):
        shade = int(60 * y / 768)
        d.line([(0, y), (1024, y)], fill=tuple(max(0, c - shade) for c in color))
    d.text((40, 40), "MOCK IMAGE (no API key)", fill=(255, 255, 255))
    d.text((40, 70), label.encode("ascii", "replace").decode(), fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()
