// Bluetooth LE central (NimBLE): finds the table, keeps one connection to it, subscribes to FFE4, writes FFE9.
//
// The relay is a pipe: it never answers the table itself. Two small exceptions, both about timing, not content:
// - The gate: when a host connects, its writes are held back until the table next asks for a handshake (0x50/1).
//   The table resets its session after about 2 s without host frames, so a returning host always starts with a
//   fresh handshake (and its init dump: stored pattern ids, state), as it would over its own Bluetooth.
// - Page pacing: Wi-Fi can deliver several pattern pages at once; pages sent 1 ms apart make the table drop the
//   session (docs/failure-modes.md), so pages (0x53) go to the table at least 80 ms apart.
// And one about a table that is stuck: see table_packet().
//
// A job (job.h) is different: while one runs the link is the job's, the host's writes are dropped, and the job
// answers the table itself.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/message_buffer.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "relay.h"

static const char *TAG = "ble";

#define SVC_UUID 0xFFE0
#define WRITE_UUID 0xFFE9
#define NOTIFY_UUID 0xFFE4
#define MIN_PAGE_GAP_MS 80
// With a host connected, write ConfirmData ourselves after this long without a host write. Wi-Fi now and then
// holds the table's packets back for 2 s or more (a lost frame waiting on a TCP retransmit), the host then
// has nothing to answer, and the table resets the session after 2 s of silence.
#define KEEPALIVE_MS 1000
#define MIN_CONN_ITVL 24   // 1.25 ms units: 30 ms
#define GATE_TIMEOUT_MS 8000
#define UNSTICK_AFTER_MS 3000
#define CONNECT_TIMEOUT_MS 10000
#define SCAN_MS 5000
#define BACKOFF_MIN_MS 1000
#define BACKOFF_MAX_MS 30000
#define NO_HOST_RELEASE_MS 30000
#define RSSI_EVERY_MS 3000
#define MAX_CANDIDATES 16

typedef enum { PH_OFF, PH_IDLE, PH_SCANNING, PH_CONNECTING, PH_DISCOVERING, PH_LINKED, PH_DISCONNECTING } phase_t;

typedef struct {
    ble_addr_t addr;
    char name[32];
    int8_t rssi;
    bool drift;
} candidate_t;

static volatile phase_t s_phase = PH_OFF;
static uint8_t s_own_addr_type;
static volatile uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_svc_start, s_svc_end, s_write_handle, s_notify_handle, s_cccd_handle;
static uint8_t s_write_props;
static bool s_dsc_past_chr;

static candidate_t s_cands[MAX_CANDIDATES];
static int s_ncands, s_heard, s_scan_rsps;   // Drift candidates; reports heard this scan; scan responses among them
static SemaphoreHandle_t s_lock;

static volatile bool s_disc_active, s_report_host, s_report_console;
static int64_t s_next_attempt_us, s_linked_at_us, s_gate_closed_at_us, s_host_left_at_us, s_last_rssi_us;
static volatile int64_t s_last_unstick_us;
static volatile bool s_unstick;          // the writer task should answer the table with ConfirmData (table_packet)
static volatile bool s_job_active;       // a job has the table (ble_job_link_up … ble_job_link_down(true))
static volatile unsigned s_link_gen;     // counts links that came up
static MessageBufferHandle_t s_job_rx;   // the table's notifications, for the job
static uint32_t s_backoff_ms = BACKOFF_MIN_MS;
static int s_failures;
static volatile int64_t s_last_write_us;   // last packet written to the table (host's or a keepalive)
static ble_addr_t s_target;
static volatile bool s_target_set, s_restart_link, s_reconnect_now;

static TaskHandle_t s_ctl_task;
static MessageBufferHandle_t s_writes;
static SemaphoreHandle_t s_write_done;
static volatile int s_write_status;

static uint8_t s_rx[600];   // table packet reassembly, only to spot 0x50/1 (host task only)
static size_t s_rx_len;

static int64_t now_us(void) { return esp_timer_get_time(); }
static void kick(void) {
    if (s_ctl_task) xTaskNotifyGive(s_ctl_task);
}

static void set_link(link_state_t l) {
    if (g_st.link == l) return;
    g_st.link = l;
    net_status_changed();
}

// ---- Scan results ----

static void trim(char *s) {
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\r' || s[n - 1] == '\n' || s[n - 1] == ' ' || s[n - 1] == 0)) s[--n] = 0;
}

