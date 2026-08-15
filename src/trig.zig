//! Deterministic, host-independent f64 transcendentals: the circular
//! `sin64` / `cos64` / `tan64`, and the exponential `exp64` / `log64` /
//! `pow64`.
//!
//! Why this module exists
//! ----------------------
//! SJON's expression sandbox promises cross-platform reproducibility: the
//! same expression yields bit-identical results on every host. For
//! `+ - * / sqrt` that falls out of IEEE 754 — those ops are correctly
//! rounded, and Zig defaults to `FloatMode.strict` (no FMA contraction /
//! reassociation), so SJON gets them for free. Transcendentals are the
//! exception: IEEE 754 does NOT mandate correctly-rounded `sin`/`cos`/
//! `tan`, so routing them through the `@sin`/`@cos`/`@tan` builtins lowers
//! to the platform's libm (glibc, musl, macOS, a WASM runtime's libm),
//! each differing in the last ULP. The native build would then disagree
//! with the freestanding `wasm32` artifacts, which (with `link_libc =
//! false`) link Zig's compiler_rt *software* implementation instead.
//!
//! To make the guarantee true *by construction* — rather than by accident
//! of which libm happens to link — we vendor the exact musl-derived f64
//! algorithm (the same one compiler_rt ships): Cody-Waite + Payne-Hanek
//! argument reduction (`remPio2`) feeding the degree-13/14 minimax
//! kernels. It is pure f64 arithmetic (`+ - *`), no libm call, no
//! allocation. Native and both WASM artifacts therefore produce identical
//! bits, and a faithful port to any other IEEE-754 f64 host would match
//! too.
//!
//! Totality: `sin64`/`cos64`/`tan64` of ±Inf or NaN return NaN (`x - x`),
//! matching the evaluator's documented domain→NaN discipline. No host
//! stack recursion, no allocation, infallible.
//!
//! Provenance: ported from musl (MIT —
//! https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT), files
//! src/math/{sin,cos,tan,__sin,__cos,__tand,__rem_pio2,__rem_pio2_large}.c.
//! Mirrors Zig's lib/compiler_rt/{sin,cos,tan,trig,rem_pio2,
//! rem_pio2_large}.zig, restricted to the f64 path and with the
//! float-exception side-effect blocks (inexact/underflow signalling)
//! removed — those do not affect the returned value.
//!
//! `exp64` mirrors Zig's lib/compiler_rt/exp.zig (itself musl src/math/exp.c —
//! the fdlibm degree-5 minimax over a Cody-Waite range reduction), restricted
//! to the f64 path with the same float-exception side-effects stripped. The
//! cross-host rationale is identical: IEEE 754 does not mandate a
//! correctly-rounded `exp`, so the `@exp` builtin lowers to platform libm
//! (native) vs compiler_rt (wasm32) and disagrees in the last ULP.
//!
//! `log64` mirrors Zig's lib/compiler_rt/log.zig (musl src/math/log.c — the
//! Arm optimized-routines table-driven log: a 128-entry reciprocal/log table
//! pair plus a degree-5 minimax), same f64-path / float-exception-stripped
//! discipline. The compiler_rt port already uses the explicit non-FMA
//! `(z - chi - clo) * invc` form, so it stays bit-stable under FloatMode.strict.
//!
//! `pow64` is musl's self-contained x^y (src/math/pow.c, Arm 2018 optimized-
//! routines): an integrated log_inline + exp_inline that carries a tail term
//! between the log and exp steps — NOT `exp64(y·log64(x))`, which would lose the
//! last ULP. It replaces `std.math.pow`, whose fractional-exponent path calls
//! the `@exp`/`@log` builtins and was therefore the one transcendental in the
//! evaluator that was NOT yet host-independent. Same non-FMA / exception-
//! stripped discipline; the `__pow_log_data` + `__exp_data` tables are vendored
//! verbatim. (compiler_rt ships no `pow`, so this ports the musl C directly.)

const std = @import("std");
const math = std.math;

comptime {
    // Guard the vendored tables against transcription drift. 686 is the
    // documented minimum term count for the quad-precision e0 bound; the
    // f64 path never needs that many, but the table is shared verbatim.
    std.debug.assert(ipio2.len >= 686);
    std.debug.assert(PIo2.len == 8);
    std.debug.assert(init_jk.len == 4);
}

// ===========================================================================
// Public f64 entry points
// ===========================================================================

/// sin(x), x in radians. Bit-identical across native and WASM. NaN for
/// ±Inf / NaN inputs.
pub fn sin64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e500000) { // |x| < 2**-26 — sin(x) ~ x
            return x;
        }
        return kSin(x, 0.0, 0);
    }

    // sin(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => kSin(y[0], y[1], 1),
        1 => kCos(y[0], y[1]),
        2 => -kSin(y[0], y[1], 1),
        else => -kCos(y[0], y[1]),
    };
}

/// cos(x), x in radians. Bit-identical across native and WASM. NaN for
/// ±Inf / NaN inputs.
pub fn cos64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e46a09e) { // |x| < 2**-27 * sqrt(2) — cos(x) ~ 1
            return 1.0;
        }
        return kCos(x, 0);
    }

    // cos(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => kCos(y[0], y[1]),
        1 => -kSin(y[0], y[1], 1),
        2 => -kCos(y[0], y[1]),
        else => kSin(y[0], y[1], 1),
    };
}

/// tan(x), x in radians. Bit-identical across native and WASM. NaN for
/// ±Inf / NaN inputs.
pub fn tan64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e400000) { // |x| < 2**-27 — tan(x) ~ x
            return x;
        }
        return kTan(x, 0.0, false);
    }

    // tan(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return kTan(y[0], y[1], n & 1 != 0);
}

// ===========================================================================
// Kernels on ~[-pi/4, pi/4]. x is the reduced angle, y its tail.
// ===========================================================================

/// kernel cos on [-pi/4, pi/4]; degree-14 minimax. `y` is the tail of x.
fn kCos(x: f64, y: f64) f64 {
    const C1 = 4.16666666666666019037e-02; // 0x3FA55555, 0x5555554C
    const C2 = -1.38888888888741095749e-03; // 0xBF56C16C, 0x16C15177
    const C3 = 2.48015872894767294178e-05; // 0x3EFA01A0, 0x19CB1590
    const C4 = -2.75573143513906633035e-07; // 0xBE927E4F, 0x809C52AD
    const C5 = 2.08757232129817482790e-09; // 0x3E21EE9E, 0xBDB4B1C4
    const C6 = -1.13596475577881948265e-11; // 0xBDA8FAE9, 0xBE8838D4

    const z = x * x;
    const w = z * z;
    const r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    const hz = 0.5 * z;
    const w2 = 1.0 - hz;
    return w2 + (((1.0 - w2) - hz) + (z * r - x * y));
}

/// kernel sin on ~[-pi/4, pi/4]; degree-13 minimax. `y` is the tail of x;
/// `iy` is 0 when y is known to be 0 (callers handle sin(-0) = -0).
fn kSin(x: f64, y: f64, iy: i32) f64 {
    const S1 = -1.66666666666666324348e-01; // 0xBFC55555, 0x55555549
    const S2 = 8.33333333332248946124e-03; // 0x3F811111, 0x1110F8A6
    const S3 = -1.98412698298579493134e-04; // 0xBF2A01A0, 0x19C161D5
    const S4 = 2.75573137070700676789e-06; // 0x3EC71DE3, 0x57B1FE7D
    const S5 = -2.50507602534068634195e-08; // 0xBE5AE5E6, 0x8A2B9CEB
    const S6 = 1.58969099521155010221e-10; // 0x3DE5D93A, 0x5ACFD57C

    const z = x * x;
    const w = z * z;
    const r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    const v = z * x;
    if (iy == 0) {
        return x + v * (S1 + z * r);
    } else {
        return x - ((z * (0.5 * y - v * r) - y) - v * S1);
    }
}

/// kernel tan on ~[-pi/4, pi/4]; degree-27 odd minimax. `y` is the tail of
/// x; `odd` selects -1/tan instead of tan (used by the rem_pio2 quadrant).
fn kTan(x_: f64, y_: f64, odd: bool) f64 {
    var x = x_;
    var y = y_;

    const T = [_]f64{
        3.33333333333334091986e-01, // 3FD55555, 55555563
        1.33333333333201242699e-01, // 3FC11111, 1110FE7A
        5.39682539762260521377e-02, // 3FABA1BA, 1BB341FE
        2.18694882948595424599e-02, // 3F9664F4, 8406D637
        8.86323982359930005737e-03, // 3F8226E3, E96E8493
        3.59207910759131235356e-03, // 3F6D6D22, C9560328
        1.45620945432529025516e-03, // 3F57DBC8, FEE08315
        5.88041240820264096874e-04, // 3F4344D8, F2F26501
        2.46463134818469906812e-04, // 3F3026F7, 1A8D1068
        7.81794442939557092300e-05, // 3F147E88, A03792A6
        7.14072491382608190305e-05, // 3F12B80F, 32F0A7E9
        -1.85586374855275456654e-05, // BEF375CB, DB605373
        2.59073051863633712884e-05, // 3EFB2A70, 74BF7AD4
    };
    // Local pi/4 split for the [0.6744, pi/4] tan identity. Distinct names
    // from the module-level `pio4` (rem_pio2's hex form) to avoid shadow;
    // both denote pi/4, kept verbatim from their respective musl sources.
    const tan_pio4 = 7.85398163397448278999e-01; // 3FE921FB, 54442D18
    const tan_pio4lo = 3.06161699786838301793e-17; // 3C81A626, 33145C07

    var z: f64 = undefined;
    var r: f64 = undefined;
    var v: f64 = undefined;
    var w: f64 = undefined;
    var s: f64 = undefined;
    var a: f64 = undefined;
    var w0: f64 = undefined;
    var a0: f64 = undefined;
    var hx: u32 = undefined;
    var sign: bool = undefined;

    hx = @intCast(@as(u64, @bitCast(x)) >> 32);
    const big = (hx & 0x7fffffff) >= 0x3FE59428; // |x| >= 0.6744
    if (big) {
        sign = hx >> 31 != 0;
        if (sign) {
            x = -x;
            y = -y;
        }
        x = (tan_pio4 - x) + (tan_pio4lo - y);
        y = 0.0;
    }
    z = x * x;
    w = z * z;

    // Break x^5*(T[1]+x^2*T[2]+...) into
    // x^5(T[1]+x^4*T[3]+...+x^20*T[11]) +
    // x^5(x^2*(T[2]+x^4*T[4]+...+x^22*[T12]))
    r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
    v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
    s = z * x;
    r = y + z * (s * (r + v) + y) + s * T[0];
    w = x + r;
    if (big) {
        s = @floatFromInt(1 - 2 * @as(i3, @intFromBool(odd)));
        v = s - 2.0 * (x + (r - w * w / (w + s)));
        return if (sign) -v else v;
    }
    if (!odd) {
        return w;
    }
    // -1.0/(x+r) has up to 2ulp error, so compute it accurately
    w0 = w;
    w0 = @bitCast(@as(u64, @bitCast(w0)) & 0xffffffff00000000);
    v = r - (w0 - x); // w0+v = r+x
    a = -1.0 / w;
    a0 = a;
    a0 = @bitCast(@as(u64, @bitCast(a0)) & 0xffffffff00000000);
    return a0 + a * (1.0 + a0 * w0 + a0 * v);
}

// ===========================================================================
// Argument reduction: x mod pi/2 into y[0]+y[1], returning the quadrant.
// ===========================================================================

const toint = 1.5 / math.floatEps(f64);
const pio4 = 0x1.921fb54442d18p-1; // pi/4
const invpio2 = 6.36619772367581382433e-01; // 53 bits of 2/pi
const pio2_1 = 1.57079632673412561417e+00; // first  33 bit of pi/2
const pio2_1t = 6.07710050650619224932e-11; // pi/2 - pio2_1
const pio2_2 = 6.07710050630396597660e-11; // second 33 bit of pi/2
const pio2_2t = 2.02226624879595063154e-21; // pi/2 - (pio2_1+pio2_2)
const pio2_3 = 2.02226624871116645580e-21; // third  33 bit of pi/2
const pio2_3t = 8.47842766036889956997e-32; // pi/2 - (pio2_1+pio2_2+pio2_3)

fn medium(ix: u32, x: f64, y: *[2]f64) i32 {
    var w: f64 = undefined;
    var t: f64 = undefined;
    var r: f64 = undefined;
    var @"fn": f64 = undefined;
    var n: i32 = undefined;
    var ex: i32 = undefined;
    var ey: i32 = undefined;
    var ui: u64 = undefined;

    // rint(x/(pi/2))
    @"fn" = x * invpio2 + toint - toint;
    n = @intFromFloat(@"fn");
    r = x - @"fn" * pio2_1;
    w = @"fn" * pio2_1t; // 1st round, good to 85 bits
    // Matters with directed rounding.
    if (r - w < -pio4) {
        n -= 1;
        @"fn" -= 1;
        r = x - @"fn" * pio2_1;
        w = @"fn" * pio2_1t;
    } else if (r - w > pio4) {
        n += 1;
        @"fn" += 1;
        r = x - @"fn" * pio2_1;
        w = @"fn" * pio2_1t;
    }
    y[0] = r - w;
    ui = @bitCast(y[0]);
    ey = @intCast((ui >> 52) & 0x7ff);
    ex = @intCast(ix >> 20);
    if (ex - ey > 16) { // 2nd round, good to 118 bits
        t = r;
        w = @"fn" * pio2_2;
        r = t - w;
        w = @"fn" * pio2_2t - ((t - r) - w);
        y[0] = r - w;
        ui = @bitCast(y[0]);
        ey = @intCast((ui >> 52) & 0x7ff);
        if (ex - ey > 49) { // 3rd round, good to 151 bits, covers all cases
            t = r;
            w = @"fn" * pio2_3;
            r = t - w;
            w = @"fn" * pio2_3t - ((t - r) - w);
            y[0] = r - w;
        }
    }
    y[1] = (r - y[0]) - w;
    return n;
}

/// Returns the remainder of x rem pi/2 in y[0]+y[1] and the quadrant.
/// Uses `remPio2Large` for large x. Caller must handle |x| ~<= pi/4.
fn remPio2(x: f64, y: *[2]f64) i32 {
    var z: f64 = undefined;
    var tx: [3]f64 = undefined;
    var ty: [2]f64 = undefined;
    var n: i32 = undefined;
    var ix: u32 = undefined;
    var sign: bool = undefined;
    var i: i32 = undefined;
    var ui: u64 = undefined;

    ui = @bitCast(x);
    sign = ui >> 63 != 0;
    ix = @truncate((ui >> 32) & 0x7fffffff);
    if (ix <= 0x400f6a7a) { // |x| ~<= 5pi/4
        if ((ix & 0xfffff) == 0x921fb) { // |x| ~= pi/2 or 2pi/2
            return medium(ix, x, y);
        }
        if (ix <= 0x4002d97c) { // |x| ~<= 3pi/4
            if (!sign) {
                z = x - pio2_1; // one round good to 85 bits
                y[0] = z - pio2_1t;
                y[1] = (z - y[0]) - pio2_1t;
                return 1;
            } else {
                z = x + pio2_1;
                y[0] = z + pio2_1t;
                y[1] = (z - y[0]) + pio2_1t;
                return -1;
            }
        } else {
            if (!sign) {
                z = x - 2 * pio2_1;
                y[0] = z - 2 * pio2_1t;
                y[1] = (z - y[0]) - 2 * pio2_1t;
                return 2;
            } else {
                z = x + 2 * pio2_1;
                y[0] = z + 2 * pio2_1t;
                y[1] = (z - y[0]) + 2 * pio2_1t;
                return -2;
            }
        }
    }
    if (ix <= 0x401c463b) { // |x| ~<= 9pi/4
        if (ix <= 0x4015fdbc) { // |x| ~<= 7pi/4
            if (ix == 0x4012d97c) { // |x| ~= 3pi/2
                return medium(ix, x, y);
            }
            if (!sign) {
                z = x - 3 * pio2_1;
                y[0] = z - 3 * pio2_1t;
                y[1] = (z - y[0]) - 3 * pio2_1t;
                return 3;
            } else {
                z = x + 3 * pio2_1;
                y[0] = z + 3 * pio2_1t;
                y[1] = (z - y[0]) + 3 * pio2_1t;
                return -3;
            }
        } else {
            if (ix == 0x401921fb) { // |x| ~= 4pi/2
                return medium(ix, x, y);
            }
            if (!sign) {
                z = x - 4 * pio2_1;
                y[0] = z - 4 * pio2_1t;
                y[1] = (z - y[0]) - 4 * pio2_1t;
                return 4;
            } else {
                z = x + 4 * pio2_1;
                y[0] = z + 4 * pio2_1t;
                y[1] = (z - y[0]) + 4 * pio2_1t;
                return -4;
            }
        }
    }
    if (ix < 0x413921fb) { // |x| ~< 2^20*(pi/2), medium size
        return medium(ix, x, y);
    }
    // all other (large) arguments
    if (ix >= 0x7ff00000) { // x is inf or NaN
        y[0] = x - x;
        y[1] = y[0];
        return 0;
    }
    // set z = scalbn(|x|,-ilogb(x)+23)
    ui = @bitCast(x);
    ui &= std.math.maxInt(u64) >> 12;
    ui |= @as(u64, 0x3ff + 23) << 52;
    z = @bitCast(ui);

    i = 0;
    while (i < 2) : (i += 1) {
        tx[@intCast(i)] = @floatFromInt(@as(i32, @intFromFloat(z)));
        z = (z - tx[@intCast(i)]) * 0x1p24;
    }
    tx[@intCast(i)] = z;
    // skip zero terms, first term is non-zero
    while (tx[@intCast(i)] == 0.0) {
        i -= 1;
    }
    n = remPio2Large(tx[0..], ty[0..], @as(i32, @intCast((ix >> 20))) - (0x3ff + 23), i + 1, 1);
    if (sign) {
        y[0] = -ty[0];
        y[1] = -ty[1];
        return -n;
    }
    y[0] = ty[0];
    y[1] = ty[1];
    return n;
}

