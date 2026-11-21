// Wi-Fi station, Bonjour (mDNS) advertisement and the TCP server Drifted connects to.
//
// One host at a time. A new connection has 5 s to send HELLO with the right token; only then does it replace
// the current host, so nothing unauthenticated can knock Drifted off.
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/message_buffer.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "job.h"
#include "mdns.h"
#include "relay.h"

static const char *TAG = "net";

#define HELLO_TIMEOUT_US (5 * 1000000LL)
#define STATUS_EVERY_US (5 * 1000000LL)

static MessageBufferHandle_t s_tx;
static SemaphoreHandle_t s_tx_lock, s_client_lock;
static uint8_t s_tx_scratch[MAX_PAYLOAD + 1];
static volatile int s_client = -1;
static volatile bool s_status_dirty;
static esp_netif_t *s_netif;
static esp_timer_handle_t s_wifi_retry;
static uint32_t s_wifi_backoff_ms = 1000;

static int64_t now_us(void) { return esp_timer_get_time(); }

// ---- Outgoing ----

void net_send(uint8_t type, const void *data, size_t len) {
    if (!s_tx || !g_st.host_connected) return;
    if (len > MAX_PAYLOAD) len = MAX_PAYLOAD;
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    s_tx_scratch[0] = type;
    memcpy(s_tx_scratch + 1, data, len);
    if (xMessageBufferSend(s_tx, s_tx_scratch, len + 1, 0) == 0) g_st.dropped_full++;
    xSemaphoreGive(s_tx_lock);
}

void net_status_changed(void) { s_status_dirty = true; }

static bool send_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        int r = send(fd, p, n, 0);
        if (r <= 0) return false;
        p += r;
        n -= r;
    }
    return true;
}

/// Frames and sends to `fd`; the caller holds s_client_lock (or owns an unpublished fd).
static bool send_frame_to(int fd, uint8_t type, const void *payload, size_t len) {
    static uint8_t frame[MAX_PAYLOAD + 3];
    if (len > MAX_PAYLOAD) len = MAX_PAYLOAD;
    frame[0] = type;
    frame[1] = len & 0xFF;
    frame[2] = len >> 8;
    memcpy(frame + 3, payload, len);
    return send_all(fd, frame, len + 3);
}

static void send_frame(uint8_t type, const void *payload, size_t len) {
    xSemaphoreTake(s_client_lock, portMAX_DELAY);
    int fd = s_client;
    if (fd >= 0 && !send_frame_to(fd, type, payload, len)) {
        ESP_LOGW(TAG, "send to host failed; closing");
        g_st.send_fails++;
        shutdown(fd, SHUT_RDWR);   // the server task sees the close and cleans up
    }
    xSemaphoreGive(s_client_lock);
}

static void tx_task(void *arg) {
    static uint8_t msg[MAX_PAYLOAD + 1];
    static char status[1400];
    int64_t last_status = 0;
    for (;;) {
        size_t n = xMessageBufferReceive(s_tx, msg, sizeof msg, pdMS_TO_TICKS(200));
        // A pending status goes before the message: "linked" must reach the host before that link's bytes.
        if (g_st.host_connected && (s_status_dirty || now_us() - last_status > STATUS_EVERY_US)) {
            s_status_dirty = false;
            int len = net_status_json(status, sizeof status);
            send_frame(MSG_STATUS, status, len);
            last_status = now_us();
        }
        if (n) send_frame(msg[0], msg + 1, n - 1);
    }
}

// ---- JSON ----

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

