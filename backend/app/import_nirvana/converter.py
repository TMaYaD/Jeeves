"""Convert NirvanaItem list → project tag names + TodoCreate list."""

from app.import_nirvana.schemas import NirvanaItem
from app.todos.schemas import TagInput, TodoCreate


def convert_items(
    items: list[NirvanaItem],
    existing_tag_names: set[str],
) -> tuple[list[str], list[TodoCreate]]:
    """Convert parsed Nirvana items into tag names and TodoCreate payloads.

    Returns:
        project_tag_names: names of project tags that should be created (de-duped,
            excludes those already in existing_tag_names).
        todos: TodoCreate instances ready for DB insertion.
    """
    # First pass: build project lookups
    # JSON format: nirvana UUID → project name
    id_to_project: dict[str, str] = {}
    # CSV format: project name → project name (identity; kept for clarity)
    name_to_project: dict[str, str] = {}
    all_project_names: set[str] = set()

    for item in items:
        if item.type == "project":
            all_project_names.add(item.name)
            id_to_project[item.id] = item.name
            name_to_project[item.name] = item.name

    new_project_names = [n for n in all_project_names if n not in existing_tag_names]

    # Second pass: build TodoCreate list for tasks only
    todos: list[TodoCreate] = []

    for item in items:
        if item.type != "task":
            continue

        # Resolve parent project
        project_name: str | None = None
        if item.parent_id and item.parent_id in id_to_project:
            project_name = id_to_project[item.parent_id]
        elif item.parent_name and item.parent_name in name_to_project:
            project_name = name_to_project[item.parent_name]

        # Build tag list
        tag_specs: list[str | TagInput] = []

        if project_name:
            tag_specs.append(TagInput(name=project_name, type="project"))  # type: ignore[arg-type]

        for tag_name in item.tags:
            tag_specs.append(tag_name)

        todos.append(
            TodoCreate(
                title=item.name,
                notes=item.notes,
                completed=item.completed,
                state=item.state,
                tags=tag_specs,
                due_date=item.due_date,
                time_estimate=item.time_estimate,
                energy_level=item.energy_level,
                waiting_for=item.waiting_for,
                capture_source="nirvana_import",
            )
        )

    return new_project_names, todos