// ===========================================================================
// Payne-Hanek large-argument reduction (table-driven multiprecision 2/pi).
// ===========================================================================

const init_jk = [_]i32{ 3, 4, 4, 6 }; // initial value for jk by precision

/// Table of 2/pi: ipio2[i] holds bits (24*i)..(24*i+23) after the binary
/// point; the value is ipio2[i] * 2^(-24(i+1)).
const ipio2 = [_]i32{
    0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
    0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
    0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
    0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
    0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
    0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
    0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
    0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
    0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
    0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
    0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,

    0x47C419, 0xC367CD, 0xDCE809, 0x2A8359, 0xC4768B, 0x961CA6,
    0xDDAF44, 0xD15719, 0x053EA5, 0xFF0705, 0x3F7E33, 0xE832C2,
    0xDE4F98, 0x327DBB, 0xC33D26, 0xEF6B1E, 0x5EF89F, 0x3A1F35,
    0xCAF27F, 0x1D87F1, 0x21907C, 0x7C246A, 0xFA6ED5, 0x772D30,
    0x433B15, 0xC614B5, 0x9D19C3, 0xC2C4AD, 0x414D2C, 0x5D000C,
    0x467D86, 0x2D71E3, 0x9AC69B, 0x006233, 0x7CD2B4, 0x97A7B4,
    0xD55537, 0xF63ED7, 0x1810A3, 0xFC764D, 0x2A9D64, 0xABD770,
    0xF87C63, 0x57B07A, 0xE71517, 0x5649C0, 0xD9D63B, 0x3884A7,
    0xCB2324, 0x778AD6, 0x23545A, 0xB91F00, 0x1B0AF1, 0xDFCE19,
    0xFF319F, 0x6A1E66, 0x615799, 0x47FBAC, 0xD87F7E, 0xB76522,
    0x89E832, 0x60BFE6, 0xCDC4EF, 0x09366C, 0xD43F5D, 0xD7DE16,
    0xDE3B58, 0x929BDE, 0x2822D2, 0xE88628, 0x4D58E2, 0x32CAC6,
    0x16E308, 0xCB7DE0, 0x50C017, 0xA71DF3, 0x5BE018, 0x34132E,
    0x621283, 0x014883, 0x5B8EF5, 0x7FB0AD, 0xF2E91E, 0x434A48,
    0xD36710, 0xD8DDAA, 0x425FAE, 0xCE616A, 0xA4280A, 0xB499D3,
    0xF2A606, 0x7F775C, 0x83C2A3, 0x883C61, 0x78738A, 0x5A8CAF,
    0xBDD76F, 0x63A62D, 0xCBBFF4, 0xEF818D, 0x67C126, 0x45CA55,
    0x36D9CA, 0xD2A828, 0x8D61C2, 0x77C912, 0x142604, 0x9B4612,
    0xC459C4, 0x44C5C8, 0x91B24D, 0xF31700, 0xAD43D4, 0xE54929,
    0x10D5FD, 0xFCBE00, 0xCC941E, 0xEECE70, 0xF53E13, 0x80F1EC,
    0xC3E7B3, 0x28F8C7, 0x940593, 0x3E71C1, 0xB3092E, 0xF3450B,
    0x9C1288, 0x7B20AB, 0x9FB52E, 0xC29247, 0x2F327B, 0x6D550C,
    0x90A772, 0x1FE76B, 0x96CB31, 0x4A1679, 0xE27941, 0x89DFF4,
    0x9794E8, 0x84E6E2, 0x973199, 0x6BED88, 0x365F5F, 0x0EFDBB,
    0xB49A48, 0x6CA467, 0x427271, 0x325D8D, 0xB8159F, 0x09E5BC,
    0x25318D, 0x3974F7, 0x1C0530, 0x010C0D, 0x68084B, 0x58EE2C,
    0x90AA47, 0x02E774, 0x24D6BD, 0xA67DF7, 0x72486E, 0xEF169F,
    0xA6948E, 0xF691B4, 0x5153D1, 0xF20ACF, 0x339820, 0x7E4BF5,
    0x6863B2, 0x5F3EDD, 0x035D40, 0x7F8985, 0x295255, 0xC06437,
    0x10D86D, 0x324832, 0x754C5B, 0xD4714E, 0x6E5445, 0xC1090B,
    0x69F52A, 0xD56614, 0x9D0727, 0x50045D, 0xDB3BB4, 0xC576EA,
    0x17F987, 0x7D6B49, 0xBA271D, 0x296996, 0xACCCC6, 0x5414AD,
    0x6AE290, 0x89D988, 0x50722C, 0xBEA404, 0x940777, 0x7030F3,
    0x27FC00, 0xA871EA, 0x49C266, 0x3DE064, 0x83DD97, 0x973FA3,
    0xFD9443, 0x8C860D, 0xDE4131, 0x9D3992, 0x8C70DD, 0xE7B717,
    0x3BDF08, 0x2B3715, 0xA0805C, 0x93805A, 0x921110, 0xD8E80F,
    0xAF806C, 0x4BFFDB, 0x0F9038, 0x761859, 0x15A562, 0xBBCB61,
    0xB989C7, 0xBD4010, 0x04F2D2, 0x277549, 0xF6B6EB, 0xBB22DB,
    0xAA140A, 0x2F2689, 0x768364, 0x333B09, 0x1A940E, 0xAA3A51,
    0xC2A31D, 0xAEEDAF, 0x12265C, 0x4DC26D, 0x9C7A2D, 0x9756C0,
    0x833F03, 0xF6F009, 0x8C402B, 0x99316D, 0x07B439, 0x15200C,
    0x5BC3D8, 0xC492F5, 0x4BADC6, 0xA5CA4E, 0xCD37A7, 0x36A9E6,
    0x9492AB, 0x6842DD, 0xDE6319, 0xEF8C76, 0x528B68, 0x37DBFC,
    0xABA1AE, 0x3115DF, 0xA1AE00, 0xDAFB0C, 0x664D64, 0xB705ED,
    0x306529, 0xBF5657, 0x3AFF47, 0xB9F96A, 0xF3BE75, 0xDF9328,
    0x3080AB, 0xF68C66, 0x15CB04, 0x0622FA, 0x1DE4D9, 0xA4B33D,
    0x8F1B57, 0x09CD36, 0xE9424E, 0xA4BE13, 0xB52333, 0x1AAAF0,
    0xA8654F, 0xA5C1D2, 0x0F3F0B, 0xCD785B, 0x76F923, 0x048B7B,
    0x721789, 0x53A6C6, 0xE26E6F, 0x00EBEF, 0x584A9B, 0xB7DAC4,
    0xBA66AA, 0xCFCF76, 0x1D02D1, 0x2DF1B1, 0xC1998C, 0x77ADC3,
    0xDA4886, 0xA05DF7, 0xF480C6, 0x2FF0AC, 0x9AECDD, 0xBC5C3F,
    0x6DDED0, 0x1FC790, 0xB6DB2A, 0x3A25A3, 0x9AAF00, 0x9353AD,
    0x0457B6, 0xB42D29, 0x7E804B, 0xA707DA, 0x0EAA76, 0xA1597B,
    0x2A1216, 0x2DB7DC, 0xFDE5FA, 0xFEDB89, 0xFDBE89, 0x6C76E4,
    0xFCA906, 0x70803E, 0x156E85, 0xFF87FD, 0x073E28, 0x336761,
    0x86182A, 0xEABD4D, 0xAFE7B3, 0x6E6D8F, 0x396795, 0x5BBF31,
    0x48D784, 0x16DF30, 0x432DC7, 0x356125, 0xCE70C9, 0xB8CB30,
    0xFD6CBF, 0xA200A4, 0xE46C05, 0xA0DD5A, 0x476F21, 0xD21262,
    0x845CB9, 0x496170, 0xE0566B, 0x015299, 0x375550, 0xB7D51E,
    0xC4F133, 0x5F6E13, 0xE4305D, 0xA92E85, 0xC3B21D, 0x3632A1,
    0xA4B708, 0xD4B1EA, 0x21F716, 0xE4698F, 0x77FF27, 0x80030C,
    0x2D408D, 0xA0CD4F, 0x99A520, 0xD3A2B3, 0x0A5D2F, 0x42F9B4,
    0xCBDA11, 0xD0BE7D, 0xC1DB9B, 0xBD17AB, 0x81A2CA, 0x5C6A08,
    0x17552E, 0x550027, 0xF0147F, 0x8607E1, 0x640B14, 0x8D4196,
    0xDEBE87, 0x2AFDDA, 0xB6256B, 0x34897B, 0xFEF305, 0x9EBFB9,
    0x4F6A68, 0xA82A4A, 0x5AC44F, 0xBCF82D, 0x985AD7, 0x95C7F4,
    0x8D4D0D, 0xA63A20, 0x5F57A4, 0xB13F14, 0x953880, 0x0120CC,
    0x86DD71, 0xB6DEC9, 0xF560BF, 0x11654D, 0x6B0701, 0xACB08C,
    0xD0C0B2, 0x485551, 0x0EFB1E, 0xC37295, 0x3B06A3, 0x3540C0,
    0x7BDC06, 0xCC45E0, 0xFA294E, 0xC8CAD6, 0x41F3E8, 0xDE647C,
    0xD8649B, 0x31BED9, 0xC397A4, 0xD45877, 0xC5E369, 0x13DAF0,
    0x3C3ABA, 0x461846, 0x5F7555, 0xF5BDD2, 0xC6926E, 0x5D2EAC,
    0xED440E, 0x423E1C, 0x87C461, 0xE9FD29, 0xF3D6E7, 0xCA7C22,
    0x35916F, 0xC5E008, 0x8DD7FF, 0xE26A6E, 0xC6FDB0, 0xC10893,
    0x745D7C, 0xB2AD6B, 0x9D6ECD, 0x7B723E, 0x6A11C6, 0xA9CFF7,
    0xDF7329, 0xBAC9B5, 0x5100B7, 0x0DB2E2, 0x24BA74, 0x607DE5,
    0x8AD874, 0x2C150D, 0x0C1881, 0x94667E, 0x162901, 0x767A9F,
    0xBEFDFD, 0xEF4556, 0x367ED9, 0x13D9EC, 0xB9BA8B, 0xFC97C4,
    0x27A831, 0xC36EF1, 0x36C594, 0x56A8D8, 0xB5A8B4, 0x0ECCCF,
    0x2D8912, 0x34576F, 0x89562C, 0xE3CE99, 0xB920D6, 0xAA5E6B,
    0x9C2A3E, 0xCC5F11, 0x4A0BFD, 0xFBF4E1, 0x6D3B8E, 0x2C86E2,
    0x84D4E9, 0xA9B4FC, 0xD1EEEF, 0xC9352E, 0x61392F, 0x442138,
    0xC8D91B, 0x0AFC81, 0x6A4AFB, 0xD81C2F, 0x84B453, 0x8C994E,
    0xCC2254, 0xDC552A, 0xD6C6C0, 0x96190B, 0xB8701A, 0x649569,
    0x605A26, 0xEE523F, 0x0F117F, 0x11B5F4, 0xF5CBFC, 0x2DBC34,
    0xEEBC34, 0xCC5DE8, 0x605EDD, 0x9B8E67, 0xEF3392, 0xB817C9,
    0x9B5861, 0xBC57E1, 0xC68351, 0x103ED8, 0x4871DD, 0xDD1C2D,
    0xA118AF, 0x462C21, 0xD7F359, 0x987AD9, 0xC0549E, 0xFA864F,
    0xFC0656, 0xAE79E5, 0x362289, 0x22AD38, 0xDC9367, 0xAAE855,
    0x382682, 0x9BE7CA, 0xA40D51, 0xB13399, 0x0ED7A9, 0x480569,
    0xF0B265, 0xA7887F, 0x974C88, 0x36D1F9, 0xB39221, 0x4A827B,
    0x21CF98, 0xDC9F40, 0x5547DC, 0x3A74E1, 0x42EB67, 0xDF9DFE,
    0x5FD45E, 0xA4677B, 0x7AACBA, 0xA2F655, 0x23882B, 0x55BA41,
    0x086E59, 0x862A21, 0x834739, 0xE6E389, 0xD49EE5, 0x40FB49,
    0xE956FF, 0xCA0F1C, 0x8A59C5, 0x2BFA94, 0xC5C1D3, 0xCFC50F,
    0xAE5ADB, 0x86C547, 0x624385, 0x3B8621, 0x94792C, 0x876110,
    0x7B4C2A, 0x1A2C80, 0x12BF43, 0x902688, 0x893C78, 0xE4C4A8,
    0x7BDBE5, 0xC23AC4, 0xEAF426, 0x8A67F7, 0xBF920D, 0x2BA365,
    0xB1933D, 0x0B7CBD, 0xDC51A4, 0x63DD27, 0xDDE169, 0x19949A,
    0x9529A8, 0x28CE68, 0xB4ED09, 0x209F44, 0xCA984E, 0x638270,
    0x237C7E, 0x32B90F, 0x8EF5A7, 0xE75614, 0x08F121, 0x2A9DB5,
    0x4D7E6F, 0x5119A5, 0xABF9B5, 0xD6DF82, 0x61DD96, 0x023616,
    0x9F3AC4, 0xA1A283, 0x6DED72, 0x7A8D39, 0xA9B882, 0x5C326B,
    0x5B2746, 0xED3400, 0x7700D2, 0x55F4FC, 0x4D5901, 0x8071E0,
};

const PIo2 = [_]f64{
    1.57079625129699707031e+00, // 0x3FF921FB, 0x40000000
    7.54978941586159635335e-08, // 0x3E74442D, 0x00000000
    5.39030252995776476554e-15, // 0x3CF84698, 0x80000000
    3.28200341580791294123e-22, // 0x3B78CC51, 0x60000000
    1.27065575308067607349e-29, // 0x39F01B83, 0x80000000
    1.22933308981111328932e-36, // 0x387A2520, 0x40000000
    2.73370053816464559624e-44, // 0x36E38222, 0x80000000
    2.16741683877804819444e-51, // 0x3569F31D, 0x00000000
};

