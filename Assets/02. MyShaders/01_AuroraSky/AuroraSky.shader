// 오로라 밤하늘 스카이박스 (URP 17, HLSL)
// 1. 하늘 그라데이션: 시선 방향의 높이(dir.y)로 지평선색 → 천정색
// 2. 별: 방향 벡터를 3D 격자로 나눠 칸마다 해시로 별 1개를 두고, 시간으로 반짝임
// 3. 오로라: 하늘 위 여러 높이의 가상 평면에 시선을 쏴서(레이마칭) 노이즈 띠를 누적
//    노이즈는 두 층을 서로 다른 화면 속도로 흘려 곱한다 (셰이더 갤러리 '노이즈 불꽃' 응용)
// 4. 언덕: 방위각(원 위의 점)마다 노이즈로 능선 높이를 정하고, 시선 높이가 그보다 낮으면 실루엣으로 칠함
//    먼 능선(옅은 남색) 위에 가까운 능선(검정)을 겹쳐 깊이감을 줌

Shader "MyShaders/AuroraSky"
{
    Properties
    {
        [Header(Sky)]
        _ZenithColor ("천정 색", Color) = (0.01, 0.015, 0.05, 1)
        _HorizonColor ("지평선 색", Color) = (0.05, 0.09, 0.18, 1)
        _GroundColor ("땅 색", Color) = (0.01, 0.01, 0.015, 1)
        _HorizonSharpness ("지평선 그라데이션 폭", Range(0.5, 8)) = 2.5

        [Header(Stars)]
        _StarDensity ("별 밀도", Range(10, 200)) = 80
        _StarSize ("별 크기", Range(0.01, 0.3)) = 0.12
        _StarBrightness ("별 밝기 (HDR)", Range(0, 5)) = 2
        _StarCoverage ("별이 있을 확률", Range(0, 1)) = 0.35
        _TwinkleSpeed ("반짝임 속도", Range(0, 10)) = 3

        [Header(Hills)]
        _HillColorFar ("먼 언덕 색", Color) = (0.02, 0.03, 0.06, 1)
        _HillColorNear ("가까운 언덕 색", Color) = (0.0, 0.0, 0.005, 1)
        _HillHeight ("언덕 높이", Range(0, 0.3)) = 0.07
        _HillScale ("언덕 굴곡 수", Range(1, 30)) = 8
        _HillRoughness ("언덕 거칠기", Range(0, 1)) = 0.35

        [Header(Aurora)]
        [HDR] _AuroraColorLow ("오로라 아래쪽 색", Color) = (0.1, 1.2, 0.5, 1)
        [HDR] _AuroraColorHigh ("오로라 위쪽 색", Color) = (0.6, 0.15, 1.0, 1)
        _AuroraIntensity ("오로라 세기", Range(0, 4)) = 1.2
        _AuroraSpeed ("오로라 흐름 속도", Range(0, 2)) = 0.3
        _AuroraScale ("오로라 무늬 크기", Range(0.1, 3)) = 0.8
        _AuroraHeight ("오로라 커튼 높이", Range(0.05, 1)) = 0.35
        _AuroraBandWidth ("오로라 띠 두께", Range(0.01, 0.3)) = 0.07
        _AuroraSharpness ("오로라 띠 선명도", Range(1, 8)) = 2.5
        _AuroraCoverage ("오로라 덮는 정도", Range(0, 1)) = 0.45
        _AuroraWarp ("오로라 휘어짐", Range(0, 3)) = 1.2
        [IntRange] _AuroraSteps ("오로라 레이마칭 단계 수", Range(8, 128)) = 48
        _AuroraDither ("디더 세기 (권장 1)", Range(0, 1)) = 1
    }

    SubShader
    {
        Tags { "Queue" = "Background" "RenderType" = "Background" "PreviewType" = "Skybox" "RenderPipeline" = "UniversalPipeline" }
        Cull Off
        ZWrite Off

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _ZenithColor;
                float4 _HorizonColor;
                float4 _GroundColor;
                float _HorizonSharpness;
                float _StarDensity;
                float _StarSize;
                float _StarBrightness;
                float _StarCoverage;
                float _TwinkleSpeed;
                float4 _HillColorFar;
                float4 _HillColorNear;
                float _HillHeight;
                float _HillScale;
                float _HillRoughness;
                float4 _AuroraColorLow;
                float4 _AuroraColorHigh;
                float _AuroraIntensity;
                float _AuroraSpeed;
                float _AuroraScale;
                float _AuroraHeight;
                float _AuroraBandWidth;
                float _AuroraSharpness;
                float _AuroraCoverage;
                float _AuroraWarp;
                float _AuroraSteps;
                float _AuroraDither;
            CBUFFER_END


            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 dirOS : TEXCOORD0;   // 스카이박스 메시는 카메라를 감싸므로, 정점 위치 = 하늘 방향
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.dirOS = v.positionOS.xyz;
                return o;
            }

            // ---------- 해시 / 노이즈 ----------
            float hash13(float3 p)
            {
                p = frac(p * 0.1031);
                p += dot(p, p.zyx + 31.32);
                return frac((p.x + p.y) * p.z);
            }

            float3 hash33(float3 p)
            {
                p = frac(p * float3(0.1031, 0.1030, 0.0973));
                p += dot(p, p.yxz + 33.33);
                return frac((p.xxy + p.yxx) * p.zyx);
            }

            float hash12(float2 p)
            {
                float3 p3 = frac(float3(p.xyx) * 0.1031);
                p3 += dot(p3, p3.yzx + 33.33);
                return frac((p3.x + p3.y) * p3.z);
            }

            // 4x4 Bayer 행렬 디더: 4x4 픽셀 안에 0~15/16 의 오프셋을 고르게 한 번씩 배치
            // 무작위 해시(백색 노이즈)는 이웃 픽셀끼리 값이 뭉쳐 입자가 보이지만,
            // Bayer 는 아주 작은 칸 안에서 오프셋이 고르게 퍼져 있어 눈에는 매끈하게 섞여 보임
            static const float kBayer4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

            float bayer4(float2 pixel)
            {
                uint2 p = (uint2)pixel & 3u;
                return (kBayer4[p.y * 4 + p.x] + 0.5) / 16.0;
            }

            // 2D 값 노이즈 (텍스처 없이 절차적으로)
            float valueNoise(float2 p)
            {
                float2 i = floor(p);
                float2 f = frac(p);
                float2 u = f * f * (3.0 - 2.0 * f);
                float a = hash12(i);
                float b = hash12(i + float2(1, 0));
                float c = hash12(i + float2(0, 1));
                float d = hash12(i + float2(1, 1));
                return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
            }

            // 프랙탈 노이즈: 옥타브마다 2배 촘촘, 절반 세기
            float fbm(float2 p)
            {
                float sum = 0.0;
                float amp = 0.5;
                [unroll] for (int k = 0; k < 4; k++)
                {
                    sum += valueNoise(p) * amp;
                    p = p * 2.03 + float2(17.1, 9.2);
                    amp *= 0.5;
                }
                return sum;
            }

            // ---------- 별 ----------
            float3 Stars(float3 dir, float time)
            {
                float3 p = dir * _StarDensity;
                float3 cell = floor(p);
                float3 local = frac(p);

                float rnd = hash13(cell);
                if (rnd > _StarCoverage) return 0; // 일부 칸에만 별

                float3 starPos = 0.25 + 0.5 * hash33(cell); // 칸 안의 별 위치 (가장자리 잘림 방지)
                float d = length(local - starPos);
                float core = smoothstep(_StarSize, 0.0, d);

                // 별마다 다른 위상·속도로 반짝임
                float twinkle = 0.6 + 0.4 * sin(time * _TwinkleSpeed * (0.5 + rnd) + rnd * 62.8);

                // 별 색: 해시로 푸른빛 ~ 노란빛
                float3 tint = lerp(float3(0.75, 0.85, 1.0), float3(1.0, 0.9, 0.7), hash13(cell + 7.0));
                return tint * core * twinkle * _StarBrightness;
            }

            // ---------- 오로라 ----------
            // 오로라 전용 2옥타브 fbm. 4옥타브의 잔 디테일은 레이마칭 한 단계 간격보다 촘촘해서
            // 단계마다 다른 무늬가 찍히고, 그것이 가로 물결 줄무늬가 되어서 큰 무늬만 남김
            // (4옥타브 fbm 과 평균·최댓값이 같도록 1.25 를 곱해 정규화)
            float fbmAurora(float2 p)
            {
                float n = valueNoise(p) * 0.5;
                n += valueNoise(p * 2.03 + float2(17.1, 9.2)) * 0.25;
                return n * 1.25;
            }

            // 한 지점(가상 평면 위 좌표)의 오로라 노이즈 두 개를 계산
            //   n1: 띠 모양을 정하는 노이즈 (0.5 등고선이 띠의 중심)
            //   gate: 띠의 일부만 남기는 마스크
            void AuroraFields(float2 p, float time, out float n1, out float gate)
            {
                float t = time * _AuroraSpeed;

                // 큰 노이즈로 좌표를 휘게 해서 커튼이 구불구불 접히게 함 (도메인 워핑)
                float2 warp = float2(fbmAurora(p * 0.35 + float2(t * 0.15, 0.0)),
                                     fbmAurora(p * 0.35 + float2(3.7, -t * 0.1))) - 0.5;
                p += warp * _AuroraWarp;

                // 두 층을 서로 다른 화면 속도로 흘림 → 무늬가 통째로 미끄러지지 않고 계속 변화
                // 화면 속도 = 오프셋 속도 / 반복 횟수 : 1층 0.4/1 = 0.4, 2층 1.6/2 = 0.8
                n1 = fbmAurora(p + float2(t * 0.4, 0.0));
                float n2 = fbmAurora(p * 2.0 + float2(-t * 1.6, t * 0.3));

                // 2층 노이즈로 띠의 일부만 남겨 끊기고 뭉치게 함 (덮는 정도가 작을수록 듬성듬성)
                gate = smoothstep(1.0 - _AuroraCoverage, 1.0 - _AuroraCoverage + 0.25, n2 + 0.15);
            }

            // 리지 모양 r(u) = (1 - |u|)^k  (u = (n - 0.5) / 띠두께, |u| < 1 에서만 0 이 아님)
            // 의 누적 적분 C(u) = ∫[-1, u] r(s) ds
            float RidgeCdf(float u, float k)
            {
                u = clamp(u, -1.0, 1.0);
                float inv = 1.0 / (k + 1.0);
                return (u <= 0.0) ? pow(1.0 + u, k + 1.0) * inv
                                  : (2.0 - pow(1.0 - u, k + 1.0)) * inv;
            }

            // 사전 적분(pre-integration):
            // 한 단계 구간에서 노이즈가 a → b 로 직선으로 변한다고 보고, 그 구간 전체의 리지 평균을 정확히 구함
            // 점 하나만 찍으면 가는 띠를 '맞히거나 놓치거나' 둘 중 하나라 단계마다 줄무늬가 생기지만,
            // 구간 평균을 쓰면 띠가 단계 사이에 걸쳐 있어도 그만큼의 빛이 빠짐없이 더해짐
            float RidgeAverage(float a, float b)
            {
                float k = _AuroraSharpness;
                float ua = (a - 0.5) / _AuroraBandWidth;
                float ub = (b - 0.5) / _AuroraBandWidth;
                float du = ub - ua;
                if (abs(du) < 1e-4)
                    return pow(saturate(1.0 - abs((ua + ub) * 0.5)), k);
                return (RidgeCdf(ub, k) - RidgeCdf(ua, k)) / du;
            }

            // 높이 비율 fi (0 = 커튼 아래, 1 = 커튼 위) 의 수평 평면에서 노이즈를 읽음
            void AuroraSample(float3 dir, float fi, float time, out float n1, out float gate)
            {
                // 높이 (1 + fi*H) 인 수평 평면과 시선의 교점 → 평면 위 2D 좌표
                float planeH = 1.0 + fi * _AuroraHeight * 4.0;
                float2 p = dir.xz * (planeH / (dir.y + 0.08)) * _AuroraScale;
                AuroraFields(p, time, n1, gate);
            }

            float3 Aurora(float3 dir, float time, float2 screenPos)
            {
                if (dir.y <= 0.0) return 0;

                float3 col = 0;
                // 픽셀마다 시작 높이를 조금씩 어긋나게 해, 남은 계단 무늬를 고르게 흩뜨린다 (4x4 Bayer 디더)
                float stepJitter = bayer4(screenPos) * _AuroraDither;
                int steps = (int)_AuroraSteps;

                // 구간 [i, i+1] 의 양 끝 값을 쓰므로, 시작점을 먼저 구해 두고 다음 단계로 넘겨 재사용
                float nPrev, gPrev;
                AuroraSample(dir, stepJitter / steps, time, nPrev, gPrev);

                [loop] for (int i = 0; i < steps; i++)
                {
                    float nNext, gNext;
                    AuroraSample(dir, (i + 1 + stepJitter) / steps, time, nNext, gNext);

                    float band = RidgeAverage(nPrev, nNext) * (gPrev + gNext) * 0.5;

                    // 위로 갈수록 옅어지고, 맨 아래도 살짝 페이드인 (커튼 아랫단이 칼같이 끊기지 않게)
                    float fi = saturate((i + 0.5 + stepJitter) / steps);   // 구간 가운데 높이
                    float fade = pow(1.0 - fi, 1.5) * smoothstep(0.0, 0.12, fi);
                    float3 c = lerp(_AuroraColorLow.rgb, _AuroraColorHigh.rgb, smoothstep(0.05, 0.6, fi));
                    col += c * band * fade;

                    nPrev = nNext;
                    gPrev = gNext;
                }
                col /= steps;

                // 지평선 근처는 대기에 묻혀 사라짐
                float horizonFade = smoothstep(0.0, 0.25, dir.y);
                return col * horizonFade * _AuroraIntensity * 3.0;
            }

            // ---------- 언덕 실루엣 ----------
            // 수평 방향(방위각)마다 언덕 높이를 노이즈로 정하고, 시선 높이(dir.y)가 그보다 낮으면 언덕으로 칠함
            // 방위각을 각도 대신 원 위의 점(xz 정규화)으로 노이즈에 넣어서 360도 한 바퀴의 이음매가 생기지 않음
            float HillMask(float3 dir, float scale, float seed, float heightMul)
            {
                float2 ring = normalize(dir.xz + 1e-5) * scale + seed;
                float broad = valueNoise(ring * 0.5);                 // 큰 산줄기
                float detail = fbm(ring * 2.0) - 0.5;                 // 잔 굴곡
                float h = _HillHeight * heightMul * (0.25 + broad + detail * _HillRoughness * 2.0);

                // 경계 안티앨리어싱: 픽셀 한 칸 크기만큼만 부드럽게
                float aa = fwidth(dir.y) * 1.5;
                return 1.0 - smoothstep(h - aa, h + aa, dir.y);
            }

            half4 frag(Varyings i) : SV_Target
            {
                float3 dir = normalize(i.dirOS);
                float time = _Time.y;

                // 1. 하늘 그라데이션
                float up = saturate(dir.y);
                float3 sky = lerp(_HorizonColor.rgb, _ZenithColor.rgb, pow(up, 1.0 / _HorizonSharpness));
                float down = saturate(-dir.y * 8.0);
                sky = lerp(sky, _GroundColor.rgb, down);

                // 2. 별 (지평선 근처는 옅게)
                float3 stars = Stars(dir, time) * smoothstep(0.0, 0.15, dir.y);

                // 3. 오로라 (오로라가 밝은 곳은 별이 가려진다)
                float3 aurora = Aurora(dir, time, i.positionCS.xy);
                float auroraLum = saturate(dot(aurora, float3(0.3, 0.6, 0.1)));
                stars *= 1.0 - auroraLum;

                float3 col = sky + stars + aurora;

                // 4. 언덕: 먼 능선(옅은 남색, 더 높고 완만) 위에 가까운 능선(검정, 낮고 거침)을 덮는다
                float far = HillMask(dir, _HillScale, 11.0, 1.0);
                col = lerp(col, _HillColorFar.rgb, far);
                float nearHill = HillMask(dir, _HillScale * 1.7, 37.0, 0.6);
                col = lerp(col, _HillColorNear.rgb, nearHill);

                return half4(col, 1.0);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
