"""
数据库模型定义
使用SQLAlchemy ORM定义所有表结构
"""
from sqlalchemy import Column, String, Integer, Boolean, DateTime, ForeignKey, Text, ARRAY, JSON, Float, UniqueConstraint, BigInteger
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
import uuid
from database.connection import Base


class User(Base):
    """用户表"""
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    phone = Column(String(11), unique=True, nullable=True, index=True)
    email = Column(String(200), nullable=True)
    apple_user_id = Column(String(255), unique=True, nullable=True, index=True)
    apple_refresh_token = Column(String(2000), nullable=True)
    password_hash = Column(String(255), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    last_login_at = Column(DateTime(timezone=True))
    is_active = Column(Boolean, default=True)
    subscription_tier = Column(String(50), default="free", nullable=False, server_default="free")
    subscription_expires_at = Column(DateTime(timezone=True), nullable=True)

    # 关系
    sessions = relationship("Session", back_populates="user", cascade="all, delete-orphan")


class Session(Base):
    """会话/任务表"""
    __tablename__ = "sessions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    title = Column(String(255))
    start_time = Column(DateTime(timezone=True))
    end_time = Column(DateTime(timezone=True))
    duration = Column(Integer)  # 秒
    status = Column(String(50))  # 'processing', 'completed', 'failed', 'archived'
    error_message = Column(Text)  # 分析失败时的错误信息，供客户端展示
    analysis_stage = Column(String(100))  # 分析各阶段
    analysis_stage_detail = Column(JSONB, nullable=True)  # 阶段详情，如 {"skills_matched": 3, "skill_names": ["职场丛林"]}
    emotion_score = Column(Integer)
    speaker_count = Column(Integer)
    tags = Column(ARRAY(String))
    audio_url = Column(String(500), nullable=True)   # 原音频 OSS URL，供剪切与声纹使用
    audio_path = Column(String(500), nullable=True)  # 原音频本地路径（无 OSS 时使用）
    image_status = Column(String(20), default="pending")  # pending|generating|completed|failed
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # ── Chat / Live / Review 通用类型字段 ────────────────────────────────────────
    session_type          = Column(String(20), default="review", server_default="review")  # 'review' | 'live' | 'chat'

    # ── Chat Session 专用字段 ────────────────────────────────────────────────────
    finalize_status       = Column(String(20), default="pending", server_default="pending")  # pending | completed | failed
    mood_state            = Column(String(50))         # Happy/Frustrated/Sad/... Gemini 分析完整对话后生成
    emotion_type          = Column(String(100))        # workplace_stress / relationship_tension / ...
    emotion_intensity     = Column(Integer)            # 1-10

    # ── Live Mode 专用字段 ──────────────────────────────────────────────────────
    card_title            = Column(String(100))        # Gemini 生成的 30 字标题（Live Mode post-processing）
    live_summary          = Column(Text)               # Gemini 生成的 200 字总结
    summary_status        = Column(String(20))         # processing | completed | failed
    skills_status         = Column(String(20))         # processing | completed
    cover_image_url       = Column(Text)               # 第一张成功生成的图片 URL
    total_images_expected  = Column(Integer, default=0)
    total_images_completed = Column(Integer, default=0)
    total_images_failed    = Column(Integer, default=0)
    gemini_token          = Column(Text)               # Gemini Live 续期 token（H-4 原子切换）
    gemini_token_updated  = Column(DateTime(timezone=True))
    ws_disconnected_at    = Column(DateTime(timezone=True))  # H-3 孤儿 Session 检测
    ended_at              = Column(DateTime(timezone=True))
    abandon_reason        = Column(String(100))        # 'timeout' | 'new_session' | 'manual'

    # 关系
    user = relationship("User", back_populates="sessions")
    analysis_result = relationship("AnalysisResult", back_populates="session", uselist=False, cascade="all, delete-orphan")
    strategy_analysis = relationship("StrategyAnalysis", back_populates="session", uselist=False, cascade="all, delete-orphan")
    live_segments     = relationship("LiveSegment", back_populates="session", cascade="all, delete-orphan", order_by="LiveSegment.segment_index")
    live_turns        = relationship("LiveTurn", back_populates="session", cascade="all, delete-orphan", order_by="LiveTurn.turn_index")
    live_events       = relationship("LiveEvent", back_populates="session", cascade="all, delete-orphan")
    live_speaker_mappings = relationship("LiveSpeakerMapping", back_populates="session", cascade="all, delete-orphan")
    live_summary_task = relationship("LiveSummaryTask", back_populates="session", uselist=False, cascade="all, delete-orphan")
    live_panel_batches = relationship("LivePanelBatch", back_populates="session", cascade="all, delete-orphan")


class AnalysisResult(Base):
    """分析结果表"""
    __tablename__ = "analysis_results"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, unique=True, index=True)
    dialogues = Column(JSONB, nullable=False)  # 对话内容数组
    risks = Column(ARRAY(String))  # 风险点数组
    summary = Column(Text)
    mood_score = Column(Integer)
    stats = Column(JSONB)  # 统计数据
    transcript = Column(Text)
    call1_result = Column(JSONB)  # Call #1 分析结果
    speaker_mapping = Column(JSONB, nullable=True)  # Speaker_0/Speaker_1 -> profile_id 映射
    card_title = Column(String(100), nullable=True)  # 对话核心主题短标题（≤30字）
    conversation_summary = Column(Text, nullable=True)  # 「谁和谁对话」总结（第二次 Gemini）
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # 关系
    session = relationship("Session", back_populates="analysis_result")


