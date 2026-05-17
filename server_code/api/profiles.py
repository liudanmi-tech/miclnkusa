"""
档案管理API路由
"""
import os
import time
from typing import List, Optional, Dict, Tuple, Any

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
import uuid
from datetime import datetime, timezone
import logging
import traceback
import asyncio

from database.connection import get_db
from database.models import Profile, Session, AnalysisResult
from auth.jwt_handler import get_current_user_id
from pydantic import BaseModel

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# 情绪头像生成（千人千面）
# 触发时机：upload_profile_photo 成功后 fire-and-forget
# 存储路径：emotion_avatars/{user_id}/{emotion}.png  (happy/excited/sad/calm)
# 服务端口：GET /api/v1/profiles/emotion-avatar/{emotion}
# ──────────────────────────────────────────────────────────────────────────────

EMOTION_SLOTS = ["happy", "excited", "sad", "calm"]

def _mood_state_to_emotion(mood_state: str) -> str:
    """将 LLM 返回的 mood_state 映射到 4 个情绪槽之一。"""
    m = (mood_state or "").lower()
    if any(k in m for k in ["excit", "energ", "elat", "亢奋", "兴奋", "激动"]):
        return "excited"
    if any(k in m for k in ["sad", "depress", "griev", "悲", "难过", "痛苦", "沮丧",
                              "anxious", "worry", "nervou", "焦虑", "担心", "紧张"]):
        return "sad"
    if any(k in m for k in ["happy", "joy", "glad", "高兴", "开心", "快乐", "愉快"]):
        return "happy"
    return "calm"


