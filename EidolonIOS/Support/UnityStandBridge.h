#import <UIKit/UIKit.h>

@class UnityFramework;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the embedded Unity player (ADR-0034) and returns its singleton, or nil
/// when the framework is missing from the app bundle.
///
/// The exported player keeps its `Data` folder at the app bundle root (the
/// UaaL "copy Data into the native app" mode), so no data bundle id is set here:
/// Unity looks for `<main bundle>/Data` by default.
UnityFramework * _Nullable EidolonUnityLoadFramework(void);

/// Starts the embedded player. Safe to call once; later calls are ignored by Unity.
void EidolonUnityStart(UnityFramework * _Nullable framework);

/// The view the player renders into; nil until the player is started.
UIView * _Nullable EidolonUnityRootView(UnityFramework * _Nullable framework);

/// Takes the player's own window out of the way. Unity creates a window of its own when
/// it starts; left as-is it sits above the app's window, so the app is visible through it
/// but every touch goes to Unity and no control answers. The player keeps rendering into
/// its root view, which the app embeds itself.
void EidolonUnityDetachWindow(UnityFramework * _Nullable framework);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
