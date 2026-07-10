#!/usr/bin/env python3
"""
每日个性化 Push 通知批量发送脚本
由 cron 在固定 UTC 时间触发，每次传入时区桶名称

用法：
  python3 daily_notifications.py EDT   # 美东夏令（UTC-4）→ 本地 20:00
  python3 daily_notifications.py EST   # 美东冬令（UTC-5）→ 本地 20:00
  python3 daily_notifications.py PDT   # 美西夏令（UTC-7）→ 本地 20:00
  python3 daily_notifications.py PST   # 美西冬令（UTC-8）→ 本地 20:00
  python3 daily_notifications.py SGT   # 新加坡（UTC+8）  → 本地 20:00

crontab（/etc/cron.d/push-notifications）：
  # 夏令时期间（3月第2个周日 ~ 11月第1个周日）:
  0  0  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py EDT
  0  3  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py PDT
  # 冬令时期间（11月第1个周日 ~ 3月第2个周日）:
  # 0  1  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py EST
  # 0  4  * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py PST
  # 全年：
  0  12 * * *  ubuntu  python3 /opt/gemini-audio-service/scripts/daily_notifications.py SGT
"""
import sys
import asyncio
import logging
import os

# 设置工作目录，确保相对 import 能找到 services/
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# 时区桶 → PostgreSQL timezone 名称列表
BUCKET_TIMEZONES: dict[str, list[str]] = {
    "EDT": [
        "America/New_York", "America/Toronto", "America/Detroit",
        "America/Indiana/Indianapolis", "America/Montreal",
    ],
    "EST": [
        "America/New_York", "America/Toronto", "America/Detroit",
        "America/Indiana/Indianapolis", "America/Montreal",
    ],
    "PDT": [
        "America/Los_Angeles", "America/Vancouver", "America/Seattle",
        "America/Phoenix", "America/Tijuana",
    ],
    "PST": [
        "America/Los_Angeles", "America/Vancouver", "America/Seattle",
        "America/Phoenix", "America/Tijuana",
    ],
    "SGT": [
        "Asia/Singapore", "Asia/Shanghai", "Asia/Hong_Kong",
        "Asia/Taipei", "Asia/Kuala_Lumpur",
    ],
}


async def main(bucket: str):
    from services.notification_service import process_batch
    timezones = BUCKET_TIMEZONES.get(bucket)
    if not timezones:
        logger.error(f"Unknown bucket: {bucket}. Valid: {list(BUCKET_TIMEZONES.keys())}")
        sys.exit(1)

    logger.info(f"[Notify] Starting batch for bucket={bucket} timezones={timezones}")
    await process_batch(timezones)
    logger.info(f"[Notify] Batch complete for bucket={bucket}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    bucket = sys.argv[1].upper()
    asyncio.run(main(bucket))
