import json
from pathlib import Path

root = Path(__file__).resolve().parent
def read(mode, name):
    return json.loads((root / f"runtime-{mode}" / name).read_text())

summary = {}
for mode in ["baseline", "fixed"]:
    before = read(mode, "ready.json")
    after = read(mode, "measured.json")
    events = [json.loads(line) for line in (root / f"runtime-{mode}" / "events.jsonl").read_text().splitlines()]
    assert before["buttonTitle"].strip() == "77%"
    assert before["hooksObserved"]
    assert before["monthlyUsedPercent"] == 76.9
    assert before["mergeIcons"] is True and before["mergeIconsStacked"] is False
    assert before["unifiedIconSource"] == "currentSelection"
    assert before["menuBarIconStyle"] == "iconAndPercent"
    assert before["selectedWindowLabel"] == "Monthly"
    assert before["usageBarsShowUsed"] is True
    assert after["monthlyUsedPercent"] == 80
    for key in ["primaryUsedPercent", "weeklyUsedPercent", "snapshotUpdatedAt", "selectedLayout",
                "configRevision", "backgroundWorkSettingsRevision", "defaultsFingerprint", "pluginSourceHash",
                "selectedProvider", "unifiedIconSource", "menuBarIconStyle", "mergedMenuLastSelectedWasOverview"]:
        assert before[key] == after[key], (mode, key)
    assert after["weeklyUsedPercent"] == 0 and after["primaryUsedPercent"] == 10
    assert after["settingsUnchangedSinceReady"]
    interval = [event for event in events if event["phase"] == "measured"]
    for event in interval + [after]:
        assert event["openMenus"] == 0
        assert not event["animationDriverActive"] and not event["blinkTaskActive"] and not event["countdownTaskActive"]
        assert event["networkAttempts"] == 0 and event["notificationAttempts"] == 0
    updates = [event for event in interval if event["event"] == "icon-update-begin"]
    if mode == "baseline":
        assert after["buttonTitle"].strip() == "77%"
        assert after["baselineProofPassed"] and len(updates) == 0
        forced = read(mode, "forced-control.json")
        assert forced["forcedControlPassed"] and forced["buttonTitle"].strip() == "80%"
    else:
        assert after["buttonTitle"].strip() == "80%"
        assert after["observerProofPassed"] and len(updates) == 1
        assert updates[0]["origin"] == "store-observer"
        ends = [event for event in interval if event["event"] == "icon-update-end"]
        assert len(ends) == 1 and ends[0]["buttonTitle"].strip() == "80%"
        assert before["storeIconSignature"] != after["storeIconSignature"]
    assert after["measuredOtherUpdates"] == 0
    summary[mode] = {
        "pid": after["pid"],
        "initialTitle": before["buttonTitle"],
        "monthlyAfter": after["monthlyUsedPercent"],
        "weeklyAfter": after["weeklyUsedPercent"],
        "titleAfterSnapshotOnly": after["buttonTitle"],
        "observerUpdates": after["measuredObserverUpdates"],
        "otherUpdates": after["measuredOtherUpdates"],
        "settingsUnchanged": after["settingsUnchangedSinceReady"],
    }

print(json.dumps(summary, indent=2))
(root / "verified-result.json").write_text(json.dumps(summary, indent=2) + "\n")
