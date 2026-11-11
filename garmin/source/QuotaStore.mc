import Toybox.Application;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Keeps the last valid payload and the outcome of the last sync attempt in Application.Storage.
//! A failed sync never replaces good data: the face keeps showing it with its age.
module QuotaStore {

    const SCHEMA_VERSION = 1;
    const K_PAYLOAD = "payload";
    const K_LAST_OK = "lastOk";
    const K_LAST_ATTEMPT = "lastAttempt";
    const K_LAST_CODE = "lastCode";

    // Code stored when the JSON arrives but is not a version this face understands.
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
            if (isValid(data)) {
                Storage.setValue(K_PAYLOAD, data as Dictionary<String, Application.PropertyValueType>);
                Storage.setValue(K_LAST_OK, now);
            } else {
                code = BAD_PAYLOAD;
            }
        }
        Storage.setValue(K_LAST_ATTEMPT, now);
        Storage.setValue(K_LAST_CODE, code);
    }

    function isValid(data) as Boolean {
        return data instanceof Dictionary
            && data["v"] == SCHEMA_VERSION
            && data["p"] instanceof Array;
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

    //! "2026-11-11T10:31:15Z" -> epoch seconds (UTC). Returns null if the text is not in that form.
    function parseIso(text) as Number or Null {
        if (!(text instanceof String) || text.length() < 19) {
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
        // Gregorian.moment() takes UTC values.
        return Gregorian.moment({
            :year => year, :month => month, :day => day,
            :hour => hour, :minute => minute, :second => second
        }).value();
    }
}