class StrategyAnalysis(Base):
    """策略分析表"""
    __tablename__ = "strategy_analysis"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, unique=True, index=True)
    visual_data = Column(JSONB, nullable=False)  # VisualData数组（兼容旧数据）
    strategies = Column(JSONB, nullable=False)  # StrategyItem数组（兼容旧数据）
    applied_skills = Column(JSONB, default=[])  # 应用的技能列表 [{"skill_id": "workplace_jungle", "priority": 100}]
    scene_category = Column(String(50))  # 识别的场景类别
    scene_confidence = Column(Float)  # 场景识别置信度（与文档/迁移一致）
    skill_cards = Column(JSONB, default=[])  # 每技能一张卡片 [{skill_id, skill_name, content_type, content}, ...]
    scene_images = Column(JSONB, default=[])  # 场景图片列表 [{scene_description, image_url, index}, ...]
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # 关系
    session = relationship("Session", back_populates="strategy_analysis")


class Skill(Base):
    """技能库表"""
    __tablename__ = "skills"

    skill_id = Column(String(100), primary_key=True)
    name = Column(String(200), nullable=False)
    description = Column(Text)
    category = Column(String(50), nullable=False, index=True)  # workplace/family/education/brainstorm
    skill_path = Column(String(500), nullable=False)  # 技能目录路径，如 "skills/workplace_jungle"
    priority = Column(Integer, default=0)
    enabled = Column(Boolean, default=True, index=True)
    version = Column(String(50))
    prompt_template = Column(Text, nullable=True)  # Prompt 模板内容，落表后查表即可用，不依赖 SKILL.md
    meta_data = Column("metadata", JSONB, default={})  # 元数据：keywords、scenarios等（使用 Column name 参数避免与 SQLAlchemy 保留字段冲突）
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # 关系
    executions = relationship("SkillExecution", back_populates="skill", cascade="all, delete-orphan")


class SkillExecution(Base):
    """技能执行记录表"""
    __tablename__ = "skill_executions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    skill_id = Column(String(100), ForeignKey("skills.skill_id"), nullable=False, index=True)
    scene_category = Column(String(50))  # 识别的场景类别
    confidence_score = Column(Float)  # 场景识别置信度（与文档/迁移一致）
    execution_time_ms = Column(Integer)  # 执行耗时（毫秒）
    success = Column(Boolean, default=True)
    error_message = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    # 关系
    skill = relationship("Skill", back_populates="executions")


class VerificationCode(Base):
    """验证码表"""
    __tablename__ = "verification_codes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    phone = Column(String(11), nullable=False, index=True)
    code = Column(String(6), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False, index=True)
    used = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class Profile(Base):
    """档案表"""
    __tablename__ = "profiles"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(100), nullable=False)
    relationship_type = Column("relationship", String(50), nullable=False)  # 自己、死党、领导等（使用 Column name 参数避免与 SQLAlchemy relationship 函数冲突）
    photo_url = Column(String(500))  # 照片URL
    notes = Column(Text)  # 备注
    audio_session_id = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="SET NULL"), nullable=True)  # 关联的对话session_id
    audio_segment_id = Column(String(100))  # 音频片段ID
    audio_start_time = Column(Integer)  # 音频片段开始时间（秒）
    audio_end_time = Column(Integer)  # 音频片段结束时间（秒）
    audio_url = Column(String(500))  # 音频片段URL
    emoji_type = Column(String(50), server_default='self')  # 情绪 emoji 风格: self | dog | cat
    voice_embedding = Column(ARRAY(Float), nullable=True)        # ECAPA-TDNN 192维（英文/通用）
    voice_embedding_updated_at = Column(DateTime(timezone=True), nullable=True)
    voice_embedding_zh = Column(ARRAY(Float), nullable=True)     # CAM++ 192维（中文专用）
    voice_embedding_zh_updated_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    # 关系
    user = relationship("User", backref="profiles")
    audio_session = relationship("Session", foreign_keys=[audio_session_id])


