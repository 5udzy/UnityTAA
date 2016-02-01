Shader "Hidden/Image Effects/Cinematic/Bloom"
{
    Properties
    {
        _MainTex("", 2D) = "" {}
        _BaseTex("", 2D) = "" {}
    }

    CGINCLUDE

    #include "UnityCG.cginc"

    #pragma multi_compile _ PREFILTER_MEDIAN
    #pragma multi_compile LINEAR_COLOR GAMMA_COLOR

    sampler2D _MainTex;
    sampler2D _BaseTex;

    float2 _MainTex_TexelSize;
    float2 _BaseTex_TexelSize;

    float _PrefilterOffs;
    half _Threshold;
    half _Cutoff;
    float _SampleScale;
    half _Intensity;

    half luma(half3 c)
    {
#if LINEAR_COLOR
        c = LinearToGammaSpace(c);
#endif
        // Rec.709 HDTV Standard
        return dot(c, half3(0.2126, 0.7152, 0.0722));
    }

    half3 median(half3 a, half3 b, half3 c)
    {
        return a + b + c - min(min(a, b), c) - max(max(a, b), c);
    }

    // On some GeForce card, we might get extraordinary high value.
    // This might be a bug in the graphics driver or Unity's deferred
    // lighting shader, but anyway we have to cut it off at the moment.
    half3 limit_hdr(half3 c) { return min(c, 65000); }
    half4 limit_hdr(half4 c) { return min(c, 65000); }

    struct v2f_multitex
    {
        float4 pos : SV_POSITION;
        float2 uv_main : TEXCOORD0;
        float2 uv_base : TEXCOORD1;
    };

    v2f_multitex vert_multitex(appdata_full v)
    {
        v2f_multitex o;
        o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
        o.uv_main = v.texcoord.xy;
        o.uv_base = v.texcoord.xy;
#if UNITY_UV_STARTS_AT_TOP
        if (_BaseTex_TexelSize.y < 0.0)
            o.uv_base.y = 1.0 - o.uv_base.y;
#endif
        return o;
    }

    half4 frag_prefilter(v2f_img i) : SV_Target
    {
        float2 uv = i.uv + _MainTex_TexelSize.xy * _PrefilterOffs;
#if PREFILTER_MEDIAN
        float3 d = _MainTex_TexelSize.xyx * float3(1, 1, 0);

        half4 s0 = limit_hdr(tex2D(_MainTex, uv));
        half3 s1 = limit_hdr(tex2D(_MainTex, uv - d.xz).rgb);
        half3 s2 = limit_hdr(tex2D(_MainTex, uv + d.xz).rgb);
        half3 s3 = limit_hdr(tex2D(_MainTex, uv - d.zy).rgb);
        half3 s4 = limit_hdr(tex2D(_MainTex, uv + d.zy).rgb);

        half3 m = median(median(s0.rgb, s1, s2), s3, s4);
#else
        half4 s0 = limit_hdr(tex2D(_MainTex, uv));
        half3 m = s0.rgb;
#endif
        half lm = luma(m);
#if GAMMA_COLOR
        m = GammaToLinearSpace(m);
#endif
        m *= saturate((lm - _Threshold) / _Cutoff);

        return half4(m, s0.a);
    }

    half4 frag_box_reduce(v2f_img i) : SV_Target
    {
        float4 d = _MainTex_TexelSize.xyxy * float4(-1, -1, +1, +1);

        half3 s;
        s  = tex2D(_MainTex, i.uv + d.xy).rgb;
        s += tex2D(_MainTex, i.uv + d.zy).rgb;
        s += tex2D(_MainTex, i.uv + d.xw).rgb;
        s += tex2D(_MainTex, i.uv + d.zw).rgb;

        return half4(s * 0.25, 0);
    }

    half4 frag_tent_expand(v2f_multitex i) : SV_Target
    {
        float4 d = _MainTex_TexelSize.xyxy * float4(1, 1, -1, 0) * _SampleScale;

        half4 base = tex2D(_BaseTex, i.uv_base);

        half3 s;
        s  = tex2D(_MainTex, i.uv_main - d.xy).rgb;
        s += tex2D(_MainTex, i.uv_main - d.wy).rgb * 2;
        s += tex2D(_MainTex, i.uv_main - d.zy).rgb;

        s += tex2D(_MainTex, i.uv_main + d.zw).rgb * 2;
        s += tex2D(_MainTex, i.uv_main       ).rgb * 4;
        s += tex2D(_MainTex, i.uv_main + d.xw).rgb * 2;

        s += tex2D(_MainTex, i.uv_main + d.zy).rgb;
        s += tex2D(_MainTex, i.uv_main + d.wy).rgb * 2;
        s += tex2D(_MainTex, i.uv_main + d.xy).rgb;

        return half4(base.rgb + s * (1.0 / 16), base.a);
    }

    half4 frag_combine(v2f_multitex i) : SV_Target
    {
        half4 base = tex2D(_BaseTex, i.uv_base);
        half3 blur = tex2D(_MainTex, i.uv_main).rgb;
#if GAMMA_COLOR
        base.rgb = GammaToLinearSpace(base.rgb);
#endif
        half3 cout = base.rgb + blur * _Intensity;
#if GAMMA_COLOR
        cout = LinearToGammaSpace(cout);
#endif
        return half4(cout, base.a);
    }

    ENDCG
    SubShader
    {
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_prefilter
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_box_reduce
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_multitex
            #pragma fragment frag_tent_expand
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_multitex
            #pragma fragment frag_combine
            #pragma target 3.0
            ENDCG
        }
    }
}
