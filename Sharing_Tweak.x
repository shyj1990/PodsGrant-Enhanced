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
// 型号名称兜底：AirPods 详情页（设置→蓝牙→ⓘ 的「关于」组）由 HeadphoneConfigs
// framework 的 BTSDeviceConfigController 渲染，「型号名称」行调用 -getModelName:。
// 诊断实测（v1.1.9~v1.2.0）：本机命中路径即此处，收到的 pid 是 PodsGrant 映射后的
// 目标值（8211），orig 为通用兜底名 "AirPods"，故需要映射反查 + 兜底名检测。
// ==============================================================================
static const struct { unsigned int pid; const char *name; } s_pid_display_names[] = {
	{8240, "AirPods 5（无线充电）"},
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

// PodsGrant 映射预设（对应 general.h 的 product_id_map_preset）：源设备 PID 会被
// 改写为目标 PID，因此系统内看到的设备 PID 是映射后的目标值（如 8211），
// 名称表里查不到——按目标 PID 反查映射源设备（首个命中）的显示名称。
// 诊断日志实测（v1.1.9）：HPS getModelName 收到的 pid=8211、orig=AirPods，
// 证实此路径需要反查 + 通用兜底名检测。
static const struct { unsigned int target_pid; unsigned int source_pid; } s_pid_mapping_presets[] = {
	{8211, 8240}, // AirPods 5（无线充电） -> AirPods 3（默认首选）
	{8211, 8246}, // AirPods 5 -> AirPods 3
	{8211, 8219}, // AirPods 4 ANC -> AirPods 3
	{0, 0},
};

static NSString *PGS_displayNameForMappedPid(int target_pid) {
	if (target_pid <= 0) return nil;
	for (int i = 0; s_pid_mapping_presets[i].target_pid; i++) {
		if ((unsigned int)target_pid == s_pid_mapping_presets[i].target_pid) {
			return PGS_displayNameForPid((int)s_pid_mapping_presets[i].source_pid);
		}
	}
	return nil;
}

// 系统的通用兜底名：查询失败时 UI 退化为 "AirPods"，
// 真实 AirPods 1/2 的合法型号名也是它（已知限制：会一并改名）。
static BOOL PGS_isGenericAirPodsName(id orig) {
	return [orig isKindOfClass:[NSString class]] && [(NSString *)orig isEqualToString:@"AirPods"];
}

// 私有类接口声明（仅供编译期解析，运行时仍为消息转发，行为不变）
@interface BTSDeviceConfigController : NSObject
@end

// ==============================================================================
// HeadphoneConfigs 兜底：AirPods 详情页（设置→蓝牙→ⓘ 的「关于」组）由
// HeadphoneConfigs.framework 的 BTSDeviceConfigController 渲染，「型号名称」
// 行调用 -getModelName:：按 key ACCESSORY_MODEL_NAME_<pid-0x2000> 查
// DeviceConfig 本地化表（各型号还有 DeviceConfig-B6xx 等专属表）。
// iOS 17 表中没有 8240/8246（key 缺失）→ 返回 nil。PID 命中下表且返回空时填充。
// ==============================================================================
%group headphoneconfigs_hook_grp

%hook BTSDeviceConfigController
- (id)getModelName:(id)a3 {
	id orig = %orig;
	unsigned int pid = 0;
	@try {
		id dev = [self valueForKey:@"device"]; // KVC 命中 ivar _device
		id classic = nil;
		if ([dev respondsToSelector:@selector(classicDevice)]) {
			classic = ((id (*)(id, SEL))objc_msgSend)(dev, @selector(classicDevice));
		}
		if (classic && [classic respondsToSelector:@selector(productId)]) {
			pid = ((unsigned int (*)(id, SEL))objc_msgSend)(classic, @selector(productId));
		}
	} @catch (NSException *e) {}
	NSString *name = PGS_displayNameForPid((int)pid);
	if (!name) {
		// PID 已被 PodsGrant 映射改写（实测 pid=8211）：反查映射源设备名称
		name = PGS_displayNameForMappedPid((int)pid);
	}
	NSString *result = orig;
	// 查询失败判定：返回空/极短，或恰为系统通用兜底名 "AirPods"（v1.1.9 日志实测 orig=AirPods）
	BOOL missed = (orig == nil) ||
		(![orig isKindOfClass:[NSString class]]) ||
		([(NSString *)orig length] <= 1) ||
		PGS_isGenericAirPodsName(orig);
	if (name && missed) {
		result = name;
	}
	return result;
}
%end

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

	// 仅设置进程：HeadphoneConfigs 关于页「型号名称」兜底（实测唯一有效路径）
	if (strstr(exec_path, "Preferences") != NULL) {
		if (NSClassFromString(@"BTSDeviceConfigController")) {
			%init(headphoneconfigs_hook_grp);
		}
	}

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
