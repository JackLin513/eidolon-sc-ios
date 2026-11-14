using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEngine;

/// Spawns one character per (costume, idol) pair found in a bundle directory and
/// mirrors the reference character's pose onto all of them. Runs at runtime
/// because AssetBundle instances cannot be stored in a scene.
public static class AllCharactersSpawner
{
    /// 每次 Spawn 记录失败原因，方便在编辑器里一次看全（导出脚本名 → 原因）。
    public static readonly List<string> Failures = new List<string>();

    public static int Spawn(string directory, int columns = 10, float spacingX = 1.05f, float spacingZ = 1.5f)
    {
        if (!Directory.Exists(directory))
        {
            Debug.LogError($"MLTD: bundle directory not found: {directory}");
            return 0;
        }

        // 这些全局 shader 参数不设的话角色会整体发黑（和 ShowCharacter 一致）。
        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);

        Failures.Clear();
        // 参考角色自己建：不依赖场景里那个 bootstrap（Play 重新加载后它可能是空的）。
        // 第一个成功实例化的角色当参考，其它都镜子它。
        GameObject reference = null;
        var created = 0;
        var bodies = Directory.GetFiles(directory, "cb_*.unity3d").OrderBy(p => p).ToList();
        foreach (var bodyFile in bodies)
        {
            var name = Path.GetFileName(bodyFile);
            var parts = Path.GetFileNameWithoutExtension(name).Split('_');
            if (parts.Length < 3) continue;
            var costume = parts[1];
            var idol = parts[2];
            var headFile = Path.Combine(directory, $"ch_{costume}_{idol}.unity3d");
            if (!File.Exists(headFile))
            {
                Failures.Add($"{name}: 缺头部 bundle");
                continue;
            }

            AssetBundle Load(string file)
            {
                var bundle = AssetBundle.GetAllLoadedAssetBundles()
                    .FirstOrDefault(b => b.name == Path.GetFileName(file));
                return bundle != null ? bundle : AssetBundle.LoadFromFile(file);
            }

            var bodyBundle = Load(bodyFile);
            var headBundle = Load(headFile);
            if (bodyBundle == null || headBundle == null)
            {
                Failures.Add($"{name}: bundle 加载为空");
                continue;
            }

            try
            {
                // 有些 cb_ 包只是贴图补丁（比如 ex004/ex023 系列），里面没有角色 prefab。
                var bodyPrefab = bodyBundle.LoadAllAssets<GameObject>()
                    .FirstOrDefault(g => g.name.StartsWith("cb_"));
                if (bodyPrefab == null)
                {
                    Failures.Add($"{name}: 贴图包，没有角色 prefab");
                    continue;
                }
                var body = UnityEngine.Object.Instantiate(bodyPrefab);
                body.name = $"MLTD_All_{costume}_{idol}";
                var head = UnityEngine.Object.Instantiate(
                    headBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_")));
                head.name = "ch_head";
                head.transform.SetParent(body.transform.Find("MODEL_00"), false);
                head.transform.localPosition = Vector3.zero;
                head.transform.localRotation = Quaternion.identity;
                head.transform.localScale = Vector3.one;

                if (reference == null)
                {
                    reference = body;
                    body.name = "MLTD_Ref";
                }
                else
                {
                    var puppet = body.AddComponent<PosePuppet>();
                    puppet.reference = reference.transform;
                }
                if (reference == body)
                    body.transform.position = new Vector3(0f, 0f, -0.2f);
                else
                {
                    var row = (created - 1) / columns;
                    var column = (created - 1) % columns;
                    body.transform.position = new Vector3(
                        (column - (columns - 1) / 2f) * spacingX, 0f, 1.6f + row * spacingZ);
                }
                created++;
            }
            catch (Exception e)
            {
                Failures.Add($"{name}: {e.GetType().Name} {e.Message}");
            }
        }


        var rows = Mathf.Max(1, (created - 1 + columns - 1) / columns);

        // 场景自带的相机会被 bootstrap 每帧摆回近景，所以这里给它挂一个持续取景组件。
        var camera = Camera.main ?? UnityEngine.Object.FindObjectOfType<Camera>();
        if (camera != null)
        {
            var framer = camera.GetComponent<BatchViewCamera>();
            if (framer == null) framer = camera.gameObject.AddComponent<BatchViewCamera>();
            var all = new System.Collections.Generic.List<GameObject> { };
            foreach (var p in UnityEngine.Object.FindObjectsOfType<PosePuppet>()) all.Add(p.gameObject);
            if (reference != null) all.Add(reference);
            framer.FitTo(all.ToArray());
        }
        Debug.Log($"MLTD: {created} characters spawned in {rows} rows");
        return created;
    }
}
