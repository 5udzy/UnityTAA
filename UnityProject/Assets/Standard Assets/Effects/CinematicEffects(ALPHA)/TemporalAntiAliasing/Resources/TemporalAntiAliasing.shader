Shader "Hidden/Temporal Anti-aliasing"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }

    CGINCLUDE
        #pragma only_renderers ps4 xboxone d3d11 d3d9 xbox360 opengl glcore
        #pragma exclude_renderers gles
        #pragma target 3.0

        #include "UnityCG.cginc"

        #define TAA_REMOVE_COLOR_SAMPLE_JITTER 1

        #define TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES 1

        #define TAA_COLOR_NEIGHBORHOOD_SAMPLE_PATTERN 1
        #define TAA_COLOR_NEIGHBORHOOD_SAMPLE_SPREAD 1.

        #define TAA_DILATE_MOTION_VECTOR_SAMPLE 1

        #define TAA_HISTORY_SAMPLE_FILTER 0
        #define TAA_CLIP_HISTORY_SAMPLE 1

        #define TAA_HISTORY_NEIGHBORHOOD_SAMPLE_SPREAD .5

        #define TAA_DEPTH_SAMPLE_PATTERN 1
        #define TAA_DEPTH_SAMPLE_SPREAD 1.

        #define TAA_SHARPEN_OUTPUT 1
        #define TAA_FINAL_BLEND_METHOD 1

        #if TAA_FINAL_BLEND_METHOD == 0
            #define TAA_FINAL_BLEND_FACTOR .97
        #endif

        struct Input
        {
            float4 vertex : POSITION;
            float2 uv : TEXCOORD0;
        };

        struct Varyings
        {
            float4 vertex : SV_POSITION;
            float2 uv : TEXCOORD0;

            float4 position : TEXCOORD1;
        };

        sampler2D _MainTex;
        sampler2D _HistoryTex;

        sampler2D _CameraMotionVectorsTexture;
        sampler2D _CameraDepthTexture;

        float4 _MainTex_TexelSize;
        float4 _CameraDepthTexture_TexelSize;

        float2 _Jitter;

        Varyings vertex(Input input)
        {
            Varyings output;

            float4 v = mul(UNITY_MATRIX_MVP, input.vertex);

            output.vertex = v;
            output.uv = input.uv;
            output.position = v;

        #if UNITY_UV_STARTS_AT_TOP
            if (_MainTex_TexelSize.y < 0)
                output.uv.y = 1. - input.uv.y;
        #endif

            return output;
        }

        // Tonemapper from http://gpuopen.com/optimized-reversible-tonemapper-for-resolve/
        float getMaximumElement(in float3 value)
        {
            // AMD_shader_trinary_minmax
            return max(max(value.x, value.y), value.z);
        }

        float4 map(in float4 color)
        {
            return float4(color.rgb * rcp(getMaximumElement(color.rgb) + 1.), color.a);
        }

        float4 map(in float4 color, in float weight)
        {
            return float4(color.rgb * rcp(weight * getMaximumElement(color.rgb) + 1.), color.a);
        }

        float4 unmap(in float4 color)
        {
            return float4(color.rgb * rcp(1. - getMaximumElement(color.rgb)), color.a);
        }

        float2 getClosestFragment(in float2 uv)
        {
            const float2 k = TAA_DEPTH_SAMPLE_SPREAD * _CameraDepthTexture_TexelSize.xy;

            #if TAA_DEPTH_SAMPLE_PATTERN == 0
                const float4 neighborhood = float4(
                    tex2D(_CameraDepthTexture, uv - k).r,
                    tex2D(_CameraDepthTexture, uv + float2(k.x, -k.y)).r,
                    tex2D(_CameraDepthTexture, uv + float2(-k.x, k.y)).r,
                    tex2D(_CameraDepthTexture, uv + k).r);

                float3 result = float3(0., 0., tex2D(_CameraDepthTexture, uv).r);

                if (neighborhood.x < result.z)
                    result = float3(-1., -1., neighborhood.x);

                if (neighborhood.y < result.z)
                    result = float3(1., -1., neighborhood.y);

                if (neighborhood.z < result.z)
                    result = float3(-1., 1., neighborhood.z);

                if (neighborhood.w < result.z)
                    result = float3(1., 1., neighborhood.w);
            #else
                const float3x3 neighborhood = float3x3(
                    tex2D(_CameraDepthTexture, uv - k).r,
                    tex2D(_CameraDepthTexture, uv - float2(0., k.y)).r,
                    tex2D(_CameraDepthTexture, uv + float2(k.x, -k.y)).r,
                    tex2D(_CameraDepthTexture, uv - float2(k.x, 0.)).r,
                    tex2D(_CameraDepthTexture, uv).r,
                    tex2D(_CameraDepthTexture, uv + float2(k.x, 0.)).r,
                    tex2D(_CameraDepthTexture, uv + float2(-k.x, k.y)).r,
                    tex2D(_CameraDepthTexture, uv + float2(0., k.y)).r,
                    tex2D(_CameraDepthTexture, uv + k).r);

                float3 result = float3(-1., -1., neighborhood._m00);

                if (neighborhood._m01 < result.z)
                    result = float3(0., -1., neighborhood._m01);

                if (neighborhood._m02 < result.z)
                    result = float3(1., -1., neighborhood._m02);

                if (neighborhood._m10 < result.z)
                    result = float3(-1., 0., neighborhood._m10);

                if (neighborhood._m11 < result.z)
                    result = float3(0., 0., neighborhood._m11);

                if (neighborhood._m12 < result.z)
                    result = float3(1., 0., neighborhood._m12);

                if (neighborhood._m20 < result.z)
                    result = float3(-1., 1., neighborhood._m20);

                if (neighborhood._m21 < result.z)
                    result = float3(0., 1., neighborhood._m21);

                if (neighborhood._m22 < result.z)
                    result = float3(1., 1., neighborhood._m22);
            #endif

            return (uv + result.xy * k);
        }

        // Adapted from Playdead's TAA implementation
        // https://github.com/playdeadgames/temporal
        float4 clipToAABB(in float4 color, in float p, in float3 minimum, in float3 maximum)
        {
            // note: only clips towards aabb center (but fast!)
            float3 center = .5 * (maximum + minimum);
            float3 extents = .5 * (maximum - minimum);

            // This is actually `distance`, however the keyword is reserved
            float4 offset = color - float4(center, p);
            float3 repeat = abs(offset.xyz / extents);

            repeat.x = max(repeat.x, max(repeat.y, repeat.z));

            if (repeat.x > 1.)
            {
                // `color` is not intersecting (nor inside) the AABB; it's clipped to the closest extent
                return float4(center, p) + offset / repeat.x;
            }
            else
            {
                // `color` is intersecting (or inside) the AABB.

                // Note: for whatever reason moving this return statement from this else into a higher
                // scope makes the NVIDIA drivers go beyond bonkers
                return color;
            }
        }

        float4 fragment(Varyings input) : SV_Target
        {
        #if TAA_DILATE_MOTION_VECTOR_SAMPLE
            float2 motion = tex2D(_CameraMotionVectorsTexture, getClosestFragment(input.uv)).xy;
        #else
            float2 motion = tex2D(_CameraMotionVectorsTexture, input.uv).xy;
        #endif

        #if TAA_REMOVE_COLOR_SAMPLE_JITTER
            float2 uv = input.uv - _Jitter;
        #else
            float2 uv = input.uv;
        #endif

            float2 k = TAA_COLOR_NEIGHBORHOOD_SAMPLE_SPREAD * _MainTex_TexelSize.xy;

            float4 color = tex2D(_MainTex, uv);

        #if TAA_COLOR_NEIGHBORHOOD_SAMPLE_PATTERN == 0
            // Karris 13: a box filter is not stable under motion, use raw color instead of an averaged one
            float4x4 neighborhood = float4x4(
                tex2D(_MainTex, uv + float2(0., -k.y)),
                tex2D(_MainTex, uv + float2(-k.x, 0.)),
                tex2D(_MainTex, uv + float2(k.x, 0.)),
                tex2D(_MainTex, uv + float2(0., k.y)));

            #if TAA_CLIP_HISTORY_SAMPLE
                #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                    float4 average = map(neighborhood[0], .2) + map(neighborhood[1], .2) + map(neighborhood[2], .2) +
                        map(neighborhood[3], .2) + map(color, .2);
                #else
                    float4 average = (neighborhood[0] + neighborhood[1] + neighborhood[2] + neighborhood[3] + color) * .2;
                #endif
            #endif

            #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                neighborhood[0] = map(neighborhood[0]);
                neighborhood[1] = map(neighborhood[1]);
                neighborhood[2] = map(neighborhood[2]);
                neighborhood[3] = map(neighborhood[3]);

                color = map(color);
            #endif

            float4 minimum = min(min(min(min(neighborhood[0], neighborhood[1]), neighborhood[2]), neighborhood[3]), color);
            float4 maximum = max(max(max(max(neighborhood[0], neighborhood[1]), neighborhood[2]), neighborhood[3]), color);
        #else
            float3x4 top = float3x4(
                tex2D(_MainTex, uv + float2(-k.x, -k.y)),
                tex2D(_MainTex, uv + float2(0., -k.y)),
                tex2D(_MainTex, uv + float2(k.x, -k.y)));

            float2x4 middle = float2x4(
                tex2D(_MainTex, uv + float2(-k.x, 0.)),
                tex2D(_MainTex, uv + float2(k.x, 0.)));

            float3x4 bottom = float3x4(
                tex2D(_MainTex, uv + float2(-k.x, k.y)),
                tex2D(_MainTex, uv + float2(0., k.y)),
                tex2D(_MainTex, uv + float2(k.x, k.y)));

            #if TAA_CLIP_HISTORY_SAMPLE
                #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                    float4 average = map(top[0], .111111) + map(top[1], .111111) + map(top[2], .111111) +
                        map(middle[0], .111111) + map(color, .111111) + map(middle[1], .111111) +
                        map(bottom[0], .111111) + map(bottom[1], .111111) + map(bottom[2], .111111);
                #else
                    float4 average = (top[0] + top[1] + top[2] + middle[0] + middle[1] + bottom[0] + bottom[1] + bottom[2] + color) * .111111;
                #endif
            #endif

            #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                top[0] = map(top[0]);
                top[1] = map(top[1]);
                top[2] = map(top[2]);

                middle[0] = map(middle[0]);
                color = map(color);
                middle[1] = map(middle[1]);

                bottom[0] = map(bottom[0]);
                bottom[1] = map(bottom[1]);
                bottom[2] = map(bottom[2]);
            #endif

            float4 minimum = min(min(min(min(min(min(min(min(top[0], top[1]), top[2]), middle[0]), middle[1]), bottom[0]), bottom[1]), bottom[2]), color);
            float4 maximum = max(max(max(max(max(max(max(max(top[0], top[1]), top[2]), middle[0]), middle[1]), bottom[0]), bottom[1]), bottom[2]), color);
        #endif

            k = TAA_HISTORY_NEIGHBORHOOD_SAMPLE_SPREAD * _MainTex_TexelSize.xy;
            uv = input.uv - motion;

        #if TAA_HISTORY_SAMPLE_FILTER == 0
            float4 history = tex2D(_HistoryTex, uv);

            #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                history = map(history);
            #endif
        #elif TAA_HISTORY_SAMPLE_FILTER == 1
            #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                float4 history = map(tex2D(_HistoryTex, input.uv + float2(0., -k.y)), .2) +
                    map(tex2D(_HistoryTex, uv + float2(-k.x, 0.)), .2) +
                    map(tex2D(_HistoryTex, uv + float2(k.x, 0.)), .2) +
                    map(tex2D(_HistoryTex, uv + float2(0., k.y)), .2) +
                    map(tex2D(_HistoryTex, uv), .2);
            #else
                float4 history = (tex2D(_HistoryTex, input.uv + float2(0., -k.y)) +
                    tex2D(_HistoryTex, uv + float2(-k.x, 0.)) +
                    tex2D(_HistoryTex, uv + float2(k.x, 0.)) +
                    tex2D(_HistoryTex, uv + float2(0., k.y)) +
                    tex2D(_HistoryTex, uv)) * .2;
            #endif
        #else
            #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
                float4 history = map(tex2D(_HistoryTex, input.uv - motion + float2(0., 0.) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(k.x, 0.) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + k * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(0., k.y) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(-k.x, k.y) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(-k.x, 0.) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv - k * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(0., -k.y) * _MainTex_TexelSize.xy), .111111) +
                    map(tex2D(_HistoryTex, uv + float2(k.x, -k.y) * _MainTex_TexelSize.xy), .111111);
            #else
                float4 history = (tex2D(_HistoryTex, input.uv - motion + float2(0., 0.) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(k.x, 0.) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + k * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(0., k.y) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(-k.x, k.y) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(-k.x, 0.) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv - k * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(0., -k.y) * _MainTex_TexelSize.xy) +
                    tex2D(_HistoryTex, uv + float2(k.x, -k.y) * _MainTex_TexelSize.xy)) * .111111;
            #endif
        #endif

        #if TAA_CLIP_HISTORY_SAMPLE
            average = clamp(average, minimum, maximum);
            history = clipToAABB(history, average.w, minimum.xyz, maximum.xyz);
        #else
            history = clamp(history, minimum, maximum);
        #endif

        #if TAA_SHARPEN_OUTPUT
            float smudge = saturate(2. * (abs(_Jitter.x) + abs(_Jitter.y) + abs(motion.x) + abs(motion.y)));
            float sharpening = saturate(smudge * .5 + rcp(1. + 32. * (Luminance(maximum.rgb) - Luminance(minimum.rgb))));
        #endif

            float2 luma = float2(Luminance(color.rgb), Luminance(history.rgb));

        #if TAA_FINAL_BLEND_METHOD == 0
            // Constant blend factor, works most of the time & cheap; but isn't as nice as a derivative of Sousa 13
            color = lerp(color, history, TAA_FINAL_BLEND_FACTOR);
        #elif TAA_FINAL_BLEND_METHOD == 1
            // Implements the final blend method from Playdead's TAA implementation
            float weight = 1. - abs(luma.x - luma.y) / max(luma.x, max(luma.y, .2));
            color = lerp(color, history, lerp(.88, .97, weight * weight));
        #endif

        #if TAA_TONEMAP_COLOR_AND_HISTORY_SAMPLES
            return unmap(color);
        #else
            return color;
        #endif
        }
    ENDCG

    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM
            #pragma vertex vertex
            #pragma fragment fragment

            ENDCG
        }
    }
}
