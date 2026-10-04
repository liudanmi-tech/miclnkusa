import io
import math
from collections import Counter
from datetime import datetime, timedelta

from PIL import Image, ImageFilter, ImageOps, ImageStat

MAX_PHOTOS = 20
MAX_SCENES = 6
MAX_MAIN = 4
MAX_QUESTIONS = 8
GAP_MINUTES = 90
EVENT_HOURS = 3
EVENT_KM = 20

ACTIVITY_LABELS = {
    "group_photo": "合影", "queue": "排队", "cable_car": "坐索道", "hiking": "爬山",
    "photo_scenery": "拍风景", "picnic": "野餐", "dining": "吃饭", "playing": "打闹",
    "sightseeing": "游览", "resting": "休息", "shopping": "买东西", "other": "其他",
}
MOOD_LABELS = {
    "belonging": "归属感", "freedom": "自由", "nostalgia": "怀念",
    "excitement": "兴奋", "warmth": "温馨", "relief": "释然",
}


# ---------- 预处理 ----------

def load_photo(raw: bytes) -> dict:
    img = Image.open(io.BytesIO(raw))
    exif = img.getexif()
    t = _exif_time(exif)
    gps = _exif_gps(exif)
    img = ImageOps.exif_transpose(img).convert("RGB")
    img.thumbnail((1280, 1280))
    buf = io.BytesIO()
    # 重新编码不带 EXIF：原始坐标在这里被丢弃，只在内存里用于事件切分
    img.save(buf, "JPEG", quality=85)
    return {
        "jpeg": buf.getvalue(), "t": t, "gps": gps,
        "sharpness": _sharpness(img), "ahash": _ahash(img),
    }


