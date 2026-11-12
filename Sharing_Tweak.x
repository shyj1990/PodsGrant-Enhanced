#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include "general.h"

static struct podsgrant_settings *settings = NULL;
static int g_unlock_token = 0;

// 4 槽位多设备环形缓存（彻底解决 Apple Watch 与 AirPods 同时广播时的缓存抖动）
struct pgs_cache_slot {
	uint16_t orig;
	uint16_t target;
};
static struct pgs_cache_slot s_pid_cache[4] = {{0,0}, {0,0}, {0,0}, {0,0}};
static int s_cache_idx = 0;

static void reload_settings_if_needed(void) {
	if (settings) {
		PGS_freeSettings(settings);
		settings = NULL;
	}
	settings = PGS_readSettings(0);
	for (int i = 0; i < 4; i++) {
		s_pid_cache[i].orig = 0;
		s_pid_cache[i].target = 0;
	}
}

static inline uint16_t fast_patch_pid(uint16_t orig) {
	for (int i = 0; i < 4; i++) {
		if (s_pid_cache[i].orig == orig) {
			return s_pid_cache[i].target;
		}
	}
	uint16_t target = PGS_patchProductId(settings, orig);
	s_pid_cache[s_cache_idx].orig = orig;
	s_pid_cache[s_cache_idx].target = target;
	s_cache_idx = (s_cache_idx + 1) & 3;
	return target;
}

%group sharing_hook_grp

%hook SFBLEScanner

- (id)pairingParsePayload:(NSData *)payload identifier:(id)idf bleDevice:(id)bleDev peerInfo:(id)peerInfo {
	if (!payload || payload.length < 7) {
		return %orig;
	}

	const uint8_t *bytes = (const uint8_t *)payload.bytes;
	uint16_t orig_pid = *(const uint16_t *)(bytes + 5);
	uint16_t patched = fast_patch_pid(orig_pid);

	if (patched && patched != orig_pid) {
		NSMutableData *mutPayload = [payload mutableCopy];
		uint16_t *target_ptr = (uint16_t *)((uint8_t *)mutPayload.mutableBytes + 5);
		*target_ptr = patched;
		return %orig(mutPayload, idf, bleDev, peerInfo);
	}
	return %orig;
}

- (id)pairingParsePayload:(NSData *)payload identifier:(id)idf bleDevice:(id)bleDev {
	if (!payload || payload.length < 7) {
		return %orig;
	}

	const uint8_t *bytes = (const uint8_t *)payload.bytes;
	uint16_t orig_pid = *(const uint16_t *)(bytes + 5);
	uint16_t patched = fast_patch_pid(orig_pid);

	if (patched && patched != orig_pid) {
		NSMutableData *mutPayload = [payload mutableCopy];
		uint16_t *target_ptr = (uint16_t *)((uint8_t *)mutPayload.mutableBytes + 5);
		*target_ptr = patched;
		return %orig(mutPayload, idf, bleDev);
	}
	return %orig;
}

%end

%end

// ==============================================================================
// 纯净 DarkPods 深色逻辑 + 100% 绝对 0 闪白 + 系统级 Taptic Engine Peek 清脆震感 (1519)
// ==============================================================================

// 私有类接口声明（仅供编译期解析，运行时仍为消息转发，行为不变）
@interface PRXCardSlideUpPresentationController : UIPresentationController
@end

@interface PGS_TitleViewStub : NSObject
- (void)setTitleText:(id)text;
@end

// ==============================================================================
// 型号名称兜底：老系统缺少新耳机（如 PID 8240）的 Localizable-PID_<pid> 本地化时，
// 「设置 → 蓝牙 → 关于」等界面的型号名称会退化为通用 "AirPods"。
// 按系统本地化 key（PRODUCT_NAME_PID_<n>）与表名（Localizable-PID_<n>）精确拦截，
// 仅当系统查询失败（原样返回 key/value）且 PID 命中下表时才替换；系统已有名称一律不动。
// ==============================================================================
static const struct { unsigned int pid; const char *name; } s_pid_display_names[] = {
	{8240, "AirPods 5 (Wireless Charging Case)"},
	{8246, "AirPods 5"},
	{8219, "AirPods 4 ANC"},
	{8212, "AirPods Pro 2 Lightning"},
	{8228, "AirPods Pro 2 USB-C"},
	{8231, "AirPods Pro 3"},
	{8232, "AirPods Pro 3 ANC"},
	{0, NULL},
};