/// Multiprecision reduction of x (broken into 24-bit chunks `x[0..nx]`
/// with exponent `e0`) modulo pi/2. Writes the result tail into `y` per
/// `prec` and returns the low 3 bits of the quadrant count. See the musl
/// `__rem_pio2_large` header for the full parameter contract.
fn remPio2Large(x: []const f64, y: []f64, e0: i32, nx: i32, prec: usize) i32 {
    var jz: i32 = undefined;
    var jx: i32 = undefined;
    var jv: i32 = undefined;
    var jp: i32 = undefined;
    var jk: i32 = undefined;
    var carry: i32 = undefined;
    var n: i32 = undefined;
    var iq: [20]i32 = undefined;
    var i: i32 = undefined;
    var j: i32 = undefined;
    var k: i32 = undefined;
    var m: i32 = undefined;
    var q0: i32 = undefined;
    var ih: i32 = undefined;

    var z: f64 = undefined;
    var fw: f64 = undefined;
    var f: [20]f64 = undefined;
    var fq: [20]f64 = undefined;
    var q: [20]f64 = undefined;

    // initialize jk
    jk = init_jk[prec];
    jp = jk;

    // determine jx,jv,q0, note that 3>q0
    jx = nx - 1;
    jv = @divFloor(e0 - 3, 24);
    if (jv < 0) jv = 0;
    q0 = e0 - 24 * (jv + 1);

    // set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
    j = jv - jx;
    m = jx + jk;
    i = 0;
    while (i <= m) : ({
        i += 1;
        j += 1;
    }) {
        f[@intCast(i)] = if (j < 0) 0.0 else @floatFromInt(ipio2[@intCast(j)]);
    }

    // compute q[0],q[1],...q[jk]
    i = 0;
    while (i <= jk) : (i += 1) {
        j = 0;
        fw = 0;
        while (j <= jx) : (j += 1) {
            fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
        }
        q[@intCast(i)] = fw;
    }

    jz = jk;

    // This is to handle a non-trivial goto translation from C.
    // An unconditional return statement is found at the end of this loop.
    recompute: while (true) {
        // distill q[] into iq[] reversingly
        i = 0;
        j = jz;
        z = q[@intCast(jz)];
        while (j > 0) : ({
            i += 1;
            j -= 1;
        }) {
            fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
            iq[@intCast(i)] = @intFromFloat(z - 0x1p24 * fw);
            z = q[@intCast(j - 1)] + fw;
        }

        // compute n
        z = math.scalbn(z, q0); // actual value of z
        z -= 8.0 * @floor(z * 0.125); // trim off integer >= 8
        n = @intFromFloat(z);
        z -= @floatFromInt(n);
        ih = 0;
        if (q0 > 0) { // need iq[jz-1] to determine n
            i = iq[@intCast(jz - 1)] >> @intCast(24 - q0);
            n += i;
            iq[@intCast(jz - 1)] -= i << @intCast(24 - q0);
            ih = iq[@intCast(jz - 1)] >> @intCast(23 - q0);
        } else if (q0 == 0) {
            ih = iq[@intCast(jz - 1)] >> 23;
        } else if (z >= 0.5) {
            ih = 2;
        }

        if (ih > 0) { // q > 0.5
            n += 1;
            carry = 0;
            i = 0;
            while (i < jz) : (i += 1) { // compute 1-q
                j = iq[@intCast(i)];
                if (carry == 0) {
                    if (j != 0) {
                        carry = 1;
                        iq[@intCast(i)] = 0x1000000 - j;
                    }
                } else {
                    iq[@intCast(i)] = 0xffffff - j;
                }
            }
            if (q0 > 0) { // rare case: chance is 1 in 12
                @branchHint(.unlikely);
                switch (q0) {
                    1 => iq[@intCast(jz - 1)] &= 0x7fffff,
                    2 => iq[@intCast(jz - 1)] &= 0x3fffff,
                    else => unreachable,
                }
            }
            if (ih == 2) {
                z = 1.0 - z;
                if (carry != 0) {
                    z -= math.scalbn(@as(f64, 1.0), q0);
                }
            }
        }

        // check if recomputation is needed
        if (z == 0.0) {
            j = 0;
            i = jz - 1;
            while (i >= jk) : (i -= 1) {
                j |= iq[@intCast(i)];
            }

            if (j == 0) { // need recomputation
                k = 1;
                while (iq[@intCast(jk - k)] == 0) : (k += 1) {
                    // k = no. of terms needed
                }

                i = jz + 1;
                while (i <= jz + k) : (i += 1) { // add q[jz+1] to q[jz+k]
                    f[@intCast(jx + i)] = @floatFromInt(ipio2[@intCast(jv + i)]);
                    j = 0;
                    fw = 0;
                    while (j <= jx) : (j += 1) {
                        fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
                    }
                    q[@intCast(i)] = fw;
                }
                jz += k;
                continue :recompute; // mimic goto recompute
            }
        }

        // chop off zero terms
        if (z == 0.0) {
            jz -= 1;
            q0 -= 24;
            while (iq[@intCast(jz)] == 0) {
                jz -= 1;
                q0 -= 24;
            }
        } else { // break z into 24-bit if necessary
            z = math.scalbn(z, -q0);
            if (z >= 0x1p24) {
                fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
                iq[@intCast(jz)] = @intFromFloat(z - 0x1p24 * fw);
                jz += 1;
                q0 += 24;
                iq[@intCast(jz)] = @intFromFloat(fw);
            } else {
                iq[@intCast(jz)] = @intFromFloat(z);
            }
        }

        // convert integer "bit" chunk to floating-point value
        fw = math.scalbn(@as(f64, 1.0), q0);
        i = jz;
        while (i >= 0) : (i -= 1) {
            q[@intCast(i)] = fw * @as(f64, @floatFromInt(iq[@intCast(i)]));
            fw *= 0x1p-24;
        }

        // compute PIo2[0,...,jp]*q[jz,...,0]
        i = jz;
        while (i >= 0) : (i -= 1) {
            fw = 0;
            k = 0;
            while (k <= jp and k <= jz - i) : (k += 1) {
                fw += PIo2[@intCast(k)] * q[@intCast(i + k)];
            }
            fq[@intCast(jz - i)] = fw;
        }

        // compress fq[] into y[]
        switch (prec) {
            0 => {
                fw = 0.0;
                i = jz;
                while (i >= 0) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                y[0] = if (ih == 0) fw else -fw;
            },

            1, 2 => {
                fw = 0.0;
                i = jz;
                while (i >= 0) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                // TODO: drop excess precision here once double_t is used
                fw = fw;
                y[0] = if (ih == 0) fw else -fw;
                fw = fq[0] - fw;
                i = 1;
                while (i <= jz) : (i += 1) {
                    fw += fq[@intCast(i)];
                }
                y[1] = if (ih == 0) fw else -fw;
            },
            3 => { // painful
                i = jz;
                while (i > 0) : (i -= 1) {
                    fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                    fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                    fq[@intCast(i - 1)] = fw;
                }
                i = jz;
                while (i > 1) : (i -= 1) {
                    fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                    fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                    fq[@intCast(i - 1)] = fw;
                }
                fw = 0;
                i = jz;
                while (i >= 2) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                if (ih == 0) {
                    y[0] = fq[0];
                    y[1] = fq[1];
                    y[2] = fw;
                } else {
                    y[0] = -fq[0];
                    y[1] = -fq[1];
                    y[2] = -fw;
                }
            },
            else => unreachable,
        }

        return n & 7;
    }
}

test "trig64 matches @sin/@cos/@tan on the reduced range" {
    // On the host where tests run, the vendored path must agree with the
    // builtin to <= a few ULP across small and reduced arguments. (Exact
    // bit-pinning lives in Expr_tests.zig against known reference values.)
    const xs = [_]f64{ 0.0, 0.2, 0.5, 0.8923, 1.0, 1.5, 2.0, 3.0, 3.5, 6.0, 12.0, 37.45, 89.123, 1000.25, 1e6 + 0.5 };
    for (xs) |x| {
        try std.testing.expectApproxEqAbs(@sin(x), sin64(x), 1e-12);
        try std.testing.expectApproxEqAbs(@cos(x), cos64(x), 1e-12);
        try std.testing.expectApproxEqAbs(@tan(x), tan64(x), 1e-9);
    }
}

test "trig64 totality: NaN / Inf -> NaN, signed zero" {
    try std.testing.expect(math.isNan(sin64(math.inf(f64))));
    try std.testing.expect(math.isNan(cos64(-math.inf(f64))));
    try std.testing.expect(math.isNan(tan64(math.nan(f64))));
    try std.testing.expect(cos64(0.0) == 1.0);
    try std.testing.expect(math.isPositiveZero(sin64(0.0)));
    try std.testing.expect(math.isNegativeZero(sin64(-0.0)));
}

// Exact-bit determinism pins. These bytes are produced by the vendored
// algorithm itself (pure strict-mode f64 `+ - *`), so they are
// host-INDEPENDENT by construction — native and both wasm32 artifacts must
// all return exactly these bits. This is the unit-level guard for the
// cross-host bit-identity guarantee that the corpus checks end to end. Each
// value was cross-checked against the host libm (`@sin`/`@cos`/`@tan`) and is
// correct to 0 ULP on the dev host; the test above re-verifies correctness on
// whatever host runs it. If a refactor or a table edit flips any byte that is
// a determinism break — investigate, don't silently re-baseline.
test "trig64 exact-bit pins across every reduction path" {
    const Case = struct { x: f64, s: u64, c: u64, t: u64 };
    const cases = [_]Case{
        // small kernel, |x| < pi/4
        .{ .x = 0.5, .s = 0x3fdeaee8744b05f0, .c = 0x3fec1528065b7d50, .t = 0x3fe17b4f5bf3474a },
        // tan |x| >= 0.6744 hits the pi/4 identity ("big") branch
        .{ .x = 0.7, .s = 0x3fe49d6e694619b8, .c = 0x3fe87996529f9d93, .t = 0x3feaf406c2fc78ae },
        .{ .x = 1.0, .s = 0x3feaed548f090cee, .c = 0x3fe14a280fb5068c, .t = 0x3ff8eb245cbee3a6 },
        // remPio2 direct quadrants n = 1..4 (covers sin/cos switch arms) and
        // the tan odd-quadrant accurate -1/(x+r) path.
        .{ .x = 2.0, .s = 0x3fed18f6ead1b446, .c = 0xbfdaa22657537205, .t = 0xc0017af62e0950f8 },
        .{ .x = 3.0, .s = 0x3fc210386db6d55b, .c = 0xbfefae04be85e5d2, .t = 0xbfc23ef71254b86f },
        .{ .x = 4.0, .s = 0xbfe837b9dddc1eae, .c = 0xbfe4eaa606db24c1, .t = 0x3ff2866f9be4de14 },
        .{ .x = 5.5, .s = 0xbfe693c94e0ab057, .c = 0x3fe6ad6c3c07d448, .t = 0xbfefdbd31615b07a },
        .{ .x = 6.0, .s = 0xbfd1e1f18ab0a2c0, .c = 0x3feeb9b7097822f5, .t = 0xbfd29fd86ebb95be },
        // medium Cody-Waite reduction (multi-round in `medium`)
        .{ .x = 100.0, .s = 0xbfe03425b78c4db8, .c = 0x3feb981dbf665fdf, .t = 0xbfe2ca74d62b5d38 },
        .{ .x = 1000.25, .s = 0x3fee1702343c0531, .c = 0x3fd5c7d948a31cf2, .t = 0x40061a9ac4ac0b18 },
        .{ .x = 123456.789, .s = 0xbfeff50e60ab53f9, .c = 0x3faa74d27c41b22a, .t = 0xc03353a85fe8d6d5 },
        // Payne-Hanek large-argument reduction, |x| > 2^20 * pi/2
        .{ .x = 1.0e7, .s = 0x3fdaea414a8a3352, .c = 0xbfed085be7a8f4a1, .t = 0xbfddaa7d34937ac4 },
        .{ .x = 1.0e15, .s = 0x3feb76f88136ceba, .c = 0xbfe06c154609d33e, .t = 0xbffac23600a95be4 },
        .{ .x = 1.0e22, .s = 0xbfeb453ab76bf397, .c = 0x3fe0be2cef01c8f4, .t = 0xbffa0f79c1b6b258 },
    };
    for (cases) |k| {
        try std.testing.expectEqual(k.s, @as(u64, @bitCast(sin64(k.x))));
        try std.testing.expectEqual(k.c, @as(u64, @bitCast(cos64(k.x))));
        try std.testing.expectEqual(k.t, @as(u64, @bitCast(tan64(k.x))));
    }
}

test "trig64 sign symmetry is exact: sin/tan odd, cos even" {
    // IEEE `+ - *` are sign-symmetric, so the whole algorithm negates
    // exactly: sin64(-x) is the bit-negation of sin64(x), etc. Spans every
    // reduction path so the quadrant/sign bookkeeping in remPio2 is exercised
    // for both signs.
    const xs = [_]f64{ 0.3, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.5, 100.0, 1000.25, 1.0e7, 1.0e15, 1.0e22 };
    for (xs) |x| {
        try std.testing.expectEqual(@as(u64, @bitCast(-sin64(x))), @as(u64, @bitCast(sin64(-x))));
        try std.testing.expectEqual(@as(u64, @bitCast(cos64(x))), @as(u64, @bitCast(cos64(-x))));
        try std.testing.expectEqual(@as(u64, @bitCast(-tan64(x))), @as(u64, @bitCast(tan64(-x))));
    }
}

test "trig64 special values: NaN/Inf -> NaN, signed zero, subnormal short-circuit" {
    const nan = math.nan(f64);
    const inf = math.inf(f64);
    inline for (.{ inf, -inf, nan }) |bad| {
        try std.testing.expect(math.isNan(sin64(bad)));
        try std.testing.expect(math.isNan(cos64(bad)));
        try std.testing.expect(math.isNan(tan64(bad)));
    }
    // signed zero flows through the tiny short-circuits unchanged
    try std.testing.expect(math.isPositiveZero(sin64(0.0)));
    try std.testing.expect(math.isNegativeZero(sin64(-0.0)));
    try std.testing.expect(cos64(0.0) == 1.0);
    try std.testing.expect(cos64(-0.0) == 1.0);
    try std.testing.expect(math.isPositiveZero(tan64(0.0)));
    try std.testing.expect(math.isNegativeZero(tan64(-0.0)));
    // smallest positive subnormal: below every kernel threshold, returned as-is
    const sub = math.floatTrueMin(f64);
    try std.testing.expectEqual(sub, sin64(sub));
    try std.testing.expectEqual(@as(f64, 1.0), cos64(sub));
    try std.testing.expectEqual(sub, tan64(sub));
}

test "trig64 identities hold across a dense sweep" {
    // Broad sanity over small + medium reduction: sin^2 + cos^2 == 1 to a
    // couple ULP everywhere, and tan == sin/cos away from the poles.
    var x: f64 = -30.0;
    while (x <= 30.0) : (x += 0.013) {
        const s = sin64(x);
        const c = cos64(x);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), s * s + c * c, 1e-15);
        if (@abs(c) > 0.1) {
            try std.testing.expectApproxEqRel(s / c, tan64(x), 1e-12);
        }
    }
}

// ===========================================================================
// Exponential family: exp64 (log64 / pow64 follow in this section).
//
// Same determinism rationale as the circular family above — vendored pure-f64
// software so native and both wasm32 artifacts agree bit-for-bit, rather than
// relying on whichever libm happens to link behind the `@exp` builtin.
// ===========================================================================

/// exp(x). Bit-identical across native and WASM. Totality: NaN→NaN,
/// +Inf→+Inf, −Inf→+0, overflow (x ≳ 709.78)→+Inf, underflow
/// (x ≲ −745.13)→+0. Pure f64 `+ − * /`, no libm call, no allocation.
/// Ported from compiler_rt/exp.zig (musl exp.c), f64 path only.
pub fn exp64(x_: f64) f64 {
    const half = [_]f64{ 0.5, -0.5 };
    const ln2hi: f64 = 6.93147180369123816490e-01;
    const ln2lo: f64 = 1.90821492927058770002e-10;
    const invln2: f64 = 1.44269504088896338700e+00;
    const P1: f64 = 1.66666666666666019037e-01;
    const P2: f64 = -2.77777777770155933842e-03;
    const P3: f64 = 6.61375632143793436117e-05;
    const P4: f64 = -1.65339022054652515390e-06;
    const P5: f64 = 4.13813679705723846039e-08;

    var x = x_;
    const ux: u64 = @bitCast(x);
    var hx = ux >> 32;
    const sign: i32 = @intCast(hx >> 31);
    hx &= 0x7FFFFFFF;

    if (math.isNan(x)) {
        return x;
    }

    // |x| >= 708.39 or nan
    if (hx >= 0x4086232B) {
        // nan
        if (hx > 0x7FF00000) {
            return x;
        }
        if (x > 709.782712893383973096) {
            // overflow if x != inf
            return math.inf(f64);
        }
        if (x < -708.39641853226410622) {
            // underflow if x != -inf
            if (x < -745.13321910194110842) {
                return 0;
            }
        }
    }

    // argument reduction
    var k: i32 = undefined;
    var hi: f64 = undefined;
    var lo: f64 = undefined;

    // |x| > 0.5 * ln2
    if (hx > 0x3FD62E42) {
        // |x| >= 1.5 * ln2
        if (hx > 0x3FF0A2B2) {
            k = @intFromFloat(invln2 * x + half[@intCast(sign)]);
        } else {
            k = 1 - sign - sign;
        }

        const dk: f64 = @floatFromInt(k);
        hi = x - dk * ln2hi;
        lo = dk * ln2lo;
        x = hi - lo;
    }
    // |x| > 2^(-28)
    else if (hx > 0x3E300000) {
        k = 0;
        hi = x;
        lo = 0;
    } else {
        return 1 + x;
    }

    const xx = x * x;
    const c = x - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))));
    const y = 1 + (x * c / (2 - c) - lo + hi);

    if (k == 0) {
        return y;
    } else {
        return math.scalbn(y, k);
    }
}

test "exp64 matches @exp on the host (sanity)" {
    // The vendored path must agree with the builtin to a handful of ULP across
    // the finite, non-flushing range. Exact bit-pinning is the test below.
    const xs = [_]f64{ -20.0, -7.0, -3.5, -1.0, -0.3, 0.0, 0.3, 0.5, 1.0, 2.5, 7.0, 20.0, 100.0, 500.0 };
    for (xs) |x| {
        try std.testing.expectApproxEqRel(@exp(x), exp64(x), 1e-14);
    }
}

