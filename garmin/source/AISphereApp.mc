import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! Entry point. Runs both in the foreground (the face) and in the background (the sync service),
//! so only background-safe code may be reached from the background process.
(:background)
class AISphereApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    (:typecheck(disableBackgroundCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        // First run on this watch: fetch as soon as Connect IQ allows. Otherwise keep the periodic event.
        scheduleSync(QuotaStore.lastAttempt() == null);
        return [new AISphereView()];
    }

    function getServiceDelegate() as [System.ServiceDelegate] {
        return [new SyncService()];
    }

    //! Called in the foreground with whatever SyncService passed to Background.exit().
    (:typecheck(disableBackgroundCheck))
    function onBackgroundData(data as Application.PersistableType) as Void {
        QuotaStore.save(data);
        scheduleSync(false);
        WatchUi.requestUpdate();
    }

    (:typecheck(disableBackgroundCheck))
    function onSettingsChanged() as Void {
        scheduleSync(true);
        WatchUi.requestUpdate();
    }

    //! soon = true: one event as early as allowed (never sooner than 5 minutes after the last one).
    //! soon = false: a repeating event every refreshMinutes (minimum 5).
    function scheduleSync(soon as Boolean) as Void {
        try {
            if (soon) {
                var last = Background.getLastTemporalEventTime();
                // A moment in the past triggers immediately.
                Background.registerForTemporalEvent(last != null ? last.add(new Time.Duration(5 * 60)) : Time.now());
            } else {
                Background.registerForTemporalEvent(new Time.Duration(refreshMinutes() * 60));
            }
        } catch (e instanceof Background.InvalidBackgroundTimeException) {
            Background.registerForTemporalEvent(new Time.Duration(refreshMinutes() * 60));
        }
    }

    function refreshMinutes() as Number {
        var value = Properties.getValue("refreshMinutes");
        if (value instanceof Number && value >= 5) {
            return value;
        }
        return 15;
    }
}
