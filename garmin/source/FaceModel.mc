import Toybox.Lang;

//! One quota window ready to draw. `left` is what remains (100 − used).
class Quota {
    var provider as String = "";
    var label as String = "";
    var left as Number = 0;
    var reset as Number or Null = null;   // epoch seconds
    var paceExpected as Number or Null = null; // CodexBar expectedUsedPercent
    var lasts as Boolean = true;          // CodexBar willLastToReset (true when unknown)
    var eta as Number or Null = null;     // seconds until it runs out, when it will not last
    var expired as Boolean = false;       // reset already passed: the value is out of date

    function initialize() {
    }

    function runsOut() as Boolean {
        return !lasts && !expired;
    }

    //! Worth showing under the time: runs out before the reset, or 40 % or less remains.
    function isCritical() as Boolean {
        return !expired && (runsOut() || left <= 40);
    }
}

class ProviderModel {
    var name as String = "";
    var quotas as Array<Quota> = [] as Array<Quota>;
    var stale as Boolean = false; // CodexBar failed for it; values are the last known ones

    function initialize() {
    }
}

//! Turns the stored JSON (docs/json-contract.md) into objects. Unknown fields are ignored.
module FaceModel {

    function providers(now as Number) as Array<ProviderModel> {
        var out = [] as Array<ProviderModel>;
        var raw = QuotaStore.providers();
        for (var i = 0; i < raw.size(); i++) {
            var p = raw[i];
            if (!(p instanceof Dictionary)) {
                continue;
            }
            var model = new ProviderModel();
            model.name = p["n"] instanceof String ? p["n"] as String : "?";
            model.stale = p["err"] != null;
            var windows = p["w"];
            if (windows instanceof Array) {
                for (var j = 0; j < windows.size(); j++) {
                    var q = quota(windows[j], model.name, now);
                    if (q != null) {
                        model.quotas.add(q);
                    }
                }
            }
            if (model.quotas.size() > 0) {
                out.add(model);
            }
        }
        return out;
    }

    function quota(w, providerName as String, now as Number) as Quota or Null {
        if (!(w instanceof Dictionary) || !(w["u"] instanceof Number)) {
            return null;
        }
        var q = new Quota();
        q.provider = providerName;
        q.label = w["l"] instanceof String ? w["l"] as String : "";
        var used = w["u"] as Number;
        q.left = used >= 100 ? 0 : (used <= 0 ? 100 : 100 - used);
        q.reset = QuotaStore.parseIso(w["r"]);
        q.expired = q.reset != null && (q.reset as Number) <= now;
        var pc = w["pc"];
        if (pc instanceof Dictionary) {
            if (pc["e"] instanceof Number) {
                q.paceExpected = pc["e"] as Number;
            }
            if (pc["ok"] instanceof Boolean) {
                q.lasts = pc["ok"] as Boolean;
            }
            if (pc["eta"] instanceof Number) {
                q.eta = pc["eta"] as Number;
            }
        }
        return q;
    }

    //! Up to `limit` critical quotas: the ones that run out first, then least remaining, then soonest reset.
    function critical(providers as Array<ProviderModel>, limit as Number) as Array<Quota> {
        var list = [] as Array<Quota>;
        for (var i = 0; i < providers.size(); i++) {
            var quotas = providers[i].quotas;
            for (var j = 0; j < quotas.size(); j++) {
                if (quotas[j].isCritical()) {
                    list.add(quotas[j]);
                }
            }
        }
        // Insertion sort: lists are tiny.
        for (var i = 1; i < list.size(); i++) {
            var item = list[i];
            var k = i - 1;
            while (k >= 0 && before(item, list[k])) {
                list[k + 1] = list[k];
                k--;
            }
            list[k + 1] = item;
        }
        return list.size() > limit ? list.slice(0, limit) : list;
    }

    function before(a as Quota, b as Quota) as Boolean {
        if (a.runsOut() != b.runsOut()) {
            return a.runsOut();
        }
        if (a.left != b.left) {
            return a.left < b.left;
        }
        var ra = a.reset != null ? a.reset as Number : 2147483647;
        var rb = b.reset != null ? b.reset as Number : 2147483647;
        return ra < rb;
    }
}
