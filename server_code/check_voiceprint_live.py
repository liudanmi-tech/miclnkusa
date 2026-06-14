#!/usr/bin/env python3
"""
诊断 live session 的声纹匹配状态。
在服务器上运行：
  python3 check_voiceprint_live.py <session_id>
"""
import asyncio, os, sys, uuid
from pathlib import Path

_root = Path(__file__).resolve().parent
if str(_root) not in sys.path:
    sys.path.insert(0, str(_root))
_env = _root / ".env"
if _env.exists():
    try:
        from dotenv import load_dotenv; load_dotenv(_env)
    except ImportError:
        pass

from sqlalchemy import select, text
from database.connection import AsyncSessionLocal
from database.models import Session as DbSession, LiveTurn, Profile

try:
    from database.models import LiveSpeakerMapping
    HAS_MAPPING = True
except ImportError:
    HAS_MAPPING = False


async def main():
    session_id = (sys.argv[1:] or [os.getenv("SESSION_ID")])[0]
    if not session_id:
        print("用法: python3 check_voiceprint_live.py <session_id>")
        sys.exit(1)

    sid = uuid.UUID(session_id)

    async with AsyncSessionLocal() as db:
        # ── 1. Session 基本信息 ─────────────────────────────────────────────
        r = await db.execute(select(DbSession).where(DbSession.id == sid))
        sess = r.scalar_one_or_none()
        if not sess:
            print(f"❌ 未找到 session: {session_id}")
            sys.exit(1)

        print("=" * 60)
        print("【Session 信息】")
        print(f"  id:           {sess.id}")
        print(f"  session_type: {sess.session_type}")
        print(f"  status:       {sess.status}")
        print(f"  user_id:      {sess.user_id}")

        user_id = sess.user_id

        # ── 2. live_turns ───────────────────────────────────────────────────
        r2 = await db.execute(
            select(LiveTurn)
            .where(LiveTurn.session_id == sid)
            .order_by(LiveTurn.turn_index)
        )
        turns = r2.scalars().all()

        print(f"\n【live_turns】共 {len(turns)} 条")
        if turns:
            for t in turns[:20]:
                print(f"  turn#{t.turn_index:>3}  speaker={t.speaker_label:<12}  text={repr(t.text[:40])}")
            if len(turns) > 20:
                print(f"  ... 共 {len(turns)} 条，只显示前 20")
        else:
            print("  ⚠️  没有任何 live_turns — 声纹匹配无法触发")

        # ── 3. live_speaker_mappings ─────────────────────────────────────────
        if HAS_MAPPING:
            r3 = await db.execute(
                select(LiveSpeakerMapping).where(LiveSpeakerMapping.session_id == sid)
            )
            mappings = r3.scalars().all()
            print(f"\n【live_speaker_mappings】共 {len(mappings)} 条")
            if mappings:
                for m in mappings:
                    print(f"  {m.speaker_label} → profile_id={m.profile_id}  confidence={m.confidence:.3f}  method={m.method}")
            else:
                print("  ⚠️  没有任何声纹匹配记录")
        else:
            # 直接 SQL
            r3 = await db.execute(
                text("SELECT speaker_label, profile_id, confidence, method FROM live_speaker_mappings WHERE session_id = :sid"),
                {"sid": str(sid)}
            )
            rows = r3.fetchall()
            print(f"\n【live_speaker_mappings】共 {len(rows)} 条")
            for row in rows:
                print(f"  {row[0]} → profile_id={row[1]}  confidence={row[2]:.3f}  method={row[3]}")
            if not rows:
                print("  ⚠️  没有任何声纹匹配记录")

        # ── 4. 用户 profiles 和 voice_embedding 状态 ────────────────────────
        r4 = await db.execute(
            select(Profile).where(Profile.user_id == user_id)
        )
        profiles = r4.scalars().all()

        print(f"\n【用户 Profiles】共 {len(profiles)} 个")
        for p in profiles:
            has_emb = bool(getattr(p, 'voice_embedding', None))
            has_audio = bool(getattr(p, 'audio_url', None))
            emb_len = len(p.voice_embedding) if has_emb else 0
            print(f"  [{p.id}]  name={p.name!r:20}  rel={p.relationship_type or '?':10}  "
                  f"audio_url={'✅' if has_audio else '❌'}  "
                  f"voice_embedding={'✅ dim=' + str(emb_len) if has_emb else '❌ 无'}")

        # ── 5. 结论 ──────────────────────────────────────────────────────────
        print("\n【诊断结论】")
        profiles_with_emb = [p for p in profiles if getattr(p, 'voice_embedding', None)]
        if not profiles_with_emb:
            print("  ❌ 根本原因：没有任何 profile 有 voice_embedding")
            print("     → 请先在档案中选择音频片段（声纹注册），保存后等待后台 embedding 计算完成")
        else:
            print(f"  ✅ 有 {len(profiles_with_emb)} 个 profile 有 voice_embedding")
            if not turns:
                print("  ❌ live_turns 为空 → WebSocket 音频未到达后端，检查 live_audio.py 是否部署")
            elif not mappings if HAS_MAPPING else not rows:
                print("  ❌ 有 turns 但无匹配 → 可能原因：")
                print("     1) turn 时长太短（< 1.0s）—— 检查 Deepgram 的 start_sec/end_sec 字段")
                print("     2) voiceprint_matcher 内部异常 —— 看服务器日志 [VoiceprintMatcher]")
                print("     3) resemblyzer 未安装 —— 在服务器运行: pip show resemblyzer")
            else:
                print("  ✅ 有匹配记录，但可能 SSE 推送未到 iOS")


if __name__ == "__main__":
    asyncio.run(main())
