using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;

/// <summary>
/// 반딧불 디졸브 데모용 컨트롤러, 셰이더볼처럼 여러 메시로 된 물체의 루트(예: ShaderBall)에 붙임
///  1. 자식 렌더러 중 FireflyDissolve 셰이더를 쓰는 것을 모두 찾아,
///     쓸기 기준점(_SweepOrigin)과 범위(_SweepRange)를 물체 전체의 바운드로 맞춤 → 여러 메시가 하나의 무늬로 사라짐
///  2. 키를 누르면 _Progress 를 0 → 1 (사라짐) 또는 1 → 0 (다시 생김) 으로 움직임
///  3. Play 를 시작하면 반딧불 Particle System 을 자식으로 만들고, 사라지는 동안 진행된 만큼 반딧불을 내보냄
/// 값은 MaterialPropertyBlock 으로 넣으므로 머티리얼 에셋은 바뀌지 않음
/// </summary>
[ExecuteAlways]
public class FireflyDissolveController : MonoBehaviour
{
    [Header("디졸브")]
    [Tooltip("사라짐 / 다시 생김을 번갈아 실행하는 키")]
    public Key toggleKey = Key.Digit2;

    [Tooltip("한 번 사라지거나 생기는 데 걸리는 시간(초)")]
    [Min(0.1f)] public float duration = 2.5f;

    [Tooltip("켜면 키 없이 사라짐 ↔ 생김을 계속 반복")]
    public bool autoLoop = false;

    [Tooltip("autoLoop 일 때 끝에서 멈춰 있는 시간(초)")]
    [Min(0f)] public float loopPause = 1f;

    [Header("반딧불 파티클")]
    [Tooltip("FireflyParticle.mat, 비워 두면 MyShaders/FireflyParticle 셰이더로 새로 만듦")]
    public Material fireflyMaterial;

    [Tooltip("한 번 완전히 사라질 때 나오는 반딧불 수")]
    [Min(0)] public int fireflyCount = 90;

    [Tooltip("반딧불 하나가 떠 있는 시간(초) 범위")]
    public Vector2 fireflyLifetime = new Vector2(3f, 5.5f);

    [Tooltip("반딧불 크기(월드 m) 범위")]
    public Vector2 fireflySize = new Vector2(0.05f, 0.1f);

    [Tooltip("위로 떠오르는 속도(m/s) 범위")]
    public Vector2 riseSpeed = new Vector2(0.05f, 0.18f);

    [Tooltip("이리저리 헤매는 정도 (Noise 모듈 세기)")]
    [Min(0f)] public float wander = 0.3f;

    static readonly int ProgressId = Shader.PropertyToID("_Progress");
    static readonly int SweepOriginId = Shader.PropertyToID("_SweepOrigin");
    static readonly int SweepRangeId = Shader.PropertyToID("_SweepRange");
    const string DissolveShaderName = "MyShaders/FireflyDissolve";
    const string ParticleShaderName = "MyShaders/FireflyParticle";

    readonly List<Renderer> _renderers = new List<Renderer>();
    MaterialPropertyBlock _block;
    Bounds _bounds;
    float _progress; // 현재 진행값
    float _target; // 목표 진행값 (0 또는 1)
    float _pauseTimer;
    bool _driving; // Play 중 한 번이라도 진행값을 움직였는지 (그 전에는 머티리얼 값 사용)

    ParticleSystem _fireflies;
    Material _runtimeMaterial;
    float _emitCarry; // 소수점 아래로 남은 반딧불 수 (다음 프레임에 이어서 계산)

    // ---------- 준비 ----------
    void OnEnable()
    {
        _block ??= new MaterialPropertyBlock();
        CollectRenderers();
        ApplySweep();
    }

    void OnValidate()
    {
        if (!isActiveAndEnabled) return;
        _block ??= new MaterialPropertyBlock();
        CollectRenderers();
        ApplySweep();
    }

    void Start()
    {
        if (Application.isPlaying) CreateFireflies();
    }

    void CollectRenderers()
    {
        _renderers.Clear();
        foreach (var r in GetComponentsInChildren<Renderer>(true))
        {
            if (r is ParticleSystemRenderer) continue;
            foreach (var m in r.sharedMaterials)
            {
                if (m != null && m.shader != null && m.shader.name == DissolveShaderName)
                {
                    _renderers.Add(r);
                    break;
                }
            }
        }
    }

    // 자식 렌더러 전체를 감싸는 바운드로 쓸기 기준점과 범위를 정함
    void ApplySweep()
    {
        if (_renderers.Count == 0) return;
        _bounds = _renderers[0].bounds;
        for (int i = 1; i < _renderers.Count; i++) _bounds.Encapsulate(_renderers[i].bounds);

        float range = Mathf.Max(_bounds.extents.x, Mathf.Max(_bounds.extents.y, _bounds.extents.z));
        foreach (var r in _renderers)
        {
            r.GetPropertyBlock(_block);
            _block.SetVector(SweepOriginId, _bounds.center);
            _block.SetFloat(SweepRangeId, Mathf.Max(range, 0.1f));
            r.SetPropertyBlock(_block);
        }
    }