class CustomSkill(Base):
    """用户自定义技能表（扩展用）"""
    __tablename__ = "custom_skills"

    id          = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id     = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name        = Column(String(200), nullable=False)
    description = Column(Text)
    prompt      = Column(Text)
    enabled     = Column(Boolean, default=True)
    created_at  = Column(DateTime(timezone=True), server_default=func.now())
    updated_at  = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    user = relationship("User", backref="custom_skills")


class UserSkillPreference(Base):
    """用户技能偏好表"""
    __tablename__ = "user_skill_preferences"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    skill_id = Column(String(100), nullable=False)
    selected = Column(Boolean, default=True)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        UniqueConstraint("user_id", "skill_id", name="uq_user_skill"),
    )

    user = relationship("User", backref="skill_preferences")


# ──────────────────────────────────────────────────────────────────────────────
# Knowledge Graph 表（替代 mem0 的结构化记忆存储）
# ──────────────────────────────────────────────────────────────────────────────

class KgPerson(Base):
    """KG 人物节点：同一用户同名自动合并，亲密度/摩擦值滑动平均更新"""
    __tablename__ = "kg_persons"

    id         = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id    = Column(UUID(as_uuid=True), nullable=False, index=True)
    name       = Column(String(100), nullable=False)
    rel_type   = Column(String(50))   # boss/colleague/friend/family/romantic/other
    rel_desc   = Column(Text)         # "直属上司"、"同部门同事"
    intimacy   = Column(Integer)      # 1-10，滑动平均
    friction   = Column(Integer)      # 1-10，滑动平均
    power      = Column(String(20))   # superior/equal/subordinate
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    profile_id = Column(UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="SET NULL"), nullable=True)

    __table_args__ = (
        UniqueConstraint("user_id", "name", name="uq_kg_person"),
    )


class KgEvent(Base):
    """KG 事件节点：一个事件可通过 KgEventPerson 关联多个人物"""
    __tablename__ = "kg_events"

    id         = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id    = Column(UUID(as_uuid=True), nullable=False, index=True)
    event_date = Column(String(20))   # ISO date string，如 "2026-05-17"
    summary    = Column(Text, nullable=False)
    sentiment  = Column(String(20))   # positive/neutral/negative
    outcome    = Column(String(20))   # resolved/ongoing/escalated
    location   = Column(String(100))
    session_id = Column(UUID(as_uuid=True))
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)


class KgEventPerson(Base):
    """KG 人物↔事件 多对多关联"""
    __tablename__ = "kg_event_persons"

    event_id  = Column(UUID(as_uuid=True), ForeignKey("kg_events.id", ondelete="CASCADE"), primary_key=True)
    person_id = Column(UUID(as_uuid=True), ForeignKey("kg_persons.id", ondelete="CASCADE"), primary_key=True)


class KgGoal(Base):
    """KG 目标节点"""
    __tablename__ = "kg_goals"

    id          = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id     = Column(UUID(as_uuid=True), nullable=False, index=True)
    description = Column(Text, nullable=False)
    status      = Column(String(20), default="in_progress")  # in_progress/completed/abandoned
    person_id   = Column(UUID(as_uuid=True), ForeignKey("kg_persons.id", ondelete="SET NULL"), nullable=True)
    session_id  = Column(UUID(as_uuid=True))
    created_at  = Column(DateTime(timezone=True), server_default=func.now())
    updated_at  = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class KgSkill(Base):
    """KG 技能应用记录：记录每次会话/对话匹配的技能及关联人物"""
    __tablename__ = "kg_skills"

    id             = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id        = Column(UUID(as_uuid=True), nullable=False, index=True)
    session_id     = Column(UUID(as_uuid=True))
    skill_id       = Column(String(100), nullable=False)   # "workplace_jungle"
    skill_name     = Column(String(200))                   # "职场丛林法则"
    skill_category = Column(String(50))                    # workplace/family/etc
    person_ids     = Column(ARRAY(UUID(as_uuid=True)))     # 本次对话涉及的人物 id 列表
    summary        = Column(Text)                          # 应用场景摘要（可选）
    applied_at     = Column(DateTime(timezone=True), server_default=func.now(), index=True)


# ══════════════════════════════════════════════════════════════════════════════
# Live Mode 模型（Meta 眼镜实时录音）
# ══════════════════════════════════════════════════════════════════════════════

