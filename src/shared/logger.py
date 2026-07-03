"""Structured JSON logging. CloudWatch Logs Insights can then query fields
directly (e.g. `filter level = "ERROR"`), which plain-text logs can't do."""

import json
import sys
from datetime import datetime, timezone


def _emit(level: str, message: str, **fields) -> None:
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "message": message,
        **fields,
    }
    print(json.dumps(record, default=str), file=sys.stdout)


def info(message: str, **fields) -> None:
    _emit("INFO", message, **fields)


def warning(message: str, **fields) -> None:
    _emit("WARNING", message, **fields)


def error(message: str, **fields) -> None:
    _emit("ERROR", message, **fields)