static void add_report(const ble_addr_t *addr, int8_t rssi, const uint8_t *data, uint8_t len) {
    // Walk the advertising data by hand rather than with ble_hs_adv_parse_fields, which rejects the whole
    // report if any field is malformed. Tables put their name ("KS…\r\n\r\n") only in the scan response,
    // and take what fits if a length runs past the end.
    char name[32] = "";
    bool ffe0 = false;
    for (int i = 0; i + 1 < len;) {
        int flen = data[i];
        if (flen == 0) break;
        int type = data[i + 1];
        const uint8_t *v = data + i + 2;
        int vlen = flen - 1;
        if (i + 1 + flen > len) vlen = len - i - 2;
        if (vlen < 0) break;
        if ((type == 0x08 || type == 0x09) && vlen > 0) {
            size_t n = (size_t)vlen < sizeof name - 1 ? (size_t)vlen : sizeof name - 1;
            memcpy(name, v, n);
            name[n] = 0;
            trim(name);
        } else if (type == 0x02 || type == 0x03) {
            for (int k = 0; k + 1 < vlen; k += 2)
                if ((v[k] | (v[k + 1] << 8)) == SVC_UUID) ffe0 = true;
        }
        i += 1 + flen;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    candidate_t *c = NULL;
    for (int i = 0; i < s_ncands; i++)
        if (ble_addr_cmp(&s_cands[i].addr, addr) == 0) c = &s_cands[i];
    // Only Drifts get a slot: a home's phones, earbuds and other gadgets would fill the list in a second and
    // crowd the table out. Its name may come only in the scan response, which carries the same address.
    bool drift = ffe0 || strncmp(name, "KS", 2) == 0;
    if (!c) s_heard++;
    if (!c && drift && s_ncands < MAX_CANDIDATES) {
        c = &s_cands[s_ncands++];
        memset(c, 0, sizeof *c);
        c->addr = *addr;
    }
    if (c) {
        c->rssi = rssi;
        if (name[0]) strlcpy(c->name, name, sizeof c->name);
        if (ffe0 || strncmp(c->name, "KS", 2) == 0) c->drift = true;
    }
    xSemaphoreGive(s_lock);
}

static void json_str(char *out, size_t len, const char *s) {
    size_t o = 0;
    if (len < 3) return;
    out[o++] = '"';
    for (; *s && o + 7 < len; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') { out[o++] = '\\'; out[o++] = ch; }
        else if (ch < 0x20) o += snprintf(out + o, len - o, "\\u%04x", ch);
        else out[o++] = ch;
    }
    out[o++] = '"';
    out[o] = 0;
}

int ble_scan_json(char *out, size_t outlen) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    // Strongest first.
    int order[MAX_CANDIDATES], n = 0;
    for (int i = 0; i < s_ncands; i++)
        if (s_cands[i].drift) order[n++] = i;
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && s_cands[order[j]].rssi > s_cands[order[j - 1]].rssi; j--) {
            int t = order[j]; order[j] = order[j - 1]; order[j - 1] = t;
        }
    int o = snprintf(out, outlen, "{\"tables\":[");
    for (int k = 0; k < n && o < (int)outlen - 120; k++) {
        candidate_t *c = &s_cands[order[k]];
        char addr[18], name[70];
        addr_to_str(c->addr.val, addr);
        json_str(name, sizeof name, c->name);
        o += snprintf(out + o, outlen - o, "%s{\"name\":%s,\"address\":\"%s\",\"addrType\":%d,\"rssi\":%d}",
                      k ? "," : "", name, addr, c->addr.type, c->rssi);
    }
    o += snprintf(out + o, outlen - o, "]}");
    xSemaphoreGive(s_lock);
    return o;
}

/// Picks the table to connect to from the last scan: the remembered name, else the strongest Drift.
static bool choose_target(void) {
    bool found = false;
    int8_t best = -128;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (int i = 0; i < s_ncands; i++) {
        candidate_t *c = &s_cands[i];
        if (g_cfg.table_name[0]) {
            if (strcasecmp(c->name, g_cfg.table_name) == 0) { s_target = c->addr; found = true; break; }
        } else if (c->drift && c->rssi > best) {
            best = c->rssi;
            s_target = c->addr;
            found = true;
        }
    }
    for (int i = 0; i < s_ncands; i++) {
        if (!s_cands[i].drift) continue;
        char addr[18];
        addr_to_str(s_cands[i].addr.val, addr);
        relay_log("found %s (%s) at %d dBm", s_cands[i].name[0] ? s_cands[i].name : "(unnamed)", addr, s_cands[i].rssi);
    }
    xSemaphoreGive(s_lock);
    return found;
}

static void name_for(const ble_addr_t *a, char *out, size_t len) {
    out[0] = 0;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (int i = 0; i < s_ncands; i++)
        if (ble_addr_cmp(&s_cands[i].addr, a) == 0) strlcpy(out, s_cands[i].name, len);
    xSemaphoreGive(s_lock);
    if (!out[0] && g_cfg.table_addr_set && memcmp(a->val, g_cfg.table_addr, 6) == 0) strlcpy(out, g_cfg.table_name, len);
}

