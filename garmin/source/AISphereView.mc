import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Weather;
import Toybox.WatchUi;

//! AI Sphere face, as designed in prototype/index.html (454 × 454 reference, scaled to the screen).
//!
//!  - Bezel: one arc per provider over 280° (gap at the bottom for the sync status). Each arc is what is
//!    LEFT of its most used window; the thin inner line is the second window; the white tick is
//!    CodexBar's pace (where you would be at a constant rate until the reset).
//!  - Centre: battery, date, time, steps and temperature, and up to two critical quotas.
//!  - Always-on: thin time, 3 px arcs without track, one critical line, small burn-in shift.
class AISphereView extends WatchUi.WatchFace {

    // Bezel geometry in prototype units (454 px screen).
    const SPAN = 280.0;
    const START = -140.0;
    const GAP = 4.0;
    const R1 = 211;     // provider arc
    const W1 = 13;
    const R2 = 196;     // second window
    const W2 = 4;
    const R_LABEL_TOP = 178;
    const R_LABEL_BOTTOM = 192;

    private var _sleeping as Boolean = false;
    private var _s as Float = 1.0; // scale from the 454 px reference

    private var _fTime as Graphics.FontType = Graphics.FONT_NUMBER_HOT;
    private var _fTimeThin as Graphics.FontType = Graphics.FONT_NUMBER_MEDIUM;
    private var _fDate as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fValue as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fLine as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fSmall as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fNote as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fLabel as Graphics.VectorFont or Null = null;

    // Localised texts (resources/strings and resources-spa/strings), loaded once in onLayout.
    private var _t as Dictionary<Symbol, String> = {} as Dictionary<Symbol, String>;

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _s = dc.getWidth() / 454.0;
        _fTime = font("RobotoCondensedBold", 132, Graphics.FONT_NUMBER_HOT);
        _fTimeThin = font("RobotoCondensedRegular", 112, Graphics.FONT_NUMBER_MEDIUM);
        _fDate = font("RobotoCondensedRegular", 28, Graphics.FONT_TINY);
        _fValue = font("RobotoCondensedBold", 30, Graphics.FONT_SMALL);
        _fLine = font("RobotoCondensedBold", 24, Graphics.FONT_XTINY);
        _fSmall = font("RobotoCondensedRegular", 22, Graphics.FONT_XTINY);
        _fNote = font("RobotoCondensedRegular", 24, Graphics.FONT_XTINY);
        _fLabel = Graphics.getVectorFont({:face => ["RobotoCondensedBold", "BionicBold"], :size => sc(17)});

