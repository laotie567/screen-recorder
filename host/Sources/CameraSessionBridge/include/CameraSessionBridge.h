#ifndef CameraSessionBridge_h
#define CameraSessionBridge_h
#import <Foundation/Foundation.h>

/// 在 @try/@catch 中调用 AVCaptureSession.startRunning。
/// 理由:startRunning 在摄像头权限缺失/设备被占用等异常态会抛出 Objective-C 异常,
/// 而 Swift 的 try/catch 抓不住 ObjC 异常,会直接 SIGABRT 杀掉宿主进程。
/// 此桥接把异常转成返回值,调用方据此抛出可控的 Swift 错误。
///
/// 返回值:nil 表示 startRunning 未抛异常(不代表 session 已 running,调用方仍需观察通知);
///        非 nil 表示抛了 ObjC 异常,内容为异常描述(用于写入日志诊断)。
NSString * _Nullable SRCameraStartSession(id session);

#endif /* CameraSessionBridge_h */