static NSString *PGS_displayNameForPid(int pid) {
	for (int i = 0; s_pid_display_names[i].name; i++) {
		if (pid > 0 && (unsigned int)pid == s_pid_display_names[i].pid) {
			return [NSString stringWithUTF8String:s_pid_display_names[i].name];
		}
	}
	return nil;
}

%group pidname_hook_grp

%hookf(CFStringRef, CFBundleCopyLocalizedString, CFBundleRef bundle, CFStringRef key, CFStringRef value, CFStringRef tableName) {
	CFStringRef orig = %orig;
	NSString *nsKey = (__bridge NSString *)key;
	NSString *nsTable = (__bridge NSString *)tableName;
	NSString *nsOrig = (__bridge NSString *)orig;
	NSString *nsValue = (__bridge NSString *)value;
	if (!nsKey || ![nsKey isKindOfClass:[NSString class]] || ![nsKey hasPrefix:@"PRODUCT_NAME_PID_"]) {
		return orig;
	}
	if (!nsTable || ![nsTable isKindOfClass:[NSString class]] || ![nsTable hasPrefix:@"Localizable-PID_"]) {
		return orig;
	}
	// 查询失败时 CFBundleCopyLocalizedString 返回 value（若提供）或 key 原样
	BOOL missed = (nsOrig == nil) ||
		(nsValue != nil && [nsOrig isEqualToString:nsValue]) ||
		[nsOrig isEqualToString:nsKey];
	if (!missed) {
		return orig;
	}
	int pid = atoi([[nsKey substringFromIndex:17] UTF8String]); // strlen("PRODUCT_NAME_PID_") == 17
	NSString *name = PGS_displayNameForPid(pid);
	if (name) {
		return (__bridge_retained CFStringRef)name;
	}
	return orig;
}

%end

%group darkpods_hook_grp

static NSTimeInterval s_last_haptic_time = 0;

static inline void PGS_TriggerHapticFeedback(void) {
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - s_last_haptic_time < 1.5) {
		return; // 1.5秒智能防抖
	}
	s_last_haptic_time = now;
	// 调用 iOS 系统硬件马达 Peek 触感反馈（1519），0 延迟、100% 必定触发
	AudioServicesPlaySystemSound(1519);
}

// 1. 转场动画前将容器底色设为完全透明，彻底消除冷启动第一帧的浅色露白
%hook PRXCardSlideUpPresentationController

- (void)presentationTransitionWillBegin {
	%orig;
	if (self.containerView) {
		self.containerView.backgroundColor = [UIColor clearColor];
	}
}

%end

// 2. 设置标题时加粗文字，并触发 Taptic Engine 清脆震动
%hook PRXCardContentView

- (void)setTitleView:(id)titleView {
	%orig;
	if (titleView && [titleView respondsToSelector:@selector(text)] && [titleView respondsToSelector:@selector(setTitleText:)]) {
		id text = [titleView text];
		[(PGS_TitleViewStub *)titleView setTitleText:text];
	}
	// 每次弹窗配置标题时，精准触发线性马达轻微清脆震动！
	PGS_TriggerHapticFeedback();
}

%end

// 3. 永久声明支持深色模式
%hook PRXFlowConfiguration

- (void)setSupportsDarkMode:(BOOL)arg1 {
	%orig(YES);
}

- (BOOL)supportsDarkMode {
	return YES;
}

%end

%end

%dtor {
	if (g_unlock_token != 0) {
		notify_cancel(g_unlock_token);
		g_unlock_token = 0;
	}
	if (settings) {
		PGS_freeSettings(settings);
		settings = NULL;
	}
}

%ctor {
	char exec_path[512] = {0};
	uint32_t len = sizeof(exec_path);
	_NSGetExecutablePath(exec_path, &len);

	// 所有注入进程（含 Settings/设置、bluetoothd）都启用型号名称兜底
	%init(pidname_hook_grp);

	// 若处于弹窗渲染服务 (SharingViewService)，激活绝对 0 闪白深色模式与 Taptic Engine
	if (strstr(exec_path, "SharingViewService") != NULL) {
		%init(darkpods_hook_grp);
		return;
	}

	// 仅对非 bluetoothd 进程（如 sharingd, SpringBoard）初始化
	if (memcmp(exec_path, "/usr/sbin/bluetoothd", 21) != 0) {
		PGS_initOSVersion();
		reload_settings_if_needed();

		notify_register_dispatch("com.apple.mobile.keybagd.first_unlock", &g_unlock_token, dispatch_get_main_queue(), ^(int token) {
			reload_settings_if_needed();
		});

		%init(sharing_hook_grp);
	}
}