test "exp64 totality: NaN/Inf, overflow, underflow, subnormal" {
    const nan = math.nan(f64);
    const inf = math.inf(f64);
    try std.testing.expect(math.isNan(exp64(nan)));
    try std.testing.expect(math.isNan(exp64(math.snan(f64))));
    try std.testing.expectEqual(inf, exp64(inf));
    try std.testing.expect(math.isPositiveZero(exp64(-inf)));
    try std.testing.expectEqual(@as(f64, 1.0), exp64(0.0));
    try std.testing.expectEqual(@as(f64, 1.0), exp64(-0.0));
    try std.testing.expectEqual(@as(f64, 2.0), exp64(math.ln2));
    // overflow: last finite, then first +Inf
    try std.testing.expectEqual(@as(f64, 0x1.fffffffffff2ap+1023), exp64(0x1.62e42fefa39efp+9));
    try std.testing.expectEqual(inf, exp64(0x1.62e42fefa39f0p+9));
    // underflow: last nonzero (smallest subnormal), then first +0
    try std.testing.expectEqual(@as(f64, 0x1p-1074), exp64(-0x1.74910d52d3051p+9));
    try std.testing.expect(math.isPositiveZero(exp64(-0x1.74910d52d3052p+9)));
    // first subnormal result
    try std.testing.expectEqual(@as(f64, 0x1.ffffffffffcf8p-1023), exp64(-0x1.6232bdd7abcd3p+9));
}

// Exact-bit determinism pins — same contract as the trig pins above: these
// bytes are exp64's own pure strict-mode f64 output, host-INDEPENDENT by
// construction, so native and both wasm32 artifacts must all return exactly
// these. Vectors are reused verbatim from Zig's compiler_rt exp() test — the
// same fdlibm algorithm exp64 ports — so a passing run also proves the
// transcription is byte-faithful. The sanity test above re-checks correctness
// against the host `@exp`. A flipped byte here is a determinism break:
// investigate, don't silently re-baseline.
test "exp64 exact-bit pins" {
    try std.testing.expectEqual(@as(f64, 0x1.490327ea61235p-12), exp64(-0x1.02239f3c6a8f1p+3));
    try std.testing.expectEqual(@as(f64, 0x1.34712ed238c04p+6), exp64(0x1.161868e18bc67p+2));
    try std.testing.expectEqual(@as(f64, 0x1.e06b1b6c18e64p-13), exp64(-0x1.0c34b3e01e6e7p+3));
    try std.testing.expectEqual(@as(f64, 0x1.7dd47f810e68cp-10), exp64(-0x1.a206f0a19dcc4p+2));
    try std.testing.expectEqual(@as(f64, 0x1.4abc77496e07ep+13), exp64(0x1.288bbb0d6a1e6p+3));
    try std.testing.expectEqual(@as(f64, 0x1.f04a9c1080500p+0), exp64(0x1.52efd0cd80497p-1));
    try std.testing.expectEqual(@as(f64, 0x1.54f1e0fd3ea0dp-1), exp64(-0x1.a05cc754481d1p-2));
    try std.testing.expectEqual(@as(f64, 0x1.c0f6266a6a547p+0), exp64(0x1.1f9ef934745cbp-1));
    try std.testing.expectEqual(@as(f64, 0x1.1599b1d4a25fbp+1), exp64(0x1.8c5db097f7442p-1));
    try std.testing.expectEqual(@as(f64, 0x1.03b5728a00229p-1), exp64(-0x1.5b86ea8118a0ep-1));
    try std.testing.expectEqual(@as(f64, 0x1.76eeed45a0634p+20), exp64(0x1.c7d30fb825911p+3));
    try std.testing.expectEqual(@as(f64, 0x1.52d3eb7be6844p+25), exp64(0x1.19be709de7505p+4));
    try std.testing.expectEqual(@as(f64, 0x1.1c28d16bb3222p-5), exp64(-0x1.ae41a1079de4dp+1));
    try std.testing.expectEqual(@as(f64, 0x1.47efa6ddd0d22p-28), exp64(-0x1.329153103b871p+4));
}

