import Toybox.Application;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Keeps the last valid payload and the outcome of the last sync attempt in Application.Storage.
//! A failed sync never replaces good data: the face keeps showing it with its age.
//!
//! The server is not trusted: only a sanitised copy is stored (known fields, bounded sizes, valid
//! dates), so a malformed or hostile JSON can never make every redraw fail.
module QuotaStore {

    const SCHEMA_VERSION = 1;
    const K_PAYLOAD = "payload";
    const K_LAST_OK = "lastOk";
    const K_LAST_ATTEMPT = "lastAttempt";
    const K_LAST_CODE = "lastCode";

    // Limits for what the face can draw sensibly (docs/json-contract.md).
    const MAX_PROVIDERS = 8;
    const MAX_WINDOWS = 3;
    const MAX_NAME = 10;
    const MAX_LABEL = 10;

    // Code stored when the JSON arrives but is not a version this face understands, or is unusable.
    const BAD_PAYLOAD = -2003;

    function save(result as Application.PersistableType) as Void {
        var now = Time.now().value();
        var code = -1;
        var data = null;
        if (result instanceof Dictionary) {
            var c = result["code"];
            if (c instanceof Number) {
                code = c;
            }
            data = result["data"];
        }
        if (code == 200) {
            var clean = sanitise(data);
            if (clean != null) {
                Storage.setValue(K_PAYLOAD, clean as Dictionary<String, Application.PropertyValueType>);
                Storage.setValue(K_LAST_OK, now);
            } else {
                code = BAD_PAYLOAD;
            }
        }
        Storage.setValue(K_LAST_ATTEMPT, now);
        Storage.setValue(K_LAST_CODE, code);
    }

    //! Drop the stored payload (used if drawing it ever fails).
    function clear() as Void {
        Storage.deleteValue(K_PAYLOAD);
    }

    //! A bounded copy with only the fields of the contract, or null if the payload is unusable.
    function sanitise(data) as Dictionary or Null {
        if (!(data instanceof Dictionary) || data["v"] != SCHEMA_VERSION || parseIso(data["t"]) == null) {
            return null;
        }
        var raw = data["p"];
        if (!(raw instanceof Array)) {
            return null;
        }
        var providers = [];
        for (var i = 0; i < raw.size() && providers.size() < MAX_PROVIDERS; i++) {
            var p = raw[i];
            if (!(p instanceof Dictionary)) {
                continue;
            }
            var windows = [];
            var ws = p["w"];
            if (ws instanceof Array) {
                for (var j = 0; j < ws.size() && windows.size() < MAX_WINDOWS; j++) {
                    var w = window(ws[j]);
                    if (w != null) {
                        windows.add(w);
                    }
                }
            }
            if (windows.size() == 0) {
                continue;
            }
            var clean = {"n" => text(p["n"], MAX_NAME, "?"), "w" => windows};
            if (p["err"] != null) {
                clean["err"] = 1;
            }
            providers.add(clean);
        }
        return {"v" => SCHEMA_VERSION, "t" => data["t"], "p" => providers};
    }

    function window(w) as Dictionary or Null {
        if (!(w instanceof Dictionary) || !(w["u"] instanceof Number)) {
            return null;
        }
        var out = {"u" => clamp(w["u"] as Number, 0, 100), "l" => text(w["l"], MAX_LABEL, "")};
        if (parseIso(w["r"]) != null) {
            out["r"] = w["r"];
        }
        var pc = w["pc"];
        if (pc instanceof Dictionary && pc["e"] instanceof Number) {
            var clean = {"e" => clamp(pc["e"] as Number, 0, 100)};
            if (pc["ok"] instanceof Boolean) {
                clean["ok"] = pc["ok"];
            }
            if (pc["eta"] instanceof Number) {
                clean["eta"] = clamp(pc["eta"] as Number, 0, 365 * 86400);
            }
            out["pc"] = clean;
        }
        return out;
    }

    function text(value, max as Number, fallback as String) as String {
        if (!(value instanceof String)) {
            return fallback;
        }
        var s = value as String;
        return s.length() > max ? s.substring(0, max) as String : s;
    }

    function clamp(n as Number, lo as Number, hi as Number) as Number {
        return n < lo ? lo : (n > hi ? hi : n);
    }

    //! Cheap structural check of what is in Storage (it was sanitised when saved).
    function isValid(data) as Boolean {
        return data instanceof Dictionary
            && data["v"] == SCHEMA_VERSION
            && data["p"] instanceof Array
            && (data["p"] as Array).size() <= MAX_PROVIDERS;
    }

    function payload() as Dictionary or Null {
        var value = Storage.getValue(K_PAYLOAD);
        return isValid(value) ? value as Dictionary : null;
    }

    function providers() as Array {
        var data = payload();
        return data != null ? data["p"] as Array : [];
    }

    //! When the Mac generated the JSON (epoch seconds), or null.
    function generatedAt() as Number or Null {
        var data = payload();
        return data != null ? parseIso(data["t"]) : null;
    }

    function lastOk() as Number or Null {
        return Storage.getValue(K_LAST_OK) as Number or Null;
    }

    function lastAttempt() as Number or Null {
        return Storage.getValue(K_LAST_ATTEMPT) as Number or Null;
    }

    function lastCode() as Number or Null {
        return Storage.getValue(K_LAST_CODE) as Number or Null;
    }

    //! "2026-11-11T10:31:15Z" -> epoch seconds (UTC). Null unless the text has that form and sane values.
    function parseIso(text) as Number or Null {
        if (!(text instanceof String) || text.length() < 19 || text.length() > 30) {
            return null;
        }
        var year = text.substring(0, 4).toNumber();
        var month = text.substring(5, 7).toNumber();
        var day = text.substring(8, 10).toNumber();
        var hour = text.substring(11, 13).toNumber();
        var minute = text.substring(14, 16).toNumber();
        var second = text.substring(17, 19).toNumber();
        if (year == null || month == null || day == null || hour == null || minute == null || second == null) {
            return null;
        }
        if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31
                || hour > 23 || minute > 59 || second > 59 || hour < 0 || minute < 0 || second < 0) {
            return null;
        }
        // Gregorian.moment() takes UTC values.
        return Gregorian.moment({
            :year => year, :month => month, :day => day,
            :hour => hour, :minute => minute, :second => second
        }).value();
    }
}
