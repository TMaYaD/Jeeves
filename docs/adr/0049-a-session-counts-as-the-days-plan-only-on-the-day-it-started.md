# ADR-0049: A session counts as the day's plan only on the calendar day it started

## Status

Accepted. Supersedes the second paragraph of [ADR-0020](0020-sessions-never-auto-close-anchor-day-attribution.md); the rest of ADR-0020 (sessions never auto-close, one open session at a time) stands.

## Context and decision

ADR-0020 attributed a session to the period opened by the most recent Evening Shutdown time, so a session started at 20:00 counted as the *next* day's plan and "Plan your day" stayed silent the next morning. The board owner reversed that: **a session is the day's plan only if it started on that calendar day**, open or closed, and a session started in the Evening belongs to that Evening — the next morning "Plan your day" shows at the planning time as usual. Because the old rule was the reason a left-open session still counted, Daily Planning is also **not offered while any session is open**: the owner reported planning from a banner that should never have appeared if an earlier session were open, and Evening Shutdown, which stays visible until that session is closed, is the only prompt it should get.

An Evening session's Evening Shutdown is **due at its start plus the available time chosen in planning**, never later than the next planning time; a session started before the Evening Shutdown time is still due at it. The available time is read from the preference planning already stores, so nothing is added to the session row. The owner called the due rule provisional, to be tuned after a few weeks of use. Reversing the calendar-day attribution later would change which morning shows Daily Planning for every user with an Evening session, which is why it is written down.
