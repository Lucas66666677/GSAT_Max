from __future__ import annotations

from dataclasses import dataclass
import logging
from typing import Protocol

try:
    from .config import settings
except ImportError:  # pragma: no cover - direct script compatibility
    from config import settings


logger = logging.getLogger("gsat_max.email")


class EmailProvider(Protocol):
    def send_action_email(
        self,
        *,
        recipient: str,
        subject: str,
        action_token: str,
        action_url: str,
    ) -> None: ...


@dataclass(frozen=True)
class DevelopmentEmailProvider:
    """Test provider that never sends network traffic or logs raw tokens."""

    def send_action_email(
        self,
        *,
        recipient: str,
        subject: str,
        action_token: str,
        action_url: str,
    ) -> None:
        logger.info(
            "Development email accepted: recipient=%s subject=%s token_length=%s url_length=%s",
            recipient,
            subject,
            len(action_token),
            len(action_url),
        )


def get_email_provider() -> EmailProvider:
    if settings.email_provider.lower() in {"development", "test"}:
        return DevelopmentEmailProvider()
    raise RuntimeError(
        "EMAIL_PROVIDER is not configured. Add a production provider implementation."
    )
