#include <metal_stdlib>
using namespace metal;

struct BendUniforms {
    float progress;      // 0 = lid open, 1 = shut
    float tilt;          // total bend angle in radians
    float aspect;        // width / height
    float cameraDist;    // eye distance in plane-heights
    float blurMix;       // 0 = sharp, 1 = fully blurred
    float shadow;        // 0...1 shadow weight
    float2 texelSize;    // for the blur passes
    float sigma;         // blur sigma in texels
};

struct GridVertex {
    float2 uv;
};

struct BendOut {
    float4 position [[position]];
    float2 uv;
    float depth;   // 0 at the hinge, 1 at the receding edge
    float curve;   // how far this row has rotated, 0...1
};

// MARK: - The bend
//
// The desktop is treated as a sheet hinged along its bottom edge. Each row is
// rotated a little further than the one below it, so the sheet curves into a
// circular arc rather than tipping as a rigid plane — that curve is what reads
// as a fold. Then a plain perspective divide makes the far edge recede.

vertex BendOut bend_vertex(uint vid [[vertex_id]],
                           const device GridVertex *vertices [[buffer(0)]],
                           constant BendUniforms &u [[buffer(1)]])
{
    float2 uv = vertices[vid].uv;
    const float H = 2.0;              // sheet height in NDC units
    float v = 1.0 - uv.y;             // texture v is top-down; geometry is bottom-up
    float yHinge = v * H;

    float yArc;
    float zOffset;
    if (u.tilt < 1e-4) {
        yArc = yHinge;                // flat: the arc formula degenerates
        zOffset = 0.0;
    } else {
        float radius = H / u.tilt;
        float a = u.tilt * v;         // rotation accumulated by this row
        yArc = radius * sin(a);
        zOffset = radius * (1.0 - cos(a));
    }

    float dist = u.cameraDist + zOffset;
    float proj = u.cameraDist / dist;

    BendOut out;
    out.position = float4((uv.x - 0.5) * 2.0 * proj,
                          (yArc - H * 0.5) * proj,
                          0.0, 1.0);
    out.uv = uv;
    out.depth = v;
    out.curve = (u.tilt < 1e-4) ? 0.0 : zOffset / max(H, 1e-4);
    return out;
}

fragment float4 bend_fragment(BendOut in [[stage_in]],
                              texture2d<float> sharp [[texture(0)]],
                              texture2d<float> blurred [[texture(1)]],
                              constant BendUniforms &u [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float3 colour = mix(sharp.sample(s, in.uv).rgb,
                        blurred.sample(s, in.uv).rgb,
                        saturate(u.blurMix));

    // Light falls off along the fold: the further a row has rotated away, the
    // less of the room it catches. A touch of ambient occlusion sits at the
    // hinge, where the sheet meets the base.
    float away = saturate(in.curve * 3.0);
    float lambert = mix(1.0, 0.35, away);
    float occlusion = 1.0 - 0.18 * u.shadow * exp(-in.depth * 12.0);
    float dim = 1.0 - 0.30 * u.shadow * u.progress;

    colour *= mix(1.0, lambert, u.shadow) * occlusion * dim;

    // Cools very slightly on the way down, like a screen losing its backlight.
    colour = mix(colour, colour * float3(0.94, 0.96, 1.04), 0.35 * u.progress);

    return float4(colour, 1.0);
}

// MARK: - Background
//
// Whatever the shrinking sheet no longer covers. Kept near-black with a gentle
// vertical lift so the fold looks like it is sitting in a space, not on a void.

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]])
{
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    FullscreenOut out;
    out.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    out.uv = c;
    return out;
}

fragment float4 background_fragment(FullscreenOut in [[stage_in]],
                                    constant BendUniforms &u [[buffer(1)]])
{
    float lift = (1.0 - in.uv.y) * 0.035;
    float3 colour = float3(0.02 + lift, 0.02 + lift, 0.025 + lift * 1.2);
    return float4(colour * (0.4 + 0.6 * u.progress), 1.0);
}

// MARK: - Separable gaussian
//
// Run at half resolution: the blur is a soft effect and nobody is counting
// pixels through it. Weights are built from the uniform sigma each pass so the
// blur can grow smoothly with the hinge instead of stepping between kernels.
//
// Nine taps either side have to cover three sigma, which puts them sigma/3
// apart — more than a texel as soon as the blur widens, and sampling detail
// finer than the gap turns it into stripes. So each tap reads from the mip
// level where its own spacing is one texel, and averages the pixels it steps
// over instead of missing them.

fragment float4 blur_fragment(FullscreenOut in [[stage_in]],
                              texture2d<float> source [[texture(0)]],
                              constant BendUniforms &u [[buffer(1)]],
                              constant float2 &direction [[buffer(2)]])
{
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float sigma = max(u.sigma, 0.01);
    float step = max(sigma / 3.0, 1.0);
    float lod = log2(step);

    float3 sum = source.sample(s, in.uv, level(lod)).rgb;
    float weightSum = 1.0;

    for (int i = 1; i <= 9; ++i) {
        float offset = float(i) * step;
        float w = exp(-(offset * offset) / (2.0 * sigma * sigma));
        float2 d = direction * u.texelSize * offset;
        sum += source.sample(s, in.uv + d, level(lod)).rgb * w;
        sum += source.sample(s, in.uv - d, level(lod)).rgb * w;
        weightSum += 2.0 * w;
    }
    return float4(sum / weightSum, 1.0);
}

fragment float4 copy_fragment(FullscreenOut in [[stage_in]],
                              texture2d<float> source [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(source.sample(s, in.uv).rgb, 1.0);
}