async def _generate_emotion_avatars_task(user_id: str, photo_bytes: bytes, photo_mime: str):
    """
    后台任务：用 Gemini 生成 2×2 情绪宫格图，PIL 裁成 4 张独立 PNG，存 R2。
    fire-and-forget，不阻塞档案保存响应。
    """
    import io
    try:
        import google.generativeai as genai
        from PIL import Image as _PIL
        from main import USE_OSS, s3_client, OSS_BUCKET_NAME
    except ImportError as e:
        logger.error(f"[情绪头像] 依赖导入失败: {e}")
        return

    IMAGE_GEN_MODEL = "gemini-3.1-flash-image-preview"

    logger.info(f"[情绪头像] 开始生成 user_id={user_id} photo_size={len(photo_bytes)}")

    grid_prompt = (
        "Generate a perfectly SQUARE image laid out as a 2x2 grid, "
        "showing the same person in 4 emotional states.\n\n"
        "STRICT RULES:\n"
        "- Image MUST be square (1:1 ratio, equal width and height)\n"
        "- Divided into EXACTLY 4 equal quadrants by thin white separator lines "
        "  at the precise horizontal and vertical center\n"
        "- Top-left:     HAPPY   – warm smile, bright joyful eyes\n"
        "- Top-right:    EXCITED – energetic, enthusiastic, wide open eyes\n"
        "- Bottom-left:  SAD     – downcast, melancholy, droopy expression\n"
        "- Bottom-right: CALM    – relaxed, peaceful, gentle neutral expression\n"
        "- Each quadrant is exactly 25 % of total image area\n"
        "- Same character appearance in all 4 panels (consistent hair, clothing)\n"
        "- Portrait headshot, upper body only, simple clean background per panel\n"
        "- Studio Ghibli illustration style"
    )

    image_bytes = None
    try:
        model = genai.GenerativeModel(IMAGE_GEN_MODEL)
        contents = [{"mime_type": photo_mime, "data": photo_bytes}, grid_prompt]

        for attempt in range(2):
            try:
                response = await asyncio.to_thread(model.generate_content, contents)
                for part in response.parts:
                    if part.inline_data is not None:
                        image_bytes = part.inline_data.data
                        break
                if image_bytes:
                    logger.info(f"[情绪头像] Gemini 生成成功 attempt={attempt+1} "
                                f"size={len(image_bytes)}")
                    break
            except Exception as e:
                logger.warning(f"[情绪头像] attempt={attempt+1} 生成失败: {e}")
                if attempt == 0:
                    await asyncio.sleep(3)
    except Exception as e:
        logger.error(f"[情绪头像] Gemini 调用异常: {e}", exc_info=True)
        return

    if not image_bytes:
        logger.error("[情绪头像] ❌ 生成失败，无图片数据")
        return

    # ── PIL 加载 + 强制正方形 ──
    try:
        img = _PIL.open(io.BytesIO(image_bytes))
        w, h = img.size
        logger.info(f"[情绪头像] 生成尺寸 {w}×{h}")

        if abs(w - h) > max(w, h) * 0.05:   # 偏差 >5% 才居中裁剪
            side = min(w, h)
            left, top = (w - side) // 2, (h - side) // 2
            img = img.crop((left, top, left + side, top + side))
            w, h = img.size
            logger.info(f"[情绪头像] 强制正方 → {w}×{h}")

        # ── 裁剪 4 象限 ──
        panels = {
            "happy":   img.crop((0,    0,    w // 2, h // 2)),
            "excited": img.crop((w//2, 0,    w,      h // 2)),
            "sad":     img.crop((0,    h//2, w // 2, h     )),
            "calm":    img.crop((w//2, h//2, w,      h     )),
        }

        for emotion, panel in panels.items():
            pw, ph = panel.size
            if pw < 30 or ph < 30:
                logger.error(f"[情绪头像] ❌ 裁剪异常 {emotion} {pw}×{ph}，放弃")
                return

        # ── 上传到 R2 ──
        if not USE_OSS or s3_client is None:
            logger.warning("[情绪头像] R2 未启用，跳过上传")
            return

        for emotion, panel in panels.items():
            buf = io.BytesIO()
            panel.convert("RGBA").save(buf, format="PNG")
            png_bytes = buf.getvalue()
            oss_key = f"emotion_avatars/{user_id}/{emotion}.png"
            try:
                await asyncio.to_thread(
                    s3_client.put_object,
                    Bucket=OSS_BUCKET_NAME,
                    Key=oss_key,
                    Body=png_bytes,
                    ContentType="image/png",
                )
                logger.info(f"[情绪头像] ✅ {emotion} → {oss_key}")
            except Exception as e:
                logger.error(f"[情绪头像] ❌ 上传 {emotion} 失败: {e}")

        logger.info(f"[情绪头像] ✅ 全部完成 user_id={user_id}")

    except Exception as e:
        logger.error(f"[情绪头像] PIL/上传异常: {e}", exc_info=True)


# 档案列表短期缓存，TTL 60 秒；创建/更新/删除时按 user_id 失效
_PROFILES_CACHE_TTL = 60
_profiles_cache: Dict[str, Tuple[List[dict], float]] = {}


def _invalidate_profiles_cache(user_id: str):
    if user_id in _profiles_cache:
        del _profiles_cache[user_id]
        logger.debug("档案列表缓存已失效: %s", user_id)


router = APIRouter(prefix="/api/v1/profiles", tags=["profiles"])


# Pydantic模型
class ProfileCreate(BaseModel):
    name: str
    relationship: str
    photo_url: Optional[str] = None
    notes: Optional[str] = None
    audio_session_id: Optional[str] = None
    audio_segment_id: Optional[str] = None
    audio_start_time: Optional[float] = None
    audio_end_time: Optional[float] = None
    audio_url: Optional[str] = None


class ProfileUpdate(BaseModel):
    name: Optional[str] = None
    relationship: Optional[str] = None
    photo_url: Optional[str] = None
    notes: Optional[str] = None
    audio_session_id: Optional[str] = None
    audio_segment_id: Optional[str] = None
    audio_start_time: Optional[float] = None
    audio_end_time: Optional[float] = None
    audio_url: Optional[str] = None


class ProfileResponse(BaseModel):
    id: str
    name: str
    relationship: str
    photo_url: Optional[str] = None
    notes: Optional[str] = None
    audio_session_id: Optional[str] = None
    audio_segment_id: Optional[str] = None
    audio_start_time: Optional[float] = None
    audio_end_time: Optional[float] = None
    audio_url: Optional[str] = None
    created_at: str
    updated_at: str

    class Config:
        from_attributes = True


def _profile_to_response(p: Profile) -> ProfileResponse:
    return ProfileResponse(
        id=str(p.id),
        name=p.name,
        relationship=p.relationship_type,
        photo_url=p.photo_url,
        notes=p.notes,
        audio_session_id=str(p.audio_session_id) if p.audio_session_id else None,
        audio_segment_id=p.audio_segment_id,
        audio_start_time=float(p.audio_start_time) if p.audio_start_time else None,
        audio_end_time=float(p.audio_end_time) if p.audio_end_time else None,
        audio_url=p.audio_url,
        created_at=p.created_at.isoformat(),
        updated_at=p.updated_at.isoformat(),
    )


@router.get("", response_model=List[ProfileResponse])
async def get_profiles(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """获取当前用户的所有档案。返回数组，与 iOS 端 Array<Profile> 解码一致。"""
    try:
        now = time.time()
        if user_id in _profiles_cache:
            cached, expiry = _profiles_cache[user_id]
            if now < expiry:
                return [ProfileResponse(**d) for d in cached]

        result = await db.execute(
            select(Profile).where(Profile.user_id == uuid.UUID(user_id)).order_by(Profile.created_at)
        )
        profiles = result.scalars().all()
        out = [_profile_to_response(p) for p in profiles]
        _profiles_cache[user_id] = ([r.model_dump() for r in out], now + _PROFILES_CACHE_TTL)
        return out
    except Exception as e:
        logger.error(f"获取档案列表失败: {type(e).__name__}: {e}")
        logger.error(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"获取档案列表失败: {str(e)}")


@router.post("", response_model=ProfileResponse, status_code=201)
async def create_profile(
    profile_data: ProfileCreate,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """创建新档案"""
    audio_session_id = None
    if profile_data.audio_session_id and str(profile_data.audio_session_id).strip():
        try:
            audio_session_id = uuid.UUID(profile_data.audio_session_id)
        except (ValueError, TypeError):
            pass
    profile = Profile(
        id=uuid.uuid4(),
        user_id=uuid.UUID(user_id),
        name=profile_data.name,
        relationship_type=profile_data.relationship,
        photo_url=profile_data.photo_url,
        notes=profile_data.notes,
        audio_session_id=audio_session_id,
        audio_segment_id=profile_data.audio_segment_id,
        audio_start_time=int(profile_data.audio_start_time) if profile_data.audio_start_time else None,
        audio_end_time=int(profile_data.audio_end_time) if profile_data.audio_end_time else None,
        audio_url=profile_data.audio_url
    )
    
    db.add(profile)
    await db.commit()
    _invalidate_profiles_cache(user_id)
    # 移除不必要的refresh，created_at和updated_at由数据库自动生成，但对象中已有值
    # await db.refresh(profile)  # 已移除，减少一次数据库查询

    return ProfileResponse(
        id=str(profile.id),
        name=profile.name,
        relationship=profile.relationship_type,
        photo_url=profile.photo_url,
        notes=profile.notes,
        audio_session_id=str(profile.audio_session_id) if profile.audio_session_id else None,
        audio_segment_id=profile.audio_segment_id,
        audio_start_time=float(profile.audio_start_time) if profile.audio_start_time else None,
        audio_end_time=float(profile.audio_end_time) if profile.audio_end_time else None,
        audio_url=profile.audio_url,
        created_at=profile.created_at.isoformat(),
        updated_at=profile.updated_at.isoformat()
    )


@router.put("/{profile_id}", response_model=ProfileResponse)
async def update_profile(
    profile_id: str,
    profile_data: ProfileUpdate,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """更新档案"""
    logger.info(f"[档案更新] profile_id={profile_id} user_id={user_id} data={profile_data.model_dump(exclude_none=True)}")
    result = await db.execute(
        select(Profile).where(
            Profile.id == uuid.UUID(profile_id),
            Profile.user_id == uuid.UUID(user_id)
        )
    )
    profile = result.scalar_one_or_none()
    
    if not profile:
        logger.warning(f"[档案更新] 档案不存在: profile_id={profile_id}")
        raise HTTPException(status_code=404, detail="档案不存在")
    
    # 更新字段
    if profile_data.name is not None:
        profile.name = profile_data.name
    if profile_data.relationship is not None:
        profile.relationship_type = profile_data.relationship
    if profile_data.photo_url is not None:
        profile.photo_url = profile_data.photo_url
    if profile_data.notes is not None:
        profile.notes = profile_data.notes
    if profile_data.audio_session_id is not None:
        profile.audio_session_id = uuid.UUID(profile_data.audio_session_id) if profile_data.audio_session_id else None
    if profile_data.audio_segment_id is not None:
        profile.audio_segment_id = profile_data.audio_segment_id
    if profile_data.audio_start_time is not None:
        profile.audio_start_time = int(profile_data.audio_start_time)
    if profile_data.audio_end_time is not None:
        profile.audio_end_time = int(profile_data.audio_end_time)
    if profile_data.audio_url is not None:
        profile.audio_url = profile_data.audio_url

    # 强制更新 updated_at，确保 iOS 端 cacheBuster URL 变化、图片缓存失效
    profile.updated_at = datetime.now(timezone.utc)

    await db.commit()
    _invalidate_profiles_cache(user_id)
    logger.info(f"[档案更新] ✅ 成功 profile_id={profile_id} photo_url={profile.photo_url}")
    # 刷新对象以获取最新的updated_at（由数据库自动更新）
    await db.refresh(profile)

    return ProfileResponse(
        id=str(profile.id),
        name=profile.name,
        relationship=profile.relationship_type,
        photo_url=profile.photo_url,
        notes=profile.notes,
        audio_session_id=str(profile.audio_session_id) if profile.audio_session_id else None,
        audio_segment_id=profile.audio_segment_id,
        audio_start_time=float(profile.audio_start_time) if profile.audio_start_time else None,
        audio_end_time=float(profile.audio_end_time) if profile.audio_end_time else None,
        audio_url=profile.audio_url,
        created_at=profile.created_at.isoformat(),
        updated_at=profile.updated_at.isoformat()
    )


@router.get("/{profile_id}/audio", summary="返回档案音频 OSS 预签名 URL（302 重定向）")
async def get_profile_audio(
    profile_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """
    验证 JWT 后，生成 60 秒有效的 OSS 预签名 URL，以 302 重定向返回。
    AVPlayer 自动跟随重定向，直接从 OSS 流式播放，支持 Range 请求和 seek。
    """
    from fastapi.responses import RedirectResponse
    from urllib.parse import urlparse

    result = await db.execute(
        select(Profile).where(
            Profile.id == uuid.UUID(profile_id),
            Profile.user_id == uuid.UUID(user_id)
        )
    )
    profile = result.scalar_one_or_none()
    if not profile or not profile.audio_url:
        raise HTTPException(status_code=404, detail="音频不存在")

    try:
        import oss2
        ak          = os.getenv("OSS_ACCESS_KEY_ID")
        sk          = os.getenv("OSS_ACCESS_KEY_SECRET")
        ep          = os.getenv("OSS_ENDPOINT", "oss-cn-beijing.aliyuncs.com")
        bucket_name = os.getenv("OSS_BUCKET_NAME")

        if not all([ak, sk, ep, bucket_name]):
            raise HTTPException(status_code=503, detail="OSS 配置不完整")

        parsed  = urlparse(profile.audio_url)
        oss_key = parsed.path.lstrip("/")

        auth   = oss2.Auth(ak, sk)
        bucket = oss2.Bucket(auth, ep, bucket_name)

        # 生成 60 秒有效预签名 URL，AVPlayer 跟随 302 后直接流式播放
        signed_url = await asyncio.to_thread(
            bucket.sign_url, "GET", oss_key, 60, slash_safe=True
        )
        logger.info(f"[档案音频] 302 → OSS signed_url (60s) profile_id={profile_id}")
        return RedirectResponse(url=signed_url, status_code=302)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[档案音频] 生成预签名 URL 失败 profile_id={profile_id}: {e}")
        raise HTTPException(status_code=502, detail=f"无法获取音频: {str(e)[:120]}")


def _parse_memory(raw: str) -> dict:
    import re
    type_m   = re.search(r'\[TYPE:(\w+)\]', raw)
    date_m   = re.search(r'\[DATE:([\d-]+)\]', raw)
    status_m = re.search(r'\[STATUS:(\w+)\]', raw)
    is_goal  = bool(re.search(r'\[GOAL\]', raw))
    content  = re.sub(r'\[[^\]]+\]', '', raw).strip(' :：-')
    mem_type = "goal" if is_goal else (type_m.group(1) if type_m else "other")
    return {"content": content, "type": mem_type,
            "date": date_m.group(1) if date_m else None,
            "status": status_m.group(1) if status_m else None}


@router.get("/{profile_id}/memories", summary="获取档案关联记忆")
async def get_profile_memories(
    profile_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """
    获取与指定档案关联的记忆，按类型分组返回。
    数据来源：PostgreSQL KG（人物/事件/目标/技能），精准 SQL JOIN，零语义漂移。
    """
    from services.knowledge_graph import get_profile_memories_kg

    # 1. 验证档案属于当前用户
    result = await db.execute(
        select(Profile).where(
            Profile.id == uuid.UUID(profile_id),
            Profile.user_id == uuid.UUID(user_id)
        )
    )
    profile = result.scalar_one_or_none()
    if not profile:
        raise HTTPException(status_code=404, detail="档案不存在")

    # 2. PostgreSQL KG 查询（替代 mem0 向量搜索）
    memories = await get_profile_memories_kg(profile.name, user_id, db)

    return {
        "profile_id": profile_id,
        "profile_name": memories["profile_name"],
        "relationship": memories["relationship"],
        "events": memories["events"],
        "goals": memories["goals"],
        "skills": memories["skills"],
        "other": memories["other"],
        "total": memories["total"],
    }


@router.delete("/{profile_id}", status_code=204)
async def delete_profile(
    profile_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """删除档案"""
    result = await db.execute(
        select(Profile).where(
            Profile.id == uuid.UUID(profile_id),
            Profile.user_id == uuid.UUID(user_id)
        )
    )
    profile = result.scalar_one_or_none()
    
    if not profile:
        raise HTTPException(status_code=404, detail="档案不存在")
    
    await db.delete(profile)
    await db.commit()
    _invalidate_profiles_cache(user_id)
    return None


@router.post("/upload-photo", summary="上传档案照片")
async def upload_profile_photo(
    file: UploadFile = File(...),
    profile_id: Optional[str] = Query(None, description="档案ID，传入则照片与该档案绑定"),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db)
):
    """上传档案照片到OSS并返回URL。传入 profile_id 时照片与该档案绑定，路径固定为 profile_{profile_id}"""
    try:
        file_content = await file.read()
        file_size = len(file_content)

        logger.info(f"[档案照片] 收到上传请求: 文件名={file.filename}, 大小={file_size} 字节, 用户={user_id}, profile_id={profile_id}")

        # ── 上传前压缩到 512×512，减少 OSS 存储体积，加快生图时下载速度 ──
        try:
            from PIL import Image as _PIL_Image
            import io as _io
            _img = _PIL_Image.open(_io.BytesIO(file_content))
            _w, _h = _img.size
            _max_dim = 512
            if _w > _max_dim or _h > _max_dim:
                _ratio = min(_max_dim / _w, _max_dim / _h)
                _new_w, _new_h = int(_w * _ratio), int(_h * _ratio)
                _img = _img.resize((_new_w, _new_h), _PIL_Image.LANCZOS)
                logger.info(f"[档案照片] 缩放: {_w}x{_h} → {_new_w}x{_new_h}")
            _buf = _io.BytesIO()
            _img.convert("RGB").save(_buf, format="JPEG", quality=85)
            file_content = _buf.getvalue()
            file.content_type = "image/jpeg"
            logger.info(f"[档案照片] 压缩完成: {file_size} → {len(file_content)} 字节 ({len(file_content)*100//file_size}%)")
        except Exception as _e:
            logger.warning(f"[档案照片] 压缩失败，使用原图: {_e}")

        from main import upload_image_to_oss
        
        # 有 profile_id 时与档案绑定，路径固定；新建档案时用随机 id
        if profile_id and profile_id.strip():
            try:
                pid = uuid.UUID(profile_id)
                # 校验档案属于当前用户
                r = await db.execute(select(Profile).where(Profile.id == pid, Profile.user_id == uuid.UUID(user_id)))
                if r.scalar_one_or_none():
                    session_id = f"profile_{profile_id}"
                    logger.info(f"[档案照片] 与档案绑定: profile_id={profile_id}")
                else:
                    session_id = f"profile_{uuid.uuid4()}"
                    logger.warning(f"[档案照片] profile_id 不属于当前用户，使用随机路径")
            except (ValueError, TypeError):
                session_id = f"profile_{uuid.uuid4()}"
        else:
            session_id = f"profile_{uuid.uuid4()}"
        
        # 上传到OSS (路径: images/{user_id}/profile_{uuid}/0.png)
        content_type = file.content_type or "image/jpeg"
        if content_type not in ("image/jpeg", "image/png", "image/webp"):
            content_type = "image/jpeg"
        logger.info(f"[档案照片] 开始上传OSS: session_id={session_id} type={content_type}")
        oss_url = await asyncio.to_thread(
            upload_image_to_oss,
            image_bytes=file_content,
            user_id=user_id,
            session_id=session_id,
            image_index=0,
            content_type=content_type
        )
        
        if not oss_url:
            logger.error(f"[档案照片] ❌ OSS上传返回None，可能OSS未启用或上传失败")
            raise HTTPException(status_code=500, detail="图片上传失败：OSS未启用或上传失败")
        
        logger.info(f"[档案照片] ✅ OSS上传成功")
        
        # 返回完整 API URL（OSS 为私有，需经后端 /api/v1/images/{session_id}/{index} 代理）
        api_base = os.getenv("API_PUBLIC_URL", "http://47.79.254.213")
        photo_url = f"{api_base.rstrip('/')}/api/v1/images/{session_id}/0"
        
        # 有 profile_id 时同步更新 Profile.photo_url，确保策略图片生成能获取参考图
        if profile_id and profile_id.strip() and session_id.startswith("profile_"):
            try:
                r = await db.execute(select(Profile).where(Profile.id == uuid.UUID(profile_id), Profile.user_id == uuid.UUID(user_id)))
                prof = r.scalar_one_or_none()
                if prof:
                    prof.photo_url = photo_url
                    await db.commit()
                    logger.info(f"[档案照片] 已更新 Profile.photo_url: profile_id={profile_id}")
            except Exception as e:
                logger.warning(f"[档案照片] 更新 Profile.photo_url 失败: {e}")
                await db.rollback()
        
        response_data = {"photo_url": photo_url}
        logger.info(f"[档案照片] 返回 photo_url={photo_url}")

        # ── 异步触发情绪头像生成（fire-and-forget，不影响响应时间）──
        try:
            asyncio.create_task(
                _generate_emotion_avatars_task(user_id, file_content, file.content_type or "image/jpeg")
            )
            logger.info(f"[档案照片] 已触发情绪头像异步生成 user_id={user_id}")
        except Exception as _e:
            logger.warning(f"[档案照片] 触发情绪头像生成失败（非致命）: {_e}")

        return response_data
    except HTTPException:
        # 重新抛出HTTP异常
        raise
    except Exception as e:
        logger.error(f"上传图片失败: {e}")
        logger.error(f"错误类型: {type(e).__name__}")
        logger.error(f"错误详情: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"上传图片失败: {str(e)}")


# ──────────────────────────────────────────────────────────────────────────────
# 情绪头像服务端点
# ──────────────────────────────────────────────────────────────────────────────

@router.get("/emotion-avatar/{emotion}", summary="获取当前用户情绪头像")
async def get_emotion_avatar(
    emotion: str,
    user_id: str = Depends(get_current_user_id),
):
    """
    返回当前用户对应情绪的头像 PNG（由档案照片生成，存于 R2）。
    emotion: happy | excited | sad | calm
    若尚未生成则返回 404。
    """
    from fastapi.responses import Response
    try:
        from main import USE_OSS, s3_client, OSS_BUCKET_NAME
    except ImportError as e:
        raise HTTPException(status_code=503, detail=f"Storage unavailable: {e}")

    if emotion not in EMOTION_SLOTS:
        raise HTTPException(status_code=400, detail=f"Invalid emotion '{emotion}'. Must be one of: {EMOTION_SLOTS}")

    if not USE_OSS or s3_client is None:
        raise HTTPException(status_code=503, detail="Storage service unavailable")

    oss_key = f"emotion_avatars/{user_id}/{emotion}.png"
    try:
        obj = await asyncio.to_thread(
            s3_client.get_object, Bucket=OSS_BUCKET_NAME, Key=oss_key
        )
        image_data = obj["Body"].read()
        return Response(content=image_data, media_type="image/png",
                        headers={"Cache-Control": "public, max-age=86400"})
    except Exception:
        raise HTTPException(status_code=404, detail="Emotion avatar not generated yet")


@router.get("/emotion-avatars/urls", summary="获取当前用户全部情绪头像 URL")
async def get_emotion_avatar_urls(
    user_id: str = Depends(get_current_user_id),
):
    """
    返回 4 个情绪头像的 API URL（由客户端携带 JWT 请求）。
    格式: { "happy": "...", "excited": "...", "sad": "...", "calm": "..." }
    """
    api_base = os.getenv("API_PUBLIC_URL", "http://47.79.254.213")
    base = api_base.rstrip("/")
    return {
        emotion: f"{base}/api/v1/profiles/emotion-avatar/{emotion}"
        for emotion in EMOTION_SLOTS
    }
