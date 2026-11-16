"""Share the audited fresh-database migration policy with standalone PG runners."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/audit"))

from run_database_regression import partition_fresh_migrations

__all__ = ["partition_fresh_migrations"]
