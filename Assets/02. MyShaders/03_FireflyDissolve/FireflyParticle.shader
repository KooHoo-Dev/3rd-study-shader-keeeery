// 반딧불 파티클 (URP 17, HLSL, Particle System 용)
// 파티클 한 장(카메라를 향한 사각형)에 반딧불 빛 하나를 그림
// 1. 빛 모양: 가운데 작고 밝은 핵 + 넓고 옅게 퍼지는 후광 (가우시안 두 개)
// 2. 깜빡임: 파티클마다 다른 박자로 숨 쉬듯 밝아졌다 어두워짐
//    - 파티클별 난수는 Particle System 의 Custom Vertex Streams 로 받은 StableRandom.x (TEXCOORD0.z)
//    - sin 을 pow 로 날카롭게 해서 '대부분 은은하다가 가끔 반짝' 하는 반딧불 리듬을 만듦
// 3. 정점 색: Start Color, Color over Lifetime 이 색과 알파로 들어와 생겨날 때·사라질 때 서서히 나타나고 꺼짐
// 4. 더하기 혼합: 겹친 빛끼리 밝아지고, 그리는 순서와 상관없이 결과가 같음

Shader "MyShaders/FireflyParticle"
{
    Properties
    {
        [HDR] _CoreColor ("핵 색", Color) = (2.2, 2.4, 1.2, 1)
        [HDR] _GlowColor ("후광 색", Color) = (0.6, 1.3, 0.15, 1)
        _CoreSize ("핵 크기", Range(0.02, 0.5)) = 0.12
        _GlowSize ("후광 크기", Range(0.1, 1)) = 0.45
        _FlickerSpeed ("깜빡임 속도", Range(0, 10)) = 2.5
        _FlickerSharpness ("깜빡임 날카로움", Range(1, 8)) = 3
        _MinBrightness ("가장 어두울 때 밝기", Range(0, 1)) = 0.15
    }

    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "RenderPipeline" = "UniversalPipeline" "IgnoreProjector" = "True" "PreviewType" = "Plane" }

        Pass
        {
            Name "Forward"
            Tags { "LightMode" = "UniversalForward" }

            Blend One One
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _CoreColor;
                float4 _GlowColor;
                float _CoreSize;
                float _GlowSize;
                float _FlickerSpeed;
                float _FlickerSharpness;
                float _MinBrightness;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float4 color : COLOR;
                // xy = 파티클 UV, z = StableRandom.x (Custom Vertex Streams 에서 UV 다음에 넣음)
                float3 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float4 color : COLOR;
                float3 uv : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                // 파티클 정점은 이미 월드 공간으로 들어옴 (Particle System 이 빌보드를 계산해 둠)
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.color = v.color;
                o.uv = v.uv;
                return o;
            }

            half4 frag(Varyings i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 사각형 중심 0, 가장자리 1
                float2 c = (i.uv.xy - 0.5) * 2.0;
                float r2 = dot(c, c);

                // 1. 핵 + 후광, 후광은 사각형 가장자리(r = 1)에서 0 이 되도록 한 번 더 깎음
                float core = exp(-r2 / (_CoreSize * _CoreSize));
                float glow = exp(-r2 / (_GlowSize * _GlowSize)) * saturate(1.0 - r2);

                // 2. 깜빡임: 파티클마다 속도(0.6~1.4배)와 위상이 다름
                float rnd = i.uv.z;
                float wave = 0.5 + 0.5 * sin(_Time.y * _FlickerSpeed * (0.6 + 0.8 * rnd) + rnd * 6.2832 * 7.0);
                float flicker = lerp(_MinBrightness, 1.0, pow(wave, _FlickerSharpness));

                // 3. 정점 색: 색과 알파(생겨나기·사라지기 페이드)를 곱함
                float3 col = (_CoreColor.rgb * core + _GlowColor.rgb * glow) * flicker;
                col *= i.color.rgb * i.color.a;

                // 4. 더하기 혼합이라 알파 대신 색 자체가 빛의 양
                return half4(col, 1.0);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