// ---- Discovery ----

static void report_scan(void) {
    static char buf[1400], fields[1400];
    int n = ble_scan_json(buf, sizeof buf);
    if (s_report_host) {
        net_send(MSG_SCAN, buf, n);
        // The result carries the tables too ({"command":"scan","ok":true,"tables":[…]}), so a caller waiting
        // for the "scan" result needs nothing else.
        snprintf(fields, sizeof fields, "%.*s", n - 2, buf + 1);
        net_result("scan", true, NULL, fields);
    }
    if (s_report_console) printf("%s\nok\n", buf);
    s_report_host = s_report_console = false;
}

static void disc_complete(void) {
    s_disc_active = false;
    if (s_report_host || s_report_console) report_scan();
    if (s_phase == PH_SCANNING) {
        s_phase = PH_IDLE;
        if (choose_target()) {
            s_target_set = true;
            s_next_attempt_us = 0;
        } else {
            relay_log(g_cfg.table_name[0] ? "table %s not found (%d adverts from other devices, %d scan responses); trying again in %lu s"
                                          : "no Drift table found%s (%d adverts from other devices, %d scan responses); trying again in %lu s",
                      g_cfg.table_name, s_heard, s_scan_rsps, (unsigned long)(s_backoff_ms / 1000));
            s_next_attempt_us = now_us() + (int64_t)s_backoff_ms * 1000;
            s_backoff_ms = s_backoff_ms * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : s_backoff_ms * 2;
        }
    }
    kick();
}

static int disc_event(struct ble_gap_event *ev, void *arg) {
    switch (ev->type) {
    case BLE_GAP_EVENT_DISC:
        if (ev->disc.event_type == BLE_HCI_ADV_RPT_EVTYPE_SCAN_RSP) s_scan_rsps++;
        add_report(&ev->disc.addr, ev->disc.rssi, ev->disc.data, ev->disc.length_data);
        break;
#if MYNEWT_VAL(BLE_EXT_ADV)
    case BLE_GAP_EVENT_EXT_DISC:
        add_report(&ev->ext_disc.addr, ev->ext_disc.rssi, ev->ext_disc.data, ev->ext_disc.length_data);
        break;
#endif
    case BLE_GAP_EVENT_DISC_COMPLETE:
        disc_complete();
        break;
    default:
        break;
    }
    return 0;
}

static int start_disc(void) {
    // 30% duty: leaves the shared radio to Wi-Fi most of the time.
    struct ble_gap_disc_params p = {.itvl = 160, .window = 48, .filter_policy = 0, .limited = 0, .passive = 0, .filter_duplicates = 0};
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_ncands = 0;
    s_heard = 0;
    s_scan_rsps = 0;
    xSemaphoreGive(s_lock);
    int rc = ble_gap_disc(s_own_addr_type, SCAN_MS, &p, disc_event, NULL);
    if (rc == 0) s_disc_active = true;
    else ESP_LOGW(TAG, "scan failed to start: %d", rc);
    return rc;
}

// ---- Connection ----

static void attempt_failed(const char *why) {
    s_failures++;
    relay_log("%s; retrying in %lu s", why, (unsigned long)(s_backoff_ms / 1000));
    s_phase = PH_IDLE;
    s_next_attempt_us = now_us() + (int64_t)s_backoff_ms * 1000;
    s_backoff_ms = s_backoff_ms * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : s_backoff_ms * 2;
    // A table found by scanning that keeps failing may be gone; look again (a remembered address is kept).
    if (s_failures >= 3 && !g_cfg.table_addr_set) s_target_set = false;
    g_st.table_known = false;
    kick();
}

static void link_fail(uint16_t conn, const char *why) {
    relay_log("setting up the table link failed: %s", why);
    ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
}

static void linked(uint16_t conn) {
    s_phase = PH_LINKED;
    s_linked_at_us = s_gate_closed_at_us = now_us();
    s_backoff_ms = BACKOFF_MIN_MS;
    s_failures = 0;
    s_rx_len = 0;
    s_last_unstick_us = 0;
    s_link_gen++;
    g_st.gate_open = false;
    g_st.mtu = ble_att_mtu(conn);
    // Remember the table we linked to (the strongest, or the one chosen over the network).
    if (!g_cfg.table_addr_set || memcmp(g_cfg.table_addr, g_st.table_addr, 6) != 0 || strcmp(g_cfg.table_name, g_st.table_name) != 0) {
        memcpy(g_cfg.table_addr, g_st.table_addr, 6);
        g_cfg.table_addr_type = g_st.table_addr_type;
        g_cfg.table_addr_set = true;
        if (g_st.table_name[0]) strlcpy(g_cfg.table_name, g_st.table_name, sizeof g_cfg.table_name);
        config_save();
    }
    char addr[18];
    addr_to_str(g_st.table_addr, addr);
    relay_log("linked to %s (%s), MTU %u; notifications on", g_st.table_name[0] ? g_st.table_name : "table", addr, g_st.mtu);
    // Status goes out before any table bytes from this link (the tx task sends a pending status first).
    set_link(LINK_LINKED);
    kick();
}

