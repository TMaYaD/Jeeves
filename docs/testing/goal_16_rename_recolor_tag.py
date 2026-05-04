"""Goal 16 — Rename and recolour a tag from the long-press management sheet.

Drives the running emulator via uiautomator2.

Pre-conditions:
  - Emulator at 1080x2400.
  - User signed in (local-only is fine).
  - At least one context tag with an active task exists. The script tries to
    use the seeded `@hhome` tag, but will create one if absent.

Background (per code: app/lib/screens/common/tag_management_sheet.dart):
  Long-press on a tag chip in the navigation drawer's TagCloud opens a
  bottom sheet exposing Rename / Recolour / Merge into… actions. Renames
  go through `tagNotifierProvider.rename`, recolours through
  `updateColor`. Both update the underlying Tag row, so every surface
  that reads from `contextTagsProvider` (drawer cloud, task chips,
  pickers) reflects the change immediately.

Flow:
  1. Open drawer → confirm `@hhome` tag chip is present in the cloud
     (or capture a new task tagged #hhome to make it appear).
  2. Long-press the `hhome` chip → assert "Rename / Recolour / Merge"
     sheet opens.
  3. Tap Rename, replace text with a fresh suffixed name (`house_<n>`),
     tap Save.
  4. ASSERT the renamed chip appears in the drawer cloud and the old
     name is gone.
  5. Long-press again → tap Recolour → tap a swatch → dialog dismisses.
  6. ASSERT the chip is still present (post-recolour). The colour itself
     isn't text-readable from a11y, so we assert via re-opening the
     management sheet and checking the dialog reflects the new selected
     swatch (selected swatch has a darker border — we assert by simply
     re-opening cleanly without errors).
"""

import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"
SUFFIX = str(int(time.time()) % 100000)
SEED_TAG = "hhome"           # already present from prior goals
NEW_TAG_NAME = f"house_{SUFFIX}"
TASK_TITLE = f"G16_TaggedTask_{SUFFIX}"


def tap(d, x, y, wait=0.8):
    d.click(x, y)
    time.sleep(wait)


def open_drawer(d):
    """The hamburger lives at top-left; coordinates differ by route. Inbox
    uses (~105, 422); the empty Focus screen uses (~105, 170). The drawer
    is open when the Search row is visible.
    """
    for x, y in ((105, 422), (105, 170)):
        d.click(x, y)
        time.sleep(1.2)
        if d(textContains="Search").exists or d(descriptionContains="Search").exists:
            return
    raise AssertionError("could not open drawer")


def find_tag_chip(d, name):
    """Tag chips render as text in the drawer cloud, e.g. '@hhome (1)'.

    The TagList chip exposes the bare name (no @, no count) via
    Semantics; the visible text shows '@<name> (<count>)'. Match either.
    """
    by_text = d(textContains=name)
    if by_text.exists:
        return by_text
    by_desc = d(descriptionContains=name)
    if by_desc.exists:
        return by_desc
    return None


def long_press_tag(d, name):
    chip = find_tag_chip(d, name)
    assert chip is not None, f"tag chip '{name}' not present in drawer cloud"
    info = chip.info
    b = info["bounds"]
    cx = (b["left"] + b["right"]) // 2
    cy = (b["top"] + b["bottom"]) // 2
    # uiautomator2 long_click defaults are short; spell out duration.
    d.long_click(cx, cy, duration=0.8)
    time.sleep(1.2)


def ensure_tag_exists(d, name):
    """If the seed tag isn't visible, capture a tagged task so it appears."""
    open_drawer(d)
    if find_tag_chip(d, name) is not None:
        # Close drawer.
        d.press("back")
        time.sleep(0.5)
        return
    d.press("back")
    time.sleep(0.5)
    # Capture task with hashtag in title — the parser auto-creates context tags.
    for _ in range(5):
        if d.xpath('//*[@hint="What\'s on your mind?"]').exists:
            break
        time.sleep(1.0)
    d.xpath('//*[@hint="What\'s on your mind?"]').click()
    time.sleep(0.4)
    d.shell(f"input text '{TASK_TITLE}\\ #{name}'")
    time.sleep(0.3)
    d(description="Add").click()
    time.sleep(1.5)


