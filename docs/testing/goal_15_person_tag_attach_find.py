"""Goal 15 — Attach a person tag (@alice) and find every task involving them.

Drives the running emulator via uiautomator2.

Pre-conditions:
  - Emulator at 1080x2400.
  - User signed in (local-only is fine).
  - App foregrounded on /inbox (script auto-launches).

Background (per project memory): People are Tags — `Tag(type='person')`,
managed by the same Tag infrastructure as contexts. The natural "find all
tasks involving Alice" surface is the Waiting For list, which groups
todos by person-tag (see waitingListGroupedProvider). Per Goal 14
findings, tag chips/lists only count tasks where `clarified = 1`, so
items must go through the clarification ritual before they surface.

Flow:
  1. Capture two inbox items ("G15_Task_A_<n>", "G15_Task_B_<n>").
  2. Open drawer → Focus → "Plan the Day".
  3. For each Clarify-Inbox item, tap PROCESS TO → "Waiting For",
     then in the PersonTagPickerSheet:
       a) On the first item, tap "Add person", type "alice", tap Add.
       b) On the second item, tick the existing "alice" row.
     Tap "Done" — `processInboxItem` is invoked via `onAfterConfirm`.
  4. Step through Energy / Time / Today's Plan to finish the ritual.
  5. Open drawer → Waiting For.
  6. ASSERT both items appear under the "alice" section header.

The asserted invariant: a single person-tag yields a single grouped
section that contains every task with that tag attached, regardless of
which task you started from.
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"
PERSON = "alice"
SUFFIX = str(int(time.time()) % 100000)
TITLES = [f"G15_Task_A_{SUFFIX}", f"G15_Task_B_{SUFFIX}"]


def tap(d, x, y, wait=0.8):
    d.click(x, y)
    time.sleep(wait)


def capture(d, title):
    # Quick-add EditText in inbox header. uiautomator2 occasionally needs a
    # nudge before xpath is ready right after app_start, so wait+retry.
    for _ in range(5):
        if d.xpath('//*[@hint="What\'s on your mind?"]').exists:
            break
        time.sleep(1.0)
    d.xpath('//*[@hint="What\'s on your mind?"]').click()
    time.sleep(0.4)
    d.send_keys(title)
    time.sleep(0.3)
    d(description="Add").click()
    time.sleep(1.0)
    assert d(descriptionContains=title).exists or \
        d(textContains=title).exists, f"capture failed for {title}"


def clarify_to_waiting(d, person, create_person):
    """Inside Clarify Inbox, route current item to Waiting For/<person>."""
    assert d(description="Clarify Inbox").exists, "not on Clarify Inbox step"
    # Reveal the PROCESS TO buttons; same swipe as goal 13.
    d.swipe(540, 1800, 540, 800)
    time.sleep(0.4)
    d(descriptionContains="Waiting For").click()
    time.sleep(1.5)
    # PersonTagPickerSheet is now open.
    if create_person:
        d(descriptionContains="Add person").click()
        time.sleep(0.7)
        d.send_keys(person)
        time.sleep(0.3)
        d(description="Add").click()
        time.sleep(0.8)
    else:
        # Tick the existing alice row. The CheckboxListTile renders as an
        # android.widget.CheckBox with content-desc=<name>, no text.
        row = d(descriptionContains=person, className="android.widget.CheckBox")
        assert row.exists, f"existing person '{person}' not found in picker"
        row.click()
        time.sleep(0.4)
    d(description="Done").click()
    time.sleep(2.0)


def main():
    d = u2.connect()
    d.app_stop(PKG)
    d.app_start(PKG)
    time.sleep(4)

    # 1. Capture both inbox items.
    for t in TITLES:
        capture(d, t)

    # 2. Open drawer → Focus → Plan the Day.
    tap(d, 105, 422, wait=1.0)
    d(description="Focus").click()
    time.sleep(1.5)
    d(description="Plan the Day").click()
    time.sleep(2.0)

    # 3. Clarify both items to Waiting For/alice.
    # Process all inbox items: ours go to Waiting For; any pre-existing
    # items get pushed to Next Action so the step advances cleanly.
    first = True
    while d(description="Clarify Inbox").exists:
        # Find which title is showing — only ours go to alice.
        ours = any(d(textContains=t).exists for t in TITLES)
        if ours:
            clarify_to_waiting(d, PERSON, create_person=first)
            first = False
        else:
            # Unrelated leftovers: push to Next Action.
            d.swipe(540, 1800, 540, 800)
            time.sleep(0.3)
            d(description="Next Action").click()
            time.sleep(1.5)

    # 4. Walk through remaining steps. The ritual ends on the "Today's
    #    Schedule" step with a "Start Day" button that exits planning.
    if d(descriptionContains="Medium").exists:
        d(descriptionContains="Medium").click()
        time.sleep(0.4)
    for _ in range(8):
        if d(description="Start Day").exists:
            d(description="Start Day").click()
            time.sleep(2.0)
            break
        for cta in ("Next", "Continue", "Finish"):
            if d(description=cta).exists:
                d(description=cta).click()
                time.sleep(1.2)
                break
        else:
            time.sleep(0.5)
    time.sleep(1.0)

    # 5. Drawer → Waiting For. The Focus screen places the hamburger at the
    #    top-left (~105, 170) — different from the inbox (~105, 422). The
    #    icon has no content-desc, so use coords.
    tap(d, 105, 170, wait=1.0)
    d(descriptionContains="Waiting For").click()
    time.sleep(1.5)

    # 6. Assert section header + both items present.
    assert d(textContains=PERSON).exists or \
        d(descriptionContains=PERSON).exists, \
        f"section header '{PERSON}' missing from Waiting For list"
    for t in TITLES:
        assert d(textContains=t).exists or d(descriptionContains=t).exists, \
            f"task '{t}' missing from Waiting For/{PERSON}"

    print(f"Goal 15 PASSED — both tasks surface under @{PERSON} in Waiting For")


if __name__ == "__main__":
    main()
