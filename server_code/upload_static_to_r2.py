"""
一次性脚本：将静态 JSON 资源上传到 Cloudflare R2
用法：在服务器上执行（需要 .env 中的 R2_* 环境变量）

cd /opt/gemini-audio-service
python3 upload_static_to_r2.py
"""

import os
import sys
import json
import boto3
from pathlib import Path
from dotenv import load_dotenv

# 加载 .env
env_path = Path(__file__).parent / ".env"
if env_path.exists():
    load_dotenv(env_path)

R2_ACCESS_KEY_ID     = os.getenv("R2_ACCESS_KEY_ID") or os.getenv("OSS_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = os.getenv("R2_SECRET_ACCESS_KEY") or os.getenv("OSS_ACCESS_KEY_SECRET")
R2_ENDPOINT_URL      = os.getenv("R2_ENDPOINT_URL") or os.getenv("OSS_ENDPOINT")
R2_BUCKET_NAME       = os.getenv("R2_BUCKET_NAME") or os.getenv("OSS_BUCKET_NAME", "micink-assets")
R2_PUBLIC_URL        = os.getenv("R2_PUBLIC_URL", "https://pub-8a9e994d008c4d3e875ef722bded6ab5.r2.dev")

if not all([R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT_URL, R2_BUCKET_NAME]):
    print("❌ 缺少 R2 环境变量: R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT_URL / R2_BUCKET_NAME")
    sys.exit(1)

s3 = boto3.client(
    "s3",
    endpoint_url=R2_ENDPOINT_URL,
    aws_access_key_id=R2_ACCESS_KEY_ID,
    aws_secret_access_key=R2_SECRET_ACCESS_KEY,
    region_name="auto",
)

# 要上传的静态文件列表：(本地路径, R2 key, content-type)
STATIC_FILES = [
    (
        Path(__file__).parent.parent / "doc" / "genz_topics.json",
        "static/genz_topics.json",
        "application/json",
    ),
]

for local_path, r2_key, content_type in STATIC_FILES:
    if not local_path.exists():
        print(f"⚠️  文件不存在，跳过: {local_path}")
        continue

    data = local_path.read_bytes()

    # 验证 JSON 合法性
    try:
        json.loads(data)
    except json.JSONDecodeError as e:
        print(f"❌ JSON 格式错误: {local_path} — {e}")
        continue

    print(f"⬆️  上传 {local_path.name} → s3://{R2_BUCKET_NAME}/{r2_key} ({len(data)} bytes)")
    s3.put_object(
        Bucket=R2_BUCKET_NAME,
        Key=r2_key,
        Body=data,
        ContentType=content_type,
        CacheControl="public, max-age=86400",   # 浏览器/CDN 缓存 1 天
    )

    public_url = f"{R2_PUBLIC_URL.rstrip('/')}/{r2_key}"
    print(f"✅ 上传成功: {public_url}")

print("\n完成。")
