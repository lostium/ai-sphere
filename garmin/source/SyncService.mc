import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Background process: downloads usage.json through the phone and hands the result to the face.
//! It never touches Storage; the foreground decides what to keep (see QuotaStore).
(:background)
class SyncService extends System.ServiceDelegate {

    // Own result codes (negative, outside Connect IQ's range).
    static const NO_URL = -2001;      // not -1001..-1004: those are Communications codes
    static const TOO_LARGE = -2002;

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        var url = Properties.getValue("dataUrl");
        if (!(url instanceof String) || url.length() == 0) {
            Background.exit({"code" => NO_URL});
            return;
        }
        var headers = {"Accept" => "application/json"};
        var key = Properties.getValue("accessKey");
        if (key instanceof String && key.length() > 0) {
            headers["X-Key"] = key;
        }
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => headers,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onResponse));
    }

    function onResponse(code as Number, data as Dictionary or String or Null) as Void {
        var result = {"code" => code};
        if (code == 200 && data instanceof Dictionary) {
            result["data"] = data;
        }
        try {
            Background.exit(result as Application.PropertyValueType);
        } catch (e instanceof Background.ExitDataSizeLimitException) {
            Background.exit({"code" => TOO_LARGE});
        }
    }
}
