#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
清除指定用户的订阅记录
在服务器 ~/gemini-audio-service/ 目录下执行：
    python3 clear_subscription.py
"""

import asyncio
import sys
import os

os.chdir(os.path.expanduser('~/gemini-audio-service'))
sys.path.insert(0, os.getcwd())

TARGET_EMAIL = "2643651600@qq.com"


async def main():
    from database.connection import AsyncSessionLocal
    from sqlalchemy import select
    from models import User

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(User).where(User.email == TARGET_EMAIL))
        user = result.scalar_one_or_none()

        if user is None:
            print(f"❌ 未找到邮箱为 {TARGET_EMAIL} 的用户")
            return

        print(f"✅ 找到用户: id={user.id}, email={user.email}")
        print(f"   当前 subscription_tier={user.subscription_tier}")
        print(f"   当前 subscription_expires_at={user.subscription_expires_at}")
        print(f"   当前 apple_original_transaction_id={user.apple_original_transaction_id}")

        user.subscription_tier = "free"
        user.subscription_expires_at = None
        user.apple_original_transaction_id = None

        await db.commit()

        print("✅ 订阅记录已清除：tier=free, expires_at=NULL, transaction_id=NULL")


asyncio.run(main())
