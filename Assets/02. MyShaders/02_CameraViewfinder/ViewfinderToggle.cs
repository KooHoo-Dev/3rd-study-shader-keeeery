using UnityEngine;
using UnityEngine.InputSystem;

/// <summary>
/// 카메라 뷰파인더 효과 조작
///  - 스페이스바: 켜기 / 끄기 (전역 변수 _ViewfinderAmount 를 0~1로 부드럽게 보간)
///  - 마우스 휠 스크롤: 뷰파인더가 켜져 있을 때 줌 인 / 줌 아웃 (_ViewfinderZoom)
/// Renderer Feature 자체를 껐다 켜지 않고 셰이더 전역 값만 바꾸므로 모든 효과가 함께 서서히 전환
/// </summary>
[ExecuteAlways]
public class ViewfinderToggle : MonoBehaviour
{
    [Header("켜기 / 끄기 (스페이스바)")]
    [Tooltip("시작할 때 켜 둘지")]
    public bool startOn = false;

    [Tooltip("켜지고 꺼지는 데 걸리는 시간(초)")]
    [Min(0.01f)] public float transitionTime = 0.3f;

    [Header("줌 (마우스 휠)")]
    [Min(1f)] public float minZoom = 1f;
    [Min(1f)] public float maxZoom = 5f;
    [Min(1f)] public float startZoom = 1.25f;

    [Tooltip("휠 한 칸에 배율이 몇 배 바뀌는지 (1.1 = 10%씩)")]
    [Min(1.01f)] public float zoomStepFactor = 1.1f;

    [Tooltip("목표 배율까지 따라가는 부드러움 (클수록 빠르다)")]
    public float zoomSharpness = 12f;

    [Tooltip("휠을 멈춘 뒤 줌 표시 바가 사라지기까지의 시간(초)")]
    public float zoomUIHoldTime = 1.2f;

    static readonly int AmountId = Shader.PropertyToID("_ViewfinderAmount");
    static readonly int IdleId = Shader.PropertyToID("_ViewfinderIdle");
    static readonly int ZoomId = Shader.PropertyToID("_ViewfinderZoom");
    static readonly int Zoom01Id = Shader.PropertyToID("_ViewfinderZoom01");
    static readonly int ZoomUIId = Shader.PropertyToID("_ViewfinderZoomUI");

    bool _on;
    float _progress;      // 켜짐 진행도 0~1 (셰이더에는 부드럽게 휜 값을 넣는다)
    float _targetZoom;    // 휠로 정한 목표 배율
    float _zoom;          // 화면에 실제로 쓰는 배율 (목표를 부드럽게 따라감)
    float _zoomUITimer;   // 줌 표시 바를 보여 줄 남은 시간

    void OnEnable() => ResetState();

    void OnValidate()
    {
        // 에디터에서 Play 하지 않을 때도 값을 바꾸면 Scene/Game 뷰에 바로 반영
        if (!Application.isPlaying) ResetState();
    }

    void ResetState()
    {
        _on = startOn;
        _progress = _on ? 1f : 0f;
        _targetZoom = _zoom = Mathf.Clamp(startZoom, minZoom, maxZoom);
        _zoomUITimer = 0f;
        Apply();
    }

    void Update()
    {
        if (!Application.isPlaying) return;

        var keyboard = Keyboard.current;
        var mouse = Mouse.current;

        // 숫자 1키: 켜기 / 끄기
        if (keyboard != null && keyboard.digit1Key.wasPressedThisFrame)
            _on = !_on;

        float target = _on ? 1f : 0f;
        _progress = Mathf.MoveTowards(_progress, target, Time.deltaTime / transitionTime);

        // 마우스 휠: 켜져 있을 때만 줌
        if (_on && mouse != null)
        {
            float scroll = mouse.scroll.ReadValue().y;
            if (Mathf.Abs(scroll) > 0.01f)
            {
                _targetZoom *= scroll > 0f ? zoomStepFactor : 1f / zoomStepFactor;
                _targetZoom = Mathf.Clamp(_targetZoom, minZoom, maxZoom);
                _zoomUITimer = zoomUIHoldTime;
            }
        }

        // 목표 배율을 부드럽게 따라감 (프레임레이트와 무관한 지수 감쇠)
        _zoom = Mathf.Lerp(_zoom, _targetZoom, 1f - Mathf.Exp(-zoomSharpness * Time.deltaTime));
        _zoomUITimer = Mathf.Max(0f, _zoomUITimer - Time.deltaTime);

        Apply();
    }

    void OnDisable()
    {
        // 컴포넌트를 끄거나 지우면 효과를 끄고, 줌은 머티리얼 기본값(_Zoom)으로 돌아가게 0 을 넣음
        Shader.SetGlobalFloat(AmountId, 0f);
        Shader.SetGlobalFloat(IdleId, 0f);
        Shader.SetGlobalFloat(ZoomId, 0f);
        Shader.SetGlobalFloat(ZoomUIId, 0f);
    }

    void Apply()
    {
        // 처음과 끝이 느린 곡선(smoothstep)으로 바꿔 전환을 자연스럽게
        float eased = Mathf.SmoothStep(0f, 1f, _progress);
        Shader.SetGlobalFloat(AmountId, eased);
        Shader.SetGlobalFloat(IdleId, 1f);   // 이 스크립트가 있는 씬에서만 평소 비네트를 켠다

        Shader.SetGlobalFloat(ZoomId, _zoom);
        // 줌 표시 바 위치: 배율의 로그 비율 (곱셈 줌과 맞춰 바가 일정한 속도로 움직이게)
        float zoom01 = maxZoom > minZoom ? Mathf.InverseLerp(Mathf.Log(minZoom), Mathf.Log(maxZoom), Mathf.Log(_zoom)) : 0f;
        Shader.SetGlobalFloat(Zoom01Id, zoom01);
        // 남은 시간의 마지막 0.3초 동안 서서히 사라짐
        Shader.SetGlobalFloat(ZoomUIId, Mathf.Clamp01(_zoomUITimer / 0.3f));
    }
}
