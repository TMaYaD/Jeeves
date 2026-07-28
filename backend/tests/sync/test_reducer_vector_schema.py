"""Schema guards over the frozen reducer vectors.

The Dart reducer is the only executable consumer of ``reducer_v1_vectors.json``
today, but the Python generator writes it — so the two sides have to agree on
the *shape* of a case, not just on its bytes.  These tests are that agreement:
they fail if the generator emits a key the Dart runner would silently ignore,
or drops one it depends on.

The #550 additions are ``permute`` (apply the ops in every order and expect the
same reduced state), ``expected_clocks`` (the stored per-field HLC, which a
values-only case cannot observe) and ``strategy_overrides`` (a preference key's
merge strategy, for keys with no production registration).
"""

from __future__ import annotations

from typing import Any

from tests.sync.vectors import reducer_vectors

CASE_REQUIRED_KEYS = {"name", "note", "ops", "expected_entities", "expected_quarantine_reasons"}
CASE_OPTIONAL_KEYS = {"permute", "expected_clocks", "strategy_overrides"}
KNOWN_STRATEGIES = {"lww", "max_timestamp_value", "set_merge"}


def _cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = reducer_vectors()["cases"]
    return cases


def test_the_case_schema_is_documented() -> None:
    document = reducer_vectors()
    assert "$case_schema" in document
    for key in sorted(CASE_OPTIONAL_KEYS):
        assert key in document["$case_schema"], f"{key} is undocumented"


def test_every_case_carries_only_known_keys() -> None:
    for case in _cases():
        keys = set(case)
        assert keys >= CASE_REQUIRED_KEYS, f"{case['name']} is missing {CASE_REQUIRED_KEYS - keys}"
        unknown = keys - CASE_REQUIRED_KEYS - CASE_OPTIONAL_KEYS
        assert not unknown, f"{case['name']} carries unknown keys {unknown}"


def test_permutation_flagged_cases_are_runnable_in_any_order() -> None:
    """A permuted case must not depend on arrival order for its verdict.

    Quarantine is a per-arrival fact and the runner only asserts it in file
    order, so a permuted case that also expects a quarantine would be asserting
    something the permutations cannot check.  Cases are also kept small — the
    runner expands them factorially.
    """
    for case in _cases():
        if not case.get("permute"):
            continue
        assert case["expected_quarantine_reasons"] == [], (
            f"{case['name']} is permuted but expects a quarantine"
        )
        assert len(case["ops"]) <= 4, f"{case['name']} permutes {len(case['ops'])} ops"


def test_expected_clocks_match_the_entities_they_describe() -> None:
    for case in _cases():
        clocks = case.get("expected_clocks")
        if clocks is None:
            continue
        for collection, entities in clocks.items():
            assert collection in case["expected_entities"], (
                f"{case['name']} pins clocks for unlisted collection {collection}"
            )
            for entity_id, fields in entities.items():
                assert fields, f"{case['name']}/{entity_id} pins an empty clock map"
                for field, hlc in fields.items():
                    assert isinstance(hlc, list) and len(hlc) == 3, (
                        f"{case['name']}/{entity_id}/{field} is not an [wall, counter, member]"
                    )
                    wall_ms, counter, member_id_hex = hlc
                    assert isinstance(wall_ms, int)
                    assert isinstance(counter, int)
                    assert isinstance(member_id_hex, str) and len(member_id_hex) == 32
                    assert member_id_hex == member_id_hex.lower()


def test_strategy_overrides_name_known_strategies() -> None:
    for case in _cases():
        for key, strategy in (case.get("strategy_overrides") or {}).items():
            assert strategy in KNOWN_STRATEGIES, f"{case['name']} overrides {key} to {strategy}"


def test_the_lattice_cases_are_present() -> None:
    """The merge-strategy coverage #550 froze, by name.

    Losing one of these to a refactor of the generator would silently drop the
    property it pins, so they are asserted by name rather than by count.
    """
    names = {case["name"] for case in _cases()}
    required = {
        "junction_revive_after_unassign",
        "junction_unassign_is_a_tombstone_not_absence",
        "max_timestamp_value_stale_later_value_wins",
        "max_timestamp_value_instant_tie_breaks_on_canonical_bytes",
        "max_timestamp_value_unparseable_loses_to_parseable",
        "max_timestamp_value_all_unparseable_orders_by_bytes",
        "max_timestamp_value_clear_then_later_resnooze_revives",
        "max_timestamp_value_stale_clear_loses_to_resnooze",
        "max_timestamp_value_clear_then_earlier_resnooze_keeps_preclear_floor",
        "max_timestamp_value_three_op_associativity",
        "set_merge_unions_concurrent_additions",
        "set_merge_three_op_associativity",
        "set_merge_unsorted_first_write_is_canonical_and_replay_safe",
        "strategy_selection_falls_back_to_lww_without_a_key",
        "strategy_selection_reads_the_stored_key",
    }
    assert required <= names, f"missing lattice vectors: {sorted(required - names)}"
