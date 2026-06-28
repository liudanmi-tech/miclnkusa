-- 服务端进度反馈增强：sessions 表增加 analysis_stage_detail
-- 存储阶段详情，如 strategy_matched_n 时 {"skills_matched": 3, "skill_names": ["职场丛林", "情绪识别"]}
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS analysis_stage_detail JSONB;