def _exif_time(exif):
    raw = exif.get_ifd(0x8769).get(36867) or exif.get(306)
    if not raw:
        return None
    try:
        return datetime.strptime(str(raw).strip("\x00 "), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None


def _exif_gps(exif):
    g = exif.get_ifd(0x8825)
    try:
        lat = _dms(g[2]) * (-1 if g.get(1) == "S" else 1)
        lon = _dms(g[4]) * (-1 if g.get(3) == "W" else 1)
        return lat, lon
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        return None


def _dms(v):
    d, m, s = (float(x) for x in v)
    return d + m / 60 + s / 3600


def _sharpness(img):
    g = img.convert("L")
    g.thumbnail((256, 256))
    return ImageStat.Stat(g.filter(ImageFilter.FIND_EDGES)).var[0]


def _ahash(img):
    g = img.convert("L").resize((8, 8))
    px = list(g.getdata())
    avg = sum(px) / len(px)
    return sum(1 << i for i, p in enumerate(px) if p > avg)


def _km(a, b):
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def dedupe(items: list[dict]) -> tuple[list[dict], int]:
    """连拍/近似照片合并，只保留最清晰的一张。"""
    kept: list[dict] = []
    merged = 0
    for it in items:
        dup = None
        for k in kept:
            close_in_time = (it["t"] and k["t"] and abs((it["t"] - k["t"]).total_seconds()) <= 120) \
                or (not it["t"] and not k["t"])
            if close_in_time and bin(it["ahash"] ^ k["ahash"]).count("1") <= 5:
                dup = k
                break
        if dup is None:
            kept.append(it)
            continue
        merged += 1
        if it["sharpness"] > dup["sharpness"]:
            kept[kept.index(dup)] = it
    return kept, merged


def split_events(items: list[dict]) -> list[list[dict]]:
    """间隔 > 3 小时或距离 > 20 公里切成新事件。无时间的照片归入最大事件。"""
    timed = sorted((i for i in items if i["t"]), key=lambda i: i["t"])
    untimed = [i for i in items if not i["t"]]
    events: list[list[dict]] = []
    for it in timed:
        if events:
            prev = events[-1][-1]
            far = it["gps"] and prev["gps"] and _km(it["gps"], prev["gps"]) > EVENT_KM
            if (it["t"] - prev["t"]) > timedelta(hours=EVENT_HOURS) or far:
                events.append([it])
                continue
            events[-1].append(it)
        else:
            events.append([it])
    if not events:
        return [untimed]
    largest = max(events, key=len)
    largest.extend(untimed)
    return events


def blurry_ids(photos: list[dict]) -> list[str]:
    if len(photos) < 3:
        return []
    vals = sorted(p["sharpness"] for p in photos)
    median = vals[len(vals) // 2]
    return [p["id"] for p in photos if p["sharpness"] < median * 0.25]


# ---------- 视觉结果 → 人物组 / 场景 / 故事草稿 ----------

def apply_vision(dream: dict, vision: dict) -> None:
    by_id = {p["id"]: p for p in dream["photos"]}
    group_meta = {g.get("person_key"): g for g in vision.get("people_groups", []) if g.get("person_key")}
    key_boxes: dict[str, list[dict]] = {}

    for pv in vision.get("photos", []):
        photo = by_id.get(pv.get("id"))
        if not photo:
            continue
        photo.update({
            "place": (pv.get("place") or "未知地点").strip(),
            "landmark": pv.get("landmark") or "",
            "environment": {k: pv.get(k) or "" for k in ("weather", "light", "season", "crowd")},
            "activity": pv.get("activity") if pv.get("activity") in ACTIVITY_LABELS else "other",
            "emotion": pv.get("emotion") or "",
            "emotion_score": float(pv.get("emotion_score") or 0.5),
            "era_clues": pv.get("era_clues") or [],
            "relation_cues": pv.get("relation_cues") or [],
            "boxes": [],
        })
        for n, person in enumerate(pv.get("people", [])[:8], 1):
            box = _norm_box(person.get("box"))
            if not box:
                continue
            b = {
                "id": f"{photo['id']}_b{n}", "bbox": box,
                "appearance": person.get("appearance") or "",
                "prominent": bool(person.get("prominent", True)),
                "group_id": None,
            }
            photo["boxes"].append(b)
            key_boxes.setdefault(person.get("person_key") or b["id"], []).append(b)

    for photo in dream["photos"]:
        photo.setdefault("place", "未知地点")
        photo.setdefault("boxes", [])
        photo.setdefault("activity", "other")
        photo.setdefault("emotion_score", 0.5)
        photo.setdefault("environment", {})

    ordered = sorted(key_boxes.items(), key=lambda kv: -len(kv[1]))
    groups = []
    for n, (key, boxes) in enumerate(ordered, 1):
        meta = group_meta.get(key, {})
        gid = f"g{n}"
        for b in boxes:
            b["group_id"] = gid
        groups.append({
            "id": gid,
            "appearance": meta.get("appearance") or boxes[0]["appearance"],
            "short": meta.get("short") or _short(boxes[0]["appearance"]),
            "confidence": float(meta.get("confidence") or 0.6),
            "box_ids": [b["id"] for b in boxes],
            "photo_ids": sorted({b["id"].split("_")[0] for b in boxes}, key=_pid_num),
            "count": len(boxes),
            "prominent": any(b["prominent"] for b in boxes),
            "state": "pending", "is_self": False, "is_main": False,
            "name": "", "relation": "", "personality": "", "catchphrase": "", "shared_memory": "",
            "asked": 0,
        })
    dream["groups"] = groups

    safety = vision.get("safety") or {}
    dream["flags"] = {"minor_possible": bool(safety.get("minor_possible")), "nudity": bool(safety.get("nudity"))}
    dream["protected_mode"] = dream["flags"]["minor_possible"]
    dream["era_pack"] = vision.get("era_pack") or "generic"
    mood = vision.get("mood_guess") or {}
    dream["mood_guess"] = {"primary": mood.get("primary") or "warmth", "secondary": mood.get("secondary") or ""}

    _build_scenes(dream)
    _build_beats(dream)
    cover = max(dream["photos"], key=lambda p: len(p["boxes"]) + 2 * p["emotion_score"])
    dream["cover"] = cover["id"]


def _norm_box(box):
    try:
        y0, x0, y1, x1 = (float(v) / 1000 for v in box)
    except (TypeError, ValueError):
        return None
    if not (0 <= x0 < x1 <= 1.001 and 0 <= y0 < y1 <= 1.001):
        return None
    return [round(y0, 4), round(x0, 4), round(y1, 4), round(x1, 4)]


def _short(appearance: str) -> str:
    first = appearance.replace("，", "、").split("、")[0].strip()
    return f"穿{first}的人" if first else "这个人"


def _pid_num(pid: str) -> int:
    return int(pid[1:])


def _build_scenes(dream):
    counts = Counter(p["place"] for p in dream["photos"])
    keep = {name for name, _ in counts.most_common(MAX_SCENES)}
    scenes, by_name, last = [], {}, None
    for p in dream["photos"]:
        name = p["place"] if p["place"] in keep else (last or p["place"])
        if name not in by_name:
            s = {"id": f"s{len(scenes) + 1}", "name": name, "kind": "photo", "photo_ids": [], "details": []}
            scenes.append(s)
            by_name[name] = s
        by_name[name]["photo_ids"].append(p["id"])
        p["scene_id"] = by_name[name]["id"]
        last = name
    dream["scenes"] = scenes


def _build_beats(dream):
    beats, cur = [], None
    for p in dream["photos"]:
        if cur and cur["scene_id"] == p["scene_id"]:
            cur["evidence"].append(p["id"])
            cur["_acts"].append(p["activity"])
            cur["who"].update(b["group_id"] for b in p["boxes"])
            continue
        cur = {
            "id": f"b{len(beats) + 1}", "kind": "beat", "t": _hhmm(p.get("t")),
            "scene_id": p["scene_id"], "who": {b["group_id"] for b in p["boxes"]},
            "_acts": [p["activity"]], "evidence": [p["id"]], "detail": "",
            "source": "photo", "confidence": 0.85 if p.get("t") else 0.6,
        }
        beats.append(cur)
    for b in beats:
        b["activity"] = Counter(b.pop("_acts")).most_common(1)[0][0]
        b["who"] = sorted(b["who"], key=_gnum)

    with_gaps = []
    for i, b in enumerate(beats):
        if i:
            prev = beats[i - 1]
            gap = _minutes_between(prev["t"], b["t"])
            if gap and gap >= GAP_MINUTES:
                with_gaps.append({
                    "id": f"gap{sum(1 for x in with_gaps if x['kind'] == 'gap') + 1}", "kind": "gap",
                    "gap": [prev["t"], b["t"]], "from_scene": prev["scene_id"], "to_scene": b["scene_id"],
                    "minutes": gap, "filled": False,
                })
        with_gaps.append(b)
    dream["beats"] = with_gaps


def _gnum(gid: str) -> int:
    return int(gid[1:]) if gid and gid[1:].isdigit() else 0


def _hhmm(iso):
    return datetime.fromisoformat(iso).strftime("%H:%M") if iso else None


def _minutes_between(a, b):
    if not a or not b:
        return None
    ta, tb = (datetime.strptime(x, "%H:%M") for x in (a, b))
    return int((tb - ta).total_seconds() // 60)


# ---------- 查询帮手 ----------

def group(dream, gid):
    return next((g for g in dream["groups"] if g["id"] == gid), None)


def scene(dream, sid):
    return next((s for s in dream["scenes"] if s["id"] == sid), None)


def scene_name(dream, sid):
    s = scene(dream, sid)
    return s["name"] if s else ""


def main_groups(dream):
    return [g for g in dream["groups"] if g["is_main"]]


def display_name(g):
    if g["is_self"]:
        return "我"
    return g["name"] or g["short"]


def refresh_main(dream):
    named = [g for g in dream["groups"] if g["state"] == "named" and not g["is_self"]]
    named.sort(key=lambda g: -g["count"])
    main_ids = {g["id"] for g in named[:MAX_MAIN]}
    for g in dream["groups"]:
        g["is_main"] = g["id"] in main_ids


def main_candidates(dream):
    """还没标注、可能成为主要人物的组。"""
    slots = MAX_MAIN - len(main_groups(dream))
    if slots <= 0:
        return []
    pending = [g for g in dream["groups"] if g["state"] == "pending" and not g["is_self"] and g["prominent"]]
    pending.sort(key=lambda g: -g["count"])
    return pending[:slots]


def cover_scene_id(dream):
    return next(p["scene_id"] for p in dream["photos"] if p["id"] == dream["cover"])


# ---------- 充足度 ----------

def readiness(dream) -> dict:
    groups = dream["groups"]
    self_known = any(g["is_self"] for g in groups) or dream.get("self_absent", False)
    mains = main_groups(dream)
    still_pending = main_candidates(dream)
    total_main = len(mains) + len(still_pending)
    named_frac = 1.0 if total_main == 0 else len(mains) / total_main
    has_trait = any(g["personality"] or g["catchphrase"] for g in mains)
    relation = {
        "score": 0.25 * self_known + 0.45 * named_frac + 0.3 * (has_trait or total_main == 0),
        "min_ok": self_known and (len(mains) >= 1 or total_main == 0),
    }

    emo = dream.get("emotion") or {}
    user_details = any((b.get("source") == "user" or b.get("user_detail")) and b.get("detail") for b in dream["beats"])
    has_trigger = bool(emo.get("trigger")) or user_details
    emotion = {
        "score": 0.5 * has_trigger + 0.5 * (emo.get("source") == "user" and bool(emo.get("primary"))),
        "min_ok": has_trigger,
    }

    beats = [b for b in dream["beats"] if b["kind"] == "beat"]
    gaps = [b for b in dream["beats"] if b["kind"] == "gap"]
    cover_sid = cover_scene_id(dream)
    cover_known = any(b["scene_id"] == cover_sid and b["activity"] != "other" for b in beats) \
        or any(b["scene_id"] == cover_sid and b["detail"] for b in beats)
    photo_scenes = [s for s in dream["scenes"] if s["kind"] != "candidate"]
    known = {b["scene_id"] for b in beats if b["activity"] != "other" or b["detail"]}
    scene_frac = len([s for s in photo_scenes if s["id"] in known]) / max(1, len(photo_scenes))
    top_gap = max(gaps, key=lambda g: g["minutes"], default=None)
    behavior = {
        "score": 0.4 * cover_known + 0.3 * scene_frac + 0.3 * (top_gap is None or top_gap["filled"]),
        "min_ok": cover_known,
    }

    env = dream.get("environment") or {}
    has_time = any(p.get("t") for p in dream["photos"])
    has_place = any(p["place"] != "未知地点" for p in dream["photos"])
    has_weather = bool(env.get("weather")) or any((p.get("environment") or {}).get("weather") for p in dream["photos"])
    environment = {
        "score": 0.25 * (has_time + has_place + has_weather + bool(env.get("sensory"))),
        "min_ok": has_place and (has_time or bool(env.get("time"))),
    }
    # 没有拍摄时间时，造梦师问过一次大致时间就算达标
    if not environment["min_ok"] and has_place and dream.get("asked_time"):
        environment["min_ok"] = True

    parts = {"relation": relation, "emotion": emotion, "behavior": behavior, "environment": environment}
    weights = {"relation": 0.3, "emotion": 0.3, "behavior": 0.25, "environment": 0.15}
    total = sum(parts[k]["score"] * w for k, w in weights.items())
    can_build = all(p["min_ok"] for p in parts.values())
    for p in parts.values():
        p["score"] = round(p["score"], 2)
    return {**parts, "total": round(total, 2), "can_build": can_build, "suggest_start": can_build and total >= 0.75}


# ---------- 下一个问题 ----------

def next_question(dream) -> dict | None:
    """人物点选标注优先；文字问题用『情绪价值 × 不确定性』打分（Jev 的简化替代）。"""
    groups = dream["groups"]
    if not any(g["is_self"] for g in groups) and not dream.get("self_absent"):
        if groups:
            return {"kind": "pick_self", "input": "pick_box", "key": "self",
                    "text": f"{_opening(dream)}先告诉我，哪个是你？点一下照片里的你。",
                    "photo": dream["cover"]}
        dream["self_absent"] = True

    cands = main_candidates(dream)
    if cands:
        g = cands[0]
        return {"kind": "label", "input": "label", "key": f"label:{g['id']}", "target": g["id"],
                "photo": g["photo_ids"][0],
                "text": f"{g['short']}是谁？和你是什么关系？"}

    if dream["question_count"] >= MAX_QUESTIONS:
        return None

    r = readiness(dream)
    if r["suggest_start"] and not dream.get("offered_start"):
        dream["offered_start"] = True
        return {"kind": "offer_start", "input": "text", "key": "offer",
                "text": "我觉得可以开始造梦了。还有想补充的吗？"}

    scored = []
    for c in _candidates(dream):
        if c["key"] in dream["asked_keys"]:
            continue
        score = c.pop("value") * c.pop("uncertainty")
        if any(m and m in c["text"] for m in dream["mentioned"]):
            score *= 1.3
        if c["input"] == "choice" and _recent_text_streak(dream) >= 2:
            score *= 2
        scored.append((score, c))
    if not scored:
        return None
    return max(scored, key=lambda sc: sc[0])[1]


def _opening(dream):
    timed = [p for p in dream["photos"] if p.get("t")]
    cover = next(p for p in dream["photos"] if p["id"] == dream["cover"])
    place = cover.get("landmark") or cover["place"]
    if timed:
        d = datetime.fromisoformat(timed[0]["t"])
        return f"这是 {d.year} 年 {d.month} 月 {d.day} 日在{place}吧？"
    return f"这是在{place}吧？"


def _recent_text_streak(dream):
    n = 0
    for t in reversed(dream["turns"]):
        if t.get("input") != "text":
            break
        n += 1
    return n


def _candidates(dream):
    out = []
    emo = dream.get("emotion") or {}

    if dream.get("follow_up"):
        out.append({"kind": "follow_up", "input": "text", "key": f"follow:{dream['follow_up']}",
                    "text": dream["follow_up"], "value": 0.95, "uncertainty": 0.95})

    if not emo.get("trigger"):
        out.append({"kind": "emotion", "input": "text", "key": "emotion:trigger",
                    "text": "那天有没有哪一刻，你到现在还记得特别清楚？",
                    "value": 1.0, "uncertainty": 0.9})
    if emo.get("source") != "user":
        out.append({"kind": "emotion_choice", "input": "choice", "key": "emotion:mood",
                    "text": "现在回想起那一天，整体更像哪种感觉？",
                    "options": [{"value": k, "label": v} for k, v in MOOD_LABELS.items()],
                    "value": 0.7, "uncertainty": 0.8})

    for g in main_groups(dream):
        if not (g["personality"] or g["catchphrase"]):
            out.append({"kind": "person_trait", "input": "text", "key": f"trait:{g['id']}", "target": g["id"],
                        "text": f"{g['name']}平时是个什么样的人？有没有什么口头禅？",
                        "value": 0.75, "uncertainty": 0.9})
        if not g["shared_memory"]:
            out.append({"kind": "person_memory", "input": "text", "key": f"memory:{g['id']}", "target": g["id"],
                        "text": f"那天你和{g['name']}之间，有没有什么印象深的小事？",
                        "value": 0.65, "uncertainty": 0.8})

    for gap in (b for b in dream["beats"] if b["kind"] == "gap" and not b["filled"]):
        a, b = scene_name(dream, gap["from_scene"]), scene_name(dream, gap["to_scene"])
        out.append({"kind": "gap", "input": "text", "key": f"gap:{gap['id']}", "target": gap["id"],
                    "photo": _scene_cover(dream, gap["to_scene"]),
                    "text": f"从{a}到{b}之间（{gap['gap'][0]}–{gap['gap'][1]}）没有照片，那段时间你们做了什么？",
                    "value": min(0.9, 0.55 + gap["minutes"] / 600), "uncertainty": 1.0})

    if not any(p.get("t") for p in dream["photos"]) and not (dream.get("environment") or {}).get("time"):
        out.append({"kind": "time", "input": "text", "key": "env:time",
                    "text": "这些照片大概是哪一年、什么季节拍的？",
                    "value": 0.97, "uncertainty": 1.0})

    if not (dream.get("environment") or {}).get("sensory"):
        cs = scene_name(dream, cover_scene_id(dream))
        out.append({"kind": "sensory", "input": "text", "key": "env:sensory",
                    "text": f"在{cs}的时候，天气怎么样？有没有什么声音或者味道你还记得？",
                    "value": 0.5, "uncertainty": 0.8})
    return out


def _scene_cover(dream, sid):
    s = scene(dream, sid)
    return s["photo_ids"][0] if s and s["photo_ids"] else None


# ---------- 回答 → 数据 ----------

def apply_updates(dream, updates: dict) -> list[str]:
    """把结构化更新写回人物表和故事草稿。所有更新都来自用户亲口，source = user。"""
    applied = []
    for pu in updates.get("persona_updates") or []:
        g = group(dream, pu.get("id"))
        if not g or g["is_self"]:
            continue
        for field in ("name", "relation", "personality", "catchphrase", "shared_memory"):
            val = (pu.get(field) or "").strip()
            if val:
                g[field] = val
                applied.append(f"{display_name(g)}.{field}")
        if g["name"] and g["state"] == "pending":
            g["state"] = "named"
    refresh_main(dream)

    for bu in updates.get("beat_updates") or []:
        if bu.get("fill_gap"):
            _fill_gap(dream, bu)
            applied.append(f"补全空白 {bu['fill_gap']}")
        elif bu.get("beat_id"):
            beat = next((b for b in dream["beats"] if b["id"] == bu["beat_id"] and b["kind"] == "beat"), None)
            if beat and bu.get("detail"):
                beat["detail"] = (beat["detail"] + "；" if beat["detail"] else "") + bu["detail"]
                beat["user_detail"] = True
                applied.append(f"{scene_name(dream, beat['scene_id'])} 细节")

    emo = updates.get("emotion") or {}
    if any(emo.get(k) for k in ("primary", "trigger", "key_line")):
        cur = dream.get("emotion") or {}
        for k in ("primary", "trigger", "key_line", "scene"):
            if emo.get(k):
                cur[k] = emo[k]
        cur["source"] = "user"
        dream["emotion"] = cur
        applied.append("情绪/触发物")

    env = updates.get("environment") or {}
    if any(env.values()):
        cur = dream.get("environment") or {}
        cur.update({k: v for k, v in env.items() if v})
        dream["environment"] = cur
        applied.append("环境")

    for ex in updates.get("new_exits") or []:
        label = (ex.get("label") or "").strip()
        if label and not any(s["name"] == label for s in dream["scenes"]):
            dream["scenes"].append({"id": f"s{len(dream['scenes']) + 1}", "name": label, "kind": "candidate",
                                    "photo_ids": [], "details": [ex.get("reason") or ""]})
            applied.append(f"候选场景 {label}")

    for m in updates.get("mentioned") or []:
        if m and m not in dream["mentioned"]:
            dream["mentioned"].append(m)
    dream["follow_up"] = (updates.get("follow_up") or "").strip() or None
    return applied


def _fill_gap(dream, bu):
    gid = bu["fill_gap"]
    idx = next((i for i, b in enumerate(dream["beats"]) if b["id"] == gid and b["kind"] == "gap"), None)
    if idx is None:
        return
    gap = dream["beats"][idx]
    gap["filled"] = True
    name = (bu.get("scene") or "").strip() or "路上"
    s = next((s for s in dream["scenes"] if s["name"] == name), None)
    if not s:
        kind = "filled" if len([x for x in dream["scenes"] if x["kind"] != "candidate"]) < MAX_SCENES else "candidate"
        s = {"id": f"s{len(dream['scenes']) + 1}", "name": name, "kind": kind, "photo_ids": [], "details": []}
        dream["scenes"].append(s)
    elif s["kind"] == "candidate":
        s["kind"] = "filled"
    act = bu.get("activity") if bu.get("activity") in ACTIVITY_LABELS else "other"
    who = [w for w in (bu.get("who") or []) if group(dream, w)]
    beat = {
        "id": f"b{sum(1 for b in dream['beats'] if b['kind'] == 'beat') + 1}", "kind": "beat",
        "t": bu.get("t") or _midpoint(*gap["gap"]), "scene_id": s["id"], "who": who,
        "activity": act, "detail": bu.get("detail") or "", "evidence": [],
        "source": "user", "confidence": 0.9, "filled_gap": gid,
    }
    dream["beats"].insert(idx + 1, beat)


def _midpoint(a, b):
    ta, tb = (datetime.strptime(x, "%H:%M") for x in (a, b))
    return (ta + (tb - ta) / 2).strftime("%H:%M")


def fill_inferred(dream):
    """用户说『就这样吧』时，缺的部分按常见情形补全，并标记为推测。"""
    if not dream.get("emotion") or not dream["emotion"].get("primary"):
        dream["emotion"] = {**(dream.get("emotion") or {}), "primary": dream["mood_guess"]["primary"], "source": "inferred"}
    if not dream["emotion"].get("trigger"):
        cs = scene_name(dream, cover_scene_id(dream))
        dream["emotion"]["trigger"] = f"大家在{cs}的那一刻"
        dream["emotion"]["trigger_source"] = "inferred"
    for g in dream["groups"]:
        if g["state"] == "pending":
            g["state"] = "passerby"
    if not any(g["is_self"] for g in dream["groups"]):
        dream["self_absent"] = True


# ---------- 梦境规格 & 记忆复原剧本 ----------

def build_spec(dream) -> dict:
    who = {g["id"]: g for g in dream["groups"] if g["state"] in ("named",) or g["is_self"]}
    characters = []
    for g in dream["groups"]:
        if g["state"] == "excluded":
            continue
        role = "self" if g["is_self"] else ("main" if g["is_main"] else ("support" if g["state"] == "named" else "passerby"))
        if role == "passerby":
            continue
        characters.append({
            "id": g["id"], "role": role, "name": display_name(g), "relation": g["relation"],
            "appearance": g["appearance"], "personality": g["personality"],
            "catchphrase": g["catchphrase"], "shared_memory": g["shared_memory"],
        })
    cover = next(p for p in dream["photos"] if p["id"] == dream["cover"])
    emotion = dict(dream.get("emotion") or {})
    if not emotion.get("primary"):
        emotion.update(primary=dream["mood_guess"]["primary"], primary_source="inferred")
    return {
        "dream_id": dream["id"],
        "era_pack": dream["era_pack"],
        "protected_mode": dream["protected_mode"],
        "emotion": emotion,
        "environment": {**cover.get("environment", {}), **(dream.get("environment") or {})},
        "cover": {"photo": cover["id"], "scene": scene_name(dream, cover["scene_id"])},
        "scenes": [{"id": s["id"], "name": s["name"], "kind": s["kind"], "details": s["details"]} for s in dream["scenes"]],
        "characters": characters,
        "beats": [_beat_view(dream, b, who) for b in dream["beats"] if b["kind"] == "beat"],
        "passerby_count": sum(1 for g in dream["groups"] if g["state"] == "passerby"),
    }


def _beat_view(dream, b, who):
    return {
        "id": b["id"], "t": b["t"], "scene": scene_name(dream, b["scene_id"]),
        "who": [display_name(who[w]) for w in b["who"] if w in who],
        "activity": ACTIVITY_LABELS.get(b["activity"], b["activity"]),
        "detail": b["detail"], "source": "user" if (b["source"] == "user" or b.get("user_detail")) else b["source"],
    }


def build_script(dream, spec) -> dict:
    anchors = []
    used_lines = set()
    emo = spec["emotion"]
    trigger_scene = emo.get("scene") or spec["cover"]["scene"]
    for b in spec["beats"]:
        a = {"t": b["t"], "scene": b["scene"],
             "event": b["detail"] or f"{'、'.join(b['who']) or '大家'}在{b['scene']}{b['activity']}",
             "source": b["source"]}
        if b["scene"] == trigger_scene and emo.get("key_line") and "trigger" not in used_lines:
            a["key_line"] = {"who": "all", "text": emo["key_line"]}
            a["hook"] = emo.get("primary")
            used_lines.add("trigger")
        else:
            for c in spec["characters"]:
                if c["catchphrase"] and c["name"] in b["who"] and c["id"] not in used_lines:
                    a["key_line"] = {"who": c["name"], "text": c["catchphrase"]}
                    used_lines.add(c["id"])
                    break
        anchors.append(a)

    free_slots = []
    timed = [a for a in anchors if a["t"]]
    for prev, nxt in zip(timed, timed[1:]):
        gap = _minutes_between(prev["t"], nxt["t"])
        if gap and gap > 30:
            start = (datetime.strptime(prev["t"], "%H:%M") + timedelta(minutes=10)).strftime("%H:%M")
            end = (datetime.strptime(nxt["t"], "%H:%M") - timedelta(minutes=10)).strftime("%H:%M")
            free_slots.append([start, end])
    timed_photos = [p for p in dream["photos"] if p.get("t")]
    day = timed_photos[0]["t"][:10] if timed_photos else (dream.get("environment") or {}).get("time", "")
    return {"day": day, "anchors": anchors, "free_slots": free_slots}
