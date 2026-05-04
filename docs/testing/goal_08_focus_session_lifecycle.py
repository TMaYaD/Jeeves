"""Goal 8 — Focus session lifecycle: Start, Pause, Resume, Complete.

Drives the running emulator via uiautomator2.
Pre-conditions:
  - Daily Planning has been completed for today with at least one task
    selected ("Polish onboarding deck" in this run).
  - User is on /focus showing today's tasks.

Each lifecycle transition is asserted by content-desc strings dumped from
the active focus screen / focus list.
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"
TASK_TITLE = "Polish onboarding deck"


def _desc_present(d, text, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        if d(description=text).exists:
            return True
        time.sleep(0.3)
    return False


def main():
    d = u2.connect()
    assert d.app_current()["package"] == PKG, "Jeeves not foregrounded"

    # --- 1. Focus list shows the planned task with a Start affordance.
    assert _desc_present(d, "Today's Tasks"), "Not on Focus screen"
    assert _desc_present(d, TASK_TITLE), f"Planned task '{TASK_TITLE}' missing"
    start_btn = d(description="Start")
    assert start_btn.exists, "Start button not visible for planned task"

    # --- 2. Start focus session -> Active focus screen with sprint timer.
    start_btn.click()
    assert _desc_present(d, TASK_TITLE, timeout=4), "Active screen header missing"
    # Jeeves opening phrase — sprint just begun.
    assert _desc_present(d, "Just begun, sir."), "Sprint did not start"
    # Sprint countdown — duration banner like 19:54 (just under 20m default).
    sprint_label = next(
        (n for n in d.xpath('//*[@content-desc]').all()
         if n.attrib.get('content-desc', '').startswith(('19:', '20:'))),
        None,
    )
    assert sprint_label is not None, "Sprint countdown not visible"

    # --- 3. Pause (sprint -> early break). The pause icon button is leftmost
    # in the action bar; tapping during a sprint calls pauseSprint() which
    # transitions to break with the configured break duration (3m default).
    d.click(0.186, 0.921)  # ~ (201, 2211) on 1080x2400
    assert _desc_present(d, "Perhaps a brief constitutional, sir.",
                         timeout=4), "Did not transition to break (paused)"
    break_label = next(
        (n for n in d.xpath('//*[@content-desc]').all()
         if n.attrib.get('content-desc', '').startswith(('02:', '03:'))),
        None,
    )
    assert break_label is not None, "Break countdown not visible after pause"

    # --- 4. Resume (skip break -> next sprint). Same button slot, now play.
    d.click(0.186, 0.921)
    assert _desc_present(d, "Just begun, sir.",
                         timeout=4), "Did not resume into a fresh sprint"

    # --- 5. Complete the task via Done.
    d.click(0.500, 0.921)  # ~ (540, 2211)
    # Returns to /focus, task no longer has a Start button, and the
    # callout switches to "End Session" because all planned tasks are done.
    assert _desc_present(d, "Today's Tasks", timeout=5), "Did not return to Focus list"
    assert d(description=TASK_TITLE).exists, "Task row missing after completion"
    assert not d(description="Start").exists, \
        "Start button still present — task was not marked done"
    assert _desc_present(d, "End Session"), \
        "End Session CTA not shown — completion not recognised"

    print("Goal 8 — focus session lifecycle PASSED")


if __name__ == "__main__":
    main()