        var ids = {
            :quotasOk => Rez.Strings.QuotasOk, :runsOut => Rez.Strings.RunsOut, :soon => Rez.Strings.Soon,
            :noUrl => Rez.Strings.NoUrl, :waiting => Rez.Strings.Waiting, :noData => Rez.Strings.NoData,
            :ago => Rez.Strings.Ago, :noPhone => Rez.Strings.NoPhone, :error => Rez.Strings.Error,
            :dataAge => Rez.Strings.DataAge, :macSilent => Rez.Strings.MacSilent, :updated => Rez.Strings.Updated,
            :noNewData => Rez.Strings.NoNewData, :thousands => Rez.Strings.ThousandsSeparator,
            :needsHttps => Rez.Strings.NeedsHttps, :notJson => Rez.Strings.NotJson, :badKey => Rez.Strings.BadKey,
            :notFound => Rez.Strings.NotFound
        };
        var keys = ids.keys();
        for (var i = 0; i < keys.size(); i++) {
            _t[keys[i] as Symbol] = WatchUi.loadResource(ids[keys[i]] as ResourceId) as String;
        }
    }

    function t(key as Symbol) as String {
        var v = _t[key];
        return v != null ? v : "";
    }

    function font(face as String, size as Number, fallback as Graphics.FontType) as Graphics.FontType {
        var f = Graphics.getVectorFont({:face => face, :size => sc(size)});
        return f != null ? f : fallback;
    }

    function sc(v as Numeric) as Number {
        return (v * _s + 0.5).toNumber();
    }

    function onEnterSleep() as Void {
        _sleeping = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _sleeping = false;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var now = Time.now().value();
        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;
        var providers = FaceModel.providers(now);
        var status = syncStatus(now);

        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_sleeping) {
            drawAlwaysOn(dc, cx, cy, providers, status, now);
            return;
        }

        drawBezel(dc, cx, cy, providers, status[2] as Boolean);

        // Battery, date and time
        drawBattery(dc, cx, cy - sc(146));
        dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - sc(108), _fDate, dateText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Theme.TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - sc(36), _fTime, timeText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        drawStats(dc, cx, cy + sc(50));

        // Critical quotas, or a quiet note when there is nothing to watch
        var critical = FaceModel.critical(providers, 2);
        if (critical.size() == 0) {
            if (providers.size() > 0) {
                dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, cy + sc(110), _fNote, t(:quotasOk), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } else {
            for (var i = 0; i < critical.size(); i++) {
                drawCriticalLine(dc, cx, cy + sc(100 + i * 29), critical[i], now, false);
            }
        }

        drawStatus(dc, cx, cy + sc(178), status);
    }

    // ------------------------------------------------------------------ bezel

    function drawBezel(dc as Graphics.Dc, cx as Number, cy as Number, providers as Array<ProviderModel>, stale as Boolean) as Void {
        var n = providers.size();
        if (n == 0) {
            dc.setPenWidth(sc(W1));
            dc.setColor(Theme.TRACK, Graphics.COLOR_TRANSPARENT);
            Geo.arc(dc, cx, cy, sc(R1), START, START + SPAN);
            return;
        }
        var gap = n > 1 ? GAP : 0.0;
        var seg = (SPAN - gap * (n - 1)) / n;

        for (var i = 0; i < n; i++) {
            var p = providers[i];
            var a0 = START + i * (seg + gap);
            var a1 = a0 + seg;
            var q1 = p.quotas[0];
            var faded = stale || p.stale;

            // Track and remaining amount of the most used window
            dc.setPenWidth(sc(W1));
            dc.setColor(Theme.TRACK, Graphics.COLOR_TRANSPARENT);
            Geo.arc(dc, cx, cy, sc(R1), a0, a1);
            if (q1.left > 0) {
                var color = Theme.level(q1.left);
                dc.setColor(faded || q1.expired ? Theme.dim(color) : color, Graphics.COLOR_TRANSPARENT);
                var end = a0 + seg * q1.left / 100.0;
                if (q1.expired) {
                    Geo.dotted(dc, cx, cy, sc(R1), a0, end);
                } else {
                    Geo.arc(dc, cx, cy, sc(R1), a0, end);
                }
            }

            // Pace tick
            if (q1.paceExpected != null && !q1.expired) {
                var expected = q1.paceExpected as Number;
                var at = a0 + seg * (100 - (expected > 100 ? 100 : expected)) / 100.0;
                dc.setPenWidth(sc(3));
                dc.setColor(Theme.TEXT, Graphics.COLOR_TRANSPARENT);
                Geo.tick(dc, cx, cy, sc(201), sc(220), at);
            }

            // Second window
            if (p.quotas.size() > 1) {
                var q2 = p.quotas[1];
                dc.setPenWidth(sc(W2));
                dc.setColor(Theme.TRACK, Graphics.COLOR_TRANSPARENT);
                Geo.arc(dc, cx, cy, sc(R2), a0, a1);
                if (q2.left > 0 && !q2.expired) {
                    var c2 = Theme.level(q2.left);
                    dc.setColor(faded ? Theme.dim(c2) : c2, Graphics.COLOR_TRANSPARENT);
                    Geo.arc(dc, cx, cy, sc(R2), a0, a0 + seg * q2.left / 100.0);
                }
            }

            var value = q1.expired ? "--" : q1.left.format("%d");
            drawLabel(dc, cx, cy, p.name + " ", value, q1.expired ? Theme.MUTED : Theme.level(q1.left), (a0 + a1) / 2);
        }
    }

    //! "NAME value" along the arc: name in grey, value in colour. Upright at the top, flipped at the bottom.
    function drawLabel(dc as Graphics.Dc, cx as Number, cy as Number, name as String, value as String, valueColor as Number, mid as Float) as Void {
        var f = _fLabel;
        if (f == null || !(dc has :drawRadialText)) {
            return;
        }
        var bottom = mid > 90 || mid < -90;
        var r = sc(bottom ? R_LABEL_BOTTOM : R_LABEL_TOP);
        var degPerPx = 180.0 / (Math.PI * r);
        var nameDeg = dc.getTextWidthInPixels(name, f) * degPerPx;
        var valueDeg = dc.getTextWidthInPixels(value, f) * degPerPx;
        var half = (nameDeg + valueDeg) / 2;
        // Reading direction runs clockwise at the top and counter-clockwise at the bottom.
        var dir = bottom ? -1 : 1;
        var nameAt = mid - dir * half + dir * nameDeg / 2;
        var valueAt = mid - dir * half + dir * (nameDeg + valueDeg / 2);
        var direction = bottom ? Graphics.RADIAL_TEXT_DIRECTION_COUNTER_CLOCKWISE : Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE;

        dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawRadialText(cx, cy, f, name, Graphics.TEXT_JUSTIFY_CENTER, Geo.toMath(nameAt), r, direction);
        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        dc.drawRadialText(cx, cy, f, value, Graphics.TEXT_JUSTIFY_CENTER, Geo.toMath(valueAt), r, direction);
    }

    // ------------------------------------------------------------------ centre

    //! Steps and temperature as one centred row: [icon] value   [icon] value
    function drawStats(dc as Graphics.Dc, cx as Number, y as Number) as Void {
        var info = ActivityMonitor.getInfo();
        var steps = info.steps != null ? info.steps as Number : 0;
        var stepsText = thousands(steps);

        var tempText = "--°";
        var conditions = Weather.getCurrentConditions();
        if (conditions != null && conditions.temperature != null) {
            tempText = toUserTemp(conditions.temperature as Numeric).format("%d") + "°";
        }

        var icon = sc(22);
        var gap = sc(8);
        var spacing = sc(30);
        var wSteps = dc.getTextWidthInPixels(stepsText, _fValue);
        var wTemp = dc.getTextWidthInPixels(tempText, _fValue);
        var x = cx - (icon + gap + wSteps + spacing + icon + gap + wTemp) / 2;

        drawStepsIcon(dc, x + icon / 2, y);
        dc.setColor(Theme.TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + icon + gap, y, _fValue, stepsText, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        x += icon + gap + wSteps + spacing;

        drawThermometerIcon(dc, x + icon / 2, y);
        dc.setColor(Theme.TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + icon + gap, y, _fValue, tempText, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Two footprints, the right one a step ahead.
    function drawStepsIcon(dc as Graphics.Dc, x as Number, y as Number) as Void {
        dc.setColor(Theme.STEPS, Graphics.COLOR_TRANSPARENT);
        var fw = sc(4);
        var fh = sc(7);
        // left foot (lower)
        dc.fillEllipse(x - sc(5), y + sc(1), fw, fh);
        dc.fillCircle(x - sc(5), y + sc(11), sc(3));
        // right foot (higher)
        dc.fillEllipse(x + sc(5), y - sc(6), fw, fh);
        dc.fillCircle(x + sc(5), y + sc(4), sc(3));
    }

    //! Thermometer: stem with a filled bulb.
    function drawThermometerIcon(dc as Graphics.Dc, x as Number, y as Number) as Void {
        dc.setColor(Theme.WARN, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(2));
        var w = sc(8);
        dc.drawRoundedRectangle(x - w / 2, y - sc(12), w, sc(18), w / 2);
        dc.fillCircle(x, y + sc(8), sc(6));
        dc.fillRectangle(x - sc(1), y - sc(4), sc(3), sc(10));
    }

    //! Battery icon filled to the charge level, followed by the percentage. Centred on (cx, y).
    function drawBattery(dc as Graphics.Dc, cx as Number, y as Number) as Void {
        var level = System.getSystemStats().battery;
        var text = level.toNumber().format("%d") + "%";
        var color = level < 20 ? Theme.CRIT : Theme.MUTED;
        var bw = sc(30);
        var bh = sc(15);
        var gap = sc(7);
        var x = cx - (bw + sc(3) + gap + dc.getTextWidthInPixels(text, _fSmall)) / 2;
        var top = y - bh / 2;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(2));
        dc.drawRoundedRectangle(x, top, bw, bh, sc(3));
        dc.fillRectangle(x + bw, y - sc(3), sc(3), sc(6)); // terminal
        var inner = ((bw - sc(6)) * (level > 100 ? 100 : level) / 100).toNumber();
        if (inner > 0) {
            dc.setColor(level < 20 ? Theme.CRIT : Theme.TEXT, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x + sc(3), top + sc(3), inner, bh - sc(6));
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + bw + sc(3) + gap, y, _fSmall, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! "CODEX WK 1% ↻49m" or, if it runs out before the reset, "CURSOR MO 29% out in 3d" (red).
    function drawCriticalLine(dc as Graphics.Dc, cx as Number, y as Number, q as Quota, now as Number, alwaysOn as Boolean) as Void {
        var f = _fLine;
        var parts = [q.provider, " " + q.label + " ", q.left.format("%d") + "%", " "] as Array<String>;
        var colors = alwaysOn
            ? [Theme.DIM, Theme.DIM, Theme.DIM, Theme.DIM] as Array<Number>
            : [Theme.TEXT, Theme.MUTED, Theme.level(q.left), Theme.MUTED] as Array<Number>;
        var tail = "";
        var tailColor = alwaysOn ? Theme.DIM : Theme.MUTED;
        var icon = false;
        if (q.runsOut()) {
            tail = Lang.format(t(:runsOut), [q.eta != null ? compact(q.eta as Number) : t(:soon)]);
            tailColor = alwaysOn ? Theme.DIM : Theme.CRIT;
        } else if (q.reset != null) {
            tail = compact((q.reset as Number) - now);
            icon = true;
        }
        var iconW = icon ? sc(16) : 0;
        var total = iconW + dc.getTextWidthInPixels(tail, f);
        for (var i = 0; i < parts.size(); i++) {
            total += dc.getTextWidthInPixels(parts[i], f);
        }
        var x = cx - total / 2;
        for (var i = 0; i < parts.size(); i++) {
            dc.setColor(colors[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, f, parts[i], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            x += dc.getTextWidthInPixels(parts[i], f);
        }
        if (icon) {
            drawResetIcon(dc, x + sc(6), y, tailColor);
            x += iconW;
        }
        dc.setColor(tailColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, f, tail, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! ↻ drawn by hand (system fonts have no such glyph).
    function drawResetIcon(dc as Graphics.Dc, x as Number, y as Number, color as Number) as Void {
        var r = sc(6);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(2));
        Geo.arc(dc, x, y, r, 30, 330);
        // Arrow head at the end of the arc (just before 12 o'clock)
        var tx = Geo.x(x, r, 330);
        var ty = Geo.y(y, r, 330);
        var a = sc(4);
        dc.fillPolygon([[tx + a, ty], [tx - a / 2, ty - a], [tx - a / 2, ty + a]] as Array<Graphics.Point2D>);
    }

    // ------------------------------------------------------------------ sync status

    //! [text, colour, stale?]
    function syncStatus(now as Number) as Array {
        var code = QuotaStore.lastCode();
        var generated = QuotaStore.generatedAt();
        if (generated == null) {
            if (code == SyncService.NO_URL) {
                return [t(:noUrl), Theme.WARN, false];
            }
            return [code == null ? t(:waiting) : Lang.format(t(:noData), [reason(code as Number)]), Theme.MUTED, false];
        }
        var age = now - (generated as Number);
        var ago = Lang.format(t(:ago), [humanDuration(age)]);
        var stale = age > 3600;
        if (code != null && code != 200) {
            return [Lang.format(t(:dataAge), [reason(code as Number), ago]), Theme.WARN, stale];
        }
        if (stale) {
            return [Lang.format(t(:macSilent), [ago]), Theme.WARN, true];
        }
        return [Lang.format(t(:updated), [ago]), Theme.MUTED, false];
    }

    //! Short words for the errors a misconfigured host produces; anything else is "error <code>".
    function reason(code as Number) as String {
        if (code == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return t(:noPhone);
        }
        if (code == Communications.SECURE_CONNECTION_REQUIRED) {
            return t(:needsHttps);
        }
        if (code == Communications.UNSUPPORTED_CONTENT_TYPE_IN_RESPONSE) {
            return t(:notJson);
        }
        if (code == 401 || code == 403) {
            return t(:badKey);
        }
        if (code == 404) {
            return t(:notFound);
        }
        return Lang.format(t(:error), [code]);
    }

    function drawStatus(dc as Graphics.Dc, cx as Number, y as Number, status as Array) as Void {
        var text = status[0] as String;
        var color = status[1] as Number;
        var dotGap = sc(14);
        var w = dc.getTextWidthInPixels(text, _fSmall) + dotGap;
        var x = cx - w / 2;
        dc.setColor(color == Theme.MUTED ? Theme.OK : color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x + sc(4), y, sc(4));
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + dotGap, y, _fSmall, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ------------------------------------------------------------------ always-on

    function drawAlwaysOn(dc as Graphics.Dc, cx as Number, cy as Number, providers as Array<ProviderModel>, status as Array, now as Number) as Void {
        // Shift everything a few pixels each minute against burn-in.
        var shifts = [[0, 0], [3, -2], [-2, 3], [2, 2], [-3, -1]] as Array<Array<Number>>;
        var s = shifts[System.getClockTime().min % 5];
        var x = cx + s[0];
        var y = cy + s[1];

        // Thin arcs, no track
        var n = providers.size();
        if (n > 0) {
            var gap = n > 1 ? GAP : 0.0;
            var seg = (SPAN - gap * (n - 1)) / n;
            dc.setPenWidth(sc(3));
            for (var i = 0; i < n; i++) {
                var q1 = providers[i].quotas[0];
                var a0 = START + i * (seg + gap);
                if (q1.left > 0 && !q1.expired) {
                    dc.setColor(Theme.dim(Theme.level(q1.left)), Graphics.COLOR_TRANSPARENT);
                    Geo.arc(dc, x, y, sc(R1), a0, a0 + seg * q1.left / 100.0);
                }
                if (q1.paceExpected != null && !q1.expired) {
                    var e = q1.paceExpected as Number;
                    dc.setColor(Theme.DIM, Graphics.COLOR_TRANSPARENT);
                    dc.setPenWidth(sc(2));
                    Geo.tick(dc, x, y, sc(205), sc(217), a0 + seg * (100 - (e > 100 ? 100 : e)) / 100.0);
                    dc.setPenWidth(sc(3));
                }
            }
        }

        dc.setColor(Theme.DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y - sc(80), _fDate, dateText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Theme.AOD_TIME, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y - sc(8), _fTimeThin, timeText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var critical = FaceModel.critical(providers, 1);
        if (critical.size() > 0) {
            drawCriticalLine(dc, x, y + sc(78), critical[0], now, true);
        }
        if (status[2] as Boolean) {
            dc.setColor(Theme.DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y + sc(150), _fSmall, t(:noNewData), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // ------------------------------------------------------------------ formatting

    //! 49m, 15h, 6d
    function compact(seconds as Number) as String {
        var m = seconds / 60;
        if (m < 0) {
            m = 0;
        }
        if (m < 60) {
            return m.format("%d") + "m";
        }
        if (m < 48 * 60) {
            return ((m + 30) / 60).format("%d") + "h";
        }
        return ((m + 720) / 1440).format("%d") + "d";
    }

    //! 3 min, 2 h 14, 3 d
    function humanDuration(seconds as Number) as String {
        var m = seconds / 60;
        if (m < 0) {
            m = 0;
        }
        if (m < 60) {
            return m.format("%d") + " min";
        }
        if (m < 48 * 60) {
            return (m / 60).format("%d") + " h " + (m % 60).format("%02d");
        }
        return (m / 1440).format("%d") + " d";
    }

    function thousands(n as Number) as String {
        if (n < 1000) {
            return n.format("%d");
        }
        return (n / 1000).format("%d") + t(:thousands) + (n % 1000).format("%03d");
    }

    function toUserTemp(celsius as Numeric) as Number {
        if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
            return (celsius * 9 / 5.0 + 32 + 0.5).toNumber();
        }
        return (celsius + (celsius >= 0 ? 0.5 : -0.5)).toNumber();
    }

    function timeText() as String {
        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        return hour.format("%02d") + ":" + clock.min.format("%02d");
    }

    function dateText() as String {
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var day = (info.day_of_week as String).toUpper();
        if (day.length() > 3) {
            day = day.substring(0, 3);
        }
        var month = (info.month as String).toUpper();
        if (month.length() > 3) {
            month = month.substring(0, 3);
        }
        return day + "  " + info.day.format("%d") + "  " + month;
    }
}
