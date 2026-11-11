import Toybox.Lang;
import Toybox.Test;

// Unit tests for the JSON sanitiser. Run: garmin/scripts/test.sh (needs the simulator).

(:test)
function sanitiseKeepsAGoodPayload(logger as Test.Logger) as Boolean {
    var clean = QuotaStore.sanitise({"v" => 1, "t" => "2026-11-11T10:00:00Z", "p" => [
        {"id" => "claude", "n" => "CLAUDE", "w" => [
            {"l" => "WK", "u" => 30, "r" => "2026-11-12T01:00:00Z", "m" => 10080, "pc" => {"e" => 93, "ok" => true}}
        ]}
    ]});
    Test.assert(clean != null);
    var p = (clean as Dictionary)["p"] as Array;
    Test.assertEqual(p.size(), 1);
    var w = ((p[0] as Dictionary)["w"] as Array)[0] as Dictionary;
    Test.assertEqual(w["u"], 30);
    Test.assertEqual(w["r"], "2026-11-12T01:00:00Z");
    Test.assertEqual((w["pc"] as Dictionary)["e"], 93);
    return true;
}

(:test)
function sanitiseRejectsWrongVersionOrDate(logger as Test.Logger) as Boolean {
    Test.assert(QuotaStore.sanitise({"v" => 2, "t" => "2026-11-11T10:00:00Z", "p" => []}) == null);
    Test.assert(QuotaStore.sanitise({"v" => 1, "t" => "9999-99-99T99:99:99Z", "p" => []}) == null);
    Test.assert(QuotaStore.sanitise({"v" => 1, "t" => "2026-11-11T10:00:00Z", "p" => "x"}) == null);
    Test.assert(QuotaStore.sanitise("not a dictionary") == null);
    return true;
}

(:test)
function sanitiseBoundsHostileInput(logger as Test.Logger) as Boolean {
    var many = [];
    for (var i = 0; i < 200; i++) {
        many.add({"n" => "PROVIDER-WITH-A-VERY-LONG-NAME", "w" => [
            {"l" => "LABEL-THAT-IS-FAR-TOO-LONG", "u" => 500, "r" => "2026-13-45T99:00:00Z",
             "pc" => {"e" => -50, "eta" => -1}},
            {"u" => -20}, {"u" => 1}, {"u" => 2}, {"u" => 3}
        ]});
    }
    var clean = QuotaStore.sanitise({"v" => 1, "t" => "2026-11-11T10:00:00Z", "p" => many}) as Dictionary;
    var p = clean["p"] as Array;
    Test.assertEqual(p.size(), QuotaStore.MAX_PROVIDERS);
    var first = p[0] as Dictionary;
    Test.assertEqual((first["n"] as String).length(), QuotaStore.MAX_NAME);
    var ws = first["w"] as Array;
    Test.assertEqual(ws.size(), QuotaStore.MAX_WINDOWS);
    var w0 = ws[0] as Dictionary;
    Test.assertEqual(w0["u"], 100);
    Test.assertEqual((w0["l"] as String).length(), QuotaStore.MAX_LABEL);
    Test.assert(w0["r"] == null);                       // impossible date dropped
    Test.assertEqual((w0["pc"] as Dictionary)["e"], 0);
    Test.assertEqual((w0["pc"] as Dictionary)["eta"], 0);
    Test.assertEqual((ws[1] as Dictionary)["u"], 0);
    return true;
}

(:test)
function sanitiseSkipsJunkEntries(logger as Test.Logger) as Boolean {
    var clean = QuotaStore.sanitise({"v" => 1, "t" => "2026-11-11T10:00:00Z", "p" => [
        "junk", 42, {"n" => "EMPTY", "w" => []}, {"n" => "NOU", "w" => [{"l" => "WK"}]},
        {"n" => 7, "w" => [{"u" => 50, "l" => ["x"]}], "err" => 1}
    ]}) as Dictionary;
    var p = clean["p"] as Array;
    Test.assertEqual(p.size(), 1);
    var only = p[0] as Dictionary;
    Test.assertEqual(only["n"], "?");
    Test.assertEqual(only["err"], 1);
    Test.assertEqual(((only["w"] as Array)[0] as Dictionary)["l"], "");
    return true;
}

(:test)
function parseIsoValidatesRanges(logger as Test.Logger) as Boolean {
    Test.assert(QuotaStore.parseIso("2026-11-11T10:31:15Z") != null);
    Test.assert(QuotaStore.parseIso("2026-00-11T10:31:15Z") == null);
    Test.assert(QuotaStore.parseIso("2026-11-11T24:00:00Z") == null);
    Test.assert(QuotaStore.parseIso("1970-01-01T00:00:00Z") == null);
    Test.assert(QuotaStore.parseIso(12345) == null);
    return true;
}