int net_status_json(char *out, size_t outlen) {
    char table[160] = "null", name[70], addr[18], rssi[8] = "null", wifi[8] = "null";
    if (g_st.table_known || g_cfg.table_addr_set || g_cfg.table_name[0]) {
        const char *n = g_st.table_known ? g_st.table_name : g_cfg.table_name;
        json_str(name, sizeof name, n);
        if (g_st.table_known || g_cfg.table_addr_set) {
            addr_to_str(g_st.table_known ? g_st.table_addr : g_cfg.table_addr, addr);
            snprintf(table, sizeof table, "{\"name\":%s,\"address\":\"%s\",\"addrType\":%d}", name, addr,
                     g_st.table_known ? g_st.table_addr_type : g_cfg.table_addr_type);
        } else {
            snprintf(table, sizeof table, "{\"name\":%s}", name);
        }
    }
    if (g_st.link == LINK_LINKED && g_st.table_rssi_valid) snprintf(rssi, sizeof rssi, "%d", g_st.table_rssi);
    int w;
    if (g_st.wifi_up && esp_wifi_sta_get_rssi(&w) == ESP_OK) snprintf(wifi, sizeof wifi, "%d", w);
    unsigned mtu = g_st.link == LINK_LINKED ? g_st.mtu : 0;
    int n = snprintf(out, outlen,
                     "{\"link\":\"%s\",\"released\":%s,\"hold\":%s,\"table\":%s,\"rssi\":%s,\"mtu\":%u,\"maxWrite\":%u,"
                     "\"gate\":\"%s\",\"host\":%s,\"wifiRssi\":%s,\"ip\":\"%s\",\"name\":\"%s\",\"uptime\":%lld,"
                     "\"firmware\":\"%s\",\"proto\":%d,\"heap\":%u,\"ota\":%s,\"stats\":{\"notifyBytes\":%lu,\"writes\":%lu,"
                     "\"droppedBeforeHandshake\":%lu,\"droppedFull\":%lu,\"pagesPaced\":%lu,\"handshakeRequests\":%lu,"
                     "\"maxPageGapMs\":%lu,\"keepalives\":%lu,\"unstuck\":%lu,\"wifiDrops\":%lu,\"wifiLastReason\":%lu,"
                     "\"hostSessions\":%lu,\"sendFails\":%lu}",
                     link_name(g_st.link), g_st.released ? "true" : "false", g_cfg.hold ? "true" : "false", table, rssi,
                     mtu, mtu > 3 ? mtu - 3 : 0, g_st.gate_open ? "open" : "waiting", g_st.host_connected ? "true" : "false",
                     wifi, g_st.ip, g_st.name, (long long)(now_us() / 1000000), RELAY_FIRMWARE_VERSION, RELAY_PROTO,
                     (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT), g_st.ota_running ? "true" : "false",
                     (unsigned long)g_st.notify_bytes, (unsigned long)g_st.writes, (unsigned long)g_st.dropped_gate,
                     (unsigned long)g_st.dropped_full, (unsigned long)g_st.paced, (unsigned long)g_st.handshakes,
                     (unsigned long)g_st.max_page_gap_ms, (unsigned long)g_st.keepalives, (unsigned long)g_st.unstuck,
                     (unsigned long)g_st.wifi_drops, (unsigned long)g_st.wifi_last_reason, (unsigned long)g_st.host_sessions,
                     (unsigned long)g_st.send_fails);
    if (n < 0 || n >= (int)outlen - 140) return n < (int)outlen ? n : (int)outlen - 1;   // (can't happen: the buffers are 1400)
    // The current or last job, if there has been one: ,"job":{…}
    char job[128];
    if (job_status_json(job, sizeof job) > 0) n += snprintf(out + n, outlen - n, ",%s", job);
    n += snprintf(out + n, outlen - n, "}");
    return n;
}

static SemaphoreHandle_t s_result_lock;

void net_result(const char *command, bool ok, const char *message, const char *extra) {
    static char buf[1600];
    if (!s_result_lock) return;
    xSemaphoreTake(s_result_lock, portMAX_DELAY);
    char cmd[40], msg[300];
    json_str(cmd, sizeof cmd, command);
    json_str(msg, sizeof msg, message ? message : "");
    int n = snprintf(buf, sizeof buf, "{\"command\":%s,\"ok\":%s,\"message\":%s%s%s}", cmd, ok ? "true" : "false", msg,
                     extra && *extra ? "," : "", extra ? extra : "");
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    net_send(MSG_RESULT, buf, n);
    xSemaphoreGive(s_result_lock);
}

// ---- Server ----

static void configure_socket(int fd) {
    int on = 1, idle = 10, intvl = 5, cnt = 3;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);   // ConfirmData replies are tiny and time-critical
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
    struct timeval tv = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/// Sends a short frame from a stack buffer (welcome, errors): safe without s_client_lock.
static void send_small(int fd, uint8_t type, const char *payload, size_t len) {
    uint8_t frame[3 + 160];
    if (len > 160) len = 160;
    frame[0] = type;
    frame[1] = len & 0xFF;
    frame[2] = len >> 8;
    memcpy(frame + 3, payload, len);
    send_all(fd, frame, len + 3);
}

static void refuse(int fd, const char *why) {
    char body[120], s[100];
    json_str(s, sizeof s, why);
    int n = snprintf(body, sizeof body, "{\"error\":%s}", s);
    send_small(fd, MSG_ERROR, body, n);
    close(fd);
}

static bool token_ok(const uint8_t *t, size_t n) {
    size_t want = strlen(g_cfg.token);
    if (want < 16 || n != want) return false;
    uint8_t diff = 0;
    for (size_t i = 0; i < n; i++) diff |= t[i] ^ (uint8_t)g_cfg.token[i];
    return diff == 0;
}

static void drop_client(const char *why) {
    xSemaphoreTake(s_client_lock, portMAX_DELAY);
    if (s_client >= 0) close(s_client);
    s_client = -1;
    g_st.host_connected = false;
    xSemaphoreGive(s_client_lock);
    ESP_LOGI(TAG, "host gone: %s", why);
    ble_host_session_ended();
}

