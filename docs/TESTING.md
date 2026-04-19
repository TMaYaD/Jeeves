# Testing Strategy

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document outlines the testing methodology and standards for the Jeeves project.

## Development Methodology: TDD (Top-Down)

We follow a strict Test-Driven Development (TDD) cycle in a Top-Down approach. The fundamental step before adding any new feature is to define its expected behavior via a failing test.

### Testing Hierarchy

1. **Write E2E Tests First**
   Start with end-to-end (E2E) tests that verify complete user journeys. E2E tests validate that all pieces of the system work together from the user's perspective.
   - *Workflow:* Write test that exercises the full user flow → Test fails → Implement.

2. **Write Integration Tests Second**
   Test component interactions at the boundaries (e.g., API boundaries, database access boundaries).

3. **Write Unit Tests Third**
   Test pure business logic, utilities, and parsers in complete isolation.

### Implementation Workflow

1. Write a failing test defining the expected behavior.
2. Implement minimum code to make the test pass.
3. Refactor and ensure the tests remain green.
4. Check for regressions by running the full test suite.

## Core Testing Principles

- **Test Real Behavior Only**: Avoid mocking system components whenever possible. Test code as it would run in production. If a component is too complex to test without excessive mocking, it should be redesigned.
- **Automation First**: Linter, analyzer, and the full test suite must pass locally before any commits are pushed.
- **No Unverified Work**: Code is considered incomplete until it has corresponding automated tests demonstrating its correctness.

## Stack-Specific Testing

### Frontend (Flutter)

- **Framework**: `flutter_test`.
- **E2E/Integration**: Flutter Integration Tests for on-device testing.
- **Unit/Widget**: Widget tests and standard Dart unit tests for Riverpod providers and logic.

### Backend (FastAPI)

- **Framework**: `pytest` running with `pytest-asyncio` for asynchronous tests.
- **Coverage**: `pytest-cov` to ensure critical business logic is tested.
- **Local DB**: Provide a test database (e.g., using `aiosqlite` or a testing PostgreSQL container) to run real integration tests rather than mocking the database layer.
