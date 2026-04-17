"""Shared utilities for the todos feature."""

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.todos.models import Tag
from app.todos.schemas import TagInput


def _infer_tag_type(name: str) -> str:
    return "context" if name.startswith("@") else "label"


async def resolve_tags(
    tag_specs: list[str | TagInput],
    user_id: str,
    db: AsyncSession,
) -> list[Tag]:
    """Return Tag ORM objects for the given specs, creating any that don't exist yet.

    Each spec is either:
    - a plain string: type is inferred from name ('context' if '@' prefix, else 'label')
    - a TagInput: explicit name + type

    At most one tag of type='project' may be in the returned list.
    """
    if not tag_specs:
        return []

    pairs: list[tuple[str, str]] = []
    project_count = 0
    for spec in tag_specs:
        if isinstance(spec, str):
            tag_type = _infer_tag_type(spec)
            pairs.append((spec, tag_type))
        else:
            pairs.append((spec.name, spec.type.value))
        if pairs[-1][1] == "project":
            project_count += 1

    if project_count > 1:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="A todo may only have one project tag.",
        )

    names = [name for name, _ in pairs]
    result = await db.execute(select(Tag).where(Tag.user_id == user_id, Tag.name.in_(names)))
    existing: dict[str, Tag] = {tag.name: tag for tag in result.scalars().all()}

    tags: list[Tag] = []
    for name, tag_type in pairs:
        if name in existing:
            tag = existing[name]
            if tag.type != tag_type:
                tag.type = tag_type
            tags.append(tag)
        else:
            new_tag = Tag(name=name, type=tag_type, user_id=user_id)
            db.add(new_tag)
            tags.append(new_tag)

    return tags
