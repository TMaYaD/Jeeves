"""Goal 9 — End-of-day Session Review (Evening Shutdown ritual).

Drives the running emulator via uiautomator2.

Pre-conditions:
  - User is signed in (local-only is fine), on /focus.
  - Today's plan has at least one INCOMPLETE task in the active focus session
    (i.e. the focus screen shows "Begin Evening Shutdown" CTA, not the
    all-clean "End Session" CTA).

Flow:
  1. From /focus → tap "Begin Evening Shutdown".
  2. Step 1 "Review Your Day" → tap Next.
  3. Step 2 "Resolve Unfinished" → for each unfinished task, pick a
     disposition (Roll Over / Return to Next Actions / Defer).
  4. Step 3 "Close Day" → tap Close Day; the moon-rise animation plays
     and the app process exits.
  5. Re-launch and verify the shutdown banner has stood down (post-state).
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"

# Disposition names as they appear in the resolution buttons.
ROLL_OVER = "Roll Over to Tomorrow"
LEAVE     = "Return to Next Actions"
MAYBE     = "Defer until a later day"


def _wait_desc(d, text, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if d(descriptionContains=text).exists:
            return True
        time.sleep(0.3)
    return False


def _tap_desc(d, text, timeout=8):
    assert _wait_desc(d, text, timeout), f"could not find '{text}'"
    d(descriptionContains=text).click()


def main():
    d = u2.connect()
    assert d.app_current()["package"] == PKG, "Jeeves not foreground"

    # ---- 1. Begin Evening Shutdown from /focus ----
    assert _wait_desc(d, "Today's Tasks"), "not on /focus"
    assert _wait_desc(d, "Begin Evening Shutdown"), \
        "no incomplete-task CTA — preconditions not met"
    _tap_desc(d, "Begin Evening Shutdown")

    # ---- 2. Step 1: Completed Review ----
    assert _wait_desc(d, "Review Your Day"), "step 1 header missing"
    assert _wait_desc(d, "Step 1 of 2"), "step indicator missing"
    _tap_desc(d, "Next")

    # ---- 3. Step 2: Resolve Unfinished, one disposition per task ----
    assert _wait_desc(d, "Resolve Unfinished"), "step 2 header missing"
    assert _wait_desc(d, "Step 2 of 2"), "step indicator missing"

    # Disposition rotation — assigns each unfinished task in turn.
    rotation = [ROLL_OVER, LEAVE, MAYBE]
    i = 0
    # Loop until the resolution buttons disappear (last task resolved).
    while _wait_desc(d, ROLL_OVER, timeout=2):
        choice = rotation[i % len(rotation)]
        i += 1
        _tap_desc(d, choice)
        time.sleep(0.6)
    assert i >= 1, "no unfinished tasks were resolved"
    print(f"resolved {i} task(s)")

    # ---- 4. Close Day ----
    assert _wait_desc(d, "I shall dim the lights"), "Close Day screen missing"
    _tap_desc(d, "Close Day")

    # The moon-rise animation runs ~3s, then the app exits to the launcher.
    end = time.time() + 10
    while time.time() < end:
        if d.app_current()["package"] != PKG:
            break
        time.sleep(0.5)
    assert d.app_current()["package"] != PKG, "app did not exit on Close Day"

    # ---- 5. Verify post-state by relaunching ----
    d.app_start(PKG)
    time.sleep(3)
    # The shutdown banner should be stood down for today; the focus / inbox
    # screen should not surface "Begin Evening Shutdown" again. After a
    # successful shutdown the next-day planning kicks in, so we either land
    # on Inbox or on Daily Planning — both are valid post-states.
    assert _wait_desc(d, "Inbox") or _wait_desc(d, "Daily Planning"), \
        "did not return to a sane post-shutdown screen"
    assert not d(descriptionContains="Begin Evening Shutdown").exists, \
        "shutdown CTA still showing after Close Day"

    print("Goal 9 PASS")


if __name__ == "__main__":
    main()
