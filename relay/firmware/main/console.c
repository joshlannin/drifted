// Line commands, over USB serial (setup: Wi-Fi, token) and over the network (scan, select, …).
// Every serial command ends with a line "ok …" or "error: …", which relay/setup.py waits for.
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "relay.h"

static void restart_soon(void *arg) { esp_restart(); }

static void schedule_restart(void) {
    static esp_timer_handle_t t;
    esp_timer_create_args_t a = {.callback = restart_soon, .name = "restart"};
    if (!t) esp_timer_create(&a, &t);
    esp_timer_start_once(t, 700 * 1000);
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = tolower((unsigned char)c);
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/// Decodes hex into `out` (NUL-terminated). setup.py sends values as hex so spaces and odd characters survive.
static bool unhex(const char *hex, char *out, size_t size) {
    size_t n = strlen(hex);
    if (n % 2 || n / 2 >= size) return false;
    for (size_t i = 0; i < n / 2; i++) {
        int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (char)(hi << 4 | lo);
    }
    out[n / 2] = 0;
    return true;
}

static bool set_value(const char *key, const char *value, char *msg, size_t msglen) {
    if (strcmp(key, "ssid") == 0) {
        if (!*value || strlen(value) > 32) { snprintf(msg, msglen, "ssid must be 1-32 bytes"); return false; }
        strlcpy(g_cfg.wifi_ssid, value, sizeof g_cfg.wifi_ssid);
    } else if (strcmp(key, "password") == 0) {
        if (strlen(value) > 64 || (*value && strlen(value) < 8)) { snprintf(msg, msglen, "password must be 8-64 characters (or empty for an open network)"); return false; }
        strlcpy(g_cfg.wifi_pass, value, sizeof g_cfg.wifi_pass);
    } else if (strcmp(key, "token") == 0) {
        if (strlen(value) < 16 || strlen(value) > 64) { snprintf(msg, msglen, "token must be 16-64 characters"); return false; }
        strlcpy(g_cfg.token, value, sizeof g_cfg.token);
    } else {
        snprintf(msg, msglen, "unknown setting %s (ssid, password, token)", key);
        return false;
    }
    if (!config_save()) { snprintf(msg, msglen, "couldn't save"); return false; }
    snprintf(msg, msglen, "%s saved%s", key, strcmp(key, "token") ? "; reboot to use it" : "");
    return true;
}

static void print_help(void) {
    printf("Drifted relay %s (%s)\n"
           "  show                         settings (secrets masked) and status\n"
           "  set ssid|password|token VAL  save a setting (sethex KEY HEX for exact bytes)\n"
           "  wifi-scan                    list Wi-Fi networks this relay can see (2.4 GHz only)\n"
           "  scan                         look for Drift tables (5 s)\n"
           "  select ADDRESS|NAME          use this table and remember it\n"
           "  forget                       forget the table; use the strongest Drift\n"
           "  release / connect            let go of the table (for the HoMedics app) / take it back\n"
           "  hold on|off                  keep the table linked while no host is connected (default on)\n"
           "  ota URL                      update firmware from an http(s) URL\n"
           "  reboot, erase (all settings), version, status\n",
           RELAY_FIRMWARE_VERSION, g_st.name);
}

static void show(void) {
    char tok[24] = "(not set)";
    size_t tl = strlen(g_cfg.token);
    if (tl) snprintf(tok, sizeof tok, "%.4s… (%u chars)", g_cfg.token, (unsigned)tl);
    char addr[18] = "";
    if (g_cfg.table_addr_set) addr_to_str(g_cfg.table_addr, addr);
    printf("name      %s\nfirmware  %s\nssid      %s\npassword  %s\ntoken     %s\ntable     %s %s\nhold      %s\n"
           "wifi      %s %s\nlink      %s\nhost      %s\n",
           g_st.name, RELAY_FIRMWARE_VERSION, g_cfg.wifi_ssid[0] ? g_cfg.wifi_ssid : "(not set)",
           g_cfg.wifi_pass[0] ? "(set)" : "(none)", tok, g_cfg.table_name[0] ? g_cfg.table_name : "(any)", addr,
           g_cfg.hold ? "on" : "off", g_st.wifi_up ? "up" : "down", g_st.ip, link_name(g_st.link),
           g_st.host_connected ? "connected" : "none");
}

static void wifi_scan(void) {
    wifi_scan_config_t sc = {0};
    if (esp_wifi_scan_start(&sc, true) != ESP_OK) { printf("error: Wi-Fi scan failed\n"); return; }
    uint16_t n = 20;
    static wifi_ap_record_t recs[20];
    esp_wifi_scan_get_ap_records(&n, recs);
    for (int i = 0; i < n; i++) printf("%4d dBm  ch %2d  %s\n", recs[i].rssi, recs[i].primary, (char *)recs[i].ssid);
    printf("ok %d networks\n", n);
}

cmd_result_t relay_command(const char *line, bool net, char *msg, size_t msglen) {
    char cmd[24] = "";
    msg[0] = 0;
    while (*line == ' ') line++;
    sscanf(line, "%23s", cmd);
    const char *arg = line + strlen(cmd);
    while (*arg == ' ') arg++;

    if (!cmd[0]) return CMD_PENDING;   // empty line: no answer
    if (strcmp(cmd, "version") == 0) { snprintf(msg, msglen, "drifted-relay %s", RELAY_FIRMWARE_VERSION); return CMD_OK; }
    if (strcmp(cmd, "status") == 0) {
        if (net) net_status_changed();
        else { static char s[1400]; net_status_json(s, sizeof s); printf("%s\n", s); }
        return CMD_OK;
    }
    if (strcmp(cmd, "scan") == 0) { ble_request_scan(net, !net); return CMD_PENDING; }
    if (strcmp(cmd, "select") == 0) return ble_select(arg, msg, msglen) ? CMD_OK : CMD_ERROR;
    if (strcmp(cmd, "forget") == 0) { ble_forget(); return CMD_OK; }
    if (strcmp(cmd, "release") == 0) { ble_set_released(true); return CMD_OK; }
    if (strcmp(cmd, "connect") == 0) {
        ble_set_released(false);
        if (net) ble_host_session_started();   // this connection becomes the host's: wait for a fresh handshake
        return CMD_OK;
    }
    if (strcmp(cmd, "hold") == 0) {
        if (strcmp(arg, "on") && strcmp(arg, "off")) { snprintf(msg, msglen, "hold on|off"); return CMD_ERROR; }
        g_cfg.hold = strcmp(arg, "on") == 0;
        config_save();
        ble_settings_changed();
        net_status_changed();
        snprintf(msg, msglen, "hold %s", arg);
        return CMD_OK;
    }
    // Answers at once ("downloading"); a second result follows when the update is written or fails.
    if (strcmp(cmd, "ota") == 0) return ota_start(arg, msg, msglen) ? CMD_OK : CMD_ERROR;
    if (strcmp(cmd, "reboot") == 0) { relay_log("restarting"); schedule_restart(); return CMD_OK; }

    // USB serial only: settings that could cut the relay off the network, and local diagnostics.
    if (net) { snprintf(msg, msglen, "%s isn't available over the network", cmd); return CMD_ERROR; }
    if (strcmp(cmd, "help") == 0) { print_help(); return CMD_OK; }
    if (strcmp(cmd, "show") == 0) { show(); return CMD_OK; }
    if (strcmp(cmd, "wifi-scan") == 0) { wifi_scan(); return CMD_PENDING; }
    if (strcmp(cmd, "erase") == 0) { config_erase(); snprintf(msg, msglen, "settings erased; restarting"); schedule_restart(); return CMD_OK; }
    if (strcmp(cmd, "set") == 0 || strcmp(cmd, "sethex") == 0) {
        char key[16] = "";
        sscanf(arg, "%15s", key);
        const char *value = arg + strlen(key);
        while (*value == ' ') value++;
        char decoded[80];
        if (strcmp(cmd, "sethex") == 0) {
            if (!unhex(value, decoded, sizeof decoded)) { snprintf(msg, msglen, "bad hex"); return CMD_ERROR; }
            value = decoded;
        }
        return set_value(key, value, msg, msglen) ? CMD_OK : CMD_ERROR;
    }
    snprintf(msg, msglen, "unknown command %s (try help)", cmd);
    return CMD_ERROR;
}

static void console_task(void *arg) {
    char line[256];
    size_t n = 0;
    for (;;) {
        uint8_t c;
        if (usb_serial_jtag_read_bytes(&c, 1, portMAX_DELAY) <= 0) continue;
        if (c == '\r' || c == '\n') {
            if (!n) continue;
            line[n] = 0;
            n = 0;
            char msg[200];
            cmd_result_t r = relay_command(line, false, msg, sizeof msg);
            if (r == CMD_OK) printf("ok%s%s\n", msg[0] ? " " : "", msg);
            else if (r == CMD_ERROR) printf("error: %s\n", msg);
            fflush(stdout);
        } else if (c == 8 || c == 127) {
            if (n) n--;
        } else if (n < sizeof line - 1) {
            line[n++] = (char)c;
        }
    }
}

void console_start(void) {
    usb_serial_jtag_driver_config_t cfg = {.rx_buffer_size = 1024, .tx_buffer_size = 1024};
    if (usb_serial_jtag_driver_install(&cfg) != ESP_OK) return;
    usb_serial_jtag_vfs_use_driver();
    setvbuf(stdout, NULL, _IONBF, 0);
    xTaskCreate(console_task, "console", 4096, NULL, 3, NULL);
}
