const std = @import("std");
const math = std.math;

comptime {
    std.debug.assert(ipio2.len >= 686);
    std.debug.assert(PIo2.len == 8);
    std.debug.assert(init_jk.len == 4);
}

pub fn sin64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e500000) {
            return x;
        }
        return kSin(x, 0.0, 0);
    }

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

pub fn cos64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e46a09e) {
            return 1.0;
        }
        return kCos(x, 0);
    }

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

pub fn tan64(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e400000) {
            return x;
        }
        return kTan(x, 0.0, false);
    }

    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return kTan(y[0], y[1], n & 1 != 0);
}

fn kCos(x: f64, y: f64) f64 {
    const C1 = 4.16666666666666019037e-02;
    const C2 = -1.38888888888741095749e-03;
    const C3 = 2.48015872894767294178e-05;
    const C4 = -2.75573143513906633035e-07;
    const C5 = 2.08757232129817482790e-09;
    const C6 = -1.13596475577881948265e-11;

    const z = x * x;
    const w = z * z;
    const r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    const hz = 0.5 * z;
    const w2 = 1.0 - hz;
    return w2 + (((1.0 - w2) - hz) + (z * r - x * y));
}

fn kSin(x: f64, y: f64, iy: i32) f64 {
    const S1 = -1.66666666666666324348e-01;
    const S2 = 8.33333333332248946124e-03;
    const S3 = -1.98412698298579493134e-04;
    const S4 = 2.75573137070700676789e-06;
    const S5 = -2.50507602534068634195e-08;
    const S6 = 1.58969099521155010221e-10;

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

fn kTan(x_: f64, y_: f64, odd: bool) f64 {
    var x = x_;
    var y = y_;

    const T = [_]f64{
        3.33333333333334091986e-01,
        1.33333333333201242699e-01,
        5.39682539762260521377e-02,
        2.18694882948595424599e-02,
        8.86323982359930005737e-03,
        3.59207910759131235356e-03,
        1.45620945432529025516e-03,
        5.88041240820264096874e-04,
        2.46463134818469906812e-04,
        7.81794442939557092300e-05,
        7.14072491382608190305e-05,
        -1.85586374855275456654e-05,
        2.59073051863633712884e-05,
    };
    const tan_pio4 = 7.85398163397448278999e-01;
    const tan_pio4lo = 3.06161699786838301793e-17;

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
    const big = (hx & 0x7fffffff) >= 0x3FE59428;
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
    w0 = w;
    w0 = @bitCast(@as(u64, @bitCast(w0)) & 0xffffffff00000000);
    v = r - (w0 - x);
    a = -1.0 / w;
    a0 = a;
    a0 = @bitCast(@as(u64, @bitCast(a0)) & 0xffffffff00000000);
    return a0 + a * (1.0 + a0 * w0 + a0 * v);
}

const toint = 1.5 / math.floatEps(f64);
const pio4 = 0x1.921fb54442d18p-1;
const invpio2 = 6.36619772367581382433e-01;
const pio2_1 = 1.57079632673412561417e+00;
const pio2_1t = 6.07710050650619224932e-11;
const pio2_2 = 6.07710050630396597660e-11;
const pio2_2t = 2.02226624879595063154e-21;
const pio2_3 = 2.02226624871116645580e-21;
const pio2_3t = 8.47842766036889956997e-32;

fn medium(ix: u32, x: f64, y: *[2]f64) i32 {
    var w: f64 = undefined;
    var t: f64 = undefined;
    var r: f64 = undefined;
    var @"fn": f64 = undefined;
    var n: i32 = undefined;
    var ex: i32 = undefined;
    var ey: i32 = undefined;
    var ui: u64 = undefined;

    @"fn" = x * invpio2 + toint - toint;
    n = @intFromFloat(@"fn");
    r = x - @"fn" * pio2_1;
    w = @"fn" * pio2_1t;
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
    if (ex - ey > 16) {
        t = r;
        w = @"fn" * pio2_2;
        r = t - w;
        w = @"fn" * pio2_2t - ((t - r) - w);
        y[0] = r - w;
        ui = @bitCast(y[0]);
        ey = @intCast((ui >> 52) & 0x7ff);
        if (ex - ey > 49) {
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
    if (ix <= 0x400f6a7a) {
        if ((ix & 0xfffff) == 0x921fb) {
            return medium(ix, x, y);
        }
        if (ix <= 0x4002d97c) {
            if (!sign) {
                z = x - pio2_1;
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
    if (ix <= 0x401c463b) {
        if (ix <= 0x4015fdbc) {
            if (ix == 0x4012d97c) {
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
            if (ix == 0x401921fb) {
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
    if (ix < 0x413921fb) {
        return medium(ix, x, y);
    }
    if (ix >= 0x7ff00000) {
        y[0] = x - x;
        y[1] = y[0];
        return 0;
    }
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

const init_jk = [_]i32{ 3, 4, 4, 6 };

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
    1.57079625129699707031e+00,
    7.54978941586159635335e-08,
    5.39030252995776476554e-15,
    3.28200341580791294123e-22,
    1.27065575308067607349e-29,
    1.22933308981111328932e-36,
    2.73370053816464559624e-44,
    2.16741683877804819444e-51,
};

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

    jk = init_jk[prec];
    jp = jk;

    jx = nx - 1;
    jv = @divFloor(e0 - 3, 24);
    if (jv < 0) jv = 0;
    q0 = e0 - 24 * (jv + 1);

    j = jv - jx;
    m = jx + jk;
    i = 0;
    while (i <= m) : ({
        i += 1;
        j += 1;
    }) {
        f[@intCast(i)] = if (j < 0) 0.0 else @floatFromInt(ipio2[@intCast(j)]);
    }

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

    recompute: while (true) {
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

        z = math.scalbn(z, q0);
        z -= 8.0 * @floor(z * 0.125);
        n = @intFromFloat(z);
        z -= @floatFromInt(n);
        ih = 0;
        if (q0 > 0) {
            i = iq[@intCast(jz - 1)] >> @intCast(24 - q0);
            n += i;
            iq[@intCast(jz - 1)] -= i << @intCast(24 - q0);
            ih = iq[@intCast(jz - 1)] >> @intCast(23 - q0);
        } else if (q0 == 0) {
            ih = iq[@intCast(jz - 1)] >> 23;
        } else if (z >= 0.5) {
            ih = 2;
        }

        if (ih > 0) {
            n += 1;
            carry = 0;
            i = 0;
            while (i < jz) : (i += 1) {
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
            if (q0 > 0) {
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

        if (z == 0.0) {
            j = 0;
            i = jz - 1;
            while (i >= jk) : (i -= 1) {
                j |= iq[@intCast(i)];
            }

            if (j == 0) {
                k = 1;
                while (iq[@intCast(jk - k)] == 0) : (k += 1) {}

                i = jz + 1;
                while (i <= jz + k) : (i += 1) {
                    f[@intCast(jx + i)] = @floatFromInt(ipio2[@intCast(jv + i)]);
                    j = 0;
                    fw = 0;
                    while (j <= jx) : (j += 1) {
                        fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
                    }
                    q[@intCast(i)] = fw;
                }
                jz += k;
                continue :recompute;
            }
        }

        if (z == 0.0) {
            jz -= 1;
            q0 -= 24;
            while (iq[@intCast(jz)] == 0) {
                jz -= 1;
                q0 -= 24;
            }
        } else {
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

        fw = math.scalbn(@as(f64, 1.0), q0);
        i = jz;
        while (i >= 0) : (i -= 1) {
            q[@intCast(i)] = fw * @as(f64, @floatFromInt(iq[@intCast(i)]));
            fw *= 0x1p-24;
        }

        i = jz;
        while (i >= 0) : (i -= 1) {
            fw = 0;
            k = 0;
            while (k <= jp and k <= jz - i) : (k += 1) {
                fw += PIo2[@intCast(k)] * q[@intCast(i + k)];
            }
            fq[@intCast(jz - i)] = fw;
        }

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
                fw = fw;
                y[0] = if (ih == 0) fw else -fw;
                fw = fq[0] - fw;
                i = 1;
                while (i <= jz) : (i += 1) {
                    fw += fq[@intCast(i)];
                }
                y[1] = if (ih == 0) fw else -fw;
            },
            3 => {
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
