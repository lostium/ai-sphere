import Toybox.Lang;

//! One quota window ready to draw. `left` is what remains (100 − used).
class Quota {
    var provider as String = "";
    var label as String = "";
    var left as Number = 0;
    var reset as Number or Null = null;   // epoch seconds
    var toReset as Number or Null = null; // seconds from now until the reset
    var paceExpected as Number or Null = null; // expected used % at a steady rate (CodexBar or elapsed time)
    var paceKnown as Boolean = false;     // lasts/eta come from CodexBar or an estimate
    var lasts as Boolean = true;          // will last to the reset (true when unknown)
    var eta as Number or Null = null;     // seconds from now until it runs out, when it will not last
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

    //! Colour by pace (docs/design.md): empty is red; without pace, by what is left.
    function color() as Number {
        if (left == 0) {
            return Theme.CRIT;
        }
        if (expired || !paceKnown) {
            return Theme.level(left);
        }
        if (lasts) {
            return Theme.OK;
        }
        if (eta == null || toReset == null) {
            return Theme.WARN;
        }
        return Theme.pace(eta as Number, toReset as Number);
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
            var generated = QuotaStore.generatedAt();
            var windows = p["w"];
            if (windows instanceof Array) {
                for (var j = 0; j < windows.size(); j++) {
                    var q = quota(windows[j], model.name, now, generated);
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

    //! `generated` is the payload's time (`t`): CodexBar's eta is aged by how old the payload is.
    function quota(w, providerName as String, now as Number, generated as Number or Null) as Quota or Null {
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
        if (q.reset != null) {
            q.toReset = (q.reset as Number) - now;
        }
        var pc = w["pc"];
        if (pc instanceof Dictionary && pc["ok"] instanceof Boolean) {
            q.paceKnown = true;
            q.lasts = pc["ok"] as Boolean;
            if (pc["e"] instanceof Number) {
                q.paceExpected = pc["e"] as Number;
            }
            if (pc["eta"] instanceof Number) {
                var age = generated != null && now > (generated as Number) ? now - (generated as Number) : 0;
                var eta = (pc["eta"] as Number) - age;
                q.eta = eta > 0 ? eta : 0;
            }
        } else if (!q.expired) {
            estimate(q, used, w["m"], now);
        }
        return q;
    }

    //! Pace from usage alone, assuming a steady rate since the window started. Skipped (colour by
    //! what is left) without a length or reset, or in the first 10 % of the window.
    function estimate(q as Quota, used as Number, minutes, now as Number) as Void {
        if (!(minutes instanceof Number) || (minutes as Number) <= 0 || q.toReset == null) {
            return;
        }
        var total = (minutes as Number).toLong() * 60;
        var elapsed = total - (q.toReset as Number).toLong();
        if (elapsed * 10 < total) {
            return;
        }
        q.paceKnown = true;
        q.paceExpected = (elapsed * 100 / total).toNumber();
        // Already empty: nothing left to run out (red by color()); the line shows the reset instead.
        if (used <= 0 || used >= 100 || used.toLong() * total <= elapsed * 100) {
            return;
        }
        q.lasts = false;
        q.eta = ((100 - used).toLong() * elapsed / used).toNumber();
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
