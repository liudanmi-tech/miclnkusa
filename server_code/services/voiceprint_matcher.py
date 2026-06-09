"""
声纹匹配器：PCM 缓冲 + 两阶段说话人识别。

Stage 1：是否是「自己」（1:1，每条 >= 1.5s 的 turn 都跑）
Stage 2：是哪个人（1:N，每条 >= 2.0s 的 turn 都跑，需 2 票确认）

数据结构全部在内存，按 session_id 隔离，会话结束后调用 cleanup() 释放。
"""
import asyncio
import logging
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────────────────────────────────────
SAMPLE_RATE = 16000          # iOS 发送的 PCM 采样率
BYTES_PER_SAMPLE = 2         # 16-bit
BYTES_PER_SEC = SAMPLE_RATE * BYTES_PER_SAMPLE   # 32000

PCM_BUFFER_SECS = 30         # 保留最近 30 秒（960 KB）
PCM_BUFFER_MAX_BYTES = BYTES_PER_SEC * PCM_BUFFER_SECS

STAGE1_MIN_DURATION = 1.0    # Stage 1 最短有效时长（秒）
STAGE2_MIN_DURATION = 1.5    # Stage 2 最短有效时长（秒）

STAGE1_CONFIRM_THRESHOLD = 0.75    # Stage 1 直接确认阈值
STAGE1_REJECT_THRESHOLD = 0.50     # Stage 1 低于此视为「不是我」

STAGE2_STRONG_THRESHOLD = 0.78     # Stage 2 单 turn 强匹配阈值
STAGE2_VOTE_THRESHOLD = 0.65       # Stage 2 进入投票的最低分
STAGE2_VOTE_MARGIN = 0.05          # 最高分与次高分的最小差距
STAGE2_VOTES_NEEDED = 2            # 投票确认所需票数


# ──────────────────────────────────────────────────────────────────────────────
# PCM 滚动缓冲
# ──────────────────────────────────────────────────────────────────────────────
class PCMBuffer:
    """
    保留最近 PCM_BUFFER_SECS 秒的原始 PCM 数据（bytearray）。
    total_written 跟踪从 stream 开始累计写入的字节数，用于时间戳 → 偏移映射。
    """

    def __init__(self):
        self._buf = bytearray()
        self._total_written: int = 0

    def append(self, chunk: bytes) -> None:
        self._buf.extend(chunk)
        self._total_written += len(chunk)
        if len(self._buf) > PCM_BUFFER_MAX_BYTES:
            drop = len(self._buf) - PCM_BUFFER_MAX_BYTES
            del self._buf[:drop]

    def extract(self, start_sec: float, end_sec: float) -> Optional[bytes]:
        """
        按 stream 绝对时间戳提取音频片段。
        若对应数据已被裁剪（太旧）则返回 None。
        """
        if start_sec >= end_sec:
            return None
        byte_start = int(start_sec * BYTES_PER_SEC)
        byte_end = int(end_sec * BYTES_PER_SEC)
        # 缓冲中有效区间：[total_written - len(buf), total_written)
        buf_base = self._total_written - len(self._buf)
        rel_start = byte_start - buf_base
        rel_end = byte_end - buf_base
        if rel_start < 0 or rel_end > len(self._buf) or rel_start >= rel_end:
            logger.debug(
                f"[PCMBuffer] 数据已裁剪或范围无效: start={start_sec:.1f}s "
                f"end={end_sec:.1f}s buf_base_sec={buf_base/BYTES_PER_SEC:.1f}s"
            )
            return None
        return bytes(self._buf[rel_start:rel_end])


# ──────────────────────────────────────────────────────────────────────────────
# 全局 session 状态（内存）
# ──────────────────────────────────────────────────────────────────────────────
_pcm_buffers: Dict[str, PCMBuffer] = {}

# 投票计数：{session_id: {speaker_label: {profile_id: vote_count}}}
_vote_counts: Dict[str, Dict[str, Dict[str, int]]] = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))

# 已确认的 speaker → profile_id 映射（不再重复跑）
_confirmed: Dict[str, Dict[str, str]] = defaultdict(dict)

# Stage 1 不确定计数（连续不确定 N 次则放弃 Stage 1，避免空跑）
_stage1_uncertain: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
STAGE1_MAX_UNCERTAIN = 5


def get_or_create_buffer(session_id: str) -> PCMBuffer:
    if session_id not in _pcm_buffers:
        _pcm_buffers[session_id] = PCMBuffer()
    return _pcm_buffers[session_id]


def append_pcm(session_id: str, chunk: bytes) -> None:
    """由 live_audio._ios_to_gemini 每帧调用"""
    get_or_create_buffer(session_id).append(chunk)


def cleanup(session_id: str) -> None:
    """会话结束时释放内存"""
    _pcm_buffers.pop(session_id, None)
    _vote_counts.pop(session_id, None)
    _confirmed.pop(session_id, None)
    _stage1_uncertain.pop(session_id, None)
    logger.info(f"[VoiceprintMatcher] cleanup session={session_id[:8]}")


