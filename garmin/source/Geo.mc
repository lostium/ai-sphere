import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

//! Geometry in "clock degrees": 0 = 12 o'clock, growing clockwise (as in the prototype).
//! Connect IQ arcs use maths degrees (0 = 3 o'clock, counter-clockwise), so everything converts here.
module Geo {

    function toMath(clockDeg as Numeric) as Float {
        var d = 90.0 - clockDeg;
        while (d < 0) {
            d += 360.0;
        }
        while (d >= 360) {
            d -= 360.0;
        }
        return d;
    }

    function x(cx as Numeric, r as Numeric, clockDeg as Numeric) as Float {
        return cx + r * Math.sin(Math.toRadians(clockDeg));
    }

    function y(cy as Numeric, r as Numeric, clockDeg as Numeric) as Float {
        return cy - r * Math.cos(Math.toRadians(clockDeg));
    }

    //! Arc drawn clockwise from a0 to a1 with the current pen. Spans under half a degree are skipped
    //! because drawArc treats equal start and end as a full circle.
    function arc(dc as Graphics.Dc, cx as Numeric, cy as Numeric, r as Numeric, a0 as Numeric, a1 as Numeric) as Void {
        if (a1 - a0 < 0.5) {
            return;
        }
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, toMath(a0), toMath(a1));
    }

    //! Dotted arc: 1.5° dashes every 4°. Used for a window whose reset has already passed.
    function dotted(dc as Graphics.Dc, cx as Numeric, cy as Numeric, r as Numeric, a0 as Numeric, a1 as Numeric) as Void {
        var a = a0;
        while (a + 1.5 <= a1) {
            arc(dc, cx, cy, r, a, a + 1.5);
            a += 4;
        }
    }

    //! Radial tick between radii r0 and r1 at the given angle.
    function tick(dc as Graphics.Dc, cx as Numeric, cy as Numeric, r0 as Numeric, r1 as Numeric, clockDeg as Numeric) as Void {
        dc.drawLine(x(cx, r0, clockDeg), y(cy, r0, clockDeg), x(cx, r1, clockDeg), y(cy, r1, clockDeg));
    }
}
