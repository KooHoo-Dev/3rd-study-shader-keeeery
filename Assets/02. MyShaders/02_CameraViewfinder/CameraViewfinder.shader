// 카메라 뷰파인더 전체 화면 효과 (URP 17, HLSL, Full Screen Pass Renderer Feature 용)
// 카메라가 그린 화면(_BlitTexture)을 다시 읽어, 캠코더 뷰파인더처럼 보이게 함
// 1. 줌 + 배럴 왜곡: 화면 중심 기준으로 UV 를 당겨 확대, 가장자리일수록 더 휘게
// 2. 색수차: R, G, B 를 서로 다른 배율로 읽어 가장자리에 색 번짐
// 3. 비네트: 화면 중심에서 멀수록 어둡게
// 4. 오버레이: 모서리 브래킷, 십자선, 깜빡이는 REC 점, 배터리, 줌 표시 바를 SDF(거리장)로 그림
// 5. 전환: 전역 변수 _ViewfinderAmount (0 = 꺼짐, 1 = 켜짐) 로 모든 효과를 함께 보간
//    ViewfinderToggle.cs 가 스페이스바에 맞춰 이 값을 부드럽게 올리고 내림
// 6. 평소 비네트: 뷰파인더가 꺼져 있을 때만 화면 가장자리를 살짝 어둡게 (켜지면 3번 비네트로 넘어감)

