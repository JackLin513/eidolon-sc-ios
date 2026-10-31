#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and reports an Objective-C exception instead of letting it abort the app.
/// AVFAudio raises these for an invalid tap or format; Swift cannot catch them.
/// Returns nil when the block ran, or the exception's reason when it raised.
FOUNDATION_EXPORT NSString *_Nullable EIDCatchObjectiveCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
