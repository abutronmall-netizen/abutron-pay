from __future__ import annotations
from dataclasses import dataclass
import os
import re
from pathlib import Path

def _b(name: str, default: bool=False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in {"1","true","yes","on"}

def _i(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default

def _f(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default

@dataclass(frozen=True)
class Settings:
    bind: str
    port: int
    poll_seconds: int
    rc1_08_url: str
    jarvis_api_token: str
    api_token: str
    db_path: str
    audit_path: str
    severities: tuple[str, ...]
    telegram_enabled: bool
    telegram_bot_token: str
    telegram_chat_id: str
    whatsapp_enabled: bool
    whatsapp_access_token: str
    whatsapp_phone_number_id: str
    whatsapp_recipient: str
    meta_graph_version: str
    whatsapp_mode: str
    whatsapp_template_name: str
    whatsapp_template_language: str
    whatsapp_verify_token: str
    meta_app_secret: str
    max_attempts: int
    telegram_min_interval: float
    whatsapp_min_interval: float
    burst_limit: int
    burst_window_seconds: int

    @classmethod
    def from_env(cls) -> "Settings":
        sev = tuple(x.strip().upper() for x in os.getenv("RC1_09_ALERT_SEVERITIES","HIGH,CRITICAL").split(",") if x.strip())
        return cls(
            bind=os.getenv("RC1_09_BIND","127.0.0.1"),
            port=_i("RC1_09_PORT",8789),
            poll_seconds=max(5,_i("RC1_09_POLL_SECONDS",15)),
            rc1_08_url=os.getenv("RC1_08_URL","http://127.0.0.1:8788").rstrip("/"),
            jarvis_api_token=os.getenv("JARVIS_API_TOKEN","").strip(),
            api_token=os.getenv("RC1_09_API_TOKEN", os.getenv("JARVIS_API_TOKEN","")).strip(),
            db_path=os.getenv("RC1_09_DB", r"C:\Abutron\Jarvis\data\rc1_09_notifications.db"),
            audit_path=os.getenv("RC1_09_AUDIT", r"C:\Abutron\Jarvis\logs\rc1_09_notifications.jsonl"),
            severities=sev,
            telegram_enabled=_b("RC1_09_TELEGRAM_ENABLED",False),
            telegram_bot_token=os.getenv("RC1_09_TELEGRAM_BOT_TOKEN","").strip(),
            telegram_chat_id=os.getenv("RC1_09_TELEGRAM_CHAT_ID","").strip(),
            whatsapp_enabled=_b("RC1_09_WHATSAPP_ENABLED",False),
            whatsapp_access_token=os.getenv("RC1_09_WHATSAPP_ACCESS_TOKEN","").strip(),
            whatsapp_phone_number_id=os.getenv("RC1_09_WHATSAPP_PHONE_NUMBER_ID","").strip(),
            whatsapp_recipient=re.sub(r"\D","",os.getenv("RC1_09_WHATSAPP_RECIPIENT","")),
            meta_graph_version=os.getenv("RC1_09_META_GRAPH_VERSION","").strip(),
            whatsapp_mode=os.getenv("RC1_09_WHATSAPP_MODE","template").strip().lower(),
            whatsapp_template_name=os.getenv("RC1_09_WHATSAPP_TEMPLATE_NAME","abutron_system_alert").strip(),
            whatsapp_template_language=os.getenv("RC1_09_WHATSAPP_TEMPLATE_LANGUAGE","en_US").strip(),
            whatsapp_verify_token=os.getenv("RC1_09_WHATSAPP_VERIFY_TOKEN","").strip(),
            meta_app_secret=os.getenv("RC1_09_META_APP_SECRET","").strip(),
            max_attempts=max(1,_i("RC1_09_MAX_ATTEMPTS",5)),
            telegram_min_interval=max(0.1,_f("RC1_09_TELEGRAM_MIN_INTERVAL",1.0)),
            whatsapp_min_interval=max(0.1,_f("RC1_09_WHATSAPP_MIN_INTERVAL",1.0)),
            burst_limit=max(1,_i("RC1_09_BURST_LIMIT",20)),
            burst_window_seconds=max(30,_i("RC1_09_BURST_WINDOW_SECONDS",300)),
        )

    def validate(self, require_channels: bool=False) -> list[str]:
        errors: list[str] = []
        if self.bind != "127.0.0.1":
            errors.append("RC1-09 must bind to 127.0.0.1")
        if not self.jarvis_api_token:
            errors.append("JARVIS_API_TOKEN is required to read RC1-08")
        if require_channels and not (self.telegram_enabled or self.whatsapp_enabled):
            errors.append("At least one notification channel must be enabled")
        if self.telegram_enabled:
            if not self.telegram_bot_token:
                errors.append("Telegram bot token missing")
            if not re.fullmatch(r"-?\d+", self.telegram_chat_id or ""):
                errors.append("Telegram chat ID must be numeric (no @username)")
        if self.whatsapp_enabled:
            if not self.whatsapp_access_token:
                errors.append("WhatsApp access token missing")
            if not self.whatsapp_phone_number_id:
                errors.append("WhatsApp phone number ID missing")
            if not self.whatsapp_recipient:
                errors.append("WhatsApp recipient missing")
            if not self.meta_graph_version:
                errors.append("Meta Graph API version missing")
            if self.whatsapp_mode not in {"template","text"}:
                errors.append("WhatsApp mode must be template or text")
            if self.whatsapp_mode == "template" and not self.whatsapp_template_name:
                errors.append("WhatsApp template name missing")
        return errors

def load_env_file(path: str | Path, override: bool=False) -> None:
    p = Path(path)
    if not p.exists():
        return
    for raw in p.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k,v = line.split("=",1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if override or k not in os.environ:
            os.environ[k] = v
