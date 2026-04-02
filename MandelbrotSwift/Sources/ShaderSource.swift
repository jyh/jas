import Foundation

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct MandelbrotUniforms {
    float centerX;
    float centerY;
    float scale;
    int maxIter;
    int width;
    int height;
};

kernel void mandelbrot(
    texture2d<float, access::write> output [[texture(0)]],
    constant MandelbrotUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.width) || gid.y >= uint(uniforms.height)) return;

    float w = float(uniforms.width);
    float h = float(uniforms.height);
    float aspect = h / w;

    float scaleX = uniforms.scale;
    float scaleY = uniforms.scale * aspect;

    float cx = uniforms.centerX + (float(gid.x) / w - 0.5) * scaleX;
    float cy = uniforms.centerY - (float(gid.y) / h - 0.5) * scaleY;

    float x = 0.0;
    float y = 0.0;
    int iter = 0;
    int maxIter = uniforms.maxIter;

    while (x * x + y * y <= 4.0 && iter < maxIter) {
        float xt = x * x - y * y + cx;
        y = 2.0 * x * y + cy;
        x = xt;
        iter++;
    }

    // Smooth iteration count
    float smoothIter;
    if (iter == maxIter) {
        smoothIter = float(maxIter);
    } else {
        float mag = x * x + y * y;
        float mu = log2(log2(mag) * 0.5);
        smoothIter = float(iter) + 1.0 - mu;
    }

    float frac = smoothIter / float(maxIter);
    frac = clamp(frac, 0.0, 1.0);

    // Color: inside the set is black
    if (iter == maxIter) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Colormap matching the Python version
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