static int cccd_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status == 0) linked(conn);
    else link_fail(conn, "couldn't enable notifications");
    return 0;
}

static int dsc_found(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0) {
        uint16_t u = ble_uuid_u16(&dsc->uuid.u);
        if (u == BLE_ATT_UUID_CHARACTERISTIC) s_dsc_past_chr = true;   // next characteristic: stop looking
        else if (u == BLE_GATT_DSC_CLT_CFG_UUID16 && !s_dsc_past_chr && !s_cccd_handle) s_cccd_handle = dsc->handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE) { link_fail(conn, "descriptor discovery failed"); return 0; }
    if (!s_cccd_handle) s_cccd_handle = s_notify_handle + 1;   // the usual layout
    static const uint8_t on[2] = {0x01, 0x00};
    if (ble_gattc_write_flat(conn, s_cccd_handle, on, sizeof on, cccd_written, NULL) != 0) link_fail(conn, "CCCD write");
    return 0;
}

static int chr_found(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0) {
        uint16_t u = ble_uuid_u16(&chr->uuid.u);
        if (u == WRITE_UUID) { s_write_handle = chr->val_handle; s_write_props = chr->properties; }
        if (u == NOTIFY_UUID) s_notify_handle = chr->val_handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE) { link_fail(conn, "characteristic discovery failed"); return 0; }
    if (!s_write_handle || !s_notify_handle) { link_fail(conn, "FFE9/FFE4 not found"); return 0; }
    s_dsc_past_chr = false;
    if (ble_gattc_disc_all_dscs(conn, s_notify_handle, s_svc_end, dsc_found, NULL) != 0) link_fail(conn, "descriptor discovery");
    return 0;
}

static int svc_found(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *svc, void *arg) {
    if (error->status == 0) {
        s_svc_start = svc->start_handle;
        s_svc_end = svc->end_handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE || !s_svc_start) { link_fail(conn, "Drift service FFE0 not found"); return 0; }
    if (ble_gattc_disc_all_chrs(conn, s_svc_start, s_svc_end, chr_found, NULL) != 0) link_fail(conn, "characteristic discovery");
    return 0;
}

static int mtu_done(uint16_t conn, const struct ble_gatt_error *error, uint16_t mtu, void *arg) {
    if (error->status == 0) g_st.mtu = mtu;
    if (ble_gattc_disc_svc_by_uuid(conn, BLE_UUID16_DECLARE(SVC_UUID), svc_found, NULL) != 0) link_fail(conn, "service discovery");
    return 0;
}

// ---- Table bytes ----

static void table_packet(uint8_t cmd, bool ack, int action) {
    if (!ack && cmd == 0x50 && action == 1) {
        g_st.handshakes++;
        if (g_st.host_connected && !g_st.gate_open) {
            g_st.gate_open = true;
            s_last_write_us = now_us();   // give the host a full second to answer before any keepalive
            relay_log("table asked for a handshake; passing the host's writes on");
            net_status_changed();
        }
        return;
    }
    // A table left half-way through an earlier init dump (a handshake cut short) repeats the message it wants
    // answered, on every new link, and never asks for a handshake again. The gate would keep the host's answers
    // back for ever. So when a host has waited a few seconds and the table sends list messages instead of a
    // handshake request, answer them here. The dump runs to its end, the table hears nothing more, resets its
    // session after 2 s and asks for a handshake as usual. (Running state and alarms are left alone: answering
    // those would keep the old session alive.)
    if (g_st.host_connected && !g_st.gate_open && !ack && cmd >= 0x30 && cmd <= 0x38 && cmd != 0x35 && cmd != 0x37) {
        int64_t since = s_gate_closed_at_us > s_linked_at_us ? s_gate_closed_at_us : s_linked_at_us;
        if (s_last_unstick_us || now_us() - since > UNSTICK_AFTER_MS * 1000LL) {
            if (!s_last_unstick_us) relay_log("the table is half-way through an old handshake (repeating 0x%02x/%d); answering it so it can start over", cmd, action);
            s_last_unstick_us = now_us();
            s_unstick = true;   // the writer task sends it (this is the Bluetooth host's task)
        }
    }
}