# ──────────────────────────────────────────────────────────────────────────────
# 主入口：匹配一条 Turn
# ──────────────────────────────────────────────────────────────────────────────
async def match_turn(
    session_id: str,
    speaker_label: str,
    start_sec: float,
    end_sec: float,
    user_id: str,
    push_event_fn,   # Callable(session_id, event_type, payload) → None
) -> None:
    """
    fire-and-forget：由 live_audio._gemini_to_ios 在 turn 落库后调用。
    在线程池中执行 Resemblyzer 推理，不阻塞主事件循环。
    每次调用创建独立 DB Session，避免与主 WS handler 共享会话的并发问题。
    """
    duration = end_sec - start_sec
    if duration < STAGE1_MIN_DURATION:
        logger.debug(f"[VoiceprintMatcher] turn 太短 ({duration:.1f}s)，跳过 session={session_id[:8]}")
        return

    if speaker_label in _confirmed.get(session_id, {}):
        return  # 已识别，跳过

    # 提取 PCM
    buf = _pcm_buffers.get(session_id)
    if buf is None:
        return
    pcm = buf.extract(start_sec, end_sec)
    if not pcm:
        logger.debug(f"[VoiceprintMatcher] PCM 数据已裁剪，跳过 session={session_id[:8]}")
        return

    # 在线程池中计算 embedding（避免阻塞 asyncio）
    from services.voiceprint_service import compute_embedding_from_bytes
    embedding = await asyncio.to_thread(compute_embedding_from_bytes, pcm)
    if embedding is None:
        return  # resemblyzer 未安装或计算失败

    # 使用独立 Session（避免与 WS handler 的 Session 并发冲突）
    from database.connection import AsyncSessionLocal
    async with AsyncSessionLocal() as db:
        # 查档案 embeddings
        self_emb, other_embs = await _load_profile_embeddings(user_id, db)

        # ── Stage 1：是否是我 ─────────────────────────────────────────────────────
        result = await _stage1(session_id, speaker_label, embedding, self_emb)
        if result:
            profile_id, confidence = result
            _confirmed[session_id][speaker_label] = profile_id
            await _write_and_push(session_id, speaker_label, profile_id, confidence, "voiceprint", db, push_event_fn)
            return

        # Stage 1 明确排除「是我」，才进 Stage 2
        if not _should_run_stage2(session_id, speaker_label, embedding, self_emb, duration):
            return

        # ── Stage 2：是哪个人 ─────────────────────────────────────────────────────
        if not other_embs:
            return  # 没有其他档案，无法识别

        result = await _stage2(session_id, speaker_label, embedding, other_embs)
        if result:
            profile_id, confidence = result
            _confirmed[session_id][speaker_label] = profile_id
            await _write_and_push(session_id, speaker_label, profile_id, confidence, "voiceprint", db, push_event_fn)


# ──────────────────────────────────────────────────────────────────────────────
# Stage 1：是否是我
# ──────────────────────────────────────────────────────────────────────────────
async def _stage1(
    session_id: str,
    speaker_label: str,
    embedding: List[float],
    self_emb: Optional[Tuple[str, List[float]]],   # (profile_id, embedding) or None
) -> Optional[Tuple[str, float]]:
    """返回 (profile_id, confidence) 或 None"""
    if self_emb is None:
        return None  # 自己档案无声纹，跳过

    from services.voiceprint_service import cosine_similarity
    profile_id, emb = self_emb
    score = cosine_similarity(embedding, emb)
    logger.info(f"[VoiceprintMatcher] Stage1 session={session_id[:8]} speaker={speaker_label} self_score={score:.3f}")

    if score >= STAGE1_CONFIRM_THRESHOLD:
        logger.info(f"[VoiceprintMatcher] Stage1 ✅ 确认是自己: speaker={speaker_label} score={score:.3f}")
        return (profile_id, score)

    if score >= STAGE1_REJECT_THRESHOLD:
        _stage1_uncertain[session_id][speaker_label] += 1
        logger.debug(f"[VoiceprintMatcher] Stage1 不确定 ({score:.3f})，等待下一条 turn")

    return None  # 不确定或确认不是我


def _should_run_stage2(
    session_id: str,
    speaker_label: str,
    embedding: List[float],
    self_emb: Optional[Tuple[str, List[float]]],
    duration: float,
) -> bool:
    """Stage 1 明确排除自己（score < REJECT_THRESHOLD），才允许 Stage 2"""
    if duration < STAGE2_MIN_DURATION:
        return False
    if self_emb is None:
        return True  # 无 self embedding，直接跑 Stage 2
    from services.voiceprint_service import cosine_similarity
    _, emb = self_emb
    score = cosine_similarity(embedding, emb)
    return score < STAGE1_REJECT_THRESHOLD


