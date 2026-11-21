// Drifted relay: holds the Bluetooth LE link to a HoMedics Drift table and passes its bytes to and from one
// host (Drifted) over TCP. See relay/README.md. MIT licence, like the rest of the repo.
#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RELAY_FIRMWARE_VERSION "0.2.1"
#define RELAY_PROTO 2   // 2: jobs (job.h)
#define RELAY_PORT 8766

// M5Stack NanoC6
#define PIN_RGB_DATA 20
#define PIN_RGB_POWER 19
#define PIN_BUTTON 9

// TCP messages: type:u8, length:u16 little-endian, payload (relay/README.md, "Relay protocol").
enum {
    MSG_HELLO = 0x01,        // host → relay: flags:u8, token
    MSG_WELCOME = 0x02,      // relay → host: JSON
    MSG_ERROR = 0x03,        // relay → host: JSON, then close
    MSG_TABLE_DATA = 0x10,   // relay → host: table notification bytes
    MSG_TABLE_WRITE = 0x11,  // host → relay: one table packet
    MSG_STATUS = 0x20,       // relay → host: JSON
    MSG_SCAN = 0x21,         // relay → host: JSON scan results
    MSG_COMMAND = 0x30,      // host → relay: command line
    MSG_RESULT = 0x31,       // relay → host: JSON
    MSG_LOG = 0x40,          // relay → host: log line
    // 0x50-0x5A: jobs (job.h)
};
#define MAX_PAYLOAD 4096
#define HELLO_FLAG_OBSERVE 0x01

// ---- Settings (NVS) ----
typedef struct {
    char wifi_ssid[33];
    char wifi_pass[65];
    char token[65];
    char table_name[32];      // remembered table, by name (from `select NAME`, or the table we linked to)
    uint8_t table_addr[6];    // remembered table, by address (little-endian, as NimBLE stores it)
    uint8_t table_addr_type;
    bool table_addr_set;
    bool hold;                // keep the table linked while no host is connected (default on)
} relay_config_t;

extern relay_config_t g_cfg;
void config_load(void);
bool config_save(void);
void config_erase(void);
bool config_ready(void);      // Wi-Fi and token set

// ---- Shared runtime state ----
typedef enum { LINK_OFF, LINK_RELEASED, LINK_IDLE, LINK_WAITING, LINK_SCANNING, LINK_CONNECTING, LINK_LINKED } link_state_t;

typedef struct {
    volatile bool wifi_up;
    volatile bool server_up;
    char ip[16];
    char name[24];                 // drifted-relay-xxxxxx (hostname, Bonjour name)
    volatile link_state_t link;
    volatile bool released;
    volatile bool host_connected;  // an authenticated client
    volatile bool gate_open;       // host writes pass to the table (after the table's 0x50/1)
    volatile bool ota_running;
    volatile bool button_held;
    volatile int8_t table_rssi;
    volatile bool table_rssi_valid;
    volatile uint16_t mtu;
    char table_name[32];           // the table we're linked or linking to
    uint8_t table_addr[6];
    uint8_t table_addr_type;
    volatile bool table_known;
    // counters
    volatile uint32_t notify_bytes, writes, dropped_gate, dropped_full, paced, handshakes, max_page_gap_ms, keepalives;
    volatile uint32_t unstuck, wifi_drops, wifi_last_reason, host_sessions, send_fails;
} relay_state_t;

extern relay_state_t g_st;

const char *link_name(link_state_t s);
void addr_to_str(const uint8_t addr[6], char out[18]);
bool addr_from_str(const char *s, uint8_t addr[6]);
void relay_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// ---- Bluetooth (ble.c) ----
void ble_start(void);
void ble_write_enqueue(const uint8_t *data, size_t len);
void ble_host_session_started(void);   // a host connected: hold its writes until the table's next handshake request
void ble_host_session_ended(void);
void ble_request_scan(bool for_host, bool for_console);
bool ble_select(const char *arg, char *msg, size_t msglen);
void ble_forget(void);
void ble_set_released(bool released);
void ble_settings_changed(void);
int ble_scan_json(char *out, size_t outlen);
// For a job (job_glue.c): the table link is the job's from link_up until link_down(true).
bool ble_job_link_up(int timeout_ms);
void ble_job_link_down(bool done);
bool ble_job_write(const uint8_t *packet, size_t len);
int ble_job_recv(uint8_t *buf, size_t max, int timeout_ms);

// ---- Network (net.c) ----
void net_start(void);
void net_send(uint8_t type, const void *data, size_t len);
void net_status_changed(void);
int net_status_json(char *out, size_t outlen);
void net_result(const char *command, bool ok, const char *message, const char *extra_json);

// ---- Commands (console.c): shared by USB serial and the network ----
typedef enum { CMD_OK, CMD_ERROR, CMD_PENDING } cmd_result_t;
cmd_result_t relay_command(const char *line, bool from_network, char *msg, size_t msglen);
void console_start(void);

// ---- Jobs (job.c is the engine; job_glue.c gives it Bluetooth, flash and the network) ----
void jobs_start(void);
void jobs_frame(uint8_t type, const uint8_t *payload, size_t len);   // a MSG_JOB_* message from the host

// ---- LED and button (led.c) ----
void led_start(void);

// ---- OTA (ota.c) ----
bool ota_start(const char *url, char *msg, size_t msglen);
void ota_mark_valid_if_healthy(void);
