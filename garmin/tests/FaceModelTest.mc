import Toybox.Lang;
import Toybox.Test;

// Unit tests for pace colours (docs/superpowers/specs/2026-11-16-pace-colours-design.md).
// Fixture: now = 2026-11-16T00:00Z, reset in 5 days, weekly window (2 days elapsed).

const PACE_RESET = "2026-11-21T00:00:00Z";

function paceNow() as Number {
    return QuotaStore.parseIso("2026-11-16T00:00:00Z") as Number;
}

function paceQuota(w as Dictionary, generated as String or Null) as Quota {
    var g = generated == null ? paceNow() : QuotaStore.parseIso(generated);
    return FaceModel.quota(w, "CODEX", paceNow(), g) as Quota;
}

function weekly(used as Number, pc as Dictionary or Null) as Dictionary {
    var w = {"l" => "WK", "u" => used, "r" => PACE_RESET, "m" => 10080} as Dictionary;
    if (pc != null) {
        w["pc"] = pc;
    }
    return w;
}

(:test)
function codexbarOutIn3dOf5IsRed(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 259200}), null);
    Test.assertEqual(q.color(), Theme.CRIT);
    Test.assert(q.runsOut());
    return true;
}

(:test)
function codexbarOutIn4_5dOf5IsAmber(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 388800}), null);
    Test.assertEqual(q.color(), Theme.WARN);
    return true;
}

(:test)
function codexbarEtaAgesWithPayload(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 388800}), "2026-11-15T00:00:00Z");
    Test.assertEqual(q.eta, 302400);
    Test.assertEqual(q.color(), Theme.CRIT);
    return true;
}

(:test)
function codexbarEtaNeverBelowZero(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 3600}), "2026-11-15T00:00:00Z");
    Test.assertEqual(q.eta, 0);
    Test.assertEqual(q.color(), Theme.CRIT);
    return true;
}

(:test)
function clockBehindPayloadDoesNotGrowEta(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 388800}), "2026-11-17T00:00:00Z");
    Test.assertEqual(q.eta, 388800);
    return true;
}

(:test)
function codexbarLastsIsGreenEvenNearlyEmpty(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(95, {"e" => 28, "ok" => true}), null);
    Test.assertEqual(q.color(), Theme.OK);
    return true;
}

(:test)
function emptyIsAlwaysRed(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(100, {"e" => 28, "ok" => true}), null);
    Test.assertEqual(q.color(), Theme.CRIT);
    return true;
}

(:test)
function codexbarWontLastWithoutEtaIsAmber(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false}), null);
    Test.assertEqual(q.color(), Theme.WARN);
    return true;
}

(:test)
function hugeEtaDoesNotOverflow(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(50, {"e" => 28, "ok" => false, "eta" => 2000000000}), null);
    Test.assertEqual(q.color(), Theme.OK);
    return true;
}

(:test)
function estimateOnPaceIsGreenWithTick(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(20, null), null);
    Test.assertEqual(q.color(), Theme.OK);
    Test.assertEqual(q.paceExpected, 28);
    Test.assert(!q.runsOut());
    return true;
}

(:test)
function estimateOutIn3dIsRed(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(40, null), null);
    Test.assertEqual(q.eta, 259200);
    Test.assert(q.runsOut());
    Test.assertEqual(q.color(), Theme.CRIT);
    return true;
}

(:test)
function estimateSlightlyFastIsAmber(logger as Test.Logger) as Boolean {
    Test.assertEqual(paceQuota(weekly(31, null), null).color(), Theme.WARN);
    return true;
}

(:test)
function estimateUnusedIsGreen(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(0, null), null);
    Test.assertEqual(q.color(), Theme.OK);
    Test.assert(!q.runsOut());
    return true;
}

(:test)
function estimateTooEarlyFallsBackToLeft(logger as Test.Logger) as Boolean {
    var w = weekly(70, null);
    w["r"] = "2026-11-22T12:00:00Z";
    var q = paceQuota(w, null);
    Test.assert(q.paceExpected == null);
    Test.assert(!q.runsOut());
    Test.assertEqual(q.color(), Theme.WARN);
    return true;
}

(:test)
function estimateResetBeyondWindowFallsBack(logger as Test.Logger) as Boolean {
    var w = weekly(70, null);
    w["m"] = 300;
    var q = paceQuota(w, null);
    Test.assert(q.paceExpected == null);
    Test.assertEqual(q.color(), Theme.WARN);
    return true;
}

(:test)
function estimateWithoutMinutesFallsBack(logger as Test.Logger) as Boolean {
    var w = weekly(90, null);
    w.remove("m");
    var q = paceQuota(w, null);
    Test.assertEqual(q.color(), Theme.CRIT);
    Test.assert(!q.runsOut());
    return true;
}

(:test)
function yearLongWindowDoesNotOverflow(logger as Test.Logger) as Boolean {
    var w = weekly(40, null);
    w["m"] = 527040;
    w["r"] = "2026-12-16T00:00:00Z";
    var c = paceQuota(w, null).color();
    Test.assert(c == Theme.OK || c == Theme.WARN || c == Theme.CRIT);
    return true;
}

(:test)
function expiredKeepsPercentColourAndNeverRunsOut(logger as Test.Logger) as Boolean {
    var w = weekly(40, {"e" => 28, "ok" => false, "eta" => 100});
    w["r"] = "2026-11-15T00:00:00Z";
    var q = paceQuota(w, null);
    Test.assert(q.expired);
    Test.assert(!q.runsOut());
    Test.assertEqual(q.color(), Theme.OK);
    return true;
}

(:test)
function estimatedRunOutGoesFirstInCriticalLines(logger as Test.Logger) as Boolean {
    var a = new ProviderModel();
    a.quotas.add(paceQuota(weekly(40, null), null));
    var b = new ProviderModel();
    b.quotas.add(paceQuota(weekly(80, {"e" => 28, "ok" => true}), null));
    var list = FaceModel.critical([a, b] as Array<ProviderModel>, 2);
    Test.assertEqual(list.size(), 2);
    Test.assertEqual(list[0].left, 60);
    return true;
}

(:test)
function estimateExhaustedShowsResetNotRunOut(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(100, null), null);
    Test.assert(!q.runsOut());
    Test.assertEqual(q.color(), Theme.CRIT);
    return true;
}

// The estimate is made when the usage was measured (t), then aged like CodexBar's eta.
(:test)
function estimateUsesPayloadTimeNotNow(logger as Test.Logger) as Boolean {
    var q = paceQuota(weekly(20, null), "2026-11-15T00:00:00Z");
    Test.assertEqual(q.eta, 259200);
    Test.assertEqual(q.color(), Theme.CRIT);
    Test.assertEqual(q.paceExpected, 28);
    return true;
}