/// log(x), natural logarithm. Bit-identical across native and WASM.
/// Totality: x<0 or NaN→NaN, ±0→−Inf, 1→+0, +Inf→+Inf. Pure f64 `+ − * /`
/// plus a 128-entry table, no libm call, no allocation. Ported from
/// compiler_rt/log.zig (musl log.c, Arm optimized-routines), f64 path only.
pub fn log64(x: f64) f64 {
    const poly1 = [_]f64{
        -0x1p-1,
        0x1.5555555555577p-2,
        -0x1.ffffffffffdcbp-3,
        0x1.999999995dd0cp-3,
        -0x1.55555556745a7p-3,
        0x1.24924a344de3p-3,
        -0x1.fffffa4423d65p-4,
        0x1.c7184282ad6cap-4,
        -0x1.999eb43b068ffp-4,
        0x1.78182f7afd085p-4,
        -0x1.5521375d145cdp-4,
    };

    const poly = [_]f64{
        -0x1.0000000000001p-1,
        0x1.555555551305bp-2,
        -0x1.fffffffeb459p-3,
        0x1.999b324f10111p-3,
        -0x1.55575e506c89fp-3,
    };

    const tab = [128]struct { invc: f64, logc: f64 }{
        .{ .invc = 0x1.734f0c3e0de9fp+0, .logc = -0x1.7cc7f79e69000p-2 },
        .{ .invc = 0x1.713786a2ce91fp+0, .logc = -0x1.76feec20d0000p-2 },
        .{ .invc = 0x1.6f26008fab5a0p+0, .logc = -0x1.713e31351e000p-2 },
        .{ .invc = 0x1.6d1a61f138c7dp+0, .logc = -0x1.6b85b38287800p-2 },
        .{ .invc = 0x1.6b1490bc5b4d1p+0, .logc = -0x1.65d5590807800p-2 },
        .{ .invc = 0x1.69147332f0cbap+0, .logc = -0x1.602d076180000p-2 },
        .{ .invc = 0x1.6719f18224223p+0, .logc = -0x1.5a8ca86909000p-2 },
        .{ .invc = 0x1.6524f99a51ed9p+0, .logc = -0x1.54f4356035000p-2 },
        .{ .invc = 0x1.63356aa8f24c4p+0, .logc = -0x1.4f637c36b4000p-2 },
        .{ .invc = 0x1.614b36b9ddc14p+0, .logc = -0x1.49da7fda85000p-2 },
        .{ .invc = 0x1.5f66452c65c4cp+0, .logc = -0x1.445923989a800p-2 },
        .{ .invc = 0x1.5d867b5912c4fp+0, .logc = -0x1.3edf439b0b800p-2 },
        .{ .invc = 0x1.5babccb5b90dep+0, .logc = -0x1.396ce448f7000p-2 },
        .{ .invc = 0x1.59d61f2d91a78p+0, .logc = -0x1.3401e17bda000p-2 },
        .{ .invc = 0x1.5805612465687p+0, .logc = -0x1.2e9e2ef468000p-2 },
        .{ .invc = 0x1.56397cee76bd3p+0, .logc = -0x1.2941b3830e000p-2 },
        .{ .invc = 0x1.54725e2a77f93p+0, .logc = -0x1.23ec58cda8800p-2 },
        .{ .invc = 0x1.52aff42064583p+0, .logc = -0x1.1e9e129279000p-2 },
        .{ .invc = 0x1.50f22dbb2bddfp+0, .logc = -0x1.1956d2b48f800p-2 },
        .{ .invc = 0x1.4f38f4734ded7p+0, .logc = -0x1.141679ab9f800p-2 },
        .{ .invc = 0x1.4d843cfde2840p+0, .logc = -0x1.0edd094ef9800p-2 },
        .{ .invc = 0x1.4bd3ec078a3c8p+0, .logc = -0x1.09aa518db1000p-2 },
        .{ .invc = 0x1.4a27fc3e0258ap+0, .logc = -0x1.047e65263b800p-2 },
        .{ .invc = 0x1.4880524d48434p+0, .logc = -0x1.feb224586f000p-3 },
        .{ .invc = 0x1.46dce1b192d0bp+0, .logc = -0x1.f474a7517b000p-3 },
        .{ .invc = 0x1.453d9d3391854p+0, .logc = -0x1.ea4443d103000p-3 },
        .{ .invc = 0x1.43a2744b4845ap+0, .logc = -0x1.e020d44e9b000p-3 },
        .{ .invc = 0x1.420b54115f8fbp+0, .logc = -0x1.d60a22977f000p-3 },
        .{ .invc = 0x1.40782da3ef4b1p+0, .logc = -0x1.cc00104959000p-3 },
        .{ .invc = 0x1.3ee8f5d57fe8fp+0, .logc = -0x1.c202956891000p-3 },
        .{ .invc = 0x1.3d5d9a00b4ce9p+0, .logc = -0x1.b81178d811000p-3 },
        .{ .invc = 0x1.3bd60c010c12bp+0, .logc = -0x1.ae2c9ccd3d000p-3 },
        .{ .invc = 0x1.3a5242b75dab8p+0, .logc = -0x1.a45402e129000p-3 },
        .{ .invc = 0x1.38d22cd9fd002p+0, .logc = -0x1.9a877681df000p-3 },
        .{ .invc = 0x1.3755bc5847a1cp+0, .logc = -0x1.90c6d69483000p-3 },
        .{ .invc = 0x1.35dce49ad36e2p+0, .logc = -0x1.87120a645c000p-3 },
        .{ .invc = 0x1.34679984dd440p+0, .logc = -0x1.7d68fb4143000p-3 },
        .{ .invc = 0x1.32f5cceffcb24p+0, .logc = -0x1.73cb83c627000p-3 },
        .{ .invc = 0x1.3187775a10d49p+0, .logc = -0x1.6a39a9b376000p-3 },
        .{ .invc = 0x1.301c8373e3990p+0, .logc = -0x1.60b3154b7a000p-3 },
        .{ .invc = 0x1.2eb4ebb95f841p+0, .logc = -0x1.5737d76243000p-3 },
        .{ .invc = 0x1.2d50a0219a9d1p+0, .logc = -0x1.4dc7b8fc23000p-3 },
        .{ .invc = 0x1.2bef9a8b7fd2ap+0, .logc = -0x1.4462c51d20000p-3 },
        .{ .invc = 0x1.2a91c7a0c1babp+0, .logc = -0x1.3b08abc830000p-3 },
        .{ .invc = 0x1.293726014b530p+0, .logc = -0x1.31b996b490000p-3 },
        .{ .invc = 0x1.27dfa5757a1f5p+0, .logc = -0x1.2875490a44000p-3 },
        .{ .invc = 0x1.268b39b1d3bbfp+0, .logc = -0x1.1f3b9f879a000p-3 },
        .{ .invc = 0x1.2539d838ff5bdp+0, .logc = -0x1.160c8252ca000p-3 },
        .{ .invc = 0x1.23eb7aac9083bp+0, .logc = -0x1.0ce7f57f72000p-3 },
        .{ .invc = 0x1.22a012ba940b6p+0, .logc = -0x1.03cdc49fea000p-3 },
        .{ .invc = 0x1.2157996cc4132p+0, .logc = -0x1.f57bdbc4b8000p-4 },
        .{ .invc = 0x1.201201dd2fc9bp+0, .logc = -0x1.e370896404000p-4 },
        .{ .invc = 0x1.1ecf4494d480bp+0, .logc = -0x1.d17983ef94000p-4 },
        .{ .invc = 0x1.1d8f5528f6569p+0, .logc = -0x1.bf9674ed8a000p-4 },
        .{ .invc = 0x1.1c52311577e7cp+0, .logc = -0x1.adc79202f6000p-4 },
        .{ .invc = 0x1.1b17c74cb26e9p+0, .logc = -0x1.9c0c3e7288000p-4 },
        .{ .invc = 0x1.19e010c2c1ab6p+0, .logc = -0x1.8a646b372c000p-4 },
        .{ .invc = 0x1.18ab07bb670bdp+0, .logc = -0x1.78d01b3ac0000p-4 },
        .{ .invc = 0x1.1778a25efbcb6p+0, .logc = -0x1.674f145380000p-4 },
        .{ .invc = 0x1.1648d354c31dap+0, .logc = -0x1.55e0e6d878000p-4 },
        .{ .invc = 0x1.151b990275fddp+0, .logc = -0x1.4485cdea1e000p-4 },
        .{ .invc = 0x1.13f0ea432d24cp+0, .logc = -0x1.333d94d6aa000p-4 },
        .{ .invc = 0x1.12c8b7210f9dap+0, .logc = -0x1.22079f8c56000p-4 },
        .{ .invc = 0x1.11a3028ecb531p+0, .logc = -0x1.10e4698622000p-4 },
        .{ .invc = 0x1.107fbda8434afp+0, .logc = -0x1.ffa6c6ad20000p-5 },
        .{ .invc = 0x1.0f5ee0f4e6bb3p+0, .logc = -0x1.dda8d4a774000p-5 },
        .{ .invc = 0x1.0e4065d2a9fcep+0, .logc = -0x1.bbcece4850000p-5 },
        .{ .invc = 0x1.0d244632ca521p+0, .logc = -0x1.9a1894012c000p-5 },
        .{ .invc = 0x1.0c0a77ce2981ap+0, .logc = -0x1.788583302c000p-5 },
        .{ .invc = 0x1.0af2f83c636d1p+0, .logc = -0x1.5715e67d68000p-5 },
        .{ .invc = 0x1.09ddb98a01339p+0, .logc = -0x1.35c8a49658000p-5 },
        .{ .invc = 0x1.08cabaf52e7dfp+0, .logc = -0x1.149e364154000p-5 },
        .{ .invc = 0x1.07b9f2f4e28fbp+0, .logc = -0x1.e72c082eb8000p-6 },
        .{ .invc = 0x1.06ab58c358f19p+0, .logc = -0x1.a55f152528000p-6 },
        .{ .invc = 0x1.059eea5ecf92cp+0, .logc = -0x1.63d62cf818000p-6 },
        .{ .invc = 0x1.04949cdd12c90p+0, .logc = -0x1.228fb8caa0000p-6 },
        .{ .invc = 0x1.038c6c6f0ada9p+0, .logc = -0x1.c317b20f90000p-7 },
        .{ .invc = 0x1.02865137932a9p+0, .logc = -0x1.419355daa0000p-7 },
        .{ .invc = 0x1.0182427ea7348p+0, .logc = -0x1.81203c2ec0000p-8 },
        .{ .invc = 0x1.008040614b195p+0, .logc = -0x1.0040979240000p-9 },
        .{ .invc = 0x1.fe01ff726fa1ap-1, .logc = 0x1.feff384900000p-9 },
        .{ .invc = 0x1.fa11cc261ea74p-1, .logc = 0x1.7dc41353d0000p-7 },
        .{ .invc = 0x1.f6310b081992ep-1, .logc = 0x1.3cea3c4c28000p-6 },
        .{ .invc = 0x1.f25f63ceeadcdp-1, .logc = 0x1.b9fc114890000p-6 },
        .{ .invc = 0x1.ee9c8039113e7p-1, .logc = 0x1.1b0d8ce110000p-5 },
        .{ .invc = 0x1.eae8078cbb1abp-1, .logc = 0x1.58a5bd001c000p-5 },
        .{ .invc = 0x1.e741aa29d0c9bp-1, .logc = 0x1.95c8340d88000p-5 },
        .{ .invc = 0x1.e3a91830a99b5p-1, .logc = 0x1.d276aef578000p-5 },
        .{ .invc = 0x1.e01e009609a56p-1, .logc = 0x1.07598e598c000p-4 },
        .{ .invc = 0x1.dca01e577bb98p-1, .logc = 0x1.253f5e30d2000p-4 },
        .{ .invc = 0x1.d92f20b7c9103p-1, .logc = 0x1.42edd8b380000p-4 },
        .{ .invc = 0x1.d5cac66fb5ccep-1, .logc = 0x1.606598757c000p-4 },
        .{ .invc = 0x1.d272caa5ede9dp-1, .logc = 0x1.7da76356a0000p-4 },
        .{ .invc = 0x1.cf26e3e6b2ccdp-1, .logc = 0x1.9ab434e1c6000p-4 },
        .{ .invc = 0x1.cbe6da2a77902p-1, .logc = 0x1.b78c7bb0d6000p-4 },
        .{ .invc = 0x1.c8b266d37086dp-1, .logc = 0x1.d431332e72000p-4 },
        .{ .invc = 0x1.c5894bd5d5804p-1, .logc = 0x1.f0a3171de6000p-4 },
        .{ .invc = 0x1.c26b533bb9f8cp-1, .logc = 0x1.067152b914000p-3 },
        .{ .invc = 0x1.bf583eeece73fp-1, .logc = 0x1.147858292b000p-3 },
        .{ .invc = 0x1.bc4fd75db96c1p-1, .logc = 0x1.2266ecdca3000p-3 },
        .{ .invc = 0x1.b951e0c864a28p-1, .logc = 0x1.303d7a6c55000p-3 },
        .{ .invc = 0x1.b65e2c5ef3e2cp-1, .logc = 0x1.3dfc33c331000p-3 },
        .{ .invc = 0x1.b374867c9888bp-1, .logc = 0x1.4ba366b7a8000p-3 },
        .{ .invc = 0x1.b094b211d304ap-1, .logc = 0x1.5933928d1f000p-3 },
        .{ .invc = 0x1.adbe885f2ef7ep-1, .logc = 0x1.66acd2418f000p-3 },
        .{ .invc = 0x1.aaf1d31603da2p-1, .logc = 0x1.740f8ec669000p-3 },
        .{ .invc = 0x1.a82e63fd358a7p-1, .logc = 0x1.815c0f51af000p-3 },
        .{ .invc = 0x1.a5740ef09738bp-1, .logc = 0x1.8e92954f68000p-3 },
        .{ .invc = 0x1.a2c2a90ab4b27p-1, .logc = 0x1.9bb3602f84000p-3 },
        .{ .invc = 0x1.a01a01393f2d1p-1, .logc = 0x1.a8bed1c2c0000p-3 },
        .{ .invc = 0x1.9d79f24db3c1bp-1, .logc = 0x1.b5b515c01d000p-3 },
        .{ .invc = 0x1.9ae2505c7b190p-1, .logc = 0x1.c2967ccbcc000p-3 },
        .{ .invc = 0x1.9852ef297ce2fp-1, .logc = 0x1.cf635d5486000p-3 },
        .{ .invc = 0x1.95cbaeea44b75p-1, .logc = 0x1.dc1bd3446c000p-3 },
        .{ .invc = 0x1.934c69de74838p-1, .logc = 0x1.e8c01b8cfe000p-3 },
        .{ .invc = 0x1.90d4f2f6752e6p-1, .logc = 0x1.f5509c0179000p-3 },
        .{ .invc = 0x1.8e6528effd79dp-1, .logc = 0x1.00e6c121fb800p-2 },
        .{ .invc = 0x1.8bfce9fcc007cp-1, .logc = 0x1.071b80e93d000p-2 },
        .{ .invc = 0x1.899c0dabec30ep-1, .logc = 0x1.0d46b9e867000p-2 },
        .{ .invc = 0x1.87427aa2317fbp-1, .logc = 0x1.13687334bd000p-2 },
        .{ .invc = 0x1.84f00acb39a08p-1, .logc = 0x1.1980d67234800p-2 },
        .{ .invc = 0x1.82a49e8653e55p-1, .logc = 0x1.1f8ffe0cc8000p-2 },
        .{ .invc = 0x1.8060195f40260p-1, .logc = 0x1.2595fd7636800p-2 },
        .{ .invc = 0x1.7e22563e0a329p-1, .logc = 0x1.2b9300914a800p-2 },
        .{ .invc = 0x1.7beb377dcb5adp-1, .logc = 0x1.3187210436000p-2 },
        .{ .invc = 0x1.79baa679725c2p-1, .logc = 0x1.377266dec1800p-2 },
        .{ .invc = 0x1.77907f2170657p-1, .logc = 0x1.3d54ffbaf3000p-2 },
        .{ .invc = 0x1.756cadbd6130cp-1, .logc = 0x1.432eee32fe000p-2 },
    };

    const tab2 = [128]struct { chi: f64, clo: f64 }{
        .{ .chi = 0x1.61000014fb66bp-1, .clo = 0x1.e026c91425b3cp-56 },
        .{ .chi = 0x1.63000034db495p-1, .clo = 0x1.dbfea48005d41p-55 },
        .{ .chi = 0x1.650000d94d478p-1, .clo = 0x1.e7fa786d6a5b7p-55 },
        .{ .chi = 0x1.67000074e6fadp-1, .clo = 0x1.1fcea6b54254cp-57 },
        .{ .chi = 0x1.68ffffedf0faep-1, .clo = -0x1.c7e274c590efdp-56 },
        .{ .chi = 0x1.6b0000763c5bcp-1, .clo = -0x1.ac16848dcda01p-55 },
        .{ .chi = 0x1.6d0001e5cc1f6p-1, .clo = 0x1.33f1c9d499311p-55 },
        .{ .chi = 0x1.6efffeb05f63ep-1, .clo = -0x1.e80041ae22d53p-56 },
        .{ .chi = 0x1.710000e86978p-1, .clo = 0x1.bff6671097952p-56 },
        .{ .chi = 0x1.72ffffc67e912p-1, .clo = 0x1.c00e226bd8724p-55 },
        .{ .chi = 0x1.74fffdf81116ap-1, .clo = -0x1.e02916ef101d2p-57 },
        .{ .chi = 0x1.770000f679c9p-1, .clo = -0x1.7fc71cd549c74p-57 },
        .{ .chi = 0x1.78ffffa7ec835p-1, .clo = 0x1.1bec19ef50483p-55 },
        .{ .chi = 0x1.7affffe20c2e6p-1, .clo = -0x1.07e1729cc6465p-56 },
        .{ .chi = 0x1.7cfffed3fc9p-1, .clo = -0x1.08072087b8b1cp-55 },
        .{ .chi = 0x1.7efffe9261a76p-1, .clo = 0x1.dc0286d9df9aep-55 },
        .{ .chi = 0x1.81000049ca3e8p-1, .clo = 0x1.97fd251e54c33p-55 },
        .{ .chi = 0x1.8300017932c8fp-1, .clo = -0x1.afee9b630f381p-55 },
        .{ .chi = 0x1.850000633739cp-1, .clo = 0x1.9bfbf6b6535bcp-55 },
        .{ .chi = 0x1.87000204289c6p-1, .clo = -0x1.bbf65f3117b75p-55 },
        .{ .chi = 0x1.88fffebf57904p-1, .clo = -0x1.9006ea23dcb57p-55 },
        .{ .chi = 0x1.8b00022bc04dfp-1, .clo = -0x1.d00df38e04b0ap-56 },
        .{ .chi = 0x1.8cfffe50c1b8ap-1, .clo = -0x1.8007146ff9f05p-55 },
        .{ .chi = 0x1.8effffc918e43p-1, .clo = 0x1.3817bd07a7038p-55 },
        .{ .chi = 0x1.910001efa5fc7p-1, .clo = 0x1.93e9176dfb403p-55 },
        .{ .chi = 0x1.9300013467bb9p-1, .clo = 0x1.f804e4b980276p-56 },
        .{ .chi = 0x1.94fffe6ee076fp-1, .clo = -0x1.f7ef0d9ff622ep-55 },
        .{ .chi = 0x1.96fffde3c12d1p-1, .clo = -0x1.082aa962638bap-56 },
        .{ .chi = 0x1.98ffff4458a0dp-1, .clo = -0x1.7801b9164a8efp-55 },
        .{ .chi = 0x1.9afffdd982e3ep-1, .clo = -0x1.740e08a5a9337p-55 },
        .{ .chi = 0x1.9cfffed49fb66p-1, .clo = 0x1.fce08c19bep-60 },
        .{ .chi = 0x1.9f00020f19c51p-1, .clo = -0x1.a3faa27885b0ap-55 },
        .{ .chi = 0x1.a10001145b006p-1, .clo = 0x1.4ff489958da56p-56 },
        .{ .chi = 0x1.a300007bbf6fap-1, .clo = 0x1.cbeab8a2b6d18p-55 },
        .{ .chi = 0x1.a500010971d79p-1, .clo = 0x1.8fecadd78793p-55 },
        .{ .chi = 0x1.a70001df52e48p-1, .clo = -0x1.f41763dd8abdbp-55 },
        .{ .chi = 0x1.a90001c593352p-1, .clo = -0x1.ebf0284c27612p-55 },
        .{ .chi = 0x1.ab0002a4f3e4bp-1, .clo = -0x1.9fd043cff3f5fp-57 },
        .{ .chi = 0x1.acfffd7ae1ed1p-1, .clo = -0x1.23ee7129070b4p-55 },
        .{ .chi = 0x1.aefffee510478p-1, .clo = 0x1.a063ee00edea3p-57 },
        .{ .chi = 0x1.b0fffdb650d5bp-1, .clo = 0x1.a06c8381f0ab9p-58 },
        .{ .chi = 0x1.b2ffffeaaca57p-1, .clo = -0x1.9011e74233c1dp-56 },
        .{ .chi = 0x1.b4fffd995badcp-1, .clo = -0x1.9ff1068862a9fp-56 },
        .{ .chi = 0x1.b7000249e659cp-1, .clo = 0x1.aff45d0864f3ep-55 },
        .{ .chi = 0x1.b8ffff987164p-1, .clo = 0x1.cfe7796c2c3f9p-56 },
        .{ .chi = 0x1.bafffd204cb4fp-1, .clo = -0x1.3ff27eef22bc4p-57 },
        .{ .chi = 0x1.bcfffd2415c45p-1, .clo = -0x1.cffb7ee3bea21p-57 },
        .{ .chi = 0x1.beffff86309dfp-1, .clo = -0x1.14103972e0b5cp-55 },
        .{ .chi = 0x1.c0fffe1b57653p-1, .clo = 0x1.bc16494b76a19p-55 },
        .{ .chi = 0x1.c2ffff1fa57e3p-1, .clo = -0x1.4feef8d30c6edp-57 },
        .{ .chi = 0x1.c4fffdcbfe424p-1, .clo = -0x1.43f68bcec4775p-55 },
        .{ .chi = 0x1.c6fffed54b9f7p-1, .clo = 0x1.47ea3f053e0ecp-55 },
        .{ .chi = 0x1.c8fffeb998fd5p-1, .clo = 0x1.383068df992f1p-56 },
        .{ .chi = 0x1.cb0002125219ap-1, .clo = -0x1.8fd8e64180e04p-57 },
        .{ .chi = 0x1.ccfffdd94469cp-1, .clo = 0x1.e7ebe1cc7ea72p-55 },
        .{ .chi = 0x1.cefffeafdc476p-1, .clo = 0x1.ebe39ad9f88fep-55 },
        .{ .chi = 0x1.d1000169af82bp-1, .clo = 0x1.57d91a8b95a71p-56 },
        .{ .chi = 0x1.d30000d0ff71dp-1, .clo = 0x1.9c1906970c7dap-55 },
        .{ .chi = 0x1.d4fffea790fc4p-1, .clo = -0x1.80e37c558fe0cp-58 },
        .{ .chi = 0x1.d70002edc87e5p-1, .clo = -0x1.f80d64dc10f44p-56 },
        .{ .chi = 0x1.d900021dc82aap-1, .clo = -0x1.47c8f94fd5c5cp-56 },
        .{ .chi = 0x1.dafffd86b0283p-1, .clo = 0x1.c7f1dc521617ep-55 },
        .{ .chi = 0x1.dd000296c4739p-1, .clo = 0x1.8019eb2ffb153p-55 },
        .{ .chi = 0x1.defffe54490f5p-1, .clo = 0x1.e00d2c652cc89p-57 },
        .{ .chi = 0x1.e0fffcdabf694p-1, .clo = -0x1.f8340202d69d2p-56 },
        .{ .chi = 0x1.e2fffdb52c8ddp-1, .clo = 0x1.b00c1ca1b0864p-56 },
        .{ .chi = 0x1.e4ffff24216efp-1, .clo = 0x1.2ffa8b094ab51p-56 },
        .{ .chi = 0x1.e6fffe88a5e11p-1, .clo = -0x1.7f673b1efbe59p-58 },
        .{ .chi = 0x1.e9000119eff0dp-1, .clo = -0x1.4808d5e0bc801p-55 },
        .{ .chi = 0x1.eafffdfa51744p-1, .clo = 0x1.80006d54320b5p-56 },
        .{ .chi = 0x1.ed0001a127fa1p-1, .clo = -0x1.002f860565c92p-58 },
        .{ .chi = 0x1.ef00007babcc4p-1, .clo = -0x1.540445d35e611p-55 },
        .{ .chi = 0x1.f0ffff57a8d02p-1, .clo = -0x1.ffb3139ef9105p-59 },
        .{ .chi = 0x1.f30001ee58ac7p-1, .clo = 0x1.a81acf2731155p-55 },
        .{ .chi = 0x1.f4ffff5823494p-1, .clo = 0x1.a3f41d4d7c743p-55 },
        .{ .chi = 0x1.f6ffffca94c6bp-1, .clo = -0x1.202f41c987875p-57 },
        .{ .chi = 0x1.f8fffe1f9c441p-1, .clo = 0x1.77dd1f477e74bp-56 },
        .{ .chi = 0x1.fafffd2e0e37ep-1, .clo = -0x1.f01199a7ca331p-57 },
        .{ .chi = 0x1.fd0001c77e49ep-1, .clo = 0x1.181ee4bceacb1p-56 },
        .{ .chi = 0x1.feffff7e0c331p-1, .clo = -0x1.e05370170875ap-57 },
        .{ .chi = 0x1.00ffff465606ep+0, .clo = -0x1.a7ead491c0adap-55 },
        .{ .chi = 0x1.02ffff3867a58p+0, .clo = -0x1.77f69c3fcb2ep-54 },
        .{ .chi = 0x1.04ffffdfc0d17p+0, .clo = 0x1.7bffe34cb945bp-54 },
        .{ .chi = 0x1.0700003cd4d82p+0, .clo = 0x1.20083c0e456cbp-55 },
        .{ .chi = 0x1.08ffff9f2cbe8p+0, .clo = -0x1.dffdfbe37751ap-57 },
        .{ .chi = 0x1.0b000010cda65p+0, .clo = -0x1.13f7faee626ebp-54 },
        .{ .chi = 0x1.0d00001a4d338p+0, .clo = 0x1.07dfa79489ff7p-55 },
        .{ .chi = 0x1.0effffadafdfdp+0, .clo = -0x1.7040570d66bcp-56 },
        .{ .chi = 0x1.110000bbafd96p+0, .clo = 0x1.e80d4846d0b62p-55 },
        .{ .chi = 0x1.12ffffae5f45dp+0, .clo = 0x1.dbffa64fd36efp-54 },
        .{ .chi = 0x1.150000dd59ad9p+0, .clo = 0x1.a0077701250aep-54 },
        .{ .chi = 0x1.170000f21559ap+0, .clo = 0x1.dfdf9e2e3deeep-55 },
        .{ .chi = 0x1.18ffffc275426p+0, .clo = 0x1.10030dc3b7273p-54 },
        .{ .chi = 0x1.1b000123d3c59p+0, .clo = 0x1.97f7980030188p-54 },
        .{ .chi = 0x1.1cffff8299eb7p+0, .clo = -0x1.5f932ab9f8c67p-57 },
        .{ .chi = 0x1.1effff48ad4p+0, .clo = 0x1.37fbf9da75bebp-54 },
        .{ .chi = 0x1.210000c8b86a4p+0, .clo = 0x1.f806b91fd5b22p-54 },
        .{ .chi = 0x1.2300003854303p+0, .clo = 0x1.3ffc2eb9fbf33p-54 },
        .{ .chi = 0x1.24fffffbcf684p+0, .clo = 0x1.601e77e2e2e72p-56 },
        .{ .chi = 0x1.26ffff52921d9p+0, .clo = 0x1.ffcbb767f0c61p-56 },
        .{ .chi = 0x1.2900014933a3cp+0, .clo = -0x1.202ca3c02412bp-56 },
        .{ .chi = 0x1.2b00014556313p+0, .clo = -0x1.2808233f21f02p-54 },
        .{ .chi = 0x1.2cfffebfe523bp+0, .clo = -0x1.8ff7e384fdcf2p-55 },
        .{ .chi = 0x1.2f0000bb8ad96p+0, .clo = -0x1.5ff51503041c5p-55 },
        .{ .chi = 0x1.30ffffb7ae2afp+0, .clo = -0x1.10071885e289dp-55 },
        .{ .chi = 0x1.32ffffeac5f7fp+0, .clo = -0x1.1ff5d3fb7b715p-54 },
        .{ .chi = 0x1.350000ca66756p+0, .clo = 0x1.57f82228b82bdp-54 },
        .{ .chi = 0x1.3700011fbf721p+0, .clo = 0x1.000bac40dd5ccp-55 },
        .{ .chi = 0x1.38ffff9592fb9p+0, .clo = -0x1.43f9d2db2a751p-54 },
        .{ .chi = 0x1.3b00004ddd242p+0, .clo = 0x1.57f6b707638e1p-55 },
        .{ .chi = 0x1.3cffff5b2c957p+0, .clo = 0x1.a023a10bf1231p-56 },
        .{ .chi = 0x1.3efffeab0b418p+0, .clo = 0x1.87f6d66b152bp-54 },
        .{ .chi = 0x1.410001532aff4p+0, .clo = 0x1.7f8375f198524p-57 },
        .{ .chi = 0x1.4300017478b29p+0, .clo = 0x1.301e672dc5143p-55 },
        .{ .chi = 0x1.44fffe795b463p+0, .clo = 0x1.9ff69b8b2895ap-55 },
        .{ .chi = 0x1.46fffe80475ep+0, .clo = -0x1.5c0b19bc2f254p-54 },
        .{ .chi = 0x1.48fffef6fc1e7p+0, .clo = 0x1.b4009f23a2a72p-54 },
        .{ .chi = 0x1.4afffe5bea704p+0, .clo = -0x1.4ffb7bf0d7d45p-54 },
        .{ .chi = 0x1.4d000171027dep+0, .clo = -0x1.9c06471dc6a3dp-54 },
        .{ .chi = 0x1.4f0000ff03ee2p+0, .clo = 0x1.77f890b85531cp-54 },
        .{ .chi = 0x1.5100012dc4bd1p+0, .clo = 0x1.004657166a436p-57 },
        .{ .chi = 0x1.530001605277ap+0, .clo = -0x1.6bfcece233209p-54 },
        .{ .chi = 0x1.54fffecdb704cp+0, .clo = -0x1.902720505a1d7p-55 },
        .{ .chi = 0x1.56fffef5f54a9p+0, .clo = 0x1.bbfe60ec96412p-54 },
        .{ .chi = 0x1.5900017e61012p+0, .clo = 0x1.87ec581afef9p-55 },
        .{ .chi = 0x1.5b00003c93e92p+0, .clo = -0x1.f41080abf0ccp-54 },
        .{ .chi = 0x1.5d0001d4919bcp+0, .clo = -0x1.8812afb254729p-54 },
        .{ .chi = 0x1.5efffe7b87a89p+0, .clo = -0x1.47eb780ed6904p-54 },
    };

    var ix: i64 = @bitCast(x);

    const LO: i64 = @bitCast(@as(f64, 1.0 - 0x1p-4));
    const HI: i64 = @bitCast(@as(f64, 1.0 + 0x1.09p-4));
    if (LO <= ix and ix < HI) {
        @branchHint(.unlikely);
        if (ix == @as(i64, @bitCast(@as(f64, 1)))) {
            @branchHint(.unlikely);
            return 0;
        }

        const r = x - 1;
        const r2 = r * r;
        const r3 = r * r2;

        const y = r3 * (poly1[1] + r * poly1[2] + r2 * poly1[3] +
            r3 * (poly1[4] + r * poly1[5] + r2 * poly1[6] +
                r3 * (poly1[7] + r * poly1[8] + r2 * poly1[9] + r3 * poly1[10])));

        var w = r * 0x1p27;
        const rhi = r + w - w;
        const rlo = r - rhi;
        w = rhi * rhi * poly1[0];
        const hi = r + w;
        const lo = r - hi + w + poly1[0] * rlo * (rhi + r);
        return y + lo + hi;
    }
    const top = @as(u64, @bitCast(ix)) >> 48;
    if (top < 0x0010 or 0x7ff0 <= top) {
        @branchHint(.unlikely);

        if (ix << 1 == 0)
            return -math.inf(f64);

        if (ix == @as(i64, @bitCast(math.inf(f64))))
            return x;

        if (top & 0x8000 != 0 or top & 0x7ff0 == 0x7ff0)
            return math.nan(f64);

        ix = @as(i64, @bitCast(x * 0x1p52)) - (52 << 52);
    }

    const tmp: packed struct(i64) { unused: u45, i: u7, k: i12 } = @bitCast(ix - 0x3fe6000000000000);
    const i = tmp.i;
    const k = tmp.k;
    const iz = ix - (@as(i64, tmp.k) << 52);
    const invc = tab[i].invc;
    const logc = tab[i].logc;
    const z: f64 = @bitCast(iz);

    // Non-FMA range reduction (musl uses fma here; the explicit form keeps it
    // bit-stable under FloatMode.strict so native and wasm agree).
    const r = (z - tab2[i].chi - tab2[i].clo) * invc;

    const kd: f64 = k;
    const w = kd * 0x1.62e42fefa3800p-1 + logc;
    const hi = w + r;
    const lo = w - hi + r + kd * 0x1.ef35793c76730p-45;

    const r2 = r * r;

    const y = lo + r2 * poly[0] + r * r2 * (poly[1] + r * poly[2] + r2 * (poly[3] + r * poly[4])) + hi;
    return @bitCast(y);
}

