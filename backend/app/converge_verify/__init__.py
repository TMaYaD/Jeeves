"""Converge-verify: the #553 Phase 1 pre-cutover convergence check.

Cutover tooling — **removed by #556**, together with
``spec/converge_verify/``, ``app/lib/cutover/`` and the settings entry that
reaches the screen. Nothing in the product depends on this package: it exists so
the user can satisfy themselves, on the phone that holds the only copy of their
store, that the legacy PowerSync-side local store and the legacy mirrored
Postgres tables hold the same rows before the Phase-2 reseed throws one of them
away.

Every read path here is SELECT-only by construction.
"""