static void handle_frame(uint8_t type, const uint8_t *p, size_t len) {
    switch (type) {
    case MSG_TABLE_WRITE:
        if (len <= 256) ble_write_enqueue(p, len);
        else relay_log("ignored a %u-byte table write (packets are at most 255 bytes)", (unsigned)len);
        break;
    case MSG_COMMAND: {
        char line[256], msg[200] = "", word[24] = "";
        size_t n = len < sizeof line - 1 ? len : sizeof line - 1;
        memcpy(line, p, n);
        line[n] = 0;
        sscanf(line, "%23s", word);
        cmd_result_t r = relay_command(line, true, msg, sizeof msg);
        if (r != CMD_PENDING) net_result(word, r == CMD_OK, msg, NULL);
        break;
    }
    default:
        if (type >= MSG_JOB_BEGIN && type <= MSG_JOB_QUERY) jobs_frame(type, p, len);
        break;   // otherwise HELLO again, or a type from a newer host: ignore
    }
}

static void server_task(void *arg) {
    int lfd = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    int on = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(RELAY_PORT), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (bind(lfd, (struct sockaddr *)&a, sizeof a) != 0 || listen(lfd, 2) != 0) {
        ESP_LOGE(TAG, "can't listen on %d", RELAY_PORT);
        vTaskDelete(NULL);
        return;
    }
    g_st.server_up = true;
    ESP_LOGI(TAG, "listening on port %d", RELAY_PORT);

    static uint8_t pbuf[300];                  // pending connection: just its HELLO
    static uint8_t cbuf[MAX_PAYLOAD + 3 + 512];
    size_t plen = 0, clen = 0;
    int pending = -1;
    int64_t pending_since = 0, refuse_until = 0;
    char pending_ip[16] = "";

    for (;;) {
        fd_set r;
        FD_ZERO(&r);
        FD_SET(lfd, &r);
        int maxfd = lfd;
        int client = s_client;
        if (pending >= 0) { FD_SET(pending, &r); if (pending > maxfd) maxfd = pending; }
        if (client >= 0) { FD_SET(client, &r); if (client > maxfd) maxfd = client; }
        struct timeval tv = {.tv_sec = 0, .tv_usec = 500000};
        if (select(maxfd + 1, &r, NULL, NULL, &tv) < 0) { vTaskDelay(pdMS_TO_TICKS(100)); continue; }

        if (pending >= 0 && now_us() - pending_since > HELLO_TIMEOUT_US) {
            refuse(pending, "no hello within 5 s");
            pending = -1;
        }

        if (FD_ISSET(lfd, &r)) {
            struct sockaddr_in from;
            socklen_t fl = sizeof from;
            int fd = accept(lfd, (struct sockaddr *)&from, &fl);
            if (fd >= 0 && now_us() < refuse_until) {
                close(fd);
            } else if (fd >= 0) {
                if (pending >= 0) refuse(pending, "another connection arrived first");
                configure_socket(fd);
                inet_ntoa_r(from.sin_addr, pending_ip, sizeof pending_ip);
                pending = fd;
                plen = 0;
                pending_since = now_us();
            }
        }

        if (pending >= 0 && FD_ISSET(pending, &r)) {
            int n = recv(pending, pbuf + plen, sizeof pbuf - plen, 0);
            if (n <= 0) { close(pending); pending = -1; }
            else {
                plen += n;
                if (plen >= 3) {
                    size_t len = pbuf[1] | pbuf[2] << 8;
                    if (pbuf[0] != MSG_HELLO || len < 1 || len > 200) {
                        refuse(pending, "expected hello");
                        pending = -1;
                    } else if (plen >= 3 + len) {
                        if (!config_ready()) {
                            refuse(pending, "relay has no token yet; run relay/setup.py");
                            pending = -1;
                        } else if (!token_ok(pbuf + 4, len - 1)) {
                            relay_log("refused a host with the wrong token");
                            refuse(pending, "wrong token");
                            pending = -1;
                            // Slow down guessing without blocking this loop (the current host's traffic).
                            refuse_until = now_us() + 1000000;
                        } else {
                            uint8_t flags = pbuf[3];
                            // Promote: the new host replaces the old one.
                            xSemaphoreTake(s_client_lock, portMAX_DELAY);
                            if (s_client >= 0) refuse(s_client, "another host connected");
                            s_client = pending;
                            char welcome[120];
                            int wn = snprintf(welcome, sizeof welcome, "{\"proto\":%d,\"firmware\":\"%s\",\"name\":\"%s\"}",
                                              RELAY_PROTO, RELAY_FIRMWARE_VERSION, g_st.name);
                            send_small(s_client, MSG_WELCOME, welcome, wn);
                            g_st.host_connected = true;
                            g_st.host_sessions++;
                            s_status_dirty = true;
                            xSemaphoreGive(s_client_lock);
                            clen = plen - 3 - len;
                            memcpy(cbuf, pbuf + 3 + len, clen);
                            pending = -1;
                            relay_log("host %s connected%s", pending_ip, flags & HELLO_FLAG_OBSERVE ? " (observing)" : "");
                            ble_host_session_started();
                            if (!(flags & HELLO_FLAG_OBSERVE)) ble_set_released(false);
                        }
                    }
                }
            }
        }

        client = s_client;
        if (client >= 0 && FD_ISSET(client, &r)) {
            int n = recv(client, cbuf + clen, sizeof cbuf - clen, 0);
            if (n <= 0) { drop_client(n == 0 ? "closed" : "error"); clen = 0; continue; }
            clen += n;
        }
        // Process whatever is buffered (including bytes that arrived with the hello).
        size_t off = 0;
        while (s_client >= 0 && clen - off >= 3) {
            size_t len = cbuf[off + 1] | cbuf[off + 2] << 8;
            if (len > MAX_PAYLOAD) { drop_client("bad frame"); clen = off = 0; break; }
            if (clen - off < 3 + len) break;
            handle_frame(cbuf[off], cbuf + off + 3, len);
            off += 3 + len;
        }
        if (off) { memmove(cbuf, cbuf + off, clen - off); clen -= off; }
    }
}