test "log64 matches @log on the host (dense table sweep)" {
    // Coarse points across the exponent range.
    const xs = [_]f64{ 1e-300, 1e-10, 0.001, 0.1, 0.5, 2.0, math.e, 10.0, 100.0, 1e6, 1e100, 1e300, 0x1.fffffffffffffp+1023 };
    for (xs) |x| {
        try std.testing.expectApproxEqRel(@log(x), log64(x), 1e-14);
    }
    // Dense across the reduced range [sqrt(2)/2, sqrt(2)] so every one of the
    // 128 table rows is exercised — the guard against a single mistranscribed
    // tab/tab2 entry slipping past the fixed pins below.
    var x: f64 = 0.708;
    while (x <= 1.414) : (x += 0.0005) {
        try std.testing.expectApproxEqRel(@log(x), log64(x), 1e-13);
    }
}

test "log64 totality: domain, zero, one, Inf/NaN" {
    const nan = math.nan(f64);
    const inf = math.inf(f64);
    try std.testing.expectEqual(-inf, log64(0.0));
    try std.testing.expectEqual(-inf, log64(-0.0));
    try std.testing.expect(math.isPositiveZero(log64(1.0)));
    try std.testing.expectEqual(@as(f64, 1.0), log64(math.e));
    try std.testing.expectEqual(inf, log64(inf));
    try std.testing.expect(math.isNan(log64(-1.0)));
    try std.testing.expect(math.isNan(log64(-inf)));
    try std.testing.expect(math.isNan(log64(nan)));
    try std.testing.expect(math.isNan(log64(math.snan(f64))));
}

// Exact-bit determinism pins — same contract as the trig/exp pins: log64's own
// pure strict-mode f64 output, host-INDEPENDENT by construction. Vectors reused
// from Zig's compiler_rt log() test (the same algorithm), so a passing run also
// proves the 128-row tables were transcribed byte-faithfully; the dense sweep
// above re-checks correctness against the host @log. A flipped byte is a
// determinism break — investigate, don't silently re-baseline.
test "log64 exact-bit pins" {
    // main table path
    try std.testing.expectEqual(@as(f64, 0x1.7815b08f99c65p+0), log64(0x1.161868e18bc67p+2));
    try std.testing.expectEqual(@as(f64, 0x1.1cfcd53d72604p+1), log64(0x1.288bbb0d6a1e6p+3));
    try std.testing.expectEqual(@as(f64, -0x1.a6694a4a85621p-2), log64(0x1.52efd0cd80497p-1));
    try std.testing.expectEqual(@as(f64, -0x1.2742bc03d02ddp-1), log64(0x1.1f9ef934745cbp-1));
    try std.testing.expectEqual(@as(f64, -0x1.06215de4a3f92p-2), log64(0x1.8c5db097f7442p-1));
    // near-1 poly1 path (both sides of 1.0)
    try std.testing.expectEqual(@as(f64, 0x1.fffffffffffffp-53), log64(0x1.0000000000001p+0));
    try std.testing.expectEqual(@as(f64, -0x1p-53), log64(0x1.fffffffffffffp-1));
    // boundary + subnormal-input scaling path
    try std.testing.expectEqual(@as(f64, 0x1.62e42fefa39efp+9), log64(0x1.fffffffffffffp+1023));
    try std.testing.expectEqual(@as(f64, -0x1.74385446d71c3p+9), log64(0x1p-1074));
    try std.testing.expectEqual(@as(f64, -0x1.6232bdd7abcd2p+9), log64(0x1p-1022));
}

// ===========================================================================
// pow64 — musl's self-contained double-precision x^y (Arm 2018 optimized-
// routines). NOT exp64(y*log64(x)): the integrated log_inline + exp_inline
// carry a tail term between the log and exp steps, preserving the last ULP.
//
// Replaces std.math.pow in SJON's evaluator. Zig 0.16's std.math.pow routes
// its fractional-exponent path through the @exp/@log builtins, which lower to
// platform libm (native) vs compiler_rt (wasm32) — reintroducing the last-ULP
// native/wasm divergence this module exists to prevent. pow64 is pure f64
// software, so `(pow b e)` is bit-identical across native and both wasm
// artifacts.
//
// Ported from musl src/math/{pow.c, pow_data.c, exp_data.c}
// (https://git.musl-libc.org/cgit/musl/, Arm 2018, MIT). The non-FMA code
// paths are taken (FMA lowers differently native-vs-wasm and would break the
// guarantee), and the float-exception side-effects (fp_force_eval / fp_barrier,
// the __math_oflow/uflow/invalid signalling) are dropped — they do not affect
// the returned value. Invalid cases return a canonical NaN (math.nan) rather
// than musl's payload-propagating x+y / (x-x)/(x-x), so even NaN results are
// bit-stable; finite results are the bit-determinism surface that the pins
// and corpus lock (NaN renders as "nan" in the wire format regardless).
// ===========================================================================

inline fn asU64(x: f64) u64 {
    return @bitCast(x);
}
inline fn asF64(i: u64) f64 {
    return @bitCast(i);
}

/// Top 12 bits (sign + exponent) of a double.
inline fn top12(x: f64) u32 {
    return @truncate(asU64(x) >> 52);
}

const POW_INF_BITS: u64 = 0x7ff0000000000000;
const POW_SIGN_BIAS: u32 = 0x800 << 7; // 0x800 << EXP_TABLE_BITS

/// musl issignaling_inline (IEEE-754-2008 sNaN bit test).
inline fn powIsSignaling(x: f64) bool {
    return 2 *% (asU64(x) ^ 0x0008000000000000) > 0xfff0000000000000;
}

/// True if the bits represent 0, infinity, or NaN.
inline fn powZeroInfNan(i: u64) bool {
    return 2 *% i -% 1 >= 2 *% POW_INF_BITS -% 1;
}

/// 0 if not an integer, 1 if odd, 2 if even. Argument is the bits of a
/// non-zero finite double.
inline fn powCheckInt(iy: u64) u2 {
    const e: u64 = (iy >> 52) & 0x7ff;
    if (e < 0x3ff) return 0;
    if (e > 0x3ff + 52) return 2;
    const sh: u6 = @intCast(0x3ff + 52 - e);
    if ((iy & ((@as(u64, 1) << sh) - 1)) != 0) return 0;
    if ((iy & (@as(u64, 1) << sh)) != 0) return 1;
    return 2;
}

// __math_oflow/uflow with the FE signalling stripped: overflow -> ±Inf,
// underflow -> ±0 (sign from sign_bias, i.e. an odd negative base).
inline fn powOflow(sign_bias: u32) f64 {
    return if (sign_bias != 0) -math.inf(f64) else math.inf(f64);
}
inline fn powUflow(sign_bias: u32) f64 {
    return if (sign_bias != 0) -0.0 else 0.0;
}

