// 반딧불 디졸브 (URP 17, HLSL)
// 물체가 반딧불 빛 같은 가장자리를 따라 사라짐, 떠오르는 반딧불은 짝 셰이더 FireflyParticle 이 그림
// 1. 디졸브: 월드 공간 3D 노이즈(+ 방향 쓸기)와 진행값을 비교해 픽셀을 잘라 냄 (clip)
// 2. 가장자리: 잘리기 직전 띠를 HDR 색으로 발광, 바깥(연두빛)은 띠 전체에 스며들고 안쪽(따뜻한 흰빛)은 얇은 선으로
// 3. 조명: 메인 라이트 램버트 + 그림자 + 환경광(SH) + 블린-퐁 하이라이트, 구멍 안쪽(뒷면)은 어둡게
// 4. 보조 패스: 그림자·깊이·노멀 패스도 같은 값으로 잘라 그림자에도 구멍이 뚫림
// 셰이더 갤러리 '디졸브'(노이즈 임계값, 가장자리 발광, 그림자 패스 자르기)를 바탕으로
// 가장자리 2단 발광, 뒷면 처리, 여러 메시가 하나의 무늬로 이어지는 월드 공간 노이즈를 더함

Shader "MyShaders/FireflyDissolve"
{
    Properties
    {
        [Header(Surface)]
        _BaseColor ("기본 색", Color) = (0.85, 0.87, 0.92, 1)
        _BaseMap ("기본 텍스처", 2D) = "white" {}
        _InnerColor ("구멍 안쪽(뒷면) 색", Color) = (0.05, 0.05, 0.08, 1)
        _Specular ("하이라이트 세기", Range(0, 1)) = 0.3
        _Smoothness ("하이라이트 날카로움", Range(1, 128)) = 32

        [Header(Dissolve)]
        _Progress ("진행값 (0 = 온전, 1 = 사라짐)", Range(0, 1)) = 0.35
        _NoiseScale ("노이즈 크기", Range(0.5, 20)) = 4
        _Sweep ("방향 쓸기 섞기", Range(0, 1)) = 0.35
        _SweepDir ("쓸기 방향 (월드)", Vector) = (0, -1, 0, 0)
        _SweepOrigin ("쓸기 기준점 (월드, 스크립트가 채움)", Vector) = (0, 0, 0, 0)
        _SweepRange ("쓸기 범위 (반지름)", Range(0.1, 5)) = 1

        [Header(Edge)]
        [HDR] _GlowColorInner ("가장자리 안쪽 색", Color) = (2.6, 2.3, 1.1, 1)
        [HDR] _GlowColorOuter ("가장자리 바깥 색", Color) = (0.9, 2.0, 0.25, 1)
        _EdgeWidth ("가장자리 폭", Range(0.005, 0.3)) = 0.05
    }

    SubShader
    {
        Tags { "RenderType" = "TransparentCutout" "Queue" = "AlphaTest" "RenderPipeline" = "UniversalPipeline" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        TEXTURE2D(_BaseMap);
        SAMPLER(sampler_BaseMap);

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseColor;
            float4 _BaseMap_ST;
            float4 _InnerColor;
            float _Specular;
            float _Smoothness;
            float _Progress;
            float _NoiseScale;
            float _Sweep;
            float4 _SweepDir;
            float4 _SweepOrigin;
            float _SweepRange;
            float4 _GlowColorInner;
            float4 _GlowColorOuter;
            float _EdgeWidth;
        CBUFFER_END

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS : NORMAL;
            float2 uv : TEXCOORD0;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float2 uv : TEXCOORD0;
            float3 positionWS : TEXCOORD1;
            float3 normalWS : TEXCOORD2;
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        Varyings vert(Attributes v)
        {
            Varyings o;
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_TRANSFER_INSTANCE_ID(v, o);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
            o.positionWS = TransformObjectToWorld(v.positionOS.xyz);
            o.positionCS = TransformWorldToHClip(o.positionWS);
            o.normalWS = TransformObjectToWorldNormal(v.normalOS);
            o.uv = TRANSFORM_TEX(v.uv, _BaseMap);
            return o;
        }

        // ---------- 해시 / 노이즈 ----------
        float hash13(float3 p)
        {
            p = frac(p * 0.1031);
            p += dot(p, p.zyx + 31.32);
            return frac((p.x + p.y) * p.z);
        }

        // 3D 값 노이즈: 격자 8 꼭짓점의 해시를 부드럽게 보간
        float valueNoise3(float3 p)
        {
            float3 i = floor(p);
            float3 f = frac(p);
            float3 u = f * f * (3.0 - 2.0 * f);
            float n000 = hash13(i);
            float n100 = hash13(i + float3(1, 0, 0));
            float n010 = hash13(i + float3(0, 1, 0));
            float n110 = hash13(i + float3(1, 1, 0));
            float n001 = hash13(i + float3(0, 0, 1));
            float n101 = hash13(i + float3(1, 0, 1));
            float n011 = hash13(i + float3(0, 1, 1));
            float n111 = hash13(i + float3(1, 1, 1));
            return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                        lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z);
        }

        float fbm3(float3 p)
        {
            return valueNoise3(p) * 0.6 + valueNoise3(p * 2.1 + 7.3) * 0.3 + valueNoise3(p * 4.3 + 1.7) * 0.1;
        }

        // ---------- 디졸브 값 ----------
        // 반환값 d = (이 지점의 노이즈) - (진행 임계값)
        //   d > 0           : 남아 있는 표면
        //   0 < d < 가장자리 : 빛나는 띠
        //   d < 0           : 이미 사라진 곳
        float DissolveValue(float3 positionWS)
        {
            // 쓸기 기준점에서 본 위치, 기준점을 오브젝트와 함께 두면 무늬가 물체에 붙음
            float3 local = positionWS - _SweepOrigin.xyz;

            // 값 노이즈는 0.5 근처에 몰려 있어 진행값 양 끝이 죽음 → 0~1 로 넓힘
            float n = saturate((fbm3(local * _NoiseScale) - 0.2) / 0.6);

            // 방향 쓸기: 쓸기 방향 쪽 끝(0)부터 반대쪽 끝(1)까지의 높이를 노이즈와 섞음
            float3 dir = normalize(_SweepDir.xyz + 1e-5);
            float h = saturate(dot(local, -dir) / (2.0 * _SweepRange) + 0.5);
            n = lerp(n, h, _Sweep);

            // 진행값 0 이면 가장자리 띠까지 전부 보이고, 1 이면 완전히 사라지도록 범위를 넓힘
            float threshold = lerp(-_EdgeWidth, 1.0, _Progress);
            return n - threshold;
        }
        ENDHLSL

        Pass
        {
            Name "Forward"
            Tags { "LightMode" = "UniversalForwardOnly" }
            // 구멍 너머로 안쪽 면이 보이도록 양면을 그림 (뒷면은 _InnerColor)
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog

            half4 frag(Varyings v, FRONT_FACE_TYPE isFront : FRONT_FACE_SEMANTIC) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);

                float d = DissolveValue(v.positionWS);

                // 이미 사라진 곳은 잘라 냄
                clip(d);

                // ---------- 남아 있는 표면: 조명 ----------
                bool front = IS_FRONT_VFACE(isFront, true, false);
                float3 normalWS = normalize(v.normalWS) * (front ? 1.0 : -1.0);
                float3 viewWS = GetWorldSpaceNormalizeViewDir(v.positionWS);

                Light light = GetMainLight(TransformWorldToShadowCoord(v.positionWS), v.positionWS, half4(1, 1, 1, 1));
                float3 lightColor = light.color * light.shadowAttenuation;
                float ndl = saturate(dot(normalWS, light.direction));
                float3 halfDir = normalize(light.direction + viewWS);
                float spec = pow(saturate(dot(normalWS, halfDir)), _Smoothness) * _Specular * ndl;

                float3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, v.uv).rgb * _BaseColor.rgb;
                albedo = front ? albedo : _InnerColor.rgb;
                float3 col = albedo * (lightColor * ndl + SampleSH(normalWS)) + lightColor * spec;

                // ---------- 가장자리 발광 ----------
                // e = 1 은 막 잘리기 직전(띠 안쪽 끝), 0 은 띠 바깥 끝
                float e = 1.0 - saturate(d / _EdgeWidth);
                // 바깥 색은 띠 전체에 서서히 스며들고, 안쪽 흰빛은 잘리기 직전의 얇은 선으로만
                col = lerp(col, _GlowColorOuter.rgb, smoothstep(0.0, 1.0, e) * smoothstep(0.0, 1.0, e));
                col += _GlowColorInner.rgb * smoothstep(0.8, 1.0, e);

                // 안개: 프래그먼트의 SV_POSITION.z 는 클립 공간 z 가 아니라서 월드 위치로 다시 계산
                col = MixFog(col, ComputeFogFactor(TransformWorldToHClip(v.positionWS).z));
                return half4(col, 1.0);
            }
            ENDHLSL
        }

        // 그림자에도 같은 구멍을 뚫음
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On
            ColorMask 0
            Cull Off

            HLSLPROGRAM
            #pragma vertex vertShadow
            #pragma fragment fragClip
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            float3 _LightDirection;
            float3 _LightPosition;

            Varyings vertShadow(Attributes v)
            {
                Varyings o = vert(v);
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDir = normalize(_LightPosition - o.positionWS);
                #else
                    float3 lightDir = _LightDirection;
                #endif
                float4 cs = TransformWorldToHClip(ApplyShadowBias(o.positionWS, o.normalWS, lightDir));
                o.positionCS = ApplyShadowClamping(cs);
                return o;
            }

            float4 fragClip(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                clip(DissolveValue(v.positionWS));
                return 0;
            }
            ENDHLSL
        }

        // 깊이 텍스처에도 구멍을 반영
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On
            ColorMask R
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment fragClip
            #pragma multi_compile_instancing

            float4 fragClip(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                clip(DissolveValue(v.positionWS));
                return v.positionCS.z;
            }
            ENDHLSL
        }

        // SSAO 처럼 노멀을 쓰는 기능용
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormalsOnly" }
            ZWrite On
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment fragNormals
            #pragma multi_compile_instancing
            #pragma multi_compile_fragment _ _GBUFFER_NORMALS_OCT
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RenderingLayers.hlsl"

            void fragNormals(Varyings v, out float4 outNormalWS : SV_Target0
            #ifdef _WRITE_RENDERING_LAYERS
                , out uint outRenderingLayers : SV_Target1
            #endif
            )
            {
                UNITY_SETUP_INSTANCE_ID(v);
                clip(DissolveValue(v.positionWS));
                float3 normalWS = normalize(v.normalWS);
                #if defined(_GBUFFER_NORMALS_OCT)
                    float2 octNormalWS = PackNormalOctQuadEncode(normalWS);
                    outNormalWS = float4(PackFloat2To888(saturate(octNormalWS * 0.5 + 0.5)), 0.0);
                #else
                    outNormalWS = float4(normalWS, 0.0);
                #endif
                #ifdef _WRITE_RENDERING_LAYERS
                    outRenderingLayers = EncodeMeshRenderingLayer();
                #endif
            }
            ENDHLSL
        }
    }
    Fallback Off
}
