"""Runtime configuration — everything comes from environment variables so the
same code runs in Lambda, tests, and locally without edits."""

import os


def table_name() -> str:
    return os.environ["TABLE_NAME"]


def required_tags() -> list[str]:
    raw = os.environ.get("REQUIRED_TAGS", "Owner,Environment,CostCenter")
    return [t.strip() for t in raw.split(",") if t.strip()]


def cpu_idle_threshold() -> float:
    return float(os.environ.get("CPU_IDLE_THRESHOLD", "5.0"))


def lookback_days() -> int:
    return int(os.environ.get("LOOKBACK_DAYS", "7"))


def snapshot_age_days() -> int:
    return int(os.environ.get("SNAPSHOT_AGE_DAYS", "90"))
