import Toybox.Lang;

//! Colours and thresholds shared by the face (same values as prototype/index.html).
module Theme {
    const TEXT = 0xECEAE5;
    const MUTED = 0x8E9196;
    const DIM = 0x5F6268;
    const TRACK = 0x1F2124;
    const OK = 0x4CD99A;
    const WARN = 0xFFB547;
    const CRIT = 0xFF5A4E;
    const STEPS = 0x6EA8FF;
    const AOD_TIME = 0xB9BBBF;

    //! Fallback colour by what is LEFT of a quota (pace unknown): green > 40 %, amber 16–40 %, red ≤ 15 %.
    function level(left as Number) as Number {
        if (left <= 15) {
            return CRIT;
        }
        return left <= 40 ? WARN : OK;
    }

    //! Colour by pace: run-out time against time to reset. Lasts → green, out at 80 % or more of
    //! the time left → amber, sooner → red. Long arithmetic: CodexBar's eta is unbounded.
    function pace(outIn as Number, toReset as Number) as Number {
        if (toReset <= 0 || outIn >= toReset) {
            return OK;
        }
        return outIn.toLong() * 10 >= toReset.toLong() * 8 ? WARN : CRIT;
    }

    //! Same hue at half the brightness (stale data, always-on mode).
    function dim(color as Number) as Number {
        return (color >> 1) & 0x7F7F7F;
    }
}
