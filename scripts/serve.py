"""Windows startup-task entrypoint; logs rotate outside the source tree."""
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import sys

import uvicorn

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root))
settings = json.loads((root / "data-runtime.json").read_text(encoding="utf-8-sig"))
os.environ["MDT_BASE_URL"] = settings["base_url"]
os.environ["MDT_DATA_DIR"] = settings["data_dir"]
logs = Path(settings["data_dir"]) / "logs"
logs.mkdir(parents=True, exist_ok=True)
handler = RotatingFileHandler(logs / "console.log", maxBytes=5_000_000, backupCount=3, encoding="utf-8")
handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
    logger = logging.getLogger(name)
    logger.handlers = [handler]
    logger.propagate = False
    logger.setLevel(logging.INFO)
uvicorn.run("app.main:create_app", factory=True, host="127.0.0.1", port=settings["port"], log_config=None)
