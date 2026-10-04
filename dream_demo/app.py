import asyncio
import io
import json
import os
import uuid
from datetime import datetime

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel

import llm
import pipeline as pl

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE, "data")
os.makedirs(DATA_DIR, exist_ok=True)

app = FastAPI(title="UGC 造梦 Demo")
app.mount("/files", StaticFiles(directory=DATA_DIR), name="files")

DREAMS: dict[str, dict] = {}
LOCKS: dict[str, asyncio.Lock] = {}
_TASKS: set[asyncio.Task] = set()


def _spawn(coro):
    task = asyncio.create_task(coro)
    _TASKS.add(task)
    task.add_done_callback(_TASKS.discard)


def _dir(did):
    return os.path.join(DATA_DIR, did)


def _save(dream):
    with open(os.path.join(_dir(dream["id"]), "dream.json"), "w", encoding="utf-8") as f:
        json.dump(dream, f, ensure_ascii=False, indent=2)


def _get(did) -> dict:
    dream = DREAMS.get(did)
    if not dream:
        raise HTTPException(404, "梦境不存在")
    return dream


def _photo_bytes(did, pid) -> bytes:
    with open(os.path.join(_dir(did), f"{pid}.jpg"), "rb") as f:
        return f.read()


def _to_jpeg(data: bytes) -> bytes:
    buf = io.BytesIO()
    Image.open(io.BytesIO(data)).convert("RGB").save(buf, "JPEG", quality=90)
    return buf.getvalue()


def _view(dream):
    out = dict(dream)
    if dream["status"] in ("interview", "building", "ready"):
        out["readiness"] = pl.readiness(dream)
    return out


# ---------- 上传 & 预处理 ----------

@app.get("/")
def index():
    return FileResponse(os.path.join(BASE, "static", "index.html"))


@app.get("/api/config")
def config():
    return {"mock": llm.MOCK, "provider": llm.PROVIDER, "text_model": llm.TEXT_MODEL, "image_model": llm.IMAGE_MODEL,
            "max_photos": pl.MAX_PHOTOS}


@app.post("/api/dreams")
async def create_dream(files: list[UploadFile] = File(...)):
    if not 1 <= len(files) <= pl.MAX_PHOTOS:
        raise HTTPException(400, f"每个梦境需要 1–{pl.MAX_PHOTOS} 张照片")
    items, notices = [], []
    for i, f in enumerate(files):
        try:
            item = pl.load_photo(await f.read())
        except Exception:
            notices.append(f"「{f.filename}」不是可识别的图片，已跳过")
            continue
        item["upload_index"] = i
        items.append(item)
    if not items:
        raise HTTPException(400, "没有可用的照片")

    did = uuid.uuid4().hex[:12]
    os.makedirs(_dir(did))
    dream = {
        "id": did, "status": "analyzing", "error": None, "created_at": datetime.now().isoformat(),
        "notices": notices, "photos": [], "groups": [], "scenes": [], "beats": [], "turns": [],
        "pending": None, "question_count": 0, "asked_keys": [], "mentioned": [],
        "emotion": None, "environment": {}, "follow_up": None, "result": None, "build_steps": [],
    }
    DREAMS[did] = dream
    LOCKS[did] = asyncio.Lock()
    _spawn(_analyze(dream, items))
    return {"id": did}


async def _analyze(dream, items):
    try:
        kept, merged = pl.dedupe(items)
        if merged:
            dream["notices"].append(f"合并了 {merged} 张连拍/相似照片，只保留最清晰的一张")
        events = pl.split_events(kept)
        main = max(events, key=len)
        if len(events) > 1:
            dream["notices"].append(f"这组照片看起来是 {len(events)} 段不同的经历，本次先用照片最多的一段（{len(main)} 张）")
        timed = sorted((i for i in main if i["t"]), key=lambda i: i["t"])
        untimed = sorted((i for i in main if not i["t"]), key=lambda i: i["upload_index"])
        if untimed:
            dream["notices"].append(f"{len(untimed)} 张照片没有拍摄时间，按上传顺序排在最后")

        for n, it in enumerate(timed + untimed, 1):
            pid = f"p{n}"
            with open(os.path.join(_dir(dream["id"]), f"{pid}.jpg"), "wb") as f:
                f.write(it["jpeg"])
            dream["photos"].append({
                "id": pid, "url": f"/files/{dream['id']}/{pid}.jpg",
                "t": it["t"].isoformat() if it["t"] else None, "sharpness": round(it["sharpness"], 1),
            })
        blurry = pl.blurry_ids(dream["photos"])
        if blurry:
            dream["notices"].append(f"{'、'.join(blurry)} 比较模糊，识别可能不准")

        vision = await llm.analyze_photos(
            [(p["id"], p["t"], _photo_bytes(dream["id"], p["id"])) for p in dream["photos"]])
        safety = vision.get("safety") or {}
        if safety.get("nudity"):
            dream["status"] = "rejected"
            dream["error"] = "照片中检测到不适合的内容，无法创建梦境"
            return
        pl.apply_vision(dream, vision)
        if dream["protected_mode"]:
            dream["notices"].append("照片里可能有未成年人，这个梦境会进入保护模式（简笔形象、不进入开拓状态）")
        dream["pending"] = pl.next_question(dream)
        dream["status"] = "interview"
    except Exception as e:
        dream["status"] = "error"
        dream["error"] = f"照片解析失败：{e}"
    finally:
        _save(dream)


