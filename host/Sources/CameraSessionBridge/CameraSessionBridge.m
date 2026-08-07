#import <AVFoundation/AVFoundation.h>
#import "CameraSessionBridge.h"

NSString *SRCameraStartSession(id session) {
    @try {
        [session startRunning];
        return nil; // 未抛异常(不代表 isRunning 已 true,调用方观察通知判定)
    } @catch (NSException *exception) {
        // 拼接 name + reason + callStack,便于诊断真实失败原因
        // (摄像头权限/设备占用/多设备并发等情况的异常文案不同)
        NSString *desc = [NSString stringWithFormat:@"%@: %@",
                          exception.name ?: @"(no name)",
                          exception.reason ?: @"(no reason)"];
        return desc;
    }
}
