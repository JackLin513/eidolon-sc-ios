using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

/// Lays every character pair in a directory out in a grid, so a whole costume
/// set can be eyeballed in one go. The first character plays the motion; the
/// rest mirror its skeleton through PosePuppet.
public static class ShowAllCharacters
{
    [MenuItem("MLTD/Show All Characters")]
    public static void Show()
    {
        var dir = Environment.GetEnvironmentVariable("MLTD_ALL_BUNDLES")
                  ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work/bundles-all");
        if (!Directory.Exists(dir))
        {
            Debug.LogError($"MLTD: bundle directory not found: {dir}");
            return;
        }

        // 和 ShowCharacter 一样：这些是全局 shader 参数，不设角色会发黑。
        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);

        foreach (var existing in GameObject.FindObjectsOfType<Transform>())
            if (existing.name.StartsWith("MLTD_All_"))
                UnityEngine.Object.DestroyImmediate(existing.gameObject);

        var bodies = Directory.GetFiles(dir, "cb_*.unity3d").OrderBy(p => p).ToList();
        var pairCount = 0;
        var columns = 10;
        var cell = new Vector3(1.05f, 0f, 1.15f);

        foreach (var bodyFile in bodies)
        {
            var name = Path.GetFileName(bodyFile);
            var costume = name.Split('_')[1];
            var idol = Path.GetFileNameWithoutExtension(name).Split('_')[2];
            var headFile = Path.Combine(dir, $"ch_{costume}_{idol}.unity3d");
            if (!File.Exists(headFile)) continue;

            AssetBundle Load(string file)
            {
                var bundle = AssetBundle.GetAllLoadedAssetBundles().FirstOrDefault(b => b.name == Path.GetFileName(file));
                return bundle != null ? bundle : AssetBundle.LoadFromFile(file);
            }

            var bodyBundle = Load(bodyFile);
            var headBundle = Load(headFile);
            if (bodyBundle == null || headBundle == null) continue;

            try
            {
                var body = UnityEngine.Object.Instantiate(
                    bodyBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_")));
                body.name = $"MLTD_All_{costume}_{idol}";
                var head = UnityEngine.Object.Instantiate(
                    headBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_")));
                head.name = "ch_head";
                head.transform.SetParent(body.transform.Find("MODEL_00"), false);
                head.transform.localPosition = Vector3.zero;
                head.transform.localRotation = Quaternion.identity;
                head.transform.localScale = Vector3.one;

                var row = pairCount / columns;
                var column = pairCount % columns;
                body.transform.position = new Vector3(
                    (column - (columns - 1) / 2f) * cell.x,
                    0f,
                    row * cell.z);
                body.transform.rotation = Quaternion.Euler(0, 180f, 0);
                pairCount++;
            }
            catch (Exception e)
            {
                Debug.LogWarning($"MLTD: skip {name}: {e.Message}");
            }
        }

        // 第一个角色当参考：它由 CharacterBootstrap 驱动，其余镜像它。
        var reference = GameObject.Find("Character");
        if (reference == null) Debug.LogWarning("MLTD: no Character bootstrap in scene; puppets will stay static");
        // 参考角色挪到最前排中间，不挡住别人。
        if (reference != null) reference.transform.position = new Vector3(0f, 0f, -1.4f);

        foreach (var t in GameObject.FindObjectsOfType<Transform>())
        {
            if (!t.name.StartsWith("MLTD_All_")) continue;
            var puppet = t.gameObject.AddComponent<PosePuppet>();
            puppet.reference = reference != null ? reference.transform : null;
        }

        var rows = Mathf.Max(1, (pairCount + columns - 1) / columns);
        if (Camera.main == null)
        {
            var camera = new GameObject("Main Camera").AddComponent<Camera>();
            camera.tag = "MainCamera";
            camera.transform.position = new Vector3(0f, 1.6f, -3.2f);
            camera.transform.LookAt(new Vector3(0f, 0.9f, (rows - 1) * cell.z * 0.5f));
        }
        Debug.Log($"MLTD: {pairCount} characters laid out in {rows} rows");
    }
}
