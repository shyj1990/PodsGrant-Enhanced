#pragma once
#include <stdint.h>
#include <stdio.h>

struct address_map_entry {
	unsigned char version_major;
	unsigned char version_minor;
	unsigned char version_patch;
	unsigned int product_id_offset;
	uint64_t first_hook_addr;
	uint64_t ability_func_addr;
	uint64_t support_remote_volume_change_addr;
	uint64_t recv_logging_handler_addr;
};

struct product_id_map_entry_custom {
	uint16_t original;
	uint16_t target;
};

struct product_id_map_entry {
	uint16_t original;
	uint16_t target;
	uint8_t  minimum_ios;
	uint8_t  maximum_ios;
	// [minimum_ios, maximum_ios] 闭区间
};

// 预设产品映射表（映射规则同步自 shyj1990/PodsGrant-IOS17-Airpods4-ANC-RootHide）
static const struct product_id_map_entry product_id_map_preset[] = {
	// 映射表按顺序首个命中即返回；目标 ID 不得再出现在本表 original 列（避免二次改写）
	{8240, 8211, 0, 255}, // AirPods 5 (Wireless Charging Case) → AirPods 3（默认首选）
	{8240, 8212, 0, 255}, // AirPods 5 (Wireless Charging Case) → AirPods Pro 2 Lightning（备用；仅当上面的 8211 条目删除后才生效）
	{8246, 8211, 0, 255}, // AirPods 5 → AirPods 3
	{8219, 8211, 0, 255}, // AirPods 4 ANC → AirPods 3
	{0, 0, 0, 0}
};

struct podsgrant_settings {
	uint8_t is_tweak_enabled;
	uint8_t is_managed_structure;
	struct product_id_map_entry_custom *product_id_mapping;
	struct address_map_entry *address_mapping;
	uint8_t product_id_mapping_cnt;
	uint8_t address_mapping_cnt;
};

#define NSSTR(a) @a
#define PGS_SETTINGS_FILE "/var/mobile/Library/Preferences/com.lns.pogr.bin"

extern unsigned char PGS_global_os_ver;

// 初始化系统版本号（保证各进程均能获取真实系统版本）
void PGS_initOSVersion(void);

// 查询并替换产品 PID
uint16_t PGS_patchProductId(struct podsgrant_settings *conf, uint16_t original);

// 配置存储与管理
int PGS_saveSettings(struct podsgrant_settings *configuration);
struct podsgrant_settings *PGS_readSettings_to(struct podsgrant_settings *configuration, int read_full_anyway);
struct podsgrant_settings *PGS_readSettings(int read_full_anyway);
void PGS_freeSettings(struct podsgrant_settings *conf);

// 动态汇编指令掩码地址解算
int PGS_findAddresses(uint64_t *addresses, uint32_t *pid_offset);