@app.get("/api/dreams/{did}")
def get_dream(did: str):
    return _view(_get(did))


# ---------- 人物澄清 ----------

class SelfBody(BaseModel):
    group_id: str | None = None


@app.post("/api/dreams/{did}/self")
async def pick_self(did: str, body: SelfBody):
    dream = _get(did)
    async with LOCKS[did]:
        for g in dream["groups"]:
            if g["is_self"]:
                g.update(is_self=False, state="pending", name="")
        if body.group_id:
            g = pl.group(dream, body.group_id)
            if not g:
                raise HTTPException(404, "没有这个人物")
            g.update(is_self=True, state="named", name="我", relation="自己")
            dream["self_absent"] = False
            answer = f"点选了 {g['short']}"
        else:
            dream["self_absent"] = True
            answer = "照片里没有我"
        pl.refresh_main(dream)
        _record(dream, answer)
        return _advance(dream)


class GroupBody(BaseModel):
    action: str  # name / passerby / exclude
    text: str = ""


@app.post("/api/dreams/{did}/groups/{gid}")
async def label_group(did: str, gid: str, body: GroupBody):
    dream = _get(did)
    async with LOCKS[did]:
        g = pl.group(dream, gid)
        if not g:
            raise HTTPException(404, "没有这个人物")
        if body.action == "passerby":
            g.update(state="passerby", is_self=False)
            answer, updates = "路人", {}
        elif body.action == "exclude":
            g.update(state="excluded", is_self=False)
            answer, updates = "不想把他放进梦里", {}
        elif body.action == "name" and body.text.strip():
            q = {"kind": "label", "target": gid, "text": f"{g['short']}是谁？和你是什么关系？"}
            updates = await llm.extract_updates(_context(dream), q, body.text.strip())
            if not any(u.get("id") == gid and u.get("name") for u in updates.get("persona_updates") or []):
                updates.setdefault("persona_updates", []).append({"id": gid, "name": body.text.strip()[:12]})
            pl.apply_updates(dream, updates)
            answer = body.text.strip()
        else:
            raise HTTPException(400, "未知操作")
        pl.refresh_main(dream)
        _record(dream, answer, updates, only_if_key=f"label:{gid}")
        return _advance(dream)


# ---------- 对话补全 ----------

class AnswerBody(BaseModel):
    text: str = ""
    choice: str = ""
    stop: bool = False


@app.post("/api/dreams/{did}/answer")
async def answer(did: str, body: AnswerBody):
    dream = _get(did)
    async with LOCKS[did]:
        if dream["status"] != "interview":
            raise HTTPException(409, "现在不在对话阶段")
        q = dream["pending"] or {"kind": "free", "input": "text", "text": "（用户主动补充）", "key": "free"}
        updates: dict = {}
        if body.stop:
            pl.fill_inferred(dream)
            _record(dream, "就这样吧")
            dream["pending"] = None
            _start_build(dream)
            return _view(dream)
        if body.choice:
            dream["emotion"] = {**(dream.get("emotion") or {}), "primary": body.choice, "source": "user"}
            text = pl.MOOD_LABELS.get(body.choice, body.choice)
        elif body.text.strip():
            text = body.text.strip()
            updates = await llm.extract_updates(_context(dream), q, text)
            if q["kind"] == "time" and not (updates.get("environment") or {}).get("time"):
                updates.setdefault("environment", {})["time"] = text
            pl.apply_updates(dream, updates)
            if q["kind"] == "time":
                dream["asked_time"] = True
        else:
            raise HTTPException(400, "回答不能为空")
        _record(dream, text, updates)
        if updates.get("user_wants_stop"):
            pl.fill_inferred(dream)
            dream["pending"] = None
            _start_build(dream)
            return _view(dream)
        return _advance(dream)