# ──────────────────────────────────────────────────────────────────────────────
# Stage 2：是哪个人（投票）
# ──────────────────────────────────────────────────────────────────────────────
async def _stage2(
    session_id: str,
    speaker_label: str,
    embedding: List[float],
    other_embs: List[Tuple[str, List[float]]],   # [(profile_id, emb), ...]
) -> Optional[Tuple[str, float]]:
    """返回 (profile_id, confidence) 或 None"""
    from services.voiceprint_service import cosine_similarity

    scores = [(pid, cosine_similarity(embedding, emb)) for pid, emb in other_embs]
    scores.sort(key=lambda x: x[1], reverse=True)
    best_pid, best_score = scores[0]
    second_score = scores[1][1] if len(scores) > 1 else 0.0
    margin = best_score - second_score

    logger.info(
        f"[VoiceprintMatcher] Stage2 session={session_id[:8]} speaker={speaker_label} "
        f"best={best_score:.3f} margin={margin:.3f} profile={best_pid[:8]}"
    )

    # 单 turn 强匹配
    if best_score >= STAGE2_STRONG_THRESHOLD and margin >= STAGE2_VOTE_MARGIN:
        logger.info(f"[VoiceprintMatcher] Stage2 ✅ 强匹配: speaker={speaker_label} score={best_score:.3f}")
        return (best_pid, best_score)

    # 进入投票
    if best_score >= STAGE2_VOTE_THRESHOLD and margin >= STAGE2_VOTE_MARGIN:
        _vote_counts[session_id][speaker_label][best_pid] += 1
        votes = _vote_counts[session_id][speaker_label][best_pid]
        logger.info(
            f"[VoiceprintMatcher] Stage2 投票 speaker={speaker_label} "
            f"profile={best_pid[:8]} votes={votes}/{STAGE2_VOTES_NEEDED}"
        )
        if votes >= STAGE2_VOTES_NEEDED:
            avg_confidence = best_score  # 用本 turn 的分数作为置信度
            logger.info(f"[VoiceprintMatcher] Stage2 ✅ 投票确认: speaker={speaker_label} score={avg_confidence:.3f}")
            return (best_pid, avg_confidence)

    return None


# ──────────────────────────────────────────────────────────────────────────────
# 写 DB + 推 SSE
# ──────────────────────────────────────────────────────────────────────────────
async def _write_and_push(
    session_id: str,
    speaker_label: str,
    profile_id: str,
    confidence: float,
    method: str,
    db,
    push_event_fn,
) -> None:
    import uuid
    from sqlalchemy import select
    from database.models import LiveSpeakerMapping, Profile

    try:
        # 查档案名
        result = await db.execute(select(Profile).where(Profile.id == uuid.UUID(profile_id)))
        profile = result.scalar_one_or_none()
        profile_name = profile.name if profile else None

        # upsert live_speaker_mappings（只在 confidence 更高时覆盖）
        existing_result = await db.execute(
            select(LiveSpeakerMapping).where(
                LiveSpeakerMapping.session_id == uuid.UUID(session_id),
                LiveSpeakerMapping.speaker_label == speaker_label,
            )
        )
        existing = existing_result.scalar_one_or_none()

        if existing is None:
            db.add(LiveSpeakerMapping(
                session_id=uuid.UUID(session_id),
                speaker_label=speaker_label,
                profile_id=uuid.UUID(profile_id),
                confidence=confidence,
                method=method,
            ))
        elif confidence > existing.confidence:
            existing.profile_id = uuid.UUID(profile_id)
            existing.confidence = confidence
            existing.method = method

        await db.commit()
        logger.info(
            f"[VoiceprintMatcher] 写 DB 成功: speaker={speaker_label} "
            f"profile={profile_name} confidence={confidence:.3f}"
        )

        # 推 SSE
        push_event_fn(
            session_id=session_id,
            event_id=None,
            event_type="speaker_identified",
            payload={
                "speaker_label": speaker_label,
                "profile_id": profile_id,
                "profile_name": profile_name,
                "confidence": round(confidence, 3),
                "method": method,
            },
        )

    except Exception as e:
        logger.exception(f"[VoiceprintMatcher] 写 DB/推送失败: {e}")
        try:
            await db.rollback()
        except Exception:
            pass


# ──────────────────────────────────────────────────────────────────────────────
# 加载用户档案 embeddings
# ──────────────────────────────────────────────────────────────────────────────
async def _load_profile_embeddings(
    user_id: str,
    db,
) -> Tuple[Optional[Tuple[str, List[float]]], List[Tuple[str, List[float]]]]:
    """
    返回 (self_emb, other_embs)
    self_emb: (profile_id, embedding) for relationship='自己'/'Self'
    other_embs: [(profile_id, embedding), ...] for all other profiles with embedding
    """
    import uuid
    from sqlalchemy import select
    from database.models import Profile

    result = await db.execute(
        select(Profile).where(
            Profile.user_id == uuid.UUID(user_id),
            Profile.voice_embedding.is_not(None),
        )
    )
    profiles = result.scalars().all()

    self_emb = None
    other_embs = []

    for p in profiles:
        emb = p.voice_embedding
        if not emb:
            continue
        rel = (p.relationship_type or "").lower()
        if rel in ("自己", "self", "myself", "me"):
            self_emb = (str(p.id), emb)
        else:
            other_embs.append((str(p.id), emb))

    return self_emb, other_embs
