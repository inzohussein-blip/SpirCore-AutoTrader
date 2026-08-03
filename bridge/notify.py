"""
SpirCore-AutoTrader :: Notifications

Sends short alerts to Telegram and/or email on notable events (executions,
risk blocks, closed trades). Standard-library only (urllib + smtplib) so it
adds no dependencies and runs anywhere.

Design rules
  * Disabled by default: with no credentials configured, send() is a no-op.
  * Every channel is wrapped in try/except -- a notification failure must
    NEVER interfere with trading.
"""
from __future__ import annotations

import json
import smtplib
import urllib.parse
import urllib.request
from email.message import EmailMessage

from config import settings


def _telegram(text: str) -> None:
    if not (settings.tg_token and settings.tg_chat_id):
        return
    url = f"https://api.telegram.org/bot{settings.tg_token}/sendMessage"
    data = urllib.parse.urlencode({
        "chat_id": settings.tg_chat_id,
        "text": text,
        "disable_web_page_preview": "true",
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=8) as r:
            r.read()
    except Exception as exc:  # noqa: BLE001 - never let notifications break trading
        print(f"[notify] telegram failed: {exc}")


def _email(subject: str, text: str) -> None:
    if not (settings.smtp_host and settings.email_to):
        return
    msg = EmailMessage()
    msg["From"] = settings.email_from or settings.smtp_user or "spircore@localhost"
    msg["To"] = settings.email_to
    msg["Subject"] = subject
    msg.set_content(text)
    try:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as s:
            if settings.smtp_tls:
                s.starttls()
            if settings.smtp_user:
                s.login(settings.smtp_user, settings.smtp_password)
            s.send_message(msg)
    except Exception as exc:  # noqa: BLE001
        print(f"[notify] email failed: {exc}")


def enabled() -> bool:
    return bool((settings.tg_token and settings.tg_chat_id)
                or (settings.smtp_host and settings.email_to))


def send(text: str, subject: str = "SpirCore alert") -> None:
    """Fan out one message to all configured channels (no-op if none)."""
    if not enabled():
        return
    _telegram(f"🔔 {text}")
    _email(subject, text)