def _context(dream) -> dict:
    return {
        "people": [{"id": g["id"], "looks": g["short"], "name": pl.display_name(g) if g["state"] == "named" else "",
                    "relation": g["relation"], "state": g["state"]} for g in dream["groups"]],
        "scenes": [s["name"] for s in dream["scenes"]],
        "beats": [{"id": b["id"], "t": b["t"], "scene": pl.scene_name(dream, b["scene_id"]),
                   "activity": b["activity"], "detail": b["detail"]} for b in dream["beats"] if b["kind"] == "beat"],
        "gaps": [{"id": b["id"], "range": b["gap"], "from": pl.scene_name(dream, b["from_scene"]),
                  "to": pl.scene_name(dream, b["to_scene"]), "filled": b["filled"]}
                 for b in dream["beats"] if b["kind"] == "gap"],
        "emotion": dream.get("emotion") or {},
    }


def _record(dream, answer, updates=None, only_if_key=None):
    q = dream["pending"]
    if not q or (only_if_key and q.get("key") != only_if_key):
        dream["turns"].append({"question": None, "answer": answer, "input": "side", "updates": updates or {}})
        return
    dream["turns"].append({"question": q["text"], "kind": q["kind"], "input": q["input"],
                           "answer": answer, "updates": updates or {}})
    dream["asked_keys"].append(q["key"])
    if q["input"] in ("text", "choice") and q["kind"] != "offer_start":
        dream["question_count"] += 1


def _advance(dream):
    dream["pending"] = pl.next_question(dream)
    if dream["turns"]:
        dream["turns"][-1]["readiness"] = pl.readiness(dream)
    _save(dream)
    return _view(dream)


# ---------- 造梦 ----------

@app.post("/api/dreams/{did}/build")
async def build(did: str):
    dream = _get(did)
    async with LOCKS[did]:
        if dream["status"] == "building":
            return _view(dream)
        if dream["status"] not in ("interview", "error", "ready") or not dream.get("cover"):
            raise HTTPException(409, "现在不能造梦")
        if not pl.readiness(dream)["can_build"]:
            pl.fill_inferred(dream)
        _start_build(dream)
        return _view(dream)


def _start_build(dream):
    dream["status"] = "building"
    dream["error"] = None
    dream["build_steps"] = []
    _save(dream)
    _spawn(_build(dream))


def _step(dream, text):
    dream["build_steps"].append({"text": text, "at": datetime.now().isoformat(timespec="seconds")})


async def _build(dream):
    did = dream["id"]
    try:
        for g in dream["groups"]:
            if g["state"] == "pending":
                g["state"] = "passerby"
        spec = pl.build_spec(dream)
        script = pl.build_script(dream, spec)
        _step(dream, "定稿梦境规格，写好记忆复原剧本")

        cover = next(p for p in dream["photos"] if p["id"] == dream["cover"])
        _step(dream, "并行：写首映分镜 / 生成封面场景背景（去人、风格化）")
        story, bg = await asyncio.gather(
            llm.write_storyboard(spec, script),
            llm.generate_background(_photo_bytes(did, cover["id"]), spec["cover"]["scene"],
                                    spec["environment"], spec["era_pack"]),
        )
        bg = _to_jpeg(bg)
        with open(os.path.join(_dir(did), "background.jpg"), "wb") as f:
            f.write(bg)

        _step(dream, "按外观描述组装人物，画出封面那一刻")
        chars = [c for c in spec["characters"] if c["role"] in ("self", "main", "support")]
        panel = _to_jpeg(await llm.generate_panel(bg, story.get("moment") or spec["cover"]["scene"],
                                                  chars, spec["protected_mode"]))
        with open(os.path.join(_dir(did), "panel.jpg"), "wb") as f:
            f.write(panel)

        _step(dream, "完成，开始首映")
        dream["result"] = {
            "spec": spec, "script": script, "story": story,
            "background_url": f"/files/{did}/background.jpg", "panel_url": f"/files/{did}/panel.jpg",
        }
        dream["status"] = "ready"
    except Exception as e:
        dream["status"] = "error"
        dream["error"] = f"造梦失败：{e}"
    finally:
        _save(dream)