/// Reassembles table packets (same framing rules as DriftedKit's PacketParser) just far enough to see commands.
static void watch_table_bytes(const uint8_t *d, size_t n) {
    if (s_rx_len + n > sizeof s_rx) s_rx_len = 0;
    if (n > sizeof s_rx) return;
    memcpy(s_rx + s_rx_len, d, n);
    s_rx_len += n;
    size_t off = 0;
    while (s_rx_len - off >= 2) {
        if (s_rx[off] != 0x7B) { off++; continue; }
        uint8_t len = s_rx[off + 1];
        if (len < 4) { off++; continue; }
        if (s_rx_len - off < len) break;
        uint8_t sum = 0;
        for (int i = 0; i < len - 1; i++) sum += s_rx[off + i];
        uint8_t ack_cmd = s_rx[off + 2];
        uint8_t alt = sum - ack_cmd + (ack_cmd & 0x7F);
        uint8_t check = s_rx[off + len - 1];
        if (sum == check || alt == check) {
            table_packet(ack_cmd & 0x7F, (ack_cmd & 0x80) != 0, len > 4 ? s_rx[off + 3] : -1);
            off += len;
        } else {
            off++;
        }
    }
    memmove(s_rx, s_rx + off, s_rx_len - off);
    s_rx_len -= off;
}

static int gap_event(struct ble_gap_event *ev, void *arg) {
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            s_conn = ev->connect.conn_handle;
            s_phase = PH_DISCOVERING;
            struct ble_gap_conn_desc d;
            if (ble_gap_conn_find(s_conn, &d) == 0) relay_log("connected; interval %u ms", d.conn_itvl * 5 / 4);
            s_svc_start = s_svc_end = s_write_handle = s_notify_handle = s_cccd_handle = 0;
            s_write_props = 0;
            if (ble_gattc_exchange_mtu(s_conn, mtu_done, NULL) != 0) mtu_done(s_conn, &(struct ble_gatt_error){.status = 1}, 23, NULL);
        } else {
            char why[48];
            snprintf(why, sizeof why, "couldn't connect (%d)", ev->connect.status);
            attempt_failed(why);
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT: {
        bool was_linked = s_phase == PH_LINKED;
        int64_t linked_for = now_us() - s_linked_at_us;
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        g_st.gate_open = false;
        g_st.table_rssi_valid = false;
        g_st.mtu = 0;
        relay_log("table link closed (reason 0x%03x)%s", ev->disconnect.reason, was_linked ? "" : " before it was ready");
        if (s_reconnect_now || (was_linked && linked_for > 60 * 1000000LL)) {
            s_reconnect_now = false;
            s_phase = PH_IDLE;
            s_backoff_ms = BACKOFF_MIN_MS;
            s_next_attempt_us = now_us() + 500 * 1000;
            kick();
        } else if (s_phase == PH_DISCONNECTING) {
            s_phase = PH_IDLE;
            kick();
        } else {
            attempt_failed("table link lost");
        }
        net_status_changed();
        break;
    }
    case BLE_GAP_EVENT_NOTIFY_RX:
        if (ev->notify_rx.attr_handle == s_notify_handle) {
            static uint8_t buf[600];
            uint16_t n = 0;
            if (ble_hs_mbuf_to_flat(ev->notify_rx.om, buf, sizeof buf, &n) == 0 && n) {
                g_st.notify_bytes += n;
                if (s_job_active) {
                    if (xMessageBufferSend(s_job_rx, buf, n, 0) != n) g_st.dropped_full++;
                } else {
                    watch_table_bytes(buf, n);   // first, so the gate is open before the host can answer
                    net_send(MSG_TABLE_DATA, buf, n);
                }
            }
        }
        break;
    case BLE_GAP_EVENT_CONN_UPDATE_REQ:
    case BLE_GAP_EVENT_L2CAP_UPDATE_REQ: {
        // The table may ask for a faster connection interval. Bluetooth then takes the shared radio so often
        // that Wi-Fi drops packets (seen: 7-10% ping loss while linked, none while released), so keep it at
        // 30 ms or slower. The table's traffic is a few small packets a second, which this carries easily.
        const struct ble_gap_upd_params *peer = ev->conn_update_req.peer_params;
        struct ble_gap_upd_params *self = ev->conn_update_req.self_params;
        *self = *peer;
        if (self->itvl_min < MIN_CONN_ITVL) self->itvl_min = MIN_CONN_ITVL;
        if (self->itvl_max < self->itvl_min) self->itvl_max = self->itvl_min;
        relay_log("table asked for a %u-%u ms connection interval; using %u-%u ms", peer->itvl_min * 5 / 4,
                  peer->itvl_max * 5 / 4, self->itvl_min * 5 / 4, self->itvl_max * 5 / 4);
        return 0;
    }
    case BLE_GAP_EVENT_CONN_UPDATE: {
        struct ble_gap_conn_desc d;
        if (ev->conn_update.status == 0 && ble_gap_conn_find(ev->conn_update.conn_handle, &d) == 0)
            relay_log("connection interval now %u ms", d.conn_itvl * 5 / 4);
        return 0;
    }
    case BLE_GAP_EVENT_MTU:
        g_st.mtu = ev->mtu.value;
        break;
    default:
        break;
    }
    return 0;
}