// ---- Wi-Fi ----

static void wifi_retry(void *arg) { esp_wifi_connect(); }

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (g_cfg.wifi_ssid[0]) esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = data;
        if (g_st.wifi_up) {
            g_st.wifi_drops++;
            g_st.wifi_last_reason = d->reason;
            relay_log("Wi-Fi lost (reason %d)", d->reason);
        }
        else ESP_LOGW(TAG, "Wi-Fi connect to \"%s\" failed (reason %d); retrying in %lu s", g_cfg.wifi_ssid, d->reason,
                      (unsigned long)(s_wifi_backoff_ms / 1000));
        g_st.wifi_up = false;
        g_st.ip[0] = 0;
        esp_timer_stop(s_wifi_retry);
        esp_timer_start_once(s_wifi_retry, (uint64_t)s_wifi_backoff_ms * 1000);
        s_wifi_backoff_ms = s_wifi_backoff_ms * 2 > 30000 ? 30000 : s_wifi_backoff_ms * 2;
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        snprintf(g_st.ip, sizeof g_st.ip, IPSTR, IP2STR(&e->ip_info.ip));
        g_st.wifi_up = true;
        s_wifi_backoff_ms = 1000;
        ESP_LOGI(TAG, "Wi-Fi up: %s (%s.local), port %d", g_st.ip, g_st.name, RELAY_PORT);
        printf("wifi ok %s\n", g_st.ip);
    }
}

void net_start(void) {
    s_tx = xMessageBufferCreate(16384);
    s_tx_lock = xSemaphoreCreateMutex();
    s_client_lock = xSemaphoreCreateMutex();
    s_result_lock = xSemaphoreCreateMutex();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_netif = esp_netif_create_default_wifi_sta();
    esp_netif_set_hostname(s_netif, g_st.name);
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));
    esp_timer_create_args_t ta = {.callback = wifi_retry, .name = "wifi_retry"};
    esp_timer_create(&ta, &s_wifi_retry);

    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, g_cfg.wifi_ssid, sizeof wc.sta.ssid);
    strlcpy((char *)wc.sta.password, g_cfg.wifi_pass, sizeof wc.sta.password);
    wc.sta.threshold.authmode = g_cfg.wifi_pass[0] ? WIFI_AUTH_WPA_WPA2_PSK : WIFI_AUTH_OPEN;
    wc.sta.sae_pwe_h2e = WPA3_SAE_PWE_BOTH;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));   // our own NVS keys hold the credentials
    ESP_ERROR_CHECK(esp_wifi_start());
    // Modem sleep stays on (the default): Bluetooth and Wi-Fi share the radio and coexistence needs it. It adds
    // up to a beacon interval (~100 ms) of latency to packets from the host, well inside the table's 2 s.

    if (mdns_init() == ESP_OK) {
        mdns_hostname_set(g_st.name);
        mdns_instance_name_set(g_st.name);
        mdns_txt_item_t txt[] = {{"firmware", RELAY_FIRMWARE_VERSION}, {"proto", "2"}};
        mdns_service_add(g_st.name, "_drifted-relay", "_tcp", RELAY_PORT, txt, 2);
    } else {
        ESP_LOGW(TAG, "mDNS didn't start; find the relay by IP address");
    }

    xTaskCreate(tx_task, "net_tx", 4096, NULL, 6, NULL);
    xTaskCreate(server_task, "net_server", 8192, NULL, 5, NULL);   // room for a job's flash writes
}
