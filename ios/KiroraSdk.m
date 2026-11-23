#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// The Swift module (KiroraSdkModule.swift), exported to JavaScript as `KiroraSdk`, with the
// same methods as the Android module so `NativeBackend` drives both.
@interface RCT_EXTERN_MODULE(KiroraSdk, RCTEventEmitter)

RCT_EXTERN_METHOD(configure:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(identify:(NSString *)token
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(logout:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(track:(NSString *)name propertiesJson:(NSString *)propertiesJson)
RCT_EXTERN_METHOD(trackScreenView:(NSString *)name)
RCT_EXTERN_METHOD(setTrackingConsent:(BOOL)granted)
RCT_EXTERN_METHOD(setPushConsent:(BOOL)granted
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(requestPushPermission:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(getPushStatus:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(setPushEnabled:(BOOL)enabled
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(flush:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(getState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(destroy)
RCT_EXTERN_METHOD(onNewPushToken:(NSString *)token)
RCT_EXTERN_METHOD(onPushRegistered:(NSString *)installationId)
RCT_EXTERN_METHOD(resolveToken:(NSString *)requestId token:(NSString *)token error:(NSString *)error)
RCT_EXTERN_METHOD(resolveAnswer:(NSString *)requestId answer:(BOOL)answer)
RCT_EXTERN_METHOD(setNotificationEvents:(BOOL)clicked received:(BOOL)received)

@end