static void connect_to(const ble_addr_t *a) {
    struct ble_gap_conn_params p = {
        .scan_itvl = 96, .scan_window = 48,     // 60 / 30 ms
        .itvl_min = 24, .itvl_max = 40,          // 30-50 ms connection interval
        .latency = 0,
        .supervision_timeout = 400,              // 4 s: tolerant of Wi-Fi taking the radio
        .min_ce_len = 0, .max_ce_len = 0,
    };
    memcpy(g_st.table_addr, a->val, 6);
    g_st.table_addr_type = a->type;
    name_for(a, g_st.table_name, sizeof g_st.table_name);
    g_st.table_known = true;
    char addr[18];
    addr_to_str(a->val, addr);
    relay_log("connecting to %s (%s)", g_st.table_name[0] ? g_st.table_name : "table", addr);
    s_phase = PH_CONNECTING;
    set_link(LINK_CONNECTING);
    int rc = ble_gap_connect(s_own_addr_type, a, CONNECT_TIMEOUT_MS, &p, gap_event, NULL);
    if (rc != 0) {
        char why[40];
        snprintf(why, sizeof why, "connect didn't start (%d)", rc);
        attempt_failed(why);
    }
}

// ---- Writes from the host ----

static int write_done(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    s_write_status = error->status;
    xSemaphoreGive(s_write_done);
    return 0;
}

static void write_packet(const uint8_t *p, size_t n) {
    uint16_t conn = s_conn, h = s_write_handle;
    if (conn == BLE_HS_CONN_HANDLE_NONE || !h) return;
    size_t max = g_st.mtu > 23 ? g_st.mtu - 3 : 20;
    for (size_t off = 0; off < n;) {
        size_t chunk = n - off < max ? n - off : max;
        if (s_write_props & BLE_GATT_CHR_PROP_WRITE_NO_RSP) {
            for (int tries = 0;; tries++) {
                int rc = ble_gattc_write_no_rsp_flat(conn, h, p + off, chunk);
                if (rc == 0) break;
                if ((rc == BLE_HS_ENOMEM || rc == BLE_HS_EBUSY) && tries < 200) { vTaskDelay(pdMS_TO_TICKS(5)); continue; }
                ESP_LOGW(TAG, "write failed: %d", rc);
                return;
            }
        } else {
            xSemaphoreTake(s_write_done, 0);
            if (ble_gattc_write_flat(conn, h, p + off, chunk, write_done, NULL) != 0) return;
            if (xSemaphoreTake(s_write_done, pdMS_TO_TICKS(3000)) != pdTRUE || s_write_status != 0) return;
        }
        off += chunk;
    }
    g_st.writes++;
    s_last_write_us = now_us();
}

static void writer_task(void *arg) {
    static uint8_t pkt[260];
    static const uint8_t confirm[] = {0x7B, 0x04, 0xD0, 0x4F};
    int64_t last_page = 0;
    for (;;) {
        size_t n = xMessageBufferReceive(s_writes, pkt, sizeof pkt, pdMS_TO_TICKS(100));
        if (s_job_active) {   // the job writes for itself (ble_job_write)
            if (n) g_st.dropped_gate++;
            s_unstick = false;
            continue;
        }
        if (s_unstick) {
            s_unstick = false;
            if (s_phase == PH_LINKED && !g_st.gate_open) {
                write_packet(confirm, sizeof confirm);
                g_st.unstuck++;
            }
        }
        if (!n) {
            if (s_phase == PH_LINKED && g_st.gate_open && g_st.host_connected && s_last_write_us &&
                now_us() - s_last_write_us >= KEEPALIVE_MS * 1000LL) {
                write_packet(confirm, sizeof confirm);
                s_last_write_us = now_us();   // even if the write failed: try again in a second, not every 200 ms
                g_st.keepalives++;
            }
            continue;
        }
        if (s_phase != PH_LINKED || !g_st.gate_open) { g_st.dropped_gate++; continue; }
        bool page = n >= 4 && pkt[0] == 0x7B && (pkt[2] & 0x7F) == 0x53;
        if (page) {
            if (last_page) {
                int64_t gap = (now_us() - last_page) / 1000;
                if (gap < MIN_PAGE_GAP_MS) { vTaskDelay(pdMS_TO_TICKS(MIN_PAGE_GAP_MS - gap)); g_st.paced++; }
                else if (gap < 5000 && gap > g_st.max_page_gap_ms) g_st.max_page_gap_ms = gap;
            }
            last_page = now_us();
        }
        write_packet(pkt, n);
    }
}

