using System.IO;
using UnityEngine;

/// 把多角色展示场景做成"进 Play 就自动重建"的形式。
///
/// AssetBundle 实例不能存进场景文件，所以不能靠保存场景来记住摆好的角色；
/// 这里改成场景里只放这个组件，Start 时按目录重新生成整套角色 + 日常动作。
public sealed class GalleryBootstrap : MonoBehaviour
{
    public string bundleDirectory = "";
    public string dailyMotionBundle = "";
    public string dailyClip = "act";
    public int columns = 10;

    private void Start()
    {
        if (string.IsNullOrEmpty(bundleDirectory))
            bundleDirectory = Path.Combine(
                System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile),
                "mltd-work/bundles-all");
        if (string.IsNullOrEmpty(dailyMotionBundle))
            dailyMotionBundle = Path.Combine(bundleDirectory, "chr_anim_com_001har.unity3d");

        var spawned = AllCharactersSpawner.Spawn(bundleDirectory, columns);
        var reference = GameObject.Find("MLTD_Ref");
        if (reference != null && File.Exists(dailyMotionBundle))
            DailyMotionPlayer.Play(dailyMotionBundle, dailyClip);
        Debug.Log($"MLTD gallery: {spawned} characters, clip {dailyClip}");
    }
}
