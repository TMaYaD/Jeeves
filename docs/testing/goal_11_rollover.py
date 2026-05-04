"""Goal 11 — Roll over an unfinished task to tomorrow's plan.

Drives the running emulator via uiautomator2.

Pre-conditions:
  - User signed in (local-only is fine).
  - At least 2 unclarified or already-clarified tasks visible in today's
    Daily Planning ritual (planning starts at the Review Tasks step or
    can advance into it with selectable items).
  - App is foregrounded with planning ritual ready to run, OR mid-ritual
    (the script auto-detects and proceeds from where it is).

Flow:
  1. Run today's Daily Planning. Mark at least 2 tasks "Still relevant",
     pick energy/time defaults, then pre-select / confirm at least one
     task into TODAY'S PLAN. Tap "Start Day".
  2. From /focus, tap "Begin Evening Shutdown" without completing the
     planned tasks (i.e. they remain unfinished).
  3. Step 1 "Review Your Day" → Next.
  4. Step 2 "Resolve Unfinished" → tap "Roll Over to Tomorrow" on the
     first unfinished task. Pick any disposition for the rest.
  5. Tap "Close Day" — the moon-rise animation plays and the app exits.
  6. Cold-relaunch the app. The next planning ritual is surfaced
     (focusSessionPlanningCompletion is in-memory only and resets).
  7. Drive through Review Tasks / Energy / Time again until the
     "Review Next Actions" step is visible.
  8. ASSERT: the rolled-over task title appears under "TODAY'S PLAN"
     (pre-selected via getLastClosedSessionRolloverTaskIds → preloaded
     into pendingSelectedTaskIds).

Post-state assertion is the single source of truth — if the rolled-over
task is in TODAY'S PLAN before the user has tapped "Select for today"
on it, rollover surfaced correctly.
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"


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


def _drive_planning_to_plan_step(d):
    """Walk the planning ritual from wherever we are up to step 5
    (Review Next Actions). Marks all review-step tasks "Still relevant",
    accepts default energy=Medium and time=8h."""
    # Step 2: Review Tasks — tap "Still relevant" then "Next" until the
    # review counter empties and the wizard advances.
    while _wait_desc(d, "Review Tasks", timeout=2):
        if d(descriptionContains="Still relevant").exists:
            d(descriptionContains="Still relevant").click()
            time.sleep(0.5)
        elif d(description="Next").exists and d(description="Next").info.get(
                "enabled", False):
            d(description="Next").click()
            time.sleep(1)
        else:
            time.sleep(0.5)
    # Step 3: Energy Check-in — pick Medium (centre tile).
    if _wait_desc(d, "Energy Check-in", timeout=4):
        d.click(0.5, 0.583)  # ~ (540, 1400)
        time.sleep(0.5)
        _tap_desc(d, "Next")
    # Step 4: Time Check-in — accept default 8h.
    if _wait_desc(d, "Time Check-in", timeout=4):
        _tap_desc(d, "Next")


def _resolve_unfinished_with_first_rollover(d):
    """Step 2 of evening shutdown — assign disposition to every
    unfinished task. The FIRST task gets Roll Over; remaining tasks
    cycle through Return / Defer."""
    rollover_label = "Roll Over to Tomorrow"
    leave_label    = "Return to Next Actions"
    rotation = [leave_label, rollover_label]  # second-and-on cycle
    rolled = 0
    i = 0
    while _wait_desc(d, rollover_label, timeout=3):
        if rolled == 0:
            d(descriptionContains=rollover_label).click()
            rolled += 1
        else:
            d(descriptionContains=rotation[i % len(rotation)]).click()
            i += 1
        time.sleep(0.6)
    assert rolled >= 1, "no unfinished task was rolled over"


def main():
    d = u2.connect()
    assert d.app_current()["package"] == PKG, "Jeeves not foregrounded"

    # ---------------------------------------------------------------
    # PHASE 1 — Plan today, capture the title we'll roll over.
    # ---------------------------------------------------------------
    if _wait_desc(d, "Daily Planning", timeout=2):
        _drive_planning_to_plan_step(d)
    assert _wait_desc(d, "Review Next Actions", timeout=8), \
        "did not reach step 5 (Review Next Actions)"

    # Capture the first task already in TODAY'S PLAN — this is the one
    # we'll roll over and verify carries forward.
    today_titles = [
        n.info["contentDescription"]
        for n in d.xpath('//*[@content-desc]').all()
        if n.info["contentDescription"].startswith("Triage_test_")
    ]
    assert len(today_titles) >= 1, "no Triage_test_* task in plan"
    rollover_title = today_titles[0]
    print(f"will roll over: {rollover_title}")

    # If only one task is selected, promote one PENDING REVIEW item so
    # we have at least 2 tasks in today's plan (goal pre-condition).
    if d(descriptionContains="PENDING REVIEW").exists and \
       d(descriptionContains="Select for today").exists:
        d(descriptionContains="Select for today").click()
        time.sleep(0.5)

    _tap_desc(d, "Next")
    _tap_desc(d, "Start Day", timeout=8)

    # ---------------------------------------------------------------
    # PHASE 2 — Begin Evening Shutdown without completing any task.
    # ---------------------------------------------------------------
    assert _wait_desc(d, "Today's Tasks", timeout=8), "not on /focus"
    _tap_desc(d, "Begin Evening Shutdown")
    assert _wait_desc(d, "Review Your Day"), "step 1 missing"
    _tap_desc(d, "Next")
    assert _wait_desc(d, "Resolve Unfinished"), "step 2 missing"
    _resolve_unfinished_with_first_rollover(d)
    assert _wait_desc(d, "Close Day", timeout=4), "Close Day screen missing"
    _tap_desc(d, "Close Day")

    # App exits to launcher on Close Day.
    end = time.time() + 10
    while time.time() < end:
        if d.app_current()["package"] != PKG:
            break
        time.sleep(0.5)
    assert d.app_current()["package"] != PKG, "app did not exit"

    # ---------------------------------------------------------------
    # PHASE 3 — Cold-relaunch and verify rollover surfaces.
    #
    # Because focusSessionPlanningCompletion is in-memory only, the
    # next launch re-enters the planning ritual immediately even on
    # the same calendar day. (Planning day-boundary semantics handle
    # the 'tomorrow' case for the production user.)
    # ---------------------------------------------------------------
    d.app_stop(PKG)
    time.sleep(1)
    d.app_start(PKG)
    time.sleep(4)

    if _wait_desc(d, "Daily Planning", timeout=8):
        _drive_planning_to_plan_step(d)

    assert _wait_desc(d, "Review Next Actions", timeout=10), \
        "next planning did not reach step 5"

    # ---------------------------------------------------------------
    # ASSERTION — the rolled-over task is pre-selected in TODAY'S PLAN.
    # ---------------------------------------------------------------
    today_section = d(descriptionContains="TODAY'S PLAN")
    assert today_section.exists, "TODAY'S PLAN section missing on next plan"

    titles_in_plan = []
    saw_today = False
    for n in d.xpath('//*[@content-desc]').all():
        cd = n.info["contentDescription"]
        if cd.startswith("TODAY'S PLAN"):
            saw_today = True
            continue
        if cd.startswith("PENDING REVIEW") or cd.startswith("LATER"):
            saw_today = False
            continue
        if saw_today and cd.startswith("Triage_test_"):
            titles_in_plan.append(cd)

    assert rollover_title in titles_in_plan, (
        f"rolled-over task '{rollover_title}' NOT pre-surfaced in next "
        f"plan; saw {titles_in_plan}"
    )
    print(f"PASS — '{rollover_title}' carried over into TODAY'S PLAN")


if __name__ == "__main__":
    main()