void ble_write_enqueue(const uint8_t *data, size_t len) {
    if (!s_writes || len == 0 || len > 256) return;
    if (xMessageBufferSend(s_writes, data, len, pdMS_TO_TICKS(100)) != len) g_st.dropped_full++;
}

// ---- Control ----

static bool want_link(void) {
    if (s_job_active) return true;
    if (g_st.released) return false;
    if (g_cfg.hold || g_st.host_connected) return true;
    return s_host_left_at_us && now_us() - s_host_left_at_us < NO_HOST_RELEASE_MS * 1000LL;
}

static void tick(void) {
    if (s_phase == PH_OFF) return;
    int64_t t = now_us();
    bool want = want_link();

    if ((s_report_host || s_report_console) && !s_disc_active && s_phase != PH_CONNECTING && s_phase != PH_DISCOVERING) start_disc();

    switch (s_phase) {
    case PH_IDLE:
        set_link(want ? LINK_WAITING : g_st.released ? LINK_RELEASED : LINK_IDLE);
        if (!want || t < s_next_attempt_us || s_disc_active) break;
        if (s_target_set) {
            connect_to(&s_target);
        } else if (g_cfg.table_addr_set) {
            ble_addr_t a = {.type = g_cfg.table_addr_type};
            memcpy(a.val, g_cfg.table_addr, 6);
            connect_to(&a);
        } else {
            s_phase = PH_SCANNING;
            set_link(LINK_SCANNING);
            if (start_disc() != 0) attempt_failed("couldn't scan");
        }
        break;
    case PH_SCANNING:
        if (!want) { ble_gap_disc_cancel(); s_disc_active = false; s_phase = PH_IDLE; kick(); }
        break;
    case PH_CONNECTING:
        if (!want) ble_gap_conn_cancel();
        break;
    case PH_DISCOVERING:
        if (!want) { s_phase = PH_DISCONNECTING; ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM); }
        break;
    case PH_LINKED:
        if (!want || s_restart_link) {
            s_reconnect_now = want;
            s_restart_link = false;
            s_phase = PH_DISCONNECTING;
            if (ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM) != 0) { s_phase = PH_IDLE; kick(); }
            break;
        }
        if (t - s_last_rssi_us > RSSI_EVERY_MS * 1000LL) {
            int8_t r;
            s_last_rssi_us = t;
            if (ble_gap_conn_rssi(s_conn, &r) == 0) { g_st.table_rssi = r; g_st.table_rssi_valid = true; }
        }
        // A host is waiting for a handshake the table hasn't asked for. Over Bluetooth a fresh connection
        // always starts with one, so reconnect.
        if (g_st.host_connected && !g_st.gate_open && !s_job_active) {
            int64_t since = s_gate_closed_at_us > s_linked_at_us ? s_gate_closed_at_us : s_linked_at_us;
            if (s_last_unstick_us > since) since = s_last_unstick_us;
            if (t - since > GATE_TIMEOUT_MS * 1000LL) {
                relay_log("no handshake request from the table for %d s; reconnecting so it starts a fresh session", GATE_TIMEOUT_MS / 1000);
                s_gate_closed_at_us = t;
                s_restart_link = true;
                kick();
            }
        }
        break;
    default:
        break;
    }
}

static void ctl_task(void *arg) {
    for (;;) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(250));
        tick();
    }
}

// ---- Commands ----

void ble_host_session_started(void) {
    g_st.gate_open = false;
    s_gate_closed_at_us = now_us();
    net_status_changed();
    kick();
}

void ble_host_session_ended(void) {
    g_st.gate_open = false;
    s_host_left_at_us = now_us();
    kick();
}

void ble_request_scan(bool for_host, bool for_console) {
    if (for_host) s_report_host = true;
    if (for_console) s_report_console = true;
    kick();
}

void ble_set_released(bool released) {
    if (g_st.released == released) return;
    g_st.released = released;
    if (!released) {
        s_backoff_ms = BACKOFF_MIN_MS;
        s_next_attempt_us = 0;
    }
    relay_log(released ? "released the table (the HoMedics app can connect now)" : "taking the table back");
    net_status_changed();
    kick();
}