class LiveSegment(Base):
    """实时录音分段表 — 每段独立上下文"""
    __tablename__ = "live_segments"

    id               = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id       = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    segment_index    = Column(Integer, nullable=False)
    start_turn_index = Column(Integer, nullable=False, default=0)
    end_turn_index   = Column(Integer)                          # NULL = 当前活跃 Segment
    running_context  = Column(Text)                             # Task A 每 10 turns 重写的摘要
    scene_title      = Column(String(200))
    status           = Column(String(20), nullable=False, default="active")  # active | closed
    split_reason     = Column(String(50))                       # silence|speaker_change|background|manual
    image_urls       = Column(JSONB, nullable=False, default=list)
    skill_results    = Column(JSONB, nullable=False, default=list)
    created_at       = Column(DateTime(timezone=True), server_default=func.now())
    closed_at        = Column(DateTime(timezone=True))

    __table_args__ = (UniqueConstraint("session_id", "segment_index", name="uq_live_segment"),)

    session = relationship("Session", back_populates="live_segments")
    turns   = relationship("LiveTurn", back_populates="segment", cascade="all, delete-orphan")
    batches = relationship("LivePanelBatch", back_populates="segment", cascade="all, delete-orphan")


class LiveTurn(Base):
    """实时录音逐条对话表"""
    __tablename__ = "live_turns"

    id             = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id     = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    turn_index     = Column(Integer, nullable=False)
    speaker        = Column(String(20), nullable=False)         # 'user' | 'other'
    speaker_label  = Column(String(50), index=True)             # 'Speaker_1' / 'Speaker_2'（Gemini diarization）
    text           = Column(Text, nullable=False)
    timestamp_ms   = Column(BigInteger)
    segment_id     = Column(UUID(as_uuid=True), ForeignKey("live_segments.id", ondelete="SET NULL"))
    matched_skills = Column(JSONB, nullable=False, default=list)  # [{skill_id, skill_name, category, confidence}]
    suggestion     = Column(Text)                               # 本 turn 的 Gemini 实时建议
    context_3b     = Column(Text)                               # 注入的 3B 历史事件片段（Task B）
    created_at     = Column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (UniqueConstraint("session_id", "turn_index", name="uq_live_turn"),)

    session = relationship("Session", back_populates="live_turns")
    segment = relationship("LiveSegment", back_populates="turns")


class LiveEvent(Base):
    """SSE 事件持久化表 — 用于断线 Last-Event-ID 重放（H-1）"""
    __tablename__ = "live_events"

    id         = Column(BigInteger, primary_key=True, autoincrement=True)
    session_id = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    event_type = Column(String(50), nullable=False)  # suggestion|skill_match|speaker_result|segment_split|warning|session_renewed
    payload    = Column(JSONB, nullable=False, default=dict)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)

    session = relationship("Session", back_populates="live_events")


class LiveSpeakerMapping(Base):
    """Speaker 识别结果持久化表（M-2）"""
    __tablename__ = "live_speaker_mappings"

    session_id    = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, primary_key=True)
    speaker_label = Column(String(50), nullable=False, primary_key=True)  # 'Speaker_1', 'Speaker_2'
    profile_id    = Column(UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="SET NULL"))
    confidence    = Column(Float, nullable=False, default=0.0)  # 0.0-1.0
    method        = Column(String(30), nullable=False, default="llm")  # llm|rule|voiceprint|user_confirmed
    updated_at    = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    session = relationship("Session", back_populates="live_speaker_mappings")
    profile = relationship("Profile", foreign_keys=[profile_id])


class LiveSummaryTask(Base):
    """后台处理任务持久化表 — 服务重启恢复用（H-2）"""
    __tablename__ = "live_summary_tasks"

    id          = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id  = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, unique=True, index=True)
    status      = Column(String(20), nullable=False, default="pending")  # pending|running|completed|failed
    started_at  = Column(DateTime(timezone=True))
    heartbeat   = Column(DateTime(timezone=True))               # 每 30s 更新；stale >5min 触发恢复
    retry_count = Column(Integer, nullable=False, default=0)
    error_msg   = Column(Text)
    created_at  = Column(DateTime(timezone=True), server_default=func.now())

    session = relationship("Session", back_populates="live_summary_task")


class LivePanelBatch(Base):
    """逐 Scene 图片生成任务追踪表（H-2）"""
    __tablename__ = "live_panel_batches"

    id                = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id        = Column(UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False, index=True)
    segment_id        = Column(UUID(as_uuid=True), ForeignKey("live_segments.id", ondelete="CASCADE"))
    scene_index       = Column(Integer, nullable=False, default=0)   # 全局排序后的 scene 编号（0-based）
    scene_description = Column(Text)                                 # Gemini 提取的场景描述
    status            = Column(String(20), nullable=False, default="pending")  # pending|running|completed|failed|skipped
    image_url         = Column(Text)                                 # 生成成功后的 R2 URL
    task_started_at   = Column(DateTime(timezone=True))
    task_heartbeat    = Column(DateTime(timezone=True))
    retry_count       = Column(Integer, nullable=False, default=0)
    error_msg         = Column(Text)
    created_at        = Column(DateTime(timezone=True), server_default=func.now())

    session = relationship("Session", back_populates="live_panel_batches")
    segment = relationship("LiveSegment", back_populates="batches")
