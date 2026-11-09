#import "UnityStandBridge.h"

#if __has_include(<UnityFramework/UnityFramework.h>)
#import <UnityFramework/UnityFramework.h>
#import <mach-o/ldsyms.h>
#endif

#if __has_include(<UnityFramework/UnityFramework.h>)
static UnityFramework *gEidolonUnityFramework = nil;
static BOOL gEidolonUnityStarted = NO;

UnityFramework * _Nullable EidolonUnityLoadFramework(void)
{
    if (gEidolonUnityFramework != nil) return gEidolonUnityFramework;

    NSString *path = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingString:@"/Frameworks/UnityFramework.framework"];
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle == nil) return nil;
    if (![bundle isLoaded]) [bundle load];

    Class principal = [bundle principalClass];
    if (principal == Nil) return nil;
    UnityFramework *framework = [principal getInstance];
    if (framework == nil) return nil;

    // A fresh instance needs the app's Mach header before it can run.
    if ([framework appController] == nil) {
        [framework setExecuteHeader:&_mh_execute_header];
    }
    gEidolonUnityFramework = framework;
    return framework;
}

void EidolonUnityStart(UnityFramework * _Nullable framework)
{
    if (framework == nil || gEidolonUnityStarted) return;
    gEidolonUnityStarted = YES;

    // Unity expects a C argv; the host's own arguments are Swift's, so hand it a
    // minimal one. The scene is the only thing that matters here.
    static char argument0[] = "Eidolon";
    static char *arguments[] = { argument0, NULL };
    [framework registerFrameworkListener:nil];
    [framework runEmbeddedWithArgc:1 argv:arguments appLaunchOpts:@{}];
}

UIView * _Nullable EidolonUnityRootView(UnityFramework * _Nullable framework)
{
    if (framework == nil) return nil;
    UnityAppController *controller = [framework appController];
    if (controller == nil) return nil;
    return [controller rootView];
}

void EidolonUnityDetachWindow(UnityFramework * _Nullable framework)
{
    if (framework == nil) return;
    UnityAppController *controller = [framework appController];
    if (controller == nil) return;
    UIWindow *window = [controller window];
    if (window == nil) return;
    // Unity's window must not stay above the app's: it is transparent, so the app is
    // visible through it, but it swallows every touch. Rendering continues in the root
    // view, which the app has already moved into its own hierarchy.
    window.hidden = YES;
    window.userInteractionEnabled = NO;
    window.windowLevel = UIWindowLevelNormal - 1;
}
#else
UnityFramework * _Nullable EidolonUnityLoadFramework(void) { return nil; }
void EidolonUnityStart(UnityFramework * _Nullable framework) { (void)framework; }
UIView * _Nullable EidolonUnityRootView(UnityFramework * _Nullable framework) { (void)framework; return nil; }
void EidolonUnityDetachWindow(UnityFramework * _Nullable framework) { (void)framework; }
#endif