const pow_log = struct {
    const ln2hi: f64 = 0x1.62e42fefa3800p-1;
    const ln2lo: f64 = 0x1.ef35793c76730p-45;
    // Coefficients pre-scaled to match the evaluation (verbatim from musl).
    const poly = [_]f64{
        -0x1p-1,
        0x1.555555555556p-2 * -2.0,
        -0x1.0000000000006p-2 * -2.0,
        0x1.999999959554ep-3 * 4.0,
        -0x1.555555529a47ap-3 * 4.0,
        0x1.2495b9b4845e9p-3 * -8.0,
        -0x1.0002b8b263fc3p-3 * -8.0,
    };
    const Entry = struct { invc: f64, logc: f64, logctail: f64 };
    const tab = [128]Entry{
        .{ .invc = 0x1.6a00000000000p+0, .logc = -0x1.62c82f2b9c800p-2, .logctail = 0x1.ab42428375680p-48 },
        .{ .invc = 0x1.6800000000000p+0, .logc = -0x1.5d1bdbf580800p-2, .logctail = -0x1.ca508d8e0f720p-46 },
        .{ .invc = 0x1.6600000000000p+0, .logc = -0x1.5767717455800p-2, .logctail = -0x1.362a4d5b6506dp-45 },
        .{ .invc = 0x1.6400000000000p+0, .logc = -0x1.51aad872df800p-2, .logctail = -0x1.684e49eb067d5p-49 },
        .{ .invc = 0x1.6200000000000p+0, .logc = -0x1.4be5f95777800p-2, .logctail = -0x1.41b6993293ee0p-47 },
        .{ .invc = 0x1.6000000000000p+0, .logc = -0x1.4618bc21c6000p-2, .logctail = 0x1.3d82f484c84ccp-46 },
        .{ .invc = 0x1.5e00000000000p+0, .logc = -0x1.404308686a800p-2, .logctail = 0x1.c42f3ed820b3ap-50 },
        .{ .invc = 0x1.5c00000000000p+0, .logc = -0x1.3a64c55694800p-2, .logctail = 0x1.0b1c686519460p-45 },
        .{ .invc = 0x1.5a00000000000p+0, .logc = -0x1.347dd9a988000p-2, .logctail = 0x1.5594dd4c58092p-45 },
        .{ .invc = 0x1.5800000000000p+0, .logc = -0x1.2e8e2bae12000p-2, .logctail = 0x1.67b1e99b72bd8p-45 },
        .{ .invc = 0x1.5600000000000p+0, .logc = -0x1.2895a13de8800p-2, .logctail = 0x1.5ca14b6cfb03fp-46 },
        .{ .invc = 0x1.5600000000000p+0, .logc = -0x1.2895a13de8800p-2, .logctail = 0x1.5ca14b6cfb03fp-46 },
        .{ .invc = 0x1.5400000000000p+0, .logc = -0x1.22941fbcf7800p-2, .logctail = -0x1.65a242853da76p-46 },
        .{ .invc = 0x1.5200000000000p+0, .logc = -0x1.1c898c1699800p-2, .logctail = -0x1.fafbc68e75404p-46 },
        .{ .invc = 0x1.5000000000000p+0, .logc = -0x1.1675cababa800p-2, .logctail = 0x1.f1fc63382a8f0p-46 },
        .{ .invc = 0x1.4e00000000000p+0, .logc = -0x1.1058bf9ae4800p-2, .logctail = -0x1.6a8c4fd055a66p-45 },
        .{ .invc = 0x1.4c00000000000p+0, .logc = -0x1.0a324e2739000p-2, .logctail = -0x1.c6bee7ef4030ep-47 },
        .{ .invc = 0x1.4a00000000000p+0, .logc = -0x1.0402594b4d000p-2, .logctail = -0x1.036b89ef42d7fp-48 },
        .{ .invc = 0x1.4a00000000000p+0, .logc = -0x1.0402594b4d000p-2, .logctail = -0x1.036b89ef42d7fp-48 },
        .{ .invc = 0x1.4800000000000p+0, .logc = -0x1.fb9186d5e4000p-3, .logctail = 0x1.d572aab993c87p-47 },
        .{ .invc = 0x1.4600000000000p+0, .logc = -0x1.ef0adcbdc6000p-3, .logctail = 0x1.b26b79c86af24p-45 },
        .{ .invc = 0x1.4400000000000p+0, .logc = -0x1.e27076e2af000p-3, .logctail = -0x1.72f4f543fff10p-46 },
        .{ .invc = 0x1.4200000000000p+0, .logc = -0x1.d5c216b4fc000p-3, .logctail = 0x1.1ba91bbca681bp-45 },
        .{ .invc = 0x1.4000000000000p+0, .logc = -0x1.c8ff7c79aa000p-3, .logctail = 0x1.7794f689f8434p-45 },
        .{ .invc = 0x1.4000000000000p+0, .logc = -0x1.c8ff7c79aa000p-3, .logctail = 0x1.7794f689f8434p-45 },
        .{ .invc = 0x1.3e00000000000p+0, .logc = -0x1.bc286742d9000p-3, .logctail = 0x1.94eb0318bb78fp-46 },
        .{ .invc = 0x1.3c00000000000p+0, .logc = -0x1.af3c94e80c000p-3, .logctail = 0x1.a4e633fcd9066p-52 },
        .{ .invc = 0x1.3a00000000000p+0, .logc = -0x1.a23bc1fe2b000p-3, .logctail = -0x1.58c64dc46c1eap-45 },
        .{ .invc = 0x1.3a00000000000p+0, .logc = -0x1.a23bc1fe2b000p-3, .logctail = -0x1.58c64dc46c1eap-45 },
        .{ .invc = 0x1.3800000000000p+0, .logc = -0x1.9525a9cf45000p-3, .logctail = -0x1.ad1d904c1d4e3p-45 },
        .{ .invc = 0x1.3600000000000p+0, .logc = -0x1.87fa06520d000p-3, .logctail = 0x1.bbdbf7fdbfa09p-45 },
        .{ .invc = 0x1.3400000000000p+0, .logc = -0x1.7ab890210e000p-3, .logctail = 0x1.bdb9072534a58p-45 },
        .{ .invc = 0x1.3400000000000p+0, .logc = -0x1.7ab890210e000p-3, .logctail = 0x1.bdb9072534a58p-45 },
        .{ .invc = 0x1.3200000000000p+0, .logc = -0x1.6d60fe719d000p-3, .logctail = -0x1.0e46aa3b2e266p-46 },
        .{ .invc = 0x1.3000000000000p+0, .logc = -0x1.5ff3070a79000p-3, .logctail = -0x1.e9e439f105039p-46 },
        .{ .invc = 0x1.3000000000000p+0, .logc = -0x1.5ff3070a79000p-3, .logctail = -0x1.e9e439f105039p-46 },
        .{ .invc = 0x1.2e00000000000p+0, .logc = -0x1.526e5e3a1b000p-3, .logctail = -0x1.0de8b90075b8fp-45 },
        .{ .invc = 0x1.2c00000000000p+0, .logc = -0x1.44d2b6ccb8000p-3, .logctail = 0x1.70cc16135783cp-46 },
        .{ .invc = 0x1.2c00000000000p+0, .logc = -0x1.44d2b6ccb8000p-3, .logctail = 0x1.70cc16135783cp-46 },
        .{ .invc = 0x1.2a00000000000p+0, .logc = -0x1.371fc201e9000p-3, .logctail = 0x1.178864d27543ap-48 },
        .{ .invc = 0x1.2800000000000p+0, .logc = -0x1.29552f81ff000p-3, .logctail = -0x1.48d301771c408p-45 },
        .{ .invc = 0x1.2600000000000p+0, .logc = -0x1.1b72ad52f6000p-3, .logctail = -0x1.e80a41811a396p-45 },
        .{ .invc = 0x1.2600000000000p+0, .logc = -0x1.1b72ad52f6000p-3, .logctail = -0x1.e80a41811a396p-45 },
        .{ .invc = 0x1.2400000000000p+0, .logc = -0x1.0d77e7cd09000p-3, .logctail = 0x1.a699688e85bf4p-47 },
        .{ .invc = 0x1.2400000000000p+0, .logc = -0x1.0d77e7cd09000p-3, .logctail = 0x1.a699688e85bf4p-47 },
        .{ .invc = 0x1.2200000000000p+0, .logc = -0x1.fec9131dbe000p-4, .logctail = -0x1.575545ca333f2p-45 },
        .{ .invc = 0x1.2000000000000p+0, .logc = -0x1.e27076e2b0000p-4, .logctail = 0x1.a342c2af0003cp-45 },
        .{ .invc = 0x1.2000000000000p+0, .logc = -0x1.e27076e2b0000p-4, .logctail = 0x1.a342c2af0003cp-45 },
        .{ .invc = 0x1.1e00000000000p+0, .logc = -0x1.c5e548f5bc000p-4, .logctail = -0x1.d0c57585fbe06p-46 },
        .{ .invc = 0x1.1c00000000000p+0, .logc = -0x1.a926d3a4ae000p-4, .logctail = 0x1.53935e85baac8p-45 },
        .{ .invc = 0x1.1c00000000000p+0, .logc = -0x1.a926d3a4ae000p-4, .logctail = 0x1.53935e85baac8p-45 },
        .{ .invc = 0x1.1a00000000000p+0, .logc = -0x1.8c345d631a000p-4, .logctail = 0x1.37c294d2f5668p-46 },
        .{ .invc = 0x1.1a00000000000p+0, .logc = -0x1.8c345d631a000p-4, .logctail = 0x1.37c294d2f5668p-46 },
        .{ .invc = 0x1.1800000000000p+0, .logc = -0x1.6f0d28ae56000p-4, .logctail = -0x1.69737c93373dap-45 },
        .{ .invc = 0x1.1600000000000p+0, .logc = -0x1.51b073f062000p-4, .logctail = 0x1.f025b61c65e57p-46 },
        .{ .invc = 0x1.1600000000000p+0, .logc = -0x1.51b073f062000p-4, .logctail = 0x1.f025b61c65e57p-46 },
        .{ .invc = 0x1.1400000000000p+0, .logc = -0x1.341d7961be000p-4, .logctail = 0x1.c5edaccf913dfp-45 },
        .{ .invc = 0x1.1400000000000p+0, .logc = -0x1.341d7961be000p-4, .logctail = 0x1.c5edaccf913dfp-45 },
        .{ .invc = 0x1.1200000000000p+0, .logc = -0x1.16536eea38000p-4, .logctail = 0x1.47c5e768fa309p-46 },
        .{ .invc = 0x1.1000000000000p+0, .logc = -0x1.f0a30c0118000p-5, .logctail = 0x1.d599e83368e91p-45 },
        .{ .invc = 0x1.1000000000000p+0, .logc = -0x1.f0a30c0118000p-5, .logctail = 0x1.d599e83368e91p-45 },
        .{ .invc = 0x1.0e00000000000p+0, .logc = -0x1.b42dd71198000p-5, .logctail = 0x1.c827ae5d6704cp-46 },
        .{ .invc = 0x1.0e00000000000p+0, .logc = -0x1.b42dd71198000p-5, .logctail = 0x1.c827ae5d6704cp-46 },
        .{ .invc = 0x1.0c00000000000p+0, .logc = -0x1.77458f632c000p-5, .logctail = -0x1.cfc4634f2a1eep-45 },
        .{ .invc = 0x1.0c00000000000p+0, .logc = -0x1.77458f632c000p-5, .logctail = -0x1.cfc4634f2a1eep-45 },
        .{ .invc = 0x1.0a00000000000p+0, .logc = -0x1.39e87b9fec000p-5, .logctail = 0x1.502b7f526feaap-48 },
        .{ .invc = 0x1.0a00000000000p+0, .logc = -0x1.39e87b9fec000p-5, .logctail = 0x1.502b7f526feaap-48 },
        .{ .invc = 0x1.0800000000000p+0, .logc = -0x1.f829b0e780000p-6, .logctail = -0x1.980267c7e09e4p-45 },
        .{ .invc = 0x1.0800000000000p+0, .logc = -0x1.f829b0e780000p-6, .logctail = -0x1.980267c7e09e4p-45 },
        .{ .invc = 0x1.0600000000000p+0, .logc = -0x1.7b91b07d58000p-6, .logctail = -0x1.88d5493faa639p-45 },
        .{ .invc = 0x1.0400000000000p+0, .logc = -0x1.fc0a8b0fc0000p-7, .logctail = -0x1.f1e7cf6d3a69cp-50 },
        .{ .invc = 0x1.0400000000000p+0, .logc = -0x1.fc0a8b0fc0000p-7, .logctail = -0x1.f1e7cf6d3a69cp-50 },
        .{ .invc = 0x1.0200000000000p+0, .logc = -0x1.fe02a6b100000p-8, .logctail = -0x1.9e23f0dda40e4p-46 },
        .{ .invc = 0x1.0200000000000p+0, .logc = -0x1.fe02a6b100000p-8, .logctail = -0x1.9e23f0dda40e4p-46 },
        .{ .invc = 0x1.0000000000000p+0, .logc = 0x0.0000000000000p+0, .logctail = 0x0.0000000000000p+0 },
        .{ .invc = 0x1.0000000000000p+0, .logc = 0x0.0000000000000p+0, .logctail = 0x0.0000000000000p+0 },
        .{ .invc = 0x1.fc00000000000p-1, .logc = 0x1.0101575890000p-7, .logctail = -0x1.0c76b999d2be8p-46 },
        .{ .invc = 0x1.f800000000000p-1, .logc = 0x1.0205658938000p-6, .logctail = -0x1.3dc5b06e2f7d2p-45 },
        .{ .invc = 0x1.f400000000000p-1, .logc = 0x1.8492528c90000p-6, .logctail = -0x1.aa0ba325a0c34p-45 },
        .{ .invc = 0x1.f000000000000p-1, .logc = 0x1.0415d89e74000p-5, .logctail = 0x1.111c05cf1d753p-47 },
        .{ .invc = 0x1.ec00000000000p-1, .logc = 0x1.466aed42e0000p-5, .logctail = -0x1.c167375bdfd28p-45 },
        .{ .invc = 0x1.e800000000000p-1, .logc = 0x1.894aa149fc000p-5, .logctail = -0x1.97995d05a267dp-46 },
        .{ .invc = 0x1.e400000000000p-1, .logc = 0x1.ccb73cdddc000p-5, .logctail = -0x1.a68f247d82807p-46 },
        .{ .invc = 0x1.e200000000000p-1, .logc = 0x1.eea31c006c000p-5, .logctail = -0x1.e113e4fc93b7bp-47 },
        .{ .invc = 0x1.de00000000000p-1, .logc = 0x1.1973bd1466000p-4, .logctail = -0x1.5325d560d9e9bp-45 },
        .{ .invc = 0x1.da00000000000p-1, .logc = 0x1.3bdf5a7d1e000p-4, .logctail = 0x1.cc85ea5db4ed7p-45 },
        .{ .invc = 0x1.d600000000000p-1, .logc = 0x1.5e95a4d97a000p-4, .logctail = -0x1.c69063c5d1d1ep-45 },
        .{ .invc = 0x1.d400000000000p-1, .logc = 0x1.700d30aeac000p-4, .logctail = 0x1.c1e8da99ded32p-49 },
        .{ .invc = 0x1.d000000000000p-1, .logc = 0x1.9335e5d594000p-4, .logctail = 0x1.3115c3abd47dap-45 },
        .{ .invc = 0x1.cc00000000000p-1, .logc = 0x1.b6ac88dad6000p-4, .logctail = -0x1.390802bf768e5p-46 },
        .{ .invc = 0x1.ca00000000000p-1, .logc = 0x1.c885801bc4000p-4, .logctail = 0x1.646d1c65aacd3p-45 },
        .{ .invc = 0x1.c600000000000p-1, .logc = 0x1.ec739830a2000p-4, .logctail = -0x1.dc068afe645e0p-45 },
        .{ .invc = 0x1.c400000000000p-1, .logc = 0x1.fe89139dbe000p-4, .logctail = -0x1.534d64fa10afdp-45 },
        .{ .invc = 0x1.c000000000000p-1, .logc = 0x1.1178e8227e000p-3, .logctail = 0x1.1ef78ce2d07f2p-45 },
        .{ .invc = 0x1.be00000000000p-1, .logc = 0x1.1aa2b7e23f000p-3, .logctail = 0x1.ca78e44389934p-45 },
        .{ .invc = 0x1.ba00000000000p-1, .logc = 0x1.2d1610c868000p-3, .logctail = 0x1.39d6ccb81b4a1p-47 },
        .{ .invc = 0x1.b800000000000p-1, .logc = 0x1.365fcb0159000p-3, .logctail = 0x1.62fa8234b7289p-51 },
        .{ .invc = 0x1.b400000000000p-1, .logc = 0x1.4913d8333b000p-3, .logctail = 0x1.5837954fdb678p-45 },
        .{ .invc = 0x1.b200000000000p-1, .logc = 0x1.527e5e4a1b000p-3, .logctail = 0x1.633e8e5697dc7p-45 },
        .{ .invc = 0x1.ae00000000000p-1, .logc = 0x1.6574ebe8c1000p-3, .logctail = 0x1.9cf8b2c3c2e78p-46 },
        .{ .invc = 0x1.ac00000000000p-1, .logc = 0x1.6f0128b757000p-3, .logctail = -0x1.5118de59c21e1p-45 },
        .{ .invc = 0x1.aa00000000000p-1, .logc = 0x1.7898d85445000p-3, .logctail = -0x1.c661070914305p-46 },
        .{ .invc = 0x1.a600000000000p-1, .logc = 0x1.8beafeb390000p-3, .logctail = -0x1.73d54aae92cd1p-47 },
        .{ .invc = 0x1.a400000000000p-1, .logc = 0x1.95a5adcf70000p-3, .logctail = 0x1.7f22858a0ff6fp-47 },
        .{ .invc = 0x1.a000000000000p-1, .logc = 0x1.a93ed3c8ae000p-3, .logctail = -0x1.8724350562169p-45 },
        .{ .invc = 0x1.9e00000000000p-1, .logc = 0x1.b31d8575bd000p-3, .logctail = -0x1.c358d4eace1aap-47 },
        .{ .invc = 0x1.9c00000000000p-1, .logc = 0x1.bd087383be000p-3, .logctail = -0x1.d4bc4595412b6p-45 },
        .{ .invc = 0x1.9a00000000000p-1, .logc = 0x1.c6ffbc6f01000p-3, .logctail = -0x1.1ec72c5962bd2p-48 },
        .{ .invc = 0x1.9600000000000p-1, .logc = 0x1.db13db0d49000p-3, .logctail = -0x1.aff2af715b035p-45 },
        .{ .invc = 0x1.9400000000000p-1, .logc = 0x1.e530effe71000p-3, .logctail = 0x1.212276041f430p-51 },
        .{ .invc = 0x1.9200000000000p-1, .logc = 0x1.ef5ade4dd0000p-3, .logctail = -0x1.a211565bb8e11p-51 },
        .{ .invc = 0x1.9000000000000p-1, .logc = 0x1.f991c6cb3b000p-3, .logctail = 0x1.bcbecca0cdf30p-46 },
        .{ .invc = 0x1.8c00000000000p-1, .logc = 0x1.07138604d5800p-2, .logctail = 0x1.89cdb16ed4e91p-48 },
        .{ .invc = 0x1.8a00000000000p-1, .logc = 0x1.0c42d67616000p-2, .logctail = 0x1.7188b163ceae9p-45 },
        .{ .invc = 0x1.8800000000000p-1, .logc = 0x1.1178e8227e800p-2, .logctail = -0x1.c210e63a5f01cp-45 },
        .{ .invc = 0x1.8600000000000p-1, .logc = 0x1.16b5ccbacf800p-2, .logctail = 0x1.b9acdf7a51681p-45 },
        .{ .invc = 0x1.8400000000000p-1, .logc = 0x1.1bf99635a6800p-2, .logctail = 0x1.ca6ed5147bdb7p-45 },
        .{ .invc = 0x1.8200000000000p-1, .logc = 0x1.214456d0eb800p-2, .logctail = 0x1.a87deba46baeap-47 },
        .{ .invc = 0x1.7e00000000000p-1, .logc = 0x1.2bef07cdc9000p-2, .logctail = 0x1.a9cfa4a5004f4p-45 },
        .{ .invc = 0x1.7c00000000000p-1, .logc = 0x1.314f1e1d36000p-2, .logctail = -0x1.8e27ad3213cb8p-45 },
        .{ .invc = 0x1.7a00000000000p-1, .logc = 0x1.36b6776be1000p-2, .logctail = 0x1.16ecdb0f177c8p-46 },
        .{ .invc = 0x1.7800000000000p-1, .logc = 0x1.3c25277333000p-2, .logctail = 0x1.83b54b606bd5cp-46 },
        .{ .invc = 0x1.7600000000000p-1, .logc = 0x1.419b423d5e800p-2, .logctail = 0x1.8e436ec90e09dp-47 },
        .{ .invc = 0x1.7400000000000p-1, .logc = 0x1.4718dc271c800p-2, .logctail = -0x1.f27ce0967d675p-45 },
        .{ .invc = 0x1.7200000000000p-1, .logc = 0x1.4c9e09e173000p-2, .logctail = -0x1.e20891b0ad8a4p-45 },
        .{ .invc = 0x1.7000000000000p-1, .logc = 0x1.522ae0738a000p-2, .logctail = 0x1.ebe708164c759p-45 },
        .{ .invc = 0x1.6e00000000000p-1, .logc = 0x1.57bf753c8d000p-2, .logctail = 0x1.fadedee5d40efp-46 },
        .{ .invc = 0x1.6c00000000000p-1, .logc = 0x1.5d5bddf596000p-2, .logctail = -0x1.a0b2a08a465dcp-47 },
    };
};

