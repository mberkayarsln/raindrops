enum ShaderSource {
    static let metal = """
#include <metal_stdlib>
using namespace metal;

struct SegmentInstance {
    float2 start;
    float2 end;
    float4 color;
    float width;
    float softness;
    float tailFade;
    float capRoundness;
};

struct WaterVertexIn {
    float2 position;
    float depth;
    float opacity;
};

struct FrameUniforms {
    float2 viewSize;
    float time;
    float pixelScale;
};

struct SegmentVarying {
    float4 position [[position]];
    float4 color;
    float2 local;
    float segmentLength;
    float halfWidth;
    float softness;
    float tailFade;
    float capRoundness;
};

struct WaterVarying {
    float4 position [[position]];
    float2 world;
    float depth;
    float opacity;
};

static float4 toClipSpace(float2 point, float2 viewSize) {
    return float4(point / viewSize * 2.0 - 1.0, 0.0, 1.0);
}

vertex SegmentVarying segmentVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device SegmentInstance *instances [[buffer(0)]],
    constant FrameUniforms &uniforms [[buffer(1)]]
) {
    SegmentInstance segment = instances[instanceID];
    float2 delta = segment.end - segment.start;
    float segmentLength = length(delta);
    float2 direction = segmentLength > 1e-4 ? delta / segmentLength : float2(0.0, 1.0);
    float2 normal = float2(-direction.y, direction.x);
    float pixel = 1.0 / uniforms.pixelScale;
    float requestedHalfWidth = segment.width * 0.5;
    float halfWidth = max(requestedHalfWidth, pixel * 0.5);
    float padding = halfWidth + pixel;
    float alongEnd = (vertexID & 1u) ? 1.0 : 0.0;
    float acrossSide = (vertexID & 2u) ? 1.0 : -1.0;
    float along = alongEnd * segmentLength + (alongEnd * 2.0 - 1.0) * padding;
    float across = acrossSide * padding;
    float2 world = segment.start + direction * along + normal * across;

    SegmentVarying out;
    out.position = toClipSpace(world, uniforms.viewSize);
    out.color = segment.color;
    out.color.a *= min(requestedHalfWidth / halfWidth, 1.0);
    out.local = float2(along, across);
    out.segmentLength = segmentLength;
    out.halfWidth = halfWidth;
    out.softness = segment.softness;
    out.tailFade = segment.tailFade;
    out.capRoundness = segment.capRoundness;
    return out;
}

fragment float4 segmentFragment(
    SegmentVarying in [[stage_in]],
    constant FrameUniforms &uniforms [[buffer(1)]]
) {
    float pixel = 1.0 / uniforms.pixelScale;
    float along = clamp(in.local.x, 0.0, in.segmentLength);
    float overshoot = in.local.x - along;
    float distanceToAxis = length(float2(overshoot * in.capRoundness, in.local.y));
    float capCoverage = in.capRoundness > 0.5 ? 1.0 : 1.0 - smoothstep(0.0, pixel, abs(overshoot));
    float inner = in.halfWidth * (1.0 - in.softness);
    float coverage = 1.0 - smoothstep(inner - pixel * 0.5, in.halfWidth + pixel * 0.5, distanceToAxis);
    float progress = in.segmentLength > 1e-4 ? along / in.segmentLength : 1.0;
    float fade = mix(1.0, progress, in.tailFade);
    float alpha = in.color.a * coverage * capCoverage * fade;
    return float4(in.color.rgb * alpha, alpha);
}

vertex WaterVarying waterVertex(
    uint vertexID [[vertex_id]],
    const device WaterVertexIn *vertices [[buffer(0)]],
    constant FrameUniforms &uniforms [[buffer(1)]]
) {
    WaterVertexIn source = vertices[vertexID];
    WaterVarying out;
    out.position = toClipSpace(source.position, uniforms.viewSize);
    out.world = source.position;
    out.depth = source.depth;
    out.opacity = source.opacity;
    return out;
}

static float causticPattern(float2 point, float time) {
    float first = sin(point.x * 0.031 + time * 0.9 + sin(point.y * 0.06 - time * 0.5) * 2.2);
    float second = sin(point.x * 0.077 - time * 1.3 + point.y * 0.043 + sin(point.x * 0.011 + point.y * 0.02 + time * 0.35) * 2.6);
    float third = sin(point.y * 0.12 + point.x * 0.019 + time * 0.8);
    return smoothstep(0.35, 1.0, first * second * 0.8 + third * 0.2);
}

fragment float4 waterFragment(
    WaterVarying in [[stage_in]],
    constant FrameUniforms &uniforms [[buffer(1)]]
) {
    float depth = max(in.depth, 0.0);
    float pixel = 1.0 / uniforms.pixelScale;
    float absorption = 1.0 - exp(-depth / 140.0);
    float shallow = 1.0 - saturate(depth / 70.0);
    float3 surfaceColor = float3(0.56, 0.74, 0.90);
    float3 midColor = float3(0.16, 0.36, 0.56);
    float3 abyssColor = float3(0.04, 0.12, 0.24);
    float3 color = mix(surfaceColor, midColor, saturate(depth / 70.0));
    color = mix(color, abyssColor, saturate((depth - 70.0) / 260.0));
    float alpha = mix(0.24, 0.62, absorption);

    float2 refracted = in.world + float2(sin(in.world.y * 0.21 + uniforms.time * 2.3) * 2.5, 0.0);
    float caustic = causticPattern(refracted, uniforms.time);
    float causticFade = exp(-depth / 90.0);
    color += caustic * 0.09 * causticFade;
    alpha += caustic * 0.03 * causticFade;

    float shaftCoordinate = in.world.x + depth * 0.35;
    float shaftA = sin(shaftCoordinate * 0.021 + uniforms.time * 0.23 + sin(shaftCoordinate * 0.006 + uniforms.time * 0.11) * 2.0);
    float shaftB = sin(shaftCoordinate * 0.047 - uniforms.time * 0.17);
    float shafts = smoothstep(0.55, 1.0, shaftA * 0.7 + shaftB * 0.3);
    float shaftVisibility = smoothstep(25.0, 90.0, depth) * exp(-depth / 320.0);
    color += float3(0.55, 0.75, 0.95) * shafts * shaftVisibility * 0.16;

    float murk = sin(in.world.x * 0.013 + in.world.y * 0.017 + uniforms.time * 0.07) * sin(in.world.y * 0.011 - uniforms.time * 0.05);
    color *= 1.0 + murk * 0.05 * absorption;

    float refractionBand = smoothstep(1.4, 3.5, depth) * (1.0 - smoothstep(3.5, 9.0, depth));
    float bandWobble = 0.5 + 0.5 * sin(in.world.x * 0.07 - uniforms.time * 1.6);
    color = mix(color, color * 0.72, refractionBand * (0.4 + 0.3 * bandWobble));
    alpha += refractionBand * 0.07;

    float subsurface = smoothstep(2.0, 6.0, depth) * (1.0 - smoothstep(6.0, 26.0, depth)) * (1.0 - shallow * 0.5);
    color += float3(0.35, 0.55, 0.70) * subsurface * 0.12;

    float highlight = 1.0 - smoothstep(max(0.9, pixel * 1.5) * 0.5, max(1.6, pixel * 2.5), depth);
    color = mix(color, float3(0.93, 0.97, 1.0), highlight);
    alpha = max(alpha, highlight * 0.8);

    alpha = min(alpha, 0.72) * in.opacity;
    return float4(color * alpha, alpha);
}
"""
}
