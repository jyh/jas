import Foundation

public let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct MandelbrotUniforms {
    float centerX_hi;
    float centerX_lo;
    float centerY_hi;
    float centerY_lo;
    float scale_hi;
    float scale_lo;
    int maxIter;
    int width;
    int height;
    int refOrbitLen;
};

// =====================================================================
// Double-double (float-float) arithmetic
// =====================================================================

struct dd {
    float hi;
    float lo;
};

inline dd quick_two_sum(float a, float b) {
    float s = a + b;
    float e = b - (s - a);
    return {s, e};
}

inline dd two_sum(float a, float b) {
    float s = a + b;
    float v = s - a;
    float e = (a - (s - v)) + (b - v);
    return {s, e};
}

inline dd two_prod(float a, float b) {
    float p = a * b;
    float e = fma(a, b, -p);
    return {p, e};
}

inline dd dd_add(dd a, dd b) {
    dd s = two_sum(a.hi, b.hi);
    float e = s.lo + a.lo + b.lo;
    return quick_two_sum(s.hi, e);
}

inline dd dd_sub(dd a, dd b) {
    return dd_add(a, {-b.hi, -b.lo});
}

inline dd dd_mul(dd a, dd b) {
    dd p = two_prod(a.hi, b.hi);
    p.lo += a.hi * b.lo + a.lo * b.hi;
    return quick_two_sum(p.hi, p.lo);
}

inline dd dd_mul_scalar(dd a, float s) {
    dd p = two_prod(a.hi, s);
    p.lo += a.lo * s;
    return quick_two_sum(p.hi, p.lo);
}

inline dd dd_from(float a) {
    return {a, 0.0f};
}

inline dd dd_from(float hi, float lo) {
    return {hi, lo};
}

// =====================================================================
// Hybrid perturbation + dd fallback Mandelbrot kernel
//
// Phase 1: Perturbation theory using precomputed reference orbit
// Phase 2: If reference orbit exhausted, continue with dd arithmetic
// =====================================================================

kernel void mandelbrot(
    texture2d<float, access::write> output [[texture(0)]],
    constant MandelbrotUniforms &uniforms [[buffer(0)]],
    constant float2 *refOrbit [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.width) || gid.y >= uint(uniforms.height)) return;

    float w = float(uniforms.width);
    float h = float(uniforms.height);
    float aspect = h / w;

    // Compute δc using dd arithmetic for precision at deep zoom
    dd scaleX = dd_from(uniforms.scale_hi, uniforms.scale_lo);
    dd scaleY = dd_mul_scalar(scaleX, aspect);

    float pixelX = float(gid.x) / w - 0.5f;
    float pixelY = float(gid.y) / h - 0.5f;

    dd dc_x_dd = dd_mul_scalar(scaleX, pixelX);
    dd dc_y_dd = dd_mul_scalar(scaleY, pixelY);

    float dcx = dc_x_dd.hi + dc_x_dd.lo;
    float dcy = -(dc_y_dd.hi + dc_y_dd.lo);

    int maxIter = uniforms.maxIter;
    int refLen = uniforms.refOrbitLen;
    int iterLimit = min(maxIter, refLen);

    // Phase 1: Perturbation iteration
    float dzx = 0.0f;
    float dzy = 0.0f;
    int iter = 0;
    float fx = 0.0f, fy = 0.0f;
    bool escaped = false;

    while (iter < iterLimit) {
        float2 Zn = refOrbit[iter];
        float Zx = Zn.x;
        float Zy = Zn.y;

        fx = Zx + dzx;
        fy = Zy + dzy;
        if (fx * fx + fy * fy > 4.0f) { escaped = true; break; }

        float new_dzx = 2.0f * (Zx * dzx - Zy * dzy) + dzx * dzx - dzy * dzy + dcx;
        float new_dzy = 2.0f * (Zx * dzy + Zy * dzx) + 2.0f * dzx * dzy + dcy;

        dzx = new_dzx;
        dzy = new_dzy;
        iter++;
    }

    // Phase 2: If reference orbit exhausted, continue with dd direct computation
    if (!escaped && iter < maxIter) {
        // Reconstruct full z as dd from Z_n + δz
        dd zx_dd, zy_dd;
        if (iter < refLen) {
            float2 Zn = refOrbit[iter];
            zx_dd = two_sum(Zn.x, dzx);
            zy_dd = two_sum(Zn.y, dzy);
        } else {
            zx_dd = dd_from(dzx);
            zy_dd = dd_from(dzy);
        }

        // Full c = center + δc
        dd cx_dd = dd_add(dd_from(uniforms.centerX_hi, uniforms.centerX_lo), dc_x_dd);
        dd cy_dd = dd_sub(dd_from(uniforms.centerY_hi, uniforms.centerY_lo), dc_y_dd);

        while (iter < maxIter) {
            dd x2 = dd_mul(zx_dd, zx_dd);
            dd y2 = dd_mul(zy_dd, zy_dd);
            dd mag2 = dd_add(x2, y2);
            if (mag2.hi > 4.0f) {
                fx = zx_dd.hi;
                fy = zy_dd.hi;
                escaped = true;
                break;
            }

            dd new_x = dd_add(dd_sub(x2, y2), cx_dd);
            dd xy = dd_mul(zx_dd, zy_dd);
            dd new_y = dd_add(dd_mul_scalar(xy, 2.0f), cy_dd);
            zx_dd = new_x;
            zy_dd = new_y;
            iter++;
        }
    }

    // Smooth iteration count
    float smoothIter;
    if (!escaped) {
        smoothIter = float(maxIter);
        iter = maxIter;
    } else {
        float mag = fx * fx + fy * fy;
        float mu = log2(log2(mag) * 0.5);
        smoothIter = float(iter) + 1.0 - mu;
    }

    float frac = smoothIter / float(maxIter);
    frac = clamp(frac, 0.0, 1.0);

    if (iter == maxIter) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Colormap
    float gamma = 0.7 + log10(float(maxIter) + 1.0) / 2.5;
    float intensity = pow(frac, gamma);
    float edge = clamp(1.0 - sqrt(intensity), 0.0, 1.0);

    float hue = fmod(0.66 + 0.34 * intensity, 1.0);
    float v = 0.25 + 0.75 * edge;

    // HSV to RGB (saturation = 1)
    float hi = hue * 6.0;
    int hi_i = int(hi) % 6;
    float f = hi - float(int(hi));
    float p = 0.0;
    float q = v * (1.0 - f);
    float t = v * f;

    float r, g, b;
    switch (hi_i) {
        case 0: r = v; g = t; b = p; break;
        case 1: r = q; g = v; b = p; break;
        case 2: r = p; g = v; b = t; break;
        case 3: r = p; g = q; b = v; break;
        case 4: r = t; g = p; b = v; break;
        default: r = v; g = p; b = q; break;
    }

    output.write(float4(r, g, b, 1.0), gid);
}
"""