Shader "MyShaders/CameraViewfinder"
{
    Properties
    {
        [Header(Lens)]
        _Zoom ("기본 줌 배율 (스크립트 없을 때)", Range(1, 4)) = 1.35
        _Distortion ("배럴 왜곡", Range(0, 1)) = 0.25
        _ChromaticAberration ("색수차", Range(0, 0.05)) = 0.012

        [Header(Vignette)]
        _VignetteStrength ("비네트 세기", Range(0, 1)) = 0.75
        _VignetteRadius ("비네트 시작 반지름", Range(0.2, 1.2)) = 0.55
        _VignetteSoftness ("비네트 부드러움", Range(0.05, 1)) = 0.45

        [Header(Idle Vignette)]
        _IdleVignetteStrength ("평소 비네트 세기 (뷰파인더 꺼짐)", Range(0, 1)) = 0.55
        _IdleVignetteRadius ("평소 비네트 시작 반지름", Range(0, 1.2)) = 0.35
        _IdleVignetteSoftness ("평소 비네트 부드러움", Range(0.05, 1.5)) = 0.75

        [Header(Overlay)]
        _OverlayColor ("오버레이 색", Color) = (1, 1, 1, 0.85)
        _LineWidthPx ("선 두께 (픽셀)", Range(0.5, 6)) = 1.5
        _Margin ("브래킷 여백", Range(0.02, 0.2)) = 0.07
        _BracketLength ("브래킷 길이", Range(0.02, 0.3)) = 0.09
        _CrosshairSize ("십자선 크기", Range(0, 0.1)) = 0.03
        _RecColor ("REC 점 색", Color) = (1, 0.15, 0.1, 1)
        _BlinkSpeed ("REC 깜빡임 속도", Range(0, 4)) = 1
        _Battery ("배터리 잔량", Range(0, 1)) = 0.7
        _ZoomBarWidth ("줌 표시 바 길이", Range(0.05, 0.5)) = 0.18
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        ZWrite Off
        ZTest Always
        Cull Off

        Pass
        {
            Name "CameraViewfinder"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            // 전체 화면 삼각형 정점 셰이더(Vert)와 _BlitTexture(카메라 화면 색) 선언
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float _Zoom;
                float _Distortion;
                float _ChromaticAberration;
                float _VignetteStrength;
                float _VignetteRadius;
                float _VignetteSoftness;
                float _IdleVignetteStrength;
                float _IdleVignetteRadius;
                float _IdleVignetteSoftness;
                float4 _OverlayColor;
                float _LineWidthPx;
                float _Margin;
                float _BracketLength;
                float _CrosshairSize;
                float4 _RecColor;
                float _BlinkSpeed;
                float _Battery;
                float _ZoomBarWidth;
            CBUFFER_END

            // 머티리얼이 아니라 스크립트가 Shader.SetGlobalFloat 로 넣는 전역 값
            // Properties 와 CBUFFER 에 넣지 않아야 전역 값이 그대로 들어옴
            float _ViewfinderAmount;
            float _ViewfinderIdle;     // ViewfinderToggle 이 켜져 있으면 1. 스크립트가 없는 씬(셰이더볼 테스트 씬 등)에서는 평소 비네트도 끈다
            float _ViewfinderZoom; // 현재 줌 배율 (0 이면 스크립트가 없는 것으로 보고 머티리얼의 _Zoom 사용)
            float _ViewfinderZoom01; // 줌 표시 바 위치 (0 = 최소 줌, 1 = 최대 줌)
            float _ViewfinderZoomUI; // 줌 표시 바 보이는 정도 (휠을 굴리면 1, 잠시 뒤 0 으로 사라짐)

            // ---------- 유틸 ----------
            // 선분 a-b 까지의 거리 (SDF)
            float sdSegment(float2 p, float2 a, float2 b)
            {
                float2 pa = p - a, ba = b - a;
                float h = saturate(dot(pa, ba) / dot(ba, ba));
                return length(pa - ba * h);
            }

            // 중심 0, 반 크기 b 인 사각형까지의 거리 (SDF, 안쪽은 음수)
            float sdBox(float2 p, float2 b)
            {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            // 글자 'W' 까지의 거리: 꺾은선 4개 (p 는 글자 중심 기준, s 는 글자 높이)
            float sdLetterW(float2 p, float s)
            {
                float2 a = float2(-0.45,  0.5) * s;
                float2 b = float2(-0.22, -0.5) * s;
                float2 c = float2( 0.0,   0.2) * s;
                float2 d = float2( 0.22, -0.5) * s;
                float2 e = float2( 0.45,  0.5) * s;
                return min(min(sdSegment(p, a, b), sdSegment(p, b, c)),
                           min(sdSegment(p, c, d), sdSegment(p, d, e)));
            }

            // 글자 'T' 까지의 거리: 가로 막대 + 세로 기둥
            float sdLetterT(float2 p, float s)
            {
                return min(sdSegment(p, float2(-0.4, 0.5) * s, float2(0.4, 0.5) * s),
                           sdSegment(p, float2( 0.0, 0.5) * s, float2(0.0, -0.5) * s));
            }

            // 거리 d 를 두께 w 의 선으로 변환 (경계를 픽셀 한 칸 폭(aa)만큼만 부드럽게)
            // 경계 폭을 ±aa 로 잡으면 가는 선이 2픽셀 넘게 번져 굵어 보여서 ±0.5aa 로 둔다
            float strokeMask(float d, float w, float aa)
            {
                return 1.0 - smoothstep(w - aa * 0.5, w + aa * 0.5, d);
            }

            float fillMask(float d, float aa)
            {
                return 1.0 - smoothstep(-aa, aa, d);
            }

            // ---------- 렌즈 ----------
            // 화면 중심 기준으로 UV 를 당겨 확대, r2: 중심에서의 거리 제곱 (화면 비율 보정됨)
            float2 LensUV(float2 uv, float r2, float zoom, float extra)
            {
                float mag = zoom * (1.0 + _Distortion * _ViewfinderAmount * r2) * (1.0 + extra);
                return 0.5 + (uv - 0.5) / mag;
            }

            // ---------- 오버레이 ----------
            // p: 화면 중심 0, 세로 -0.5~0.5, 가로는 화면 비율만큼 (정사각형 단위)
            // 반환: rgb = 오버레이 색, a = 덮는 정도
            float4 Overlay(float2 p, float aspect, float aa, float a)
            {
                // 선 두께를 화면 높이 비율이 아니라 '픽셀'로 정한다 → 해상도가 바뀌어도 늘 같은 굵기.
                // aa = 픽셀 한 칸의 크기, strokeMask 의 w 는 중심선에서 한쪽까지의 거리라 절반을 쓴다
                float lw = _LineWidthPx * 0.5 * aa;

                // 켜질 때 브래킷이 바깥에서 안으로 모여드는 연출
                float spread = lerp(1.12, 1.0, a);
                float2 B = (float2(0.5 * aspect, 0.5) - _Margin) * spread;   // 브래킷 모서리 위치

                float lines = 0.0;

                // 1. 모서리 브래킷: abs(p) 로 네 모서리를 한 번에 그림 (좌우·상하 대칭)
                float2 q = abs(p);
                float dH = sdSegment(q, float2(B.x - _BracketLength, B.y), B);
                float dV = sdSegment(q, float2(B.x, B.y - _BracketLength), B);
                lines = max(lines, strokeMask(min(dH, dV), lw, aa));

                // 2. 십자선: 가운데 작은 틈을 두고 네 방향 짧은 선
                float gap = _CrosshairSize * 0.35;
                float dC = min(sdSegment(q, float2(gap, 0), float2(_CrosshairSize, 0)),
                               sdSegment(q, float2(0, gap), float2(0, _CrosshairSize)));
                lines = max(lines, strokeMask(dC, lw, aa));

                // 3. 배터리 (오른쪽 위): 테두리 + 단자 + 잔량만큼 채움
                float2 batC = float2(B.x - 0.07, B.y - 0.045);
                float2 batHalf = float2(0.035, 0.014);
                float2 bp = p - batC;
                float dBody = abs(sdBox(bp, batHalf));
                float dTip = sdBox(bp - float2(batHalf.x + 0.005, 0), float2(0.004, 0.006));
                lines = max(lines, strokeMask(dBody, lw, aa));
                lines = max(lines, fillMask(dTip, aa));
                float fillW = (batHalf.x - 0.006) * _Battery;
                float dFill = sdBox(bp - float2(-(batHalf.x - 0.006) + fillW, 0), float2(fillW, batHalf.y - 0.006));
                lines = max(lines, fillMask(dFill, aa) * step(0.001, _Battery));

                // 4. 줌 표시 바 (아래 가운데): 캠코더의 W ─●─ T 표시처럼 현재 줌 위치를 보여 줌
                //    휠을 굴릴 때만 나타났다가 사라짐 (_ViewfinderZoomUI)
                float2 zc = float2(0.0, -B.y + 0.03);
                float zw = _ZoomBarWidth;
                float2 zp = p - zc;
                float dBar = sdSegment(zp, float2(-zw, 0), float2(zw, 0));
                // 양 끝 눈금 (W, T 자리)
                float dTicks = min(sdSegment(zp, float2(-zw, -0.008), float2(-zw, 0.008)),
                                   sdSegment(zp, float2( zw, -0.008), float2( zw, 0.008)));
                // 현재 위치 표시 (작은 사각형)
                float markerX = lerp(-zw, zw, saturate(_ViewfinderZoom01));
                float dMarker = sdBox(zp - float2(markerX, 0), float2(0.004, 0.012));
                // 양 끝 글자: W(Wide, 넓게) 왼쪽, T(Tele, 당겨서) 오른쪽, 폰트 없이 선분 SDF로 그림
                float letterSize = 0.018;
                float letterGap = 0.022;
                float dLetters = min(sdLetterW(zp - float2(-zw - letterGap, 0), letterSize),
                                     sdLetterT(zp - float2( zw + letterGap, 0), letterSize));
                float zoomBar = max(strokeMask(min(min(dBar, dTicks), dLetters), lw, aa), fillMask(dMarker, aa));
                lines = max(lines, zoomBar * saturate(_ViewfinderZoomUI));

                float3 col = _OverlayColor.rgb;
                float alpha = lines * _OverlayColor.a;

                // 5. REC 점 (왼쪽 위): 1초 주기로 깜빡인다
                float2 recC = float2(-B.x + 0.05, B.y - 0.045);
                float blink = (_BlinkSpeed <= 0.0) ? 1.0 : step(0.5, frac(_Time.y * _BlinkSpeed));
                float rec = fillMask(length(p - recC) - 0.014, aa) * blink;
                col = lerp(col, _RecColor.rgb, rec);
                alpha = max(alpha, rec * _RecColor.a);

                return float4(col, alpha * a);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float a = saturate(_ViewfinderAmount);
                float2 uv = input.texcoord.xy;

                float aspect = _ScreenParams.x / _ScreenParams.y;
                // 화면 비율을 보정한 중심 좌표 (세로 기준 -0.5~0.5)
                float2 p = (uv - 0.5) * float2(aspect, 1.0);
                float r2 = dot(p, p);
                float r = sqrt(r2);

                // 0. 평소 비네트: 뷰파인더가 꺼져 있을 때만 가장자리를 살짝 어둡게 (켜질수록 사라지고 뷰파인더 비네트로 넘어감)
                float idleAmount = _IdleVignetteStrength * saturate(_ViewfinderIdle) * (1.0 - a);
                float idleVig = lerp(1.0, smoothstep(_IdleVignetteRadius + _IdleVignetteSoftness, _IdleVignetteRadius, r), idleAmount);

                // 꺼져 있으면 원본 화면에 평소 비네트만 입혀 돌려줌
                if (a <= 0.0)
                    return SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv) * idleVig;

                float aa = fwidth(p.y) * 1.0;

                // 1. + 2. 줌, 배럴 왜곡, 색수차
                float targetZoom = (_ViewfinderZoom > 0.0) ? _ViewfinderZoom : _Zoom;
                float zoom = lerp(1.0, targetZoom, a);
                float ca = _ChromaticAberration * a * r2 * 4.0;
                float3 col;
                col.r = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, LensUV(uv, r2, zoom, -ca)).r;
                col.g = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, LensUV(uv, r2, zoom, 0.0)).g;
                col.b = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, LensUV(uv, r2, zoom, ca)).b;

                // 3. 비네트: 반지름 _VignetteRadius 부터 어두워지기 시작 (전환 중에는 평소 비네트와 함께 곱해짐)
                col *= idleVig;
                float vig = smoothstep(_VignetteRadius + _VignetteSoftness, _VignetteRadius, r);
                col *= lerp(1.0, vig, _VignetteStrength * a);

                // 4. 오버레이
                float4 ov = Overlay(p, aspect, aa, a);
                col = lerp(col, ov.rgb, ov.a);

                return half4(max(col, 0.0), 1.0);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
