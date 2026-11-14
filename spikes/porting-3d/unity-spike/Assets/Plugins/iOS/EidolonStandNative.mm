#import <Foundation/Foundation.h>

// Unity → Swift event channel for the 3D stand (ADR-0034).
//
// Unity's il2cpp resolves the `__Internal` P/Invoke declared by
// Assets/Scripts/EidolonStandBridge.cs to this symbol. Posting to the default
// NSNotificationCenter reaches the host app in the same process; the Swift
// adapter (UnityStandRenderer) observes NSNotification.Name("EidolonStandEvent")
// and reads the JSON string from userInfo["json"].

extern "C" void EidolonUnityPostEvent(const char *json)
{
    NSString *message = json != NULL ? [NSString stringWithUTF8String:json] : @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"EidolonStandEvent"
                                                        object:nil
                                                      userInfo:@{ @"json" : message }];
}
