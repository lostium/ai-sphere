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

    //! Colour by what is LEFT of a quota: green > 40 %, amber 16–40 %, red ≤ 15 %.
    function level(left as Number) as Number {
        if (left <= 15) {
            return CRIT;
        }
        return left <= 40 ? WARN : OK;
    }

    //! Same hue at half the brightness (stale data, always-on mode).
    function dim(color as Number) as Number {
        return (color >> 1) & 0x7F7F7F;
    }
}