    // ---------- 반딧불 Particle System 만들기 ----------
    void CreateFireflies()
    {
        if (_renderers.Count == 0) return;

        var go = new GameObject("Fireflies");
        go.transform.SetParent(transform, false);
        go.transform.position = _bounds.center;

        _fireflies = go.AddComponent<ParticleSystem>();
        _fireflies.Stop(true, ParticleSystemStopBehavior.StopEmittingAndClear);

        // 기본: 월드 공간에서 떠다니고, 스스로는 내보내지 않음 (Emit 으로만 내보냄)
        var main = _fireflies.main;
        main.duration = 5f;
        main.loop = true;
        main.playOnAwake = false;
        main.startLifetime = new ParticleSystem.MinMaxCurve(fireflyLifetime.x, fireflyLifetime.y);
        main.startSpeed = new ParticleSystem.MinMaxCurve(0.02f, 0.1f);
        main.startSize = new ParticleSystem.MinMaxCurve(fireflySize.x, fireflySize.y);
        main.startColor = Color.white; // 색은 셰이더의 핵·후광 색이 정함
        main.simulationSpace = ParticleSystemSimulationSpace.World;
        main.maxParticles = Mathf.Max(fireflyCount * 3, 50);

        var emission = _fireflies.emission;
        emission.rateOverTime = 0f;

        // 모양: 셰이더볼의 공 표면에서 생겨남 (구 표면, 바운드 크기)
        var shape = _fireflies.shape;
        shape.shapeType = ParticleSystemShapeType.Sphere;
        shape.radius = Mathf.Min(_bounds.extents.x, Mathf.Min(_bounds.extents.y, _bounds.extents.z));
        shape.radiusThickness = 0f;

        // 천천히 떠오름
        var velocity = _fireflies.velocityOverLifetime;
        velocity.enabled = true;
        velocity.space = ParticleSystemSimulationSpace.World;
        velocity.x = new ParticleSystem.MinMaxCurve(0f, 0f);
        velocity.y = new ParticleSystem.MinMaxCurve(riseSpeed.x, riseSpeed.y);
        velocity.z = new ParticleSystem.MinMaxCurve(0f, 0f);

        // 이리저리 헤맴
        var noise = _fireflies.noise;
        noise.enabled = true;
        noise.strength = wander;
        noise.frequency = 0.6f;
        noise.scrollSpeed = 0.25f;
        noise.damping = true;
        noise.quality = ParticleSystemNoiseQuality.Medium;

        // 생겨날 때 서서히 켜지고, 사라질 때 서서히 꺼짐 (정점 색 알파 → 셰이더에서 곱함)
        var colorOverLifetime = _fireflies.colorOverLifetime;
        colorOverLifetime.enabled = true;
        var gradient = new Gradient();
        gradient.SetKeys(
            new[] { new GradientColorKey(Color.white, 0f), new GradientColorKey(Color.white, 1f) },
            new[] { new GradientAlphaKey(0f, 0f), new GradientAlphaKey(1f, 0.15f), new GradientAlphaKey(1f, 0.7f), new GradientAlphaKey(0f, 1f) });
        colorOverLifetime.color = gradient;

        // 렌더러: 카메라를 향한 사각형 + 파티클별 난수(StableRandom.x)를 셰이더로 넘김
        var psr = go.GetComponent<ParticleSystemRenderer>();
        psr.renderMode = ParticleSystemRenderMode.Billboard;
        psr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        psr.receiveShadows = false;
        psr.SetActiveVertexStreams(new List<ParticleSystemVertexStream>
        {
            ParticleSystemVertexStream.Position,
            ParticleSystemVertexStream.Color,
            ParticleSystemVertexStream.UV, // TEXCOORD0.xy
            ParticleSystemVertexStream.StableRandomX // TEXCOORD0.z
        });

        if (fireflyMaterial == null)
        {
            var shader = Shader.Find(ParticleShaderName);
            if (shader != null) _runtimeMaterial = new Material(shader);
        }
        psr.sharedMaterial = fireflyMaterial != null ? fireflyMaterial : _runtimeMaterial;

        _fireflies.Play();
    }

    // ---------- 매 프레임 ----------
    void Update()
    {
        if (!Application.isPlaying) return;

        var keyboard = Keyboard.current;
        bool pressed = keyboard != null && keyboard[toggleKey].wasPressedThisFrame;

        if (pressed)
        {
            if (!_driving) { _driving = true; _progress = 0f; }
            _target = _target > 0.5f ? 0f : 1f;
        }
        else if (autoLoop)
        {
            if (!_driving) { _driving = true; _progress = 0f; _target = 1f; }
            if (Mathf.Approximately(_progress, _target))
            {
                _pauseTimer += Time.deltaTime;
                if (_pauseTimer >= loopPause)
                {
                    _pauseTimer = 0f;
                    _target = _target > 0.5f ? 0f : 1f;
                }
            }
        }

        if (!_driving) return;

        float previous = _progress;
        _progress = Mathf.MoveTowards(_progress, _target, Time.deltaTime / duration);
        foreach (var r in _renderers)
        {
            r.GetPropertyBlock(_block);
            _block.SetFloat(ProgressId, _progress);
            r.SetPropertyBlock(_block);
        }

        // 사라지는 중(진행값이 커질 때)에만, 진행된 만큼 반딧불을 내보냄
        float delta = _progress - previous;
        if (_fireflies != null && delta > 0f)
        {
            _emitCarry += delta * fireflyCount;
            int count = Mathf.FloorToInt(_emitCarry);
            if (count > 0)
            {
                _fireflies.Emit(count);
                _emitCarry -= count;
            }
        }
    }

    void OnDisable()
    {
        // 블록을 비워 머티리얼 값으로 되돌림
        foreach (var r in _renderers)
            if (r != null) r.SetPropertyBlock(null);
        _driving = false;
    }

    void OnDestroy()
    {
        if (!Application.isPlaying) return;
        if (_fireflies != null) Destroy(_fireflies.gameObject);
        if (_runtimeMaterial != null) Destroy(_runtimeMaterial);
    }
}
