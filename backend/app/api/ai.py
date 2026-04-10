"""AI integration endpoints — proxies LLM calls server-side.

Keeps API keys out of the client. Uses the Anthropic Python SDK.
All endpoints are designed to be non-blocking on the critical path:
the client can submit a task optimistically and apply AI suggestions
asynchronously when the response arrives.
"""

import anthropic
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.auth.dependencies import get_current_user
from app.config import settings
from app.models.user import User

router = APIRouter(prefix="/ai", tags=["ai"])

_client: anthropic.AsyncAnthropic | None = None


def _get_client() -> anthropic.AsyncAnthropic:
    global _client
    if _client is None:
        if not settings.anthropic_api_key:
            raise HTTPException(status_code=503, detail="AI service not configured")
        _client = anthropic.AsyncAnthropic(api_key=settings.anthropic_api_key)
    return _client


class ParseRequest(BaseModel):
    input: str


class ParseResponse(BaseModel):
    title: str
    due_date: str | None = None
    list_name: str | None = None
    tags: list[str] = []
    notes: str | None = None


_PARSE_SYSTEM = """You are a task parser. Given a natural language task description,
extract structured fields and return valid JSON with keys:
title (string, required), due_date (ISO8601 string or null),
list_name (string or null), tags (array of strings), notes (string or null).
Return only the JSON object, no explanation."""


@router.post("/parse", response_model=ParseResponse)
async def parse_natural_language(
    body: ParseRequest, _: User = Depends(get_current_user)
) -> ParseResponse:
    client = _get_client()
    message = await client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=256,
        system=_PARSE_SYSTEM,
        messages=[{"role": "user", "content": body.input}],
    )
    import json

    text = message.content[0].text  # type: ignore[union-attr]
    data = json.loads(text)
    return ParseResponse(**data)


@router.get("/suggestions/{todo_id}")
async def get_suggestions(
    todo_id: str, _: User = Depends(get_current_user)
) -> dict[str, list[str]]:
    # TODO: fetch todo from DB, build prompt, return suggestions
    return {"suggestions": []}


@router.get("/summarize/{list_id}")
async def summarize_list(list_id: str, _: User = Depends(get_current_user)) -> dict[str, str]:
    # TODO: fetch todos in list, summarize
    return {"summary": ""}
