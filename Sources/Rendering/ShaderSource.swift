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
    float deepness = saturate(depth / 70.0);
    float3 shallowColor = float3(0.56, 0.74, 0.90);
    float3 deepColor = float3(0.14, 0.30, 0.50);
    float3 color = mix(shallowColor, deepColor, deepness);
    float alpha = mix(0.24, 0.52, deepness);

    float2 refracted = in.world + float2(sin(in.world.y * 0.21 + uniforms.time * 2.3) * 2.5, 0.0);
    float caustic = causticPattern(refracted, uniforms.time);
    color += caustic * 0.09 * (1.0 - deepness * 0.6);
    alpha += caustic * 0.03;

    float refractionBand = smoothstep(1.4, 3.5, depth) * (1.0 - smoothstep(3.5, 9.0, depth));
    float bandWobble = 0.5 + 0.5 * sin(in.world.x * 0.07 - uniforms.time * 1.6);
    color = mix(color, color * 0.72, refractionBand * (0.4 + 0.3 * bandWobble));
    alpha += refractionBand * 0.07;

    float highlight = 1.0 - smoothstep(max(0.9, pixel * 1.5) * 0.5, max(1.6, pixel * 2.5), depth);
    color = mix(color, float3(0.93, 0.97, 1.0), highlight);
    alpha = max(alpha, highlight * 0.8);

    alpha *= in.opacity;
    return float4(color * alpha, alpha);
}
"""
}
