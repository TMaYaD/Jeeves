"""Goal 18 — Use the app fully offline (airplane mode) and confirm
captures persist across a force-stop + relaunch.

Drives the running emulator via uiautomator2.

Pre-conditions:
  - Emulator at 1080x2400.
  - Jeeves package `loonyb.in.jeeves` installed.
  - Caller is responsible for enabling/disabling airplane mode around
    this script (the script asserts airplane mode is on at start).

Flow:
  1. Assert airplane_mode_on == 1.
  2. Cold-launch app on /inbox.
  3. Capture three inbox items with timestamped titles.
  4. Assert all three visible in inbox.
  5. Force-stop, relaunch, wait for /inbox.
  6. Assert all three still visible -> persistence proven offline.

The asserted invariant: locally captured inbox items survive a process
restart with the network disabled, i.e. the capture path writes to the
on-device store synchronously and does not require a server round-trip.
"""

import subprocess
import time
import uiautomator2 as u2

PKG = "loonyb.in.jeeves"
SUFFIX = str(int(time.time()) % 100000)
TITLES = [
    f"G18_Offline_A_{SUFFIX}",
    f"G18_Offline_B_{SUFFIX}",
    f"G18_Offline_C_{SUFFIX}",
]


def adb(*args):
    return subprocess.check_output(["adb", "shell", *args]).decode().strip()


QUICK_ADD_XPATH = '//*[contains(@hint, "What")]'


def capture(d, title):
    for _ in range(15):
        if d.xpath(QUICK_ADD_XPATH).exists:
            break
        time.sleep(1.0)
    d.xpath(QUICK_ADD_XPATH).click()
    time.sleep(0.4)
    d.send_keys(title)
    time.sleep(0.3)
    d(description="Add").click()
    time.sleep(1.0)
    assert d(textContains=title).exists or d(descriptionContains=title).exists, \
        f"capture failed for {title}"


def wait_for_inbox(d, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if d.xpath(QUICK_ADD_XPATH).exists:
            return
        time.sleep(0.5)
    raise AssertionError("inbox quick-add never appeared")


def main():
    # 1. Verify airplane mode is on.
    am = adb("settings", "get", "global", "airplane_mode_on")
    assert am == "1", f"expected airplane_mode_on=1, got {am!r}"

    d = u2.connect()

    # 2. Cold-launch app.
    d.app_stop(PKG)
    d.app_start(PKG)
    wait_for_inbox(d)

    # 3. Capture three offline items.
    for t in TITLES:
        capture(d, t)

    # 4. All three visible right now?
    for t in TITLES:
        assert d(textContains=t).exists or d(descriptionContains=t).exists, f"post-capture missing {t}"

    # 5. Force-stop and relaunch.
    d.app_stop(PKG)
    time.sleep(1.0)
    d.app_start(PKG)
    wait_for_inbox(d)

    # 6. Persistence assertion across restart, still offline.
    am2 = adb("settings", "get", "global", "airplane_mode_on")
    assert am2 == "1", f"airplane mode flipped during run: {am2!r}"
    for t in TITLES:
        assert d(textContains=t).exists or d(descriptionContains=t).exists, \
            f"item '{t}' missing from inbox after offline restart"

    print("OK: 3 offline captures persisted across restart.")


if __name__ == "__main__":
    main()