const exp_d = struct {
    const invln2N: f64 = 0x1.71547652b82fep0 * 128.0; // N/ln2, N = 1<<7
    const negln2hiN: f64 = -0x1.62e42fefa0000p-8;
    const negln2loN: f64 = -0x1.cf79abc9e3b3ap-47;
    const shift: f64 = 0x1.8p52;
    // exp polynomial C2..C5 (pow's exp_inline does not use C6).
    const poly = [_]f64{
        0x1.ffffffffffdbdp-2,
        0x1.555555555543cp-3,
        0x1.55555cf172b91p-5,
        0x1.1111167a4d017p-7,
    };
    // tab[2k] = asuint64(T[k]); tab[2k+1] = asuint64(H[k]) - (k<<52)/N.
    const tab = [256]u64{
        0x0,                0x3ff0000000000000,
        0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
        0xbc7160139cd8dc5d, 0x3fefec9a3e778061,
        0xbc905e7a108766d1, 0x3fefe315e86e7f85,
        0x3c8cd2523567f613, 0x3fefd9b0d3158574,
        0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
        0x3c60f74e61e6c861, 0x3fefc74518759bc8,
        0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
        0x3c979aa65d837b6d, 0x3fefb5586cf9890f,
        0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
        0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2,
        0xbc6a033489906e0b, 0x3fef9b66affed31b,
        0xbc9556522a2fbd0e, 0x3fef9301d0125b51,
        0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
        0xbc91c923b9d5f416, 0x3fef829aaea92de0,
        0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
        0xbc801b15eaa59348, 0x3fef72b83c7d517b,
        0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
        0x3c8b898c3f1353bf, 0x3fef635beb6fcb75,
        0xbc96d99c7611eb26, 0x3fef5be084045cd4,
        0x3c9aecf73e3a2f60, 0x3fef54873168b9aa,
        0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
        0x3c8a6f4144a6c38d, 0x3fef463b88628cd6,
        0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
        0x3c968efde3a8a894, 0x3fef387a6e756238,
        0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
        0x3c80472b981fe7f2, 0x3fef2b4565e27cdd,
        0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
        0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1,
        0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
        0x3c8b3782720c0ab4, 0x3fef1285a6e4030b,
        0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
        0x3c834d754db0abb6, 0x3fef06fe0a31b715,
        0x3c864201e2ac744c, 0x3fef0170fc4cd831,
        0x3c8fdd395dd3f84a, 0x3feefc08b26416ff,
        0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
        0xbc924aedcc4b5068, 0x3feef1a7373aa9cb,
        0xbc9907f81b512d8e, 0x3feeecae6d05d866,
        0xbc71d1e83e9436d2, 0x3feee7db34e59ff7,
        0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
        0x3c859f48a72a4c6d, 0x3feedea64c123422,
        0xbc9312607a28698a, 0x3feeda4504ac801c,
        0xbc58a78f4817895b, 0x3feed60a21f72e2a,
        0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
        0x3c4363ed60c2ac11, 0x3feece086061892d,
        0x3c9666093b0664ef, 0x3feeca41ed1d0057,
        0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0,
        0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
        0x3c7690cebb7aafb0, 0x3feebfdad5362a27,
        0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
        0xbc8f94340071a38e, 0x3feeb9b2769d2ca7,
        0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
        0xbc78dec6bd0f385f, 0x3feeb42b569d4f82,
        0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
        0x3c93350518fdd78e, 0x3feeaf4736b527da,
        0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
        0x3c9063e1e21c5409, 0x3feeab07dd485429,
        0x3c34c7855019c6ea, 0x3feea9268a5946b7,
        0x3c9432e62b64c035, 0x3feea76f15ad2148,
        0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
        0xbc8c33c53bef4da8, 0x3feea47eb03a5585,
        0xbc845378892be9ae, 0x3feea34634ccc320,
        0xbc93cedd78565858, 0x3feea23882552225,
        0x3c5710aa807e1964, 0x3feea155d44ca973,
        0xbc93b3efbf5e2228, 0x3feea09e667f3bcd,
        0xbc6a12ad8734b982, 0x3feea012750bdabf,
        0xbc6367efb86da9ee, 0x3fee9fb23c651a2f,
        0xbc80dc3d54e08851, 0x3fee9f7df9519484,
        0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74,
        0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
        0xbc8619321e55e68a, 0x3fee9feb564267c9,
        0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
        0xbc7b32dcb94da51d, 0x3feea11473eb0187,
        0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
        0x3c65ebe1abd66c55, 0x3feea2f336cf4e62,
        0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
        0xbc9369b6f13b3734, 0x3feea589994cce13,
        0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
        0xbc94d450d872576e, 0x3feea8d99b4492ed,
        0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
        0x3c8db72fc1f0eab4, 0x3feeace5422aa0db,
        0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
        0x3c7bf68359f35f44, 0x3feeb1ae99157736,
        0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
        0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5,
        0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
        0xbc92434322f4f9aa, 0x3feebd829fde4e50,
        0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
        0x3c71affc2b91ce27, 0x3feec49182a3f090,
        0x3c6dd235e10a73bb, 0x3feec86319e32323,
        0xbc87c50422622263, 0x3feecc667b5de565,
        0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
        0xbc91bbd1d3bcbb15, 0x3feed503b23e255d,
        0x3c90cc319cee31d2, 0x3feed99e1330b358,
        0x3c8469846e735ab3, 0x3feede6b5579fdbf,
        0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
        0x3c8c1a7792cb3387, 0x3feee89f995ad3ad,
        0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
        0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb,
        0xbc90a40e3da6f640, 0x3feef9728de5593a,
        0xbc68d6f438ad9334, 0x3feeff76f2fb5e47,
        0xbc91eee26b588a35, 0x3fef05b030a1064a,
        0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2,
        0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
        0x3c736eae30af0cb3, 0x3fef199bdd85529c,
        0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
        0x3c84e08fd10959ac, 0x3fef27f12e57d14b,
        0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
        0x3c676b2c6c921968, 0x3fef3720dcef9069,
        0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
        0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c,
        0xbc900dae3875a949, 0x3fef4f87080d89f2,
        0x3c74a385a63d07a7, 0x3fef5818dcfba487,
        0xbc82919e2040220f, 0x3fef60e316c98398,
        0x3c8e5a50d5c192ac, 0x3fef69e603db3285,
        0x3c843a59ac016b4b, 0x3fef7321f301b460,
        0xbc82d52107b43e1f, 0x3fef7c97337b9b5f,
        0xbc892ab93b470dc9, 0x3fef864614f5a129,
        0x3c74b604603a88d3, 0x3fef902ee78b3ff6,
        0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
        0xbc8ff7128fd391f0, 0x3fefa4afa2a490da,
        0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
        0x3c8ec3bc41aa2008, 0x3fefba1bee615a27,
        0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
        0x3c8a64a931d185ee, 0x3fefd0765b6e4540,
        0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
        0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8,
        0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
    };
};

/// log(x) with ~15 extra bits returned in `tail`. `ix` is the bits of x
/// (subnormals normalized by the caller). Non-FMA reduction.
fn powLogInline(ix: u64, tail: *f64) f64 {
    const OFF: u64 = 0x3fe6955500000000;
    const tmp = ix -% OFF;
    const i: usize = @intCast((tmp >> (52 - 7)) % 128);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52; // arithmetic shift
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z = asF64(iz);
    const kd: f64 = @floatFromInt(k);

    const invc = pow_log.tab[i].invc;
    const logc = pow_log.tab[i].logc;
    const logctail = pow_log.tab[i].logctail;

    // Split z so that rhi, rlo and rhi*rhi are exact and |rlo| <= |r|.
    const zhi = asF64((iz +% 0x80000000) & 0xffffffff00000000);
    const zlo = z - zhi;
    const rhi = zhi * invc - 1.0;
    const rlo = zlo * invc;
    const r = rhi + rlo;

    const t1 = kd * pow_log.ln2hi + logc;
    const t2 = t1 + r;
    const lo1 = kd * pow_log.ln2lo + logctail;
    const lo2 = t1 - t2 + r;

    const ar = pow_log.poly[0] * r; // poly[0] = -0.5
    const ar2 = r * ar;
    const ar3 = r * ar2;
    const arhi = pow_log.poly[0] * rhi;
    const arhi2 = rhi * arhi;
    const hi = t2 + arhi2;
    const lo3 = rlo * (ar + arhi);
    const lo4 = t2 - hi + arhi2;
    const p = ar3 * (pow_log.poly[1] + r * pow_log.poly[2] +
        ar2 * (pow_log.poly[3] + r * pow_log.poly[4] + ar2 * (pow_log.poly[5] + r * pow_log.poly[6])));
    const lo = lo1 + lo2 + lo3 + lo4 + p;
    const y = hi + lo;
    tail.* = hi - y + lo;
    return y;
}

// Overflow/underflow tail of exp_inline (k near the representable edge).
fn powSpecialcase(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if ((ki & 0x80000000) == 0) {
        // k > 0: exponent of scale may have overflowed by <= 460.
        sbits -%= @as(u64, 1009) << 52;
        const scale = asF64(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0: subnormal range needs care.
    sbits +%= @as(u64, 1022) << 52;
    const scale = asF64(sbits);
    var y = scale + scale * tmp;
    if (@abs(y) < 1.0) {
        // Round y to the right precision before scaling into subnormals.
        var one: f64 = 1.0;
        if (y < 0.0) one = -1.0;
        const lo = scale - y + scale * tmp;
        const hi = one + y;
        const lo2 = one - hi + y + lo;
        y = (hi + lo2) - one;
        if (y == 0.0) y = asF64(sbits & 0x8000000000000000); // fix sign of 0
        // (musl signals the underflow exception here; dropped — no value effect)
    }
    return 0x1p-1022 * y;
}

/// sign*exp(x+xtail), sign from sign_bias (0 or POW_SIGN_BIAS). Non-FMA,
/// non-TOINT path; |xtail| < 2^-8/N and |xtail| <= |x|.
fn powExpInline(x: f64, xtail: f64, sign_bias: u32) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
        @branchHint(.unlikely);
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            // tiny x: avoid spurious underflow (0 is a common input).
            const one: f64 = 1.0 + x; // WANT_ROUNDING
            return if (sign_bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            // inf/nan already handled by the caller.
            return if ((asU64(x) >> 63) != 0) powUflow(sign_bias) else powOflow(sign_bias);
        }
        abstop = 0;
    }
    // exp(x) = 2^(k/N) * exp(r), r in [-ln2/2N, ln2/2N].
    const z = exp_d.invln2N * x;
    const kd0 = z + exp_d.shift; // Shift forces the rounding
    const ki = asU64(kd0);
    const kd = kd0 - exp_d.shift;
    var r = x + kd * exp_d.negln2hiN + kd * exp_d.negln2loN;
    r += xtail;
    const idx: u64 = 2 * (ki % 128);
    const top = (ki +% @as(u64, sign_bias)) << (52 - 7);
    const tail = asF64(exp_d.tab[@intCast(idx)]);
    const sbits = exp_d.tab[@intCast(idx + 1)] +% top;
    const r2 = r * r;
    const tmp = tail + r + r2 * (exp_d.poly[0] + r * exp_d.poly[1]) + r2 * r2 * (exp_d.poly[2] + r * exp_d.poly[3]);
    if (abstop == 0) {
        @branchHint(.unlikely);
        return powSpecialcase(tmp, sbits, ki);
    }
    const scale = asF64(sbits);
    return scale + scale * tmp;
}

/// x^y. Bit-identical across native and WASM. Replaces std.math.pow in the
/// evaluator. Ported from musl pow.c (Arm 2018 optimized-routines).
pub fn pow64(x: f64, y: f64) f64 {
    var sign_bias: u32 = 0;
    var ix = asU64(x);
    const iy = asU64(y);
    var topx = top12(x);
    const topy = top12(y);
    if ((topx -% 0x001) >= 0x7ff - 0x001 or ((topy & 0x7ff) -% 0x3be) >= 0x43e - 0x3be) {
        @branchHint(.unlikely);
        // x in (<0x1p-126, inf, nan) or |y| tiny/huge/nan.
        if (powZeroInfNan(iy)) {
            @branchHint(.unlikely);
            if (2 *% iy == 0) return if (powIsSignaling(x)) x + y else 1.0;
            if (ix == asU64(1.0)) return if (powIsSignaling(y)) x + y else 1.0;
            if (2 *% ix > 2 *% POW_INF_BITS or 2 *% iy > 2 *% POW_INF_BITS) return x + y;
            if (2 *% ix == 2 *% asU64(1.0)) return 1.0;
            if ((2 *% ix < 2 *% asU64(1.0)) == ((iy >> 63) == 0)) return 0.0;
            return y * y;
        }
        if (powZeroInfNan(ix)) {
            @branchHint(.unlikely);
            var x2 = x * x;
            if ((ix >> 63) != 0 and powCheckInt(iy) == 1) x2 = -x2;
            return if ((iy >> 63) != 0) 1.0 / x2 else x2;
        }
        if ((ix >> 63) != 0) {
            // finite x < 0
            const yint = powCheckInt(iy);
            if (yint == 0) return math.nan(f64); // __math_invalid: canonical NaN
            if (yint == 1) sign_bias = POW_SIGN_BIAS;
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if (((topy & 0x7ff) -% 0x3be) >= 0x43e - 0x3be) {
            // sign_bias == 0 here (y not odd).
            if (ix == asU64(1.0)) return 1.0;
            if ((topy & 0x7ff) < 0x3be) {
                // |y| < 2^-65: x^y ~= 1 + y*log(x).
                return if (ix > asU64(1.0)) 1.0 + y else 1.0 - y; // WANT_ROUNDING
            }
            return if ((ix > asU64(1.0)) == (topy < 0x800)) powOflow(0) else powUflow(0);
        }
        if (topx == 0) {
            // normalize subnormal x so the exponent becomes negative
            ix = asU64(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix -%= @as(u64, 52) << 52;
        }
    }

    var lo: f64 = undefined;
    const hi = powLogInline(ix, &lo);
    // y*hi + y*lo carried in extended precision, non-FMA split.
    const yhi = asF64(iy & 0xfffffffff8000000);
    const ylo = y - yhi;
    const lhi = asF64(asU64(hi) & 0xfffffffff8000000);
    const llo = hi - lhi + lo;
    const ehi = yhi * lhi;
    const elo = ylo * lhi + y * llo;
    return powExpInline(ehi, elo, sign_bias);
}

test "pow64 matches std.math.pow on the host (sanity + dense sweep)" {
    const cases = [_][2]f64{
        .{ 2.0, 0.5 },    .{ 2.0, 10.0 },    .{ 3.0, 1.5 },   .{ 10.0, 1.0 / 3.0 },
        .{ 0.5, -2.0 },   .{ 7.0, 2.5 },     .{ 1.5, 100.0 }, .{ 100.0, 0.01 },
        .{ 2.0, -0.5 },   .{ 5.0, 3.0 },     .{ 0.1, 0.1 },   .{ 1234.5, 0.7 },
        .{ 2.0, 1023.0 }, .{ 2.0, -1000.0 },
    };
    for (cases) |c| {
        try std.testing.expectApproxEqRel(std.math.pow(f64, c[0], c[1]), pow64(c[0], c[1]), 1e-13);
    }
    // dense fractional sweep — exercises the log/exp tables broadly.
    var b: f64 = 0.3;
    while (b <= 12.0) : (b += 0.037) {
        var e: f64 = -3.5;
        while (e <= 3.5) : (e += 0.11) {
            try std.testing.expectApproxEqRel(std.math.pow(f64, b, e), pow64(b, e), 1e-12);
        }
    }
}

test "pow64 special cases (IEEE-754 matrix)" {
    const nan = math.nan(f64);
    const inf = math.inf(f64);
    // x^0 == 1 for any x (incl. nan, inf, 0)
    try std.testing.expectEqual(@as(f64, 1.0), pow64(3.0, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(nan, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(inf, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(0.0, 0.0));
    // 1^y == 1 for any y (incl. nan, inf)
    try std.testing.expectEqual(@as(f64, 1.0), pow64(1.0, 5.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(1.0, nan));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(1.0, inf));
    // nan propagation (x != 1, y != 0)
    try std.testing.expect(math.isNan(pow64(nan, 2.0)));
    try std.testing.expect(math.isNan(pow64(2.0, nan)));
    // negative base
    try std.testing.expectEqual(@as(f64, -8.0), pow64(-2.0, 3.0)); // odd int
    try std.testing.expectEqual(@as(f64, 4.0), pow64(-2.0, 2.0)); // even int
    try std.testing.expect(math.isNan(pow64(-2.0, 0.5))); // non-int -> nan
    // signed-zero base
    try std.testing.expectEqual(inf, pow64(0.0, -1.0)); // +0 ^ neg = +inf
    try std.testing.expectEqual(-inf, pow64(-0.0, -1.0)); // -0 ^ neg-odd = -inf
    try std.testing.expect(math.isPositiveZero(pow64(0.0, 2.0))); // +0 ^ pos = +0
    try std.testing.expect(math.isNegativeZero(pow64(-0.0, 3.0))); // -0 ^ pos-odd = -0
    // infinities
    try std.testing.expectEqual(inf, pow64(inf, 2.0));
    try std.testing.expect(math.isPositiveZero(pow64(inf, -1.0)));
    try std.testing.expectEqual(@as(f64, 1.0), pow64(-1.0, inf)); // |x|==1, y=inf
    try std.testing.expectEqual(inf, pow64(2.0, inf));
    try std.testing.expect(math.isPositiveZero(pow64(2.0, -inf)));
    try std.testing.expectEqual(inf, pow64(0.5, -inf));
    try std.testing.expect(math.isPositiveZero(pow64(0.5, inf)));
    // overflow / underflow
    try std.testing.expectEqual(inf, pow64(2.0, 100000.0));
    try std.testing.expect(math.isPositiveZero(pow64(2.0, -100000.0)));
}

// Exact-bit determinism pins — pow64's own pure strict-mode f64 output,
// host-INDEPENDENT by construction (non-FMA, no libm). Captured from a native
// run and cross-checked against std.math.pow by the sanity test above; these
// are the bytes native and both wasm32 artifacts must all return. A flipped
// byte is a determinism break — investigate, don't silently re-baseline.
test "pow64 exact-bit pins" {
    const Case = struct { b: f64, e: f64, bits: u64 };
    const cases = [_]Case{
        .{ .b = 2.0, .e = 0.5, .bits = 0x3ff6a09e667f3bcd }, // sqrt(2)
        .{ .b = 3.0, .e = 1.5, .bits = 0x4014c8dc2e423980 },
        .{ .b = 10.0, .e = 1.0 / 3.0, .bits = 0x40013c484138704f },
        .{ .b = 2.0, .e = 64.0, .bits = 0x43f0000000000000 }, // exact 2^64
        .{ .b = 0.5, .e = 0.5, .bits = 0x3fe6a09e667f3bcd }, // 1/sqrt(2)
        .{ .b = 123.0, .e = 0.456, .bits = 0x4021f2cd03d9df6d },
        .{ .b = 1.0000000001, .e = 1000.0, .bits = 0x3ff000001ad7f2d6 },
        .{ .b = 7.0, .e = -2.5, .bits = 0x3f7f98412d43e086 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.bits, @as(u64, @bitCast(pow64(c.b, c.e))));
    }
}