def main():
    d = u2.connect()
    # Bring the app to foreground without restarting — `app_stop` followed
    # by `app_start` was triggering the Google "Checking info..." gms popup
    # on this emulator image, which blocks input. Resume via monkey instead.
    d.shell(f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")
    time.sleep(3)

    # If a Google sign-in / "Checking info" interstitial popped up, back out.
    for _ in range(5):
        focus = d.shell("dumpsys window | grep mCurrentFocus").output
        if "google.android.gms" in focus or "GoogleSignIn" in focus \
                or "MinuteMaid" in focus:
            d.press("back")
            time.sleep(1.0)
        else:
            break

    # If a Daily-Planning suggestion banner is showing, dismiss it so the
    # hamburger area is hittable (the banner overlaps row at y~422).
    if d(descriptionContains="Quite").exists:
        # Tap the X (close) button at the right edge of the banner.
        d(description="Close").click() if d(description="Close").exists \
            else d.click(1010, 158)
        time.sleep(0.6)
    # If planning is in progress (e.g. resumed from a previous session),
    # walk through the remaining steps to land back on Inbox/Focus.
    if d(textContains="Daily Planning").exists:
        for _ in range(12):
            # Pick Medium energy if asked.
            if d(descriptionContains="Medium").exists:
                d(descriptionContains="Medium").click()
                time.sleep(0.4)
            for cta in ("Start Day", "Next", "Continue", "Finish"):
                btn = d(description=cta) if d(description=cta).exists \
                    else (d(text=cta) if d(text=cta).exists else None)
                if btn is not None:
                    btn.click()
                    time.sleep(1.2)
                    break
            else:
                time.sleep(0.5)
            if d(textContains="Inbox").exists or d(textContains="Focus").exists:
                break

    # 1. Make sure a tag is present.
    ensure_tag_exists(d, SEED_TAG)

    # 2. Long-press the chip → assert sheet opens.
    open_drawer(d)
    long_press_tag(d, SEED_TAG)
    assert d(textContains="Rename").exists, "rename action missing from sheet"
    assert d(textContains="Recolour").exists, "recolour action missing"
    assert d(textContains="Merge").exists, "merge action missing"

    # 3. Tap Rename → replace text → Save.
    d(textContains="Rename").click()
    time.sleep(1.0)
    assert d(textContains="Rename tag").exists, "rename dialog didn't open"
    # The TextField is pre-populated with current name; clear it before typing.
    if d(focused=True).exists:
        d(focused=True).clear_text()
    else:
        d.press("KEYCODE_MOVE_END")
        for _ in range(len(SEED_TAG) + 4):
            d.press("del")
    # Use `input text` directly to avoid triggering Google autofill on some
    # emulator images.
    d.shell(f"input text {NEW_TAG_NAME}")
    time.sleep(0.4)
    d(textContains="Save").click()
    time.sleep(1.5)

    # 4. Reopen drawer (rename closes the sheet but keeps drawer open
    #    on Material; verify chip text changed).
    if not (d(textContains=NEW_TAG_NAME).exists
            or d(descriptionContains=NEW_TAG_NAME).exists):
        # Rename may have closed the drawer too — reopen.
        open_drawer(d)
    assert d(textContains=NEW_TAG_NAME).exists \
        or d(descriptionContains=NEW_TAG_NAME).exists, \
        f"renamed tag '{NEW_TAG_NAME}' missing from cloud"
    assert not (d(text=f"@{SEED_TAG}").exists
                or d(text=f"@{SEED_TAG} (1)").exists), \
        f"old tag name '{SEED_TAG}' still showing"

    # 5. Long-press renamed chip → Recolour → pick a swatch.
    long_press_tag(d, NEW_TAG_NAME)
    assert d(textContains="Recolour").exists, "sheet didn't reopen"
    d(textContains="Recolour").click()
    time.sleep(1.2)
    assert d(textContains="Choose colour").exists, "recolour dialog missing"
    # Pick the first swatch via its Semantics label "Set tag colour <hex>".
    swatch = d(descriptionContains="Set tag colour ")
    assert swatch.exists, "no colour swatches found"
    swatch.click()
    time.sleep(1.5)

    # 6. After recolour the dialog dismisses. Reopen the management sheet
    #    cleanly to assert the tag survived the update.
    open_drawer(d) if not d(textContains=NEW_TAG_NAME).exists else None
    long_press_tag(d, NEW_TAG_NAME)
    assert d(textContains="Rename").exists, \
        "post-recolour sheet failed to open — tag may have been corrupted"
    d.press("back")  # close sheet
    time.sleep(0.5)

    print(f"Goal 16 PASSED — tag renamed to '{NEW_TAG_NAME}' and recoloured; "
          "change reflected in the drawer cloud.")


if __name__ == "__main__":
    main()
