"""Minimal Sync Server — content-blind op log (ADR-0026, ADR-0027, ADR-0028).

The server stores and transports opaque envelopes.  It parses the fixed-width
v1 header to populate index columns and to run its content-blind authorization
checks, and it never looks at a body.  Domain schema, reduction and conflict
resolution all live on the client.
"""
