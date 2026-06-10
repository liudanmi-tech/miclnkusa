-- 为 profiles 表添加中文 CAM++ embedding 列
-- 安全：ADD COLUMN IF NOT EXISTS，可重复执行
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS voice_embedding_zh FLOAT[] DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS voice_embedding_zh_updated_at TIMESTAMPTZ DEFAULT NULL;
