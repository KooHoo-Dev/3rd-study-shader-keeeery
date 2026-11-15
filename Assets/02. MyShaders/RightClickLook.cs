using UnityEngine;
using UnityEngine.InputSystem;

/// <summary>
/// 마우스 오른쪽 버튼을 누른 채 움직이면 카메라가 제자리에서 시점을 돌린다 (좌우 = Yaw, 상하 = Pitch).
/// Main Camera 에 붙인다.
/// </summary>
public class RightClickLook : MonoBehaviour
{
    [Tooltip("마우스 1픽셀당 회전 각도(도)")]
    public float sensitivity = 0.15f;

    [Tooltip("위아래로 볼 수 있는 최대 각도(도)")]
    [Range(0f, 89f)] public float pitchLimit = 80f;

    [Tooltip("마우스를 위로 올리면 아래를 보게 할지")]
    public bool invertY = false;

    [Tooltip("드래그하는 동안 커서를 숨기고 고정할지")]
    public bool lockCursorWhileLooking = true;

    float _yaw;
    float _pitch;

    void Start()
    {
        // 지금 카메라 방향에서 시작
        Vector3 euler = transform.eulerAngles;
        _yaw = euler.y;
        _pitch = euler.x > 180f ? euler.x - 360f : euler.x;   // 0~360 → -180~180
    }

    void Update()
    {
        var mouse = Mouse.current;
        if (mouse == null) return;

        bool looking = mouse.rightButton.isPressed;

        if (lockCursorWhileLooking)
        {
            if (mouse.rightButton.wasPressedThisFrame) SetCursorLocked(true);
            if (mouse.rightButton.wasReleasedThisFrame) SetCursorLocked(false);
        }

        if (!looking) return;

        Vector2 delta = mouse.delta.ReadValue() * sensitivity;
        _yaw += delta.x;
        _pitch += invertY ? delta.y : -delta.y;
        _pitch = Mathf.Clamp(_pitch, -pitchLimit, pitchLimit);

        transform.rotation = Quaternion.Euler(_pitch, _yaw, 0f);
    }

    void OnDisable() => SetCursorLocked(false);

    static void SetCursorLocked(bool locked)
    {
        Cursor.lockState = locked ? CursorLockMode.Locked : CursorLockMode.None;
        Cursor.visible = !locked;
    }
}
