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
// Pass 1: Compute smooth iteration counts into a float texture
// =====================================================================

kernel void mandelbrot_iterations(
    texture2d<float, access::write> iterTex [[texture(0)]],
    constant MandelbrotUniforms &uniforms [[buffer(0)]],
    constant float2 *refOrbit [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.width) || gid.y >= uint(uniforms.height)) return;

    float w = float(uniforms.width);
    float h = float(uniforms.height);
    float aspect = h / w;

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

    // Phase 2: dd fallback
    if (!escaped && iter < maxIter) {
        dd zx_dd, zy_dd;
        if (iter < refLen) {
            // Phase 1 escaped early — should not happen since escaped==false, but guard anyway.
            float2 Zn = refOrbit[iter];
            zx_dd = two_sum(Zn.x, dzx);
            zy_dd = two_sum(Zn.y, dzy);
        } else {
            // Phase 1 exhausted the reference orbit (iter == refLen, center is exterior).
            // Reconstruct z = Z_{refLen} + δz, where Z_{refLen} = f(orbit[refLen-1]).
            // Without this, δz is used as z directly, misclassifying interior pixels.
            float2 Zlast = refOrbit[refLen - 1];
            dd Zx_last = dd_from(Zlast.x);
            dd Zy_last = dd_from(Zlast.y);
            dd cx_ref = dd_from(uniforms.centerX_hi, uniforms.centerX_lo);
            dd cy_ref = dd_from(uniforms.centerY_hi, uniforms.centerY_lo);
            dd x2r = dd_mul(Zx_last, Zx_last);
            dd y2r = dd_mul(Zy_last, Zy_last);
            dd xyr = dd_mul(Zx_last, Zy_last);
            dd Zx_next = dd_add(dd_sub(x2r, y2r), cx_ref);
            dd Zy_next = dd_add(dd_mul_scalar(xyr, 2.0f), cy_ref);
            zx_dd = dd_add(Zx_next, dd_from(dzx));
            zy_dd = dd_add(Zy_next, dd_from(dzy));
        }

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

    // Smooth iteration count; -1 marks interior (in-set) pixels
    float smoothIter;
    if (!escaped) {
        smoothIter = -1.0;
    } else {
        float mag = fx * fx + fy * fy;
        float mu = log2(log2(mag) * 0.5);
        smoothIter = float(iter) + 1.0 - mu;
    }

    iterTex.write(float4(smoothIter, 0.0, 0.0, 0.0), gid);
}

// =====================================================================
// Pass 2: Colorize using a precomputed color LUT (built on CPU)
// =====================================================================

struct ColorUniforms {
    int width;
    int height;
    int lutSize;
    float maxIter;
};

kernel void mandelbrot_colorize(
    texture2d<float, access::read> iterTex [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ColorUniforms &uniforms [[buffer(0)]],
    constant float4 *colorLUT [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.width) || gid.y >= uint(uniforms.height)) return;

    float smoothIter = iterTex.read(gid).r;

    if (smoothIter < 0.0) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    int lutSize = uniforms.lutSize;
    int idx = clamp(int(smoothIter / uniforms.maxIter * float(lutSize)), 0, lutSize - 1);
    output.write(colorLUT[idx], gid);
}
"""
