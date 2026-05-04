"""Goal 13 — Someday/Maybe round trip.

Drives the running emulator via uiautomator2.

Pre-conditions:
  - Emulator at 1080x2400.
  - User signed in (local-only is fine).
  - App foregrounded on /inbox (or any shell route — script auto-navigates).

Flow:
  1. Capture an inbox item ("RoundtripTask_G13").
  2. Open drawer → Focus → "Plan the Day" (Daily Planning ritual).
  3. In step 1 "Clarify Inbox", scroll to the PROCESS TO section and tap
     "Maybe". Item moves out of inbox; ritual advances to next step.
  4. Back out of planning. Open drawer → "Maybe" inventory.
  5. ASSERT: "RoundtripTask_G13" is visible in the Maybe list.
  6. Tap the task to open task detail. Tap the status pill.
  7. In the status sheet, tap "Next" (or whichever affordance restores the
     intent to next).  This is the resurrection step.
  8. Open drawer → Next Actions.
  9. ASSERT: "RoundtripTask_G13" is visible in Next Actions.

Note (2026-05-03 manual run): The status sheet for a Maybe item only
exposes "Waiting For ›", "Done", and "Trash" — there is no direct
"Next Action" / restore tile (see widgets/task_status_row.dart). The
resurrection affordance is missing. This script asserts the desired
behaviour and will fail until the affordance lands; treat the failure
in step 7/9 as the bug signal.
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"
TITLE = "RoundtripTask_G13"


def main():
    d = u2.connect()
    d.app_stop(PKG)
    d.app_start(PKG)
    time.sleep(4)

    # 1. Capture inbox item
    d.xpath('//*[@hint="What\'s on your mind?"]').click()
    d.send_keys(TITLE)
    d(description="Add").click()
    time.sleep(1)
    assert d(descriptionContains=TITLE).exists, "inbox item not captured"

    # 2. Open drawer → Focus → Plan the Day
    d.click(105, 422)  # hamburger (NAF, no a11y label)
    time.sleep(1)
    d(description="Focus").click()
    time.sleep(1.5)
    d(description="Plan the Day").click()
    time.sleep(2)

    # 3. Clarify Inbox → Maybe
    assert d(description="Clarify Inbox").exists, "not on Clarify Inbox step"
    d.swipe(540, 1800, 540, 800)  # reveal Maybe button below the fold
    time.sleep(0.5)
    d(description="Maybe").click()
    time.sleep(1.5)

    # 4. Exit planning ritual back to shell. Use system back; if app dies,
    #    cold-relaunch (planning state is in-memory).
    d.press("back")
    time.sleep(1)
    if not d(description="Inbox").exists:
        d.app_start(PKG)
        time.sleep(4)

    # 5. Drawer → Maybe → assert visible
    d.click(105, 422)
    time.sleep(1)
    d(description="Maybe").click()
    time.sleep(1.5)
    assert d(textContains=TITLE).exists or d(descriptionContains=TITLE).exists, \
        f"task '{TITLE}' missing from Maybe list"

    # 6. Open task detail; tap status pill
    d(textContains=TITLE).click()
    time.sleep(1)
    d(description="Someday").click()  # status pill label for Maybe items
    time.sleep(0.8)

    # 7. Resurrect: tap Next (currently missing — see top-of-file note)
    assert d(text="Next").exists, \
        "RESURRECTION AFFORDANCE MISSING: status sheet for Maybe item " \
        "exposes Waiting For/Done/Trash but no Next/Restore tile"
    d(text="Next").click()
    time.sleep(1)

    # 8. Drawer → Next Actions
    d.press("back")
    time.sleep(0.5)
    d.click(105, 422)
    time.sleep(1)
    d(description="Next Actions").click()
    time.sleep(1.5)

    # 9. Assert visible in Next Actions
    assert d(textContains=TITLE).exists, \
        f"task '{TITLE}' missing from Next Actions after resurrection"

    print("Goal 13 OK: round-tripped via Someday/Maybe.")


if __name__ == "__main__":
    main()
