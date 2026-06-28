"""
Cloudflare R2 存储模块（S3 兼容协议）
替代阿里云 OSS，存储档案图、AI生成场景图、封面图
"""
import os
import time
import logging
import traceback
from typing import Optional, Tuple
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

# ── 配置 ──────────────────────────────────────────────────
R2_ACCESS_KEY_ID     = os.getenv("R2_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = os.getenv("R2_SECRET_ACCESS_KEY")
R2_ENDPOINT_URL      = os.getenv("R2_ENDPOINT_URL", "https://65bbba67bcef53a9e38ad8b152048cc1.r2.cloudflarestorage.com")
R2_BUCKET_NAME       = os.getenv("R2_BUCKET_NAME", "micink-assets")
R2_PUBLIC_URL        = os.getenv("R2_PUBLIC_URL", "https://pub-ba70400e9a9d457d8e979b947afa1757.r2.dev")

USE_R2 = os.getenv("USE_R2", "false").lower() == "true"

# ── 客户端初始化 ──────────────────────────────────────────
r2_client = None

def init_r2():
    global r2_client, USE_R2
    if not USE_R2:
        logger.info("R2 功能未启用（USE_R2=false）")
        return
    if not all([R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT_URL, R2_BUCKET_NAME]):
        logger.warning("⚠️ R2 配置不完整，禁用 R2（需要 R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY）")
        USE_R2 = False
        return
    try:
        from botocore.config import Config as _BotoCoreConfig
        r2_client = boto3.client(
            "s3",
            region_name="auto",
            endpoint_url=R2_ENDPOINT_URL,
            aws_access_key_id=R2_ACCESS_KEY_ID,
            aws_secret_access_key=R2_SECRET_ACCESS_KEY,
            config=_BotoCoreConfig(
                request_checksum_calculation='when_required',
                response_checksum_validation='when_required',
            ),
        )
        # 连通性检查
        r2_client.head_bucket(Bucket=R2_BUCKET_NAME)
        logger.info(f"✅ R2 初始化成功 bucket={R2_BUCKET_NAME} endpoint={R2_ENDPOINT_URL}")
    except Exception as e:
        logger.error(f"❌ R2 初始化失败: {e}")
        USE_R2 = False
        r2_client = None


def upload_to_r2(image_bytes: bytes, object_key: str,
                 content_type: str = "image/png") -> Optional[str]:
    """
    上传字节数据到 R2。
    Returns: 公开访问 URL（R2_PUBLIC_URL/{key}），失败返回 None
    """
    if not USE_R2 or r2_client is None:
        return None
    try:
        t0 = time.time()
        r2_client.put_object(
            Bucket=R2_BUCKET_NAME,
            Key=object_key,
            Body=image_bytes,
            ContentType=content_type,
        )
        logger.info(f"✅ R2 上传成功 key={object_key} size={len(image_bytes)} 耗时={time.time()-t0:.2f}s")
        public_url = f"{R2_PUBLIC_URL.rstrip('/')}/{object_key}"
        return public_url
    except Exception as e:
        logger.error(f"❌ R2 上传失败 key={object_key}: {e}")
        logger.error(traceback.format_exc())
        return None


def download_from_r2(object_key: str) -> Optional[Tuple[bytes, str]]:
    """
    从 R2 下载对象。
    Returns: (bytes, content_type) 或 None
    """
    if not USE_R2 or r2_client is None:
        return None
    try:
        resp = r2_client.get_object(Bucket=R2_BUCKET_NAME, Key=object_key)
        data = resp["Body"].read()
        content_type = resp.get("ContentType", "image/png")
        return data, content_type
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None  # 正常缺失，不打错误
        logger.error(f"❌ R2 下载失败 key={object_key}: {e}")
        return None
    except Exception as e:
        logger.error(f"❌ R2 下载失败 key={object_key}: {e}")
        return None


def image_key(user_id: str, session_id: str, image_index: int) -> str:
    """生成图片的统一 R2 key"""
    return f"images/{user_id}/{session_id}/{image_index}.png"


def profile_key(user_id: str, session_id: str) -> str:
    """生成档案照片的统一 R2 key（session_id 形如 profile_{uuid}）"""
    return f"images/{user_id}/{session_id}/0.png"
