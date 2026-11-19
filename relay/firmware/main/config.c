// Settings in NVS. Secrets (Wi-Fi password, token) are set over USB serial (relay/setup.py), never compiled in.
#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "relay.h"

static const char *TAG = "config";
relay_config_t g_cfg;

static void get_str(nvs_handle_t h, const char *key, char *out, size_t size) {
    size_t len = size;
    if (nvs_get_str(h, key, out, &len) != ESP_OK) out[0] = 0;
}

void config_load(void) {
    memset(&g_cfg, 0, sizeof g_cfg);
    g_cfg.hold = true;
    nvs_handle_t h;
    if (nvs_open("relay", NVS_READONLY, &h) != ESP_OK) return;   // nothing saved yet
    get_str(h, "ssid", g_cfg.wifi_ssid, sizeof g_cfg.wifi_ssid);
    get_str(h, "pass", g_cfg.wifi_pass, sizeof g_cfg.wifi_pass);
    get_str(h, "token", g_cfg.token, sizeof g_cfg.token);
    get_str(h, "tname", g_cfg.table_name, sizeof g_cfg.table_name);
    size_t len = 7;
    uint8_t addr[7];
    if (nvs_get_blob(h, "taddr", addr, &len) == ESP_OK && len == 7) {
        memcpy(g_cfg.table_addr, addr, 6);
        g_cfg.table_addr_type = addr[6];
        g_cfg.table_addr_set = true;
    }
    uint8_t hold = 1;
    if (nvs_get_u8(h, "hold", &hold) == ESP_OK) g_cfg.hold = hold != 0;
    nvs_close(h);
}

bool config_save(void) {
    nvs_handle_t h;
    if (nvs_open("relay", NVS_READWRITE, &h) != ESP_OK) return false;
    esp_err_t e = ESP_OK;
    e |= nvs_set_str(h, "ssid", g_cfg.wifi_ssid);
    e |= nvs_set_str(h, "pass", g_cfg.wifi_pass);
    e |= nvs_set_str(h, "token", g_cfg.token);
    e |= nvs_set_str(h, "tname", g_cfg.table_name);
    if (g_cfg.table_addr_set) {
        uint8_t addr[7];
        memcpy(addr, g_cfg.table_addr, 6);
        addr[6] = g_cfg.table_addr_type;
        e |= nvs_set_blob(h, "taddr", addr, 7);
    } else {
        nvs_erase_key(h, "taddr");
    }
    e |= nvs_set_u8(h, "hold", g_cfg.hold ? 1 : 0);
    e |= nvs_commit(h);
    nvs_close(h);
    if (e != ESP_OK) ESP_LOGE(TAG, "saving settings failed");
    return e == ESP_OK;
}

void config_erase(void) {
    nvs_handle_t h;
    if (nvs_open("relay", NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_all(h);
        nvs_commit(h);
        nvs_close(h);
    }
    config_load();
}

bool config_ready(void) { return g_cfg.wifi_ssid[0] && strlen(g_cfg.token) >= 16; }
