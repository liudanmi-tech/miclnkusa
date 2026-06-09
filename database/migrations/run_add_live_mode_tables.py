"""
执行 Live Mode 数据库迁移
新增表: live_turns, live_segments, live_events,
        live_speaker_mappings, live_summary_tasks, live_panel_batches
修改表: sessions（添加 Live Mode 字段）, profiles（添加声纹意愿字段）
"""
import asyncio
import os
import sys
from pathlib import Path
import asyncpg
from urllib.parse import urlparse
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

MIGRATION_FILE = Path(__file__).parent / "add_live_mode_tables.sql"

EXPECTED_TABLES = [
    "live_turns",
    "live_segments",
    "live_events",
    "live_speaker_mappings",
    "live_summary_tasks",
    "live_panel_batches",
]

EXPECTED_SESSION_COLUMNS = [
    "session_type", "card_title", "live_summary",
    "summary_status", "image_status", "skills_status",
    "cover_image_url", "gemini_token", "ws_disconnected_at",
    "ended_at", "abandon_reason",
]


def parse_database_url(url: str) -> dict:
    url = url.replace("postgresql+asyncpg://", "postgresql://")
    parsed = urlparse(url)
    return {
        "host": parsed.hostname or "localhost",
        "port": parsed.port or 5432,
        "user": parsed.username or "postgres",
        "password": parsed.password or "postgres",
        "database": parsed.path.lstrip("/") or "gemini_audio_db",
    }


async def verify_migration(conn) -> bool:
    """迁移后验证：检查所有表和字段是否存在"""
    ok = True

    # 检查新增表
    rows = await conn.fetch(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='public' AND table_name=ANY($1)",
        EXPECTED_TABLES,
    )
    existing = {r["table_name"] for r in rows}
    for t in EXPECTED_TABLES:
        if t in existing:
            logger.info(f"  ✅ 表 {t} 存在")
        else:
            logger.error(f"  ❌ 表 {t} 不存在")
            ok = False

    # 检查 sessions 新增字段
    rows = await conn.fetch(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name='sessions' AND column_name=ANY($1)",
        EXPECTED_SESSION_COLUMNS,
    )
    existing_cols = {r["column_name"] for r in rows}
    for col in EXPECTED_SESSION_COLUMNS:
        if col in existing_cols:
            logger.info(f"  ✅ sessions.{col} 存在")
        else:
            logger.error(f"  ❌ sessions.{col} 不存在")
            ok = False

    return ok


async def run_migration():
    try:
        from dotenv import load_dotenv
        load_dotenv()

        database_url = os.getenv(
            "DATABASE_URL",
            "postgresql://postgres:postgres@localhost:5432/gemini_audio_db",
        )
        db_config = parse_database_url(database_url)

        logger.info(
            f"连接数据库: {db_config['user']}@{db_config['host']}:{db_config['port']}/{db_config['database']}"
        )

        if not MIGRATION_FILE.exists():
            logger.error(f"迁移文件不存在: {MIGRATION_FILE}")
            return False

        sql_content = MIGRATION_FILE.read_text(encoding="utf-8")

        conn = await asyncpg.connect(
            host=db_config["host"],
            port=db_config["port"],
            user=db_config["user"],
            password=db_config["password"],
            database=db_config["database"],
        )

        try:
            logger.info("开始执行 Live Mode 数据库迁移...")
            await conn.execute(sql_content)
            logger.info("SQL 执行完成，开始验证...")

            ok = await verify_migration(conn)

            if ok:
                logger.info("✅ Live Mode 数据库迁移成功！")
            else:
                logger.error("❌ 迁移验证失败，请检查以上错误")
            return ok

        except Exception as e:
            error_msg = str(e).lower()
            if "already exists" in error_msg or "duplicate" in error_msg:
                logger.warning(f"⚠️ 部分对象已存在，继续验证: {e}")
                ok = await verify_migration(conn)
                return ok
            else:
                logger.error(f"❌ 数据库迁移失败: {e}")
                raise
        finally:
            await conn.close()

    except asyncpg.exceptions.InvalidPasswordError:
        logger.error("❌ 数据库密码错误")
        return False
    except asyncpg.exceptions.InvalidCatalogNameError:
        logger.error(f"❌ 数据库不存在，请检查 DATABASE_URL")
        return False
    except Exception as e:
        logger.error(f"❌ 迁移失败: {e}")
        import traceback
        logger.error(traceback.format_exc())
        return False


if __name__ == "__main__":
    success = asyncio.run(run_migration())
    sys.exit(0 if success else 1)
