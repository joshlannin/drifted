// Drifted relay firmware: entry point and small shared helpers. See relay/README.md.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "nvs_flash.h"
#include "relay.h"

relay_state_t g_st;

const char *link_name(link_state_t s) {
    switch (s) {
    case LINK_OFF: return "off";
    case LINK_RELEASED: return "released";
    case LINK_IDLE: return "idle";
    case LINK_WAITING: return "waiting";
    case LINK_SCANNING: return "scanning";
    case LINK_CONNECTING: return "connecting";
    case LINK_LINKED: return "linked";
    }
    return "?";
}

/// NimBLE keeps addresses little-endian; people (and the protocol) write them most significant byte first.
void addr_to_str(const uint8_t a[6], char out[18]) {
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x", a[5], a[4], a[3], a[2], a[1], a[0]);
}

bool addr_from_str(const char *s, uint8_t a[6]) {
    unsigned v[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return false;
    for (int i = 0; i < 6; i++) a[5 - i] = (uint8_t)v[i];
    return true;
}

/// Logs to USB serial and to the connected host (it shows up in Drifted's log as "relay: …").
void relay_log(const char *fmt, ...) {
    char buf[200];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof buf) n = sizeof buf - 1;
    ESP_LOGI("relay", "%s", buf);
    net_send(MSG_LOG, buf, n);
}

void app_main(void) {
    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    config_load();
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(g_st.name, sizeof g_st.name, "drifted-relay-%02x%02x%02x", mac[3], mac[4], mac[5]);

    led_start();
    console_start();
    net_start();
    ble_start();

    printf("\nDrifted relay %s (%s). Type help for commands.\n", RELAY_FIRMWARE_VERSION, g_st.name);
    if (!config_ready()) printf("Not set up yet: run relay/setup.py on the computer this is plugged into.\n");
}