bool ble_select(const char *arg, char *msg, size_t msglen) {
    while (*arg == ' ') arg++;
    if (!*arg) { snprintf(msg, msglen, "give an address (aa:bb:cc:dd:ee:ff) or a table name"); return false; }
    uint8_t a[6];
    if (addr_from_str(arg, a)) {
        int type = -1;
        const char *slash = strchr(arg, '/');
        if (slash) type = atoi(slash + 1) ? 1 : 0;
        char name[32] = "";
        xSemaphoreTake(s_lock, portMAX_DELAY);
        for (int i = 0; i < s_ncands; i++)
            if (memcmp(s_cands[i].addr.val, a, 6) == 0) {
                if (type < 0) type = s_cands[i].addr.type;
                strlcpy(name, s_cands[i].name, sizeof name);
            }
        xSemaphoreGive(s_lock);
        memcpy(g_cfg.table_addr, a, 6);
        g_cfg.table_addr_type = type < 0 ? BLE_ADDR_PUBLIC : type;
        g_cfg.table_addr_set = true;
        strlcpy(g_cfg.table_name, name, sizeof g_cfg.table_name);
        s_target.type = g_cfg.table_addr_type;
        memcpy(s_target.val, a, 6);
        s_target_set = true;
    } else {
        strlcpy(g_cfg.table_name, arg, sizeof g_cfg.table_name);
        trim(g_cfg.table_name);
        g_cfg.table_addr_set = false;
        s_target_set = false;
    }
    config_save();
    snprintf(msg, msglen, "using %s", arg);
    relay_log("table set to %s", arg);
    bool same = g_st.table_known && g_cfg.table_addr_set && memcmp(g_st.table_addr, g_cfg.table_addr, 6) == 0;
    if (!same) s_restart_link = true;
    s_backoff_ms = BACKOFF_MIN_MS;
    s_next_attempt_us = 0;
    if (!same && s_phase == PH_CONNECTING) ble_gap_conn_cancel();
    kick();
    return true;
}

void ble_forget(void) {
    g_cfg.table_name[0] = 0;
    g_cfg.table_addr_set = false;
    config_save();
    s_target_set = false;
    s_restart_link = true;
    s_next_attempt_us = 0;
    relay_log("forgot the table; will pick the strongest Drift");
    kick();
}

void ble_settings_changed(void) { kick(); }

// ---- Jobs ----

bool ble_job_link_up(int timeout_ms) {
    static uint8_t scrap[600];
    while (xMessageBufferReceive(s_job_rx, scrap, sizeof scrap, 0)) {}
    unsigned gen = s_link_gen;
    s_job_active = true;
    g_st.gate_open = false;
    s_backoff_ms = BACKOFF_MIN_MS;
    s_next_attempt_us = 0;
    // A link that's already up carries someone else's session (or none): the job starts on a fresh one, where
    // the table asks for a handshake.
    if (s_phase == PH_LINKED) s_restart_link = true;
    net_status_changed();
    kick();
    int64_t deadline = now_us() + timeout_ms * 1000LL;
    while (now_us() < deadline) {
        if (s_phase == PH_LINKED && !s_restart_link && s_link_gen != gen) return true;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return false;
}

void ble_job_link_down(bool done) {
    if (done) {
        // Back to what the relay does without a job: released stays released; a host that holds the table gets
        // a fresh handshake (the gate is closed, and the table resets its session once the job stops answering).
        s_job_active = false;
        s_gate_closed_at_us = now_us();
        net_status_changed();
        kick();
        return;
    }
    if (s_phase != PH_LINKED) return;
    s_restart_link = true;
    kick();
    for (int i = 0; i < 150 && s_phase == PH_LINKED; i++) vTaskDelay(pdMS_TO_TICKS(20));
}

bool ble_job_write(const uint8_t *packet, size_t len) {
    if (s_phase != PH_LINKED) return false;
    write_packet(packet, len);
    return s_phase == PH_LINKED;
}

int ble_job_recv(uint8_t *buf, size_t max, int timeout_ms) {
    size_t n = xMessageBufferReceive(s_job_rx, buf, max, pdMS_TO_TICKS(timeout_ms));
    if (n) return (int)n;
    return s_phase == PH_LINKED ? 0 : -1;
}

// ---- Start ----

static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    s_phase = PH_IDLE;
    relay_log("Bluetooth ready");
    kick();
}

static void on_reset(int reason) {
    ESP_LOGW(TAG, "NimBLE host reset: %d", reason);
    s_phase = PH_OFF;
    s_conn = BLE_HS_CONN_HANDLE_NONE;
    s_disc_active = false;
    g_st.gate_open = false;
    set_link(LINK_OFF);
}

static void host_task(void *arg) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void ble_start(void) {
    s_lock = xSemaphoreCreateMutex();
    s_write_done = xSemaphoreCreateBinary();
    s_writes = xMessageBufferCreate(4096);
    s_job_rx = xMessageBufferCreate(6144);
    if (nimble_port_init() != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE init failed");
        return;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_att_set_preferred_mtu(247);
    xTaskCreate(writer_task, "ble_write", 4096, NULL, 6, NULL);
    xTaskCreate(ctl_task, "ble_ctl", 4096, NULL, 5, &s_ctl_task);
    nimble_port_freertos_init(host_task);
}
