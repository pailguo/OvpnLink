/*
 * openvpn_bridge.c
 * OpenVPN core 的 C 桥接层：供 NAPI 外壳 (napi_init.cpp) 调用。
 *
 * 设计：OpenVPN 头文件是纯 C，不能在 C++ 中直接 include（protected 等
 * 关键字冲突）。因此所有与 core 的交互都收敛到这个 C 文件，
 * napi_init.cpp 只通过 extern "C" 的简单接口调用这里。
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <hilog/log.h>
#ifdef __OHOS__
#include <network/netmanager/net_connection.h>
#endif

#include "management_client.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "OpenVpnBridge"

/* 信号处理器 */
static void signal_handler(int sig, siginfo_t *info, void *context)
{
    char buf[256];
    snprintf(buf, sizeof(buf), "SIGNAL CAUGHT: sig=%d, addr=%p", sig, info->si_addr);

    int fd = open("/data/storage/el2/base/cache/openvpn_signal.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0)
    {
        write(fd, buf, strlen(buf));
        write(fd, "\n", 1);
        close(fd);
    }

    OH_LOG_ERROR(LOG_APP, "[signal_handler] %{public}s", buf);

    /* 调用原始的 pthread_exit */
    pthread_exit((void*)-1);
}

#include "config.h"
#include "openvpn/openvpn.h"
#include "openvpn/manage.h"
#include "openvpn/error.h"

/* 调试日志文件 */
static void debug_log(const char *msg)
{
    /* 同时输出到 hilog 和文件 */
    OH_LOG_INFO(LOG_APP, "[Bridge] %{public}s", msg);

    /* 使用应用缓存目录，不需要特殊权限 */
    int fd = open("/data/storage/el2/base/cache/openvpn_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0)
    {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}

/* OpenVPN core 的消息出口（error.c 的 x_msg_va 调用）。
 * 输出到 hilog + 文件（文件便于 hdc 读取定位问题）。 */
void ovpn_log_msg(unsigned int flags, const char *msg)
{
    (void)flags;
    OH_LOG_INFO(LOG_APP, "[OpenVPN] %{public}s", msg);

    /* 写入独立文件，便于 hdc 读取 OpenVPN 的真实错误信息 */
    int fd = open("/data/storage/el2/base/cache/openvpn_msg.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0)
    {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}

/* management log on all 推送的日志回调（NAPI 层设置） */
static void (*g_mgmt_log_cb)(const char *formatted) = NULL;

/* 连接日志文件（对齐原版 log_dir\<配置名>.log，追加 / 每次连接覆盖）。
 * 文件名规则与 ets/common/ProfileLog.ets 的 connectionLogName 一致：
 * 控制字符和 <>:"/\|?*; 换成下划线。 */
static char g_conn_log_path[512] = "/data/storage/el2/base/cache/openvpn.log";

/* 界面回调是「级别|正文」，级别只用于上色。日志文件只保留正文。 */
static const char *log_file_text(const char *formatted)
{
    const char *sep;
    size_t i;

    if (formatted == NULL || formatted[0] < '0' || formatted[0] > '9')
    {
        return formatted;
    }
    sep = strchr(formatted, '|');
    if (sep == NULL || sep == formatted || (size_t)(sep - formatted) >= 3)
    {
        return formatted;
    }
    for (i = 0; formatted + i < sep; i++)
    {
        if (formatted[i] < '0' || formatted[i] > '9')
        {
            return formatted;
        }
    }
    return sep + 1;
}

static void on_mgmt_log(const char *formatted)
{
    /* 落地连接日志（供查看日志打开，等同原版 viewlog 的 log 文件） */
    if (formatted)
    {
        const char *text = log_file_text(formatted);
        int fd = open(g_conn_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0)
        {
            write(fd, text, strlen(text));
            write(fd, "\n", 1);
            close(fd);
        }
    }

    if (g_mgmt_log_cb)
    {
        g_mgmt_log_cb(formatted);
    }
}

static void emit_status(const char *msg);

static void on_mgmt_echo(const char *message)
{
    char buf[1024];
    if (message == NULL || message[0] == '\0')
    {
        return;
    }
    snprintf(buf, sizeof(buf), "ECHO:%s", message);
    emit_status(buf);
}

void ovpn_set_mgmt_log_callback(void (*log_cb)(const char *formatted))
{
    g_mgmt_log_cb = log_cb;
    mgmt_client_set_log_callback(on_mgmt_log);
    mgmt_client_set_echo_callback(on_mgmt_echo);
}

/* openvpn_main 是 static 的，对外入口是 main()（非 _WIN32 下定义在 openvpn.c）。
 * main() 会调用 openvpn_main，返回码即退出状态。 */
extern int main(int argc, char *argv[]);
extern void openvpn_exit(int status);

/* ---------------- 状态 ---------------- */
static pthread_t g_core_thread;
static volatile int g_running = 0;
static char g_config_path[512] = {0};  /* 保存配置文件路径 */
static volatile int g_exit_status = -999;  /* 记录退出状态码 */

/* ---------------- 连接选项（来自 ArkTS 设置页，对齐原版 GUI） ----------------
 * 原版 GUI 在每次连接时把这些选项拼进 OpenVPN 命令行（openvpn.c:BuildCommandLine）：
 *   - 代理：proxy_source != config 时加 --management-query-proxy，GUI 应答地址端口。
 *     手动代理用设置里的地址；系统代理用 OH_NetConn_GetDefaultHttpProxy。
 *   - 日志：log_append 控制 openvpn.log 追加/覆盖。
 *   - 管理端口：mgmt_port_offset + 配置 id（我们 unix socket 用偏移命名区分）。
 * 这些值在 ovpn_start 创建线程前由 NAPI 层设置，跨连接有效（设置改变下次连接生效）。 */
static int g_proxy_mode = 0;         /* 0=使用配置文件 1=系统代理 2=手动 */
static int g_proxy_sub_type = 0;     /* 0=HTTP 1=SOCKS */
static char g_proxy_server[256] = {0};
static int g_proxy_port = 0;
static char g_proxy_username[128] = {0};  /* 代理认证用户名（空=不认证） */
static char g_proxy_password[128] = {0};  /* 代理认证密码 */
static char g_socks_auth_file[512] = {0}; /* SOCKS 用户名密码文件，仅用户名非空时有效 */
static char g_auth_type[64] = "Auth";     /* 最近一次管理接口密码请求的类型 */
static int g_append_log = 1;         /* 1=追加 0=覆盖（OpenVPN 连接日志） */
static int g_mgmt_port_offset = 25340;
static char g_auth_file[512] = {0}; /* CLI 凭据文件（--auth-user-pass <file>，无头模式） */

/* NAPI 层在调用 ovpn_start() 前设置连接选项 */
void ovpn_set_start_options(int proxy_mode, int proxy_sub_type,
                            const char *proxy_server, int proxy_port,
                            int append_log, int mgmt_offset,
                            const char *proxy_username, const char *proxy_password)
{
    g_proxy_mode = proxy_mode;
    g_proxy_sub_type = proxy_sub_type;
    if (proxy_server)
    {
        snprintf(g_proxy_server, sizeof(g_proxy_server), "%s", proxy_server);
    }
    else
    {
        g_proxy_server[0] = '\0';
    }
    g_proxy_port = proxy_port;
    if (proxy_username)
    {
        snprintf(g_proxy_username, sizeof(g_proxy_username), "%s", proxy_username);
    }
    else
    {
        g_proxy_username[0] = '\0';
    }
    if (proxy_password)
    {
        snprintf(g_proxy_password, sizeof(g_proxy_password), "%s", proxy_password);
    }
    else
    {
        g_proxy_password[0] = '\0';
    }
    g_append_log = append_log;
    if (mgmt_offset > 0)
    {
        g_mgmt_port_offset = mgmt_offset;
    }
    char opt_buf[384];
    snprintf(opt_buf, sizeof(opt_buf),
             "start options: proxy_mode=%d sub=%d server=%s port=%d append=%d mgmt=%d",
             g_proxy_mode, g_proxy_sub_type, g_proxy_server, g_proxy_port,
             g_append_log, g_mgmt_port_offset);
    debug_log(opt_buf);
}

/* 设置 CLI 凭据文件（无头模式：--auth-user-pass <file>，文件两行：用户名/密码）。
 * 对齐原版 openvpn.exe 命令行认证机制。 */
void ovpn_set_auth_file(const char *path)
{
    if (path && path[0] != '\0')
    {
        snprintf(g_auth_file, sizeof(g_auth_file), "%s", path);
    }
    else
    {
        g_auth_file[0] = '\0';
    }
    char buf[560];
    snprintf(buf, sizeof(buf), "auth file set: %s", g_auth_file[0] ? g_auth_file : "(none)");
    debug_log(buf);
}

/* ---------------- 简单回调（由 NAPI 层注册） ---------------- */
static void (*g_status_cb)(const char *msg) = NULL;
static void (*g_log_cb)(const char *line) = NULL;
static void (*g_auth_request_cb)(const char *type) = NULL;  /* 认证请求回调 */

static pthread_mutex_t g_ipv6_config_mutex = PTHREAD_MUTEX_INITIALIZER;
static char g_ipv6_config[128] = {0};
/* ROUTE6 在 OPENTUN 之前到达，创建 VpnConfig 时一次性写入。
 * redirect-gateway ipv6 会下发 ::/3、2000::/4、3000::/4、fc00::/7，而不是 ::/0。 */
#define OVPN_IPV6_ROUTE_MAX 64
#define OVPN_IPV6_ROUTE_LEN 80
static char g_ipv6_routes[OVPN_IPV6_ROUTE_MAX][OVPN_IPV6_ROUTE_LEN];
static int g_ipv6_route_count = 0;

static void clear_ipv6_cache_locked(void)
{
    g_ipv6_config[0] = '\0';
    g_ipv6_route_count = 0;
}

static void emit_status(const char *msg);

void ovpn_set_callbacks(void (*status_cb)(const char *), void (*log_cb)(const char *))
{
    g_status_cb = status_cb;
    g_log_cb = log_cb;
}

void ovpn_set_auth_callback(void (*auth_cb)(const char *type))
{
    g_auth_request_cb = auth_cb;
}

static int proxy_auth_type(const char *type)
{
    return type != NULL
        && (strcmp(type, "HTTP Proxy") == 0 || strcmp(type, "SOCKS Proxy") == 0);
}

/* Management 客户端认证请求处理 */
static void on_auth_request(const char *type)
{
    if (type != NULL && type[0] != '\0')
    {
        snprintf(g_auth_type, sizeof(g_auth_type), "%s", type);
    }
    else
    {
        snprintf(g_auth_type, sizeof(g_auth_type), "%s", "Auth");
    }

    /* 手动代理已填账号时直接回答。系统代理没有账号字段，407 仍走对话框。 */
    if (g_proxy_mode == 2 && proxy_auth_type(type) && g_proxy_username[0] != '\0')
    {
        char buf[160];
        snprintf(buf, sizeof(buf), "proxy auth from settings: %s", type);
        debug_log(buf);
        mgmt_client_send_auth(type, g_proxy_username, g_proxy_password);
        return;
    }

    debug_log("AUTH_REQUEST received");
    if (g_auth_request_cb)
    {
        g_auth_request_cb(g_auth_type);
    }
    if (!proxy_auth_type(type))
    {
        emit_status("AUTH_REQUEST");
    }
}

/* Management 客户端 tun 设备请求处理 */
static void (*g_tun_request_cb)(const char *dev) = NULL;  /* tun 请求回调（NAPI 层设置） */

static void on_tun_request(const char *dev)
{
    debug_log("TUN_REQUEST received");
    char buf[128];
    snprintf(buf, sizeof(buf), "TUN_REQUEST dev=%s", dev);
    debug_log(buf);
    if (g_tun_request_cb)
    {
        g_tun_request_cb(dev);
    }
    emit_status("TUN_REQUEST");
}

void ovpn_set_tun_callback(void (*tun_cb)(const char *dev))
{
    g_tun_request_cb = tun_cb;
    /* 同时注册到 management 客户端 */
    mgmt_client_set_tun_callback(on_tun_request);
}

/* Management 客户端 protect fd 请求处理（PROTECTFD，OpenVPN 附带 SCM_RIGHTS fd）。
 * 上层须对 fd 调用 VpnConnection.protect()，使该 socket 绕过 VPN 隧道，
 * 防止默认路由下隧道包自环（对齐 OpenVPN for Android protect 模型）。 */
static void (*g_protect_fd_cb)(int fd) = NULL;  /* protect fd 回调（NAPI 层设置） */

static void on_protect_fd(int fd)
{
    debug_log("PROTECT_FD received");
    char buf[64];
    snprintf(buf, sizeof(buf), "PROTECT_FD fd=%d", fd);
    debug_log(buf);
    if (g_protect_fd_cb)
    {
        g_protect_fd_cb(fd);
    }
}

void ovpn_set_protect_fd_callback(void (*fd_cb)(int fd))
{
    g_protect_fd_cb = fd_cb;
    /* 同时注册到 management 客户端 */
    mgmt_client_set_protect_fd_callback(on_protect_fd);
}

/* 流量统计回调（NAPI 层设置，由 management 客户端 status 2 轮询触发） */
static void (*g_bytecount_cb)(long long bytes_in, long long bytes_out) = NULL;

static void on_bytecount(long long bytes_in, long long bytes_out)
{
    if (g_bytecount_cb)
    {
        g_bytecount_cb(bytes_in, bytes_out);
    }
}

void ovpn_set_bytecount_callback(void (*cb)(long long bytes_in, long long bytes_out))
{
    g_bytecount_cb = cb;
    mgmt_client_set_bytecount_callback(on_bytecount);
}

/* 连接状态回调（NAPI 层设置，由 management state on 推送触发） */
static void (*g_state_cb)(const char *state, const char *detail) = NULL;

static void on_state(const char *state, const char *detail)
{
    if (g_state_cb)
    {
        g_state_cb(state, detail);
    }
}

static void on_auth_verify_failed(void)
{
    debug_log("AUTH_VERIFY_FAILED");
    emit_status("AUTH_VERIFY_FAILED");
}

void ovpn_set_state_callback(void (*cb)(const char *state, const char *detail))
{
    g_state_cb = cb;
    mgmt_client_set_state_callback(on_state);
    mgmt_client_set_auth_verify_failed_callback(on_auth_verify_failed);
}

/* 从 NAPI 层调用，发送认证信息 */
int ovpn_send_auth(const char *username, const char *password)
{
    char buf[96];
    snprintf(buf, sizeof(buf), "ovpn_send_auth type=%s", g_auth_type);
    debug_log(buf);
    return mgmt_client_send_auth(g_auth_type, username, password);
}

/* SOCKS 需要认证时，把用户名和密码写成 OpenVPN 认识的两行文件。 */
const char *ovpn_socks_auth_file(void)
{
    return g_socks_auth_file;
}

static void prepare_socks_auth_file(void)
{
    g_socks_auth_file[0] = '\0';
    if (g_proxy_mode != 2 || g_proxy_sub_type != 1 || g_proxy_username[0] == '\0')
    {
        return;
    }

    char path[512];
    snprintf(path, sizeof(path), "/data/storage/el2/base/haps/entry/files/proxy-socks.auth");
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
    {
        debug_log("failed to write socks auth file");
        return;
    }
    char body[320];
    int n = snprintf(body, sizeof(body), "%s\n%s\n", g_proxy_username, g_proxy_password);
    if (n > 0)
    {
        ssize_t w = write(fd, body, (size_t)n);
        if (w != n)
        {
            debug_log("socks auth file short write");
        }
    }
    close(fd);
    snprintf(g_socks_auth_file, sizeof(g_socks_auth_file), "%s", path);
    debug_log("socks auth file ready");
}

#ifdef __OHOS__
static int ascii_lower(int c)
{
    if (c >= 'A' && c <= 'Z')
    {
        return c + ('a' - 'A');
    }
    return c;
}

static int mem_ieq(const char *a, const char *b, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
    {
        if (ascii_lower((unsigned char)a[i]) != ascii_lower((unsigned char)b[i]))
        {
            return 0;
        }
    }
    return 1;
}

/* 排除列表：完全匹配、子域名，或「主机:端口」。单独的 * 表示不走代理。 */
static int exclusion_hit(const char *host, const char *pat)
{
    size_t hlen;
    size_t plen;
    if (host == NULL || pat == NULL || pat[0] == '\0' || strcmp(pat, "*") == 0)
    {
        return 0;
    }
    hlen = strlen(host);
    plen = strlen(pat);
    if (hlen == plen && mem_ieq(host, pat, plen))
    {
        return 1;
    }
    if (hlen > plen && host[hlen - plen - 1] == '.' && mem_ieq(host + (hlen - plen), pat, plen))
    {
        return 1;
    }
    if (hlen > plen && host[plen] == ':' && mem_ieq(host, pat, plen))
    {
        return 1;
    }
    return 0;
}

static int system_proxy_bypassed(const char *remote, const NetConn_HttpProxy *proxy)
{
    int n;
    int i;
    if (remote == NULL || remote[0] == '\0' || proxy->exclusionListSize <= 0)
    {
        return 0;
    }
    n = proxy->exclusionListSize;
    if (n > NETCONN_MAX_EXCLUSION_SIZE)
    {
        n = NETCONN_MAX_EXCLUSION_SIZE;
    }
    if (n == 1 && strcmp(proxy->exclusionList[0], "*") == 0)
    {
        return 1;
    }
    for (i = 0; i < n; i++)
    {
        if (exclusion_hit(remote, proxy->exclusionList[i]))
        {
            return 1;
        }
    }
    return 0;
}

static void send_proxy_none(const char *why)
{
    debug_log(why);
    mgmt_client_send_cmd("proxy NONE\n");
}

/* 系统设置只有 HTTP 代理。UDP 不能走 HTTP 代理，回答直连。 */
static void reply_system_http_proxy(const char *proto, const char *remote)
{
    NetConn_HttpProxy *proxy;
    int32_t rc;
    char cmd[640];
    char buf[160];

    if (strcmp(proto, "TCP") != 0)
    {
        send_proxy_none("system HTTP proxy skipped: remote is not TCP");
        return;
    }
    proxy = (NetConn_HttpProxy *)calloc(1, sizeof(*proxy));
    if (proxy == NULL)
    {
        send_proxy_none("system proxy alloc failed");
        return;
    }
    rc = OH_NetConn_GetDefaultHttpProxy(proxy);
    if (rc != 0 || proxy->host[0] == '\0' || proxy->port == 0)
    {
        snprintf(buf, sizeof(buf), "system proxy unavailable: rc=%d", (int)rc);
        free(proxy);
        send_proxy_none(buf);
        return;
    }
    if (strpbrk(proxy->host, " \t\r\n") != NULL)
    {
        free(proxy);
        send_proxy_none("system proxy host rejected");
        return;
    }
    if (system_proxy_bypassed(remote, proxy))
    {
        free(proxy);
        send_proxy_none("system proxy bypasses this host");
        return;
    }
    snprintf(cmd, sizeof(cmd), "proxy HTTP %s %u\n", proxy->host, (unsigned)proxy->port);
    free(proxy);
    debug_log(cmd);
    mgmt_client_send_cmd(cmd);
}
#endif

/* 回答 OpenVPN 的 >PROXY:序号,TCP|UDP,主机 。HTTP 只在 TCP 上生效。 */
void ovpn_reply_proxy_query(const char *body)
{
    char proto[16] = {0};
    char remote[256] = {0};
    const char *comma1 = body != NULL ? strchr(body, ',') : NULL;
    const char *comma2 = comma1 != NULL ? strchr(comma1 + 1, ',') : NULL;
    if (comma1 != NULL && comma2 != NULL)
    {
        size_t len = (size_t)(comma2 - comma1 - 1);
        if (len >= sizeof(proto))
        {
            len = sizeof(proto) - 1;
        }
        memcpy(proto, comma1 + 1, len);
        proto[len] = '\0';

        len = 0;
        while (comma2[1 + len] != '\0' && comma2[1 + len] != '\r' && comma2[1 + len] != '\n'
            && len + 1 < sizeof(remote))
        {
            remote[len] = comma2[1 + len];
            len++;
        }
        remote[len] = '\0';
    }

    char cmd[640];
    int manual = (g_proxy_mode == 2 && g_proxy_server[0] != '\0' && g_proxy_port > 0);
    int socks = (g_proxy_sub_type == 1);
    int http_on_tcp = (!socks && strcmp(proto, "TCP") == 0);
    if (manual && (socks || http_on_tcp))
    {
        const char *kind = socks ? "SOCKS" : "HTTP";
        snprintf(cmd, sizeof(cmd), "proxy %s %s %d\n", kind, g_proxy_server, g_proxy_port);
        debug_log(cmd);
        mgmt_client_send_cmd(cmd);
        return;
    }
    if (g_proxy_mode == 1)
    {
#ifdef __OHOS__
        reply_system_http_proxy(proto, remote);
#else
        debug_log("system proxy is not available, direct connect");
        mgmt_client_send_cmd("proxy NONE\n");
#endif
        return;
    }
    if (manual && !socks)
    {
        debug_log("manual HTTP proxy skipped: remote is not TCP");
    }
    snprintf(cmd, sizeof(cmd), "proxy NONE\n");
    debug_log(cmd);
    mgmt_client_send_cmd(cmd);
}

void ovpn_set_config_path(const char *path)
{
    if (path && strlen(path) < sizeof(g_config_path))
    {
        strncpy(g_config_path, path, sizeof(g_config_path) - 1);
        g_config_path[sizeof(g_config_path) - 1] = '\0';
    }
}

/* 按配置名确定本次连接日志路径。name 是界面上的配置名，可含子目录斜杠。 */
void ovpn_set_log_name(const char *name)
{
    char safe[256];
    size_t n = 0;
    const char *src = (name && name[0] != '\0') ? name : "openvpn";
    const char *bad = "<>:\"/\\|?*;";

    while (src[n] != '\0' && n + 1 < sizeof(safe))
    {
        unsigned char c = (unsigned char)src[n];
        if (c < 32 || strchr(bad, (char)c) != NULL)
        {
            safe[n] = '_';
        }
        else
        {
            safe[n] = (char)c;
        }
        n++;
    }
    safe[n] = '\0';
    if (safe[0] == '\0')
    {
        snprintf(safe, sizeof(safe), "openvpn");
    }
    snprintf(g_conn_log_path, sizeof(g_conn_log_path),
             "/data/storage/el2/base/cache/%s.log", safe);
}

/* ---------------- 内部帮助函数 ---------------- */
static void emit_status(const char *msg)
{
    debug_log(msg);
    if (g_status_cb)
    {
        g_status_cb(msg);
    }
}

/* core（options.c）DNS 推送上报入口：收到服务端推送的 DNS 地址列表，
 * 以 "DNS:<addr1>,<addr2>" 形式经 status 通道发给 ArkTS（VpnConfig.dnsAddresses）。 */
void ovpn_emit_dns(const char *addrs)
{
    if (!addrs || addrs[0] == '\0')
    {
        return;
    }
    char buf[320];
    snprintf(buf, sizeof(buf), "DNS:%s", addrs);
    emit_status(buf);
}

/* core（tun.c）IPv6 接口配置上报入口：IFCONFIG6 的 MSG 内容为
 * "<IPv6 地址>/<前缀长度> <MTU>"，在 OPENTUN 前传给 ArkTS 配置 VpnConfig。 */
void ovpn_emit_ipv6_config(const char *config)
{
    if (!config || config[0] == '\0')
    {
        return;
    }
    char stored[128];
    snprintf(stored, sizeof(stored), "%s", config);
    size_t len = strlen(stored);
    while (len > 0 && (stored[len - 1] == '\r' || stored[len - 1] == '\n' ||
                       stored[len - 1] == ' ' || stored[len - 1] == '\t'))
    {
        stored[--len] = '\0';
    }
    if (stored[0] == '\0')
    {
        return;
    }
    pthread_mutex_lock(&g_ipv6_config_mutex);
    snprintf(g_ipv6_config, sizeof(g_ipv6_config), "%s", stored);
    pthread_mutex_unlock(&g_ipv6_config_mutex);

    char buf[384];
    snprintf(buf, sizeof(buf), "IFCONFIG6:%s", stored);
    emit_status(buf);
}

/* ROUTE6 MSG 形如 "<network>/<prefix> <device>"。android-gw 是绕过 VPN 的伪网关，不进隧道。 */
void ovpn_add_ipv6_route(const char *route)
{
    if (!route || route[0] == '\0')
    {
        return;
    }
    while (*route == ' ' || *route == '\t')
    {
        route++;
    }
    char token[OVPN_IPV6_ROUTE_LEN];
    size_t i = 0;
    while (route[i] != '\0' && route[i] != ' ' && route[i] != '\t' &&
           route[i] != '\r' && route[i] != '\n' && i + 1 < sizeof(token))
    {
        token[i] = route[i];
        i++;
    }
    token[i] = '\0';
    const char *device = route + i;
    while (*device == ' ' || *device == '\t')
    {
        device++;
    }
    if (strncmp(device, "android-gw", 10) == 0)
    {
        return;
    }
    if (strchr(token, ':') == NULL || strchr(token, '/') == NULL)
    {
        return;
    }

    pthread_mutex_lock(&g_ipv6_config_mutex);
    for (int n = 0; n < g_ipv6_route_count; n++)
    {
        if (strcmp(g_ipv6_routes[n], token) == 0)
        {
            pthread_mutex_unlock(&g_ipv6_config_mutex);
            return;
        }
    }
    if (g_ipv6_route_count >= OVPN_IPV6_ROUTE_MAX)
    {
        pthread_mutex_unlock(&g_ipv6_config_mutex);
        debug_log("IPv6 route dropped: table full");
        return;
    }
    snprintf(g_ipv6_routes[g_ipv6_route_count], OVPN_IPV6_ROUTE_LEN, "%s", token);
    g_ipv6_route_count++;
    pthread_mutex_unlock(&g_ipv6_config_mutex);

    char buf[160];
    snprintf(buf, sizeof(buf), "ROUTE6:%s", token);
    emit_status(buf);
}

int ovpn_get_ipv6_routes(char *routes, size_t routes_size)
{
    if (!routes || routes_size == 0)
    {
        return -1;
    }
    routes[0] = '\0';
    pthread_mutex_lock(&g_ipv6_config_mutex);
    size_t used = 0;
    for (int n = 0; n < g_ipv6_route_count; n++)
    {
        size_t len = strlen(g_ipv6_routes[n]);
        size_t need = len + (used > 0 ? 1 : 0);
        if (used + need + 1 > routes_size)
        {
            break;
        }
        if (used > 0)
        {
            routes[used++] = ',';
        }
        memcpy(routes + used, g_ipv6_routes[n], len);
        used += len;
        routes[used] = '\0';
    }
    int count = g_ipv6_route_count;
    pthread_mutex_unlock(&g_ipv6_config_mutex);
    return count;
}

int ovpn_get_ipv6_config(char *config, size_t config_size)
{
    if (!config || config_size == 0)
    {
        return -1;
    }
    pthread_mutex_lock(&g_ipv6_config_mutex);
    snprintf(config, config_size, "%s", g_ipv6_config);
    pthread_mutex_unlock(&g_ipv6_config_mutex);
    return config[0] == '\0' ? 0 : 1;
}

/* OpenVPN 退出时调用此函数记录状态 */
void ovpn_record_exit(int status)
{
    g_exit_status = status;
    char buf[128];
    snprintf(buf, sizeof(buf), "EXIT_STATUS=%d", status);
    debug_log(buf);
    emit_status(buf);
}

/* 过滤配置文件中的 Windows 专属选项（参考 OpenVPN for Android 客户端预处理逻辑）。
 * 鸿蒙/Linux 构建不认识的选项会导致 parse_argv 失败退出。 */
static void filter_config_file(const char *src_path, char *dst_path, size_t dst_size)
{
    snprintf(dst_path, dst_size, "%s.filtered", src_path);

    FILE *src = fopen(src_path, "r");
    if (!src)
    {
        /* 原文件打不开，退回用原路径 */
        snprintf(dst_path, dst_size, "%s", src_path);
        return;
    }
    FILE *dst = fopen(dst_path, "w");
    if (!dst)
    {
        fclose(src);
        snprintf(dst_path, dst_size, "%s", src_path);
        return;
    }

    char line[2048];
    int removed = 0;
    while (fgets(line, sizeof(line), src))
    {
        char *p = line;
        while (*p == ' ' || *p == '\t')
        {
            p++;
        }

        /* Windows 专属选项，鸿蒙构建不支持，跳过 */
        if (strncmp(p, "block-outside-dns", 17) == 0
            || strncmp(p, "route-method", 12) == 0
            || strncmp(p, "register-dns", 12) == 0
            || strncmp(p, "win-sys", 7) == 0
            || strncmp(p, "dhcp-option DOMAIN", 18) == 0
            || strncmp(p, "cryptoapicert", 13) == 0
            || strncmp(p, "tls-crypto-v2", 13) == 0)
        {
            char logbuf[300];
            snprintf(logbuf, sizeof(logbuf), "Filtered Windows-only option: %s", p);
            logbuf[strcspn(logbuf, "\r\n")] = '\0';
            debug_log(logbuf);
            removed++;
            continue;
        }

        fputs(line, dst);
    }
    fclose(src);
    fclose(dst);

    char logbuf[128];
    snprintf(logbuf, sizeof(logbuf), "Config filtered: %d Windows-only lines removed", removed);
    debug_log(logbuf);
}

/* ---------------- core 线程 ---------------- */

/* 线程清理函数：当 core 线程通过 pthread_exit（openvpn_exit 在 __OHOS__ 下
 * 改用 pthread_exit 退出）或正常返回时，pthread 都会调用它。
 *
 * 这是卡死问题的核心修复：之前 pthread_exit 让 main() 不返回，
 * core_thread_main 里 main() 之后的 g_running=0 永远执行不到，
 * 导致下次 ovpn_start() 误判旧实例仍在运行、等待 5 秒后返回 -1。 */
static void core_thread_cleanup(void *arg)
{
    (void)arg;
    if (g_running)
    {
        g_running = 0;
        debug_log("THREAD_CLEANUP: g_running=0");
        emit_status("THREAD_EXITED");
    }
}

/* 实际执行 OpenVPN 的线程体（从 core_thread_main 拆出，便于 cleanup 包裹） */
static void core_thread_run(void)
{
    debug_log("=== THREAD_STARTED ===");
    emit_status("THREAD_STARTED");

    /* 追加日志文件 = 关闭时：每次连接覆盖连接日志（对齐原版 log_append=0） */
    if (g_append_log == 0)
    {
        int fd = open(g_conn_log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0)
        {
            close(fd);
        }
        debug_log("log append disabled: openvpn.log truncated for this connection");
    }

    /* 安装信号处理器 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = signal_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    debug_log("Signal handlers installed");

    /* management socket 放在应用私有目录（config 目录的上级，即 files 目录）
     * g_config_path 形如: .../files/config/xxx.ovpn
     * 文件名带管理端口偏移（对齐原版 mgmt_port_offset：端口 = 偏移 + 配置索引，
     * 鸿蒙 unix socket 用文件名区分，避免多配置共用同一 socket 状态）。 */
    char mgmt_path[512];
    mgmt_path[0] = '\0';
    {
        char *last_slash = strrchr(g_config_path, '/');
        if (last_slash)
        {
            *last_slash = '\0';                       /* → .../files/config */
            char *config_dir_end = strrchr(g_config_path, '/');
            if (config_dir_end)
            {
                *config_dir_end = '\0';               /* → .../files */
                snprintf(mgmt_path, sizeof(mgmt_path), "%s/ovpn_mgmt_%d.sock",
                         g_config_path, g_mgmt_port_offset);
                *config_dir_end = '/';                /* 还原 */
            }
            *last_slash = '/';                        /* 还原 */
        }
    }
    if (mgmt_path[0] == '\0')
    {
        snprintf(mgmt_path, sizeof(mgmt_path), "/data/storage/el2/base/haps/entry/files/ovpn_mgmt_%d.sock",
                 g_mgmt_port_offset);
    }
    debug_log("Mgmt socket path:");
    debug_log(mgmt_path);

    /* 如果设置了配置文件路径，使用 --config 参数 */
    if (g_config_path[0] != '\0')
    {
        char status_buf[256];
        snprintf(status_buf, sizeof(status_buf), "CONFIG:%s", g_config_path);
        debug_log(status_buf);
        emit_status(status_buf);

        /* 过滤 Windows 专属选项，生成 .filtered 配置文件 */
        char filtered_config[560];
        filter_config_file(g_config_path, filtered_config, sizeof(filtered_config));
        debug_log("Using filtered config:");
        debug_log(filtered_config);

        /* 先启动 management server（上层监听，OpenVPN 作为 client 连入）
         * 与 Windows OpenVPN GUI 相同的机制 */
        debug_log("Starting management server...");
        if (mgmt_client_start(mgmt_path, on_auth_request) == 0)
        {
            debug_log("Management server started");
        }
        else
        {
            debug_log("Failed to start management server");
        }

        /* 构建 OpenVPN argv（对齐原版 GUI BuildCommandLine）：
         * 代理：手动设置时注入 --http-proxy/--socks-proxy（OpenVPN 原生参数）；
         * 使用配置文件设置 / 系统代理：不注入（系统代理鸿蒙无法读取，等同配置文件）。 */
        char *argv[32];
        int ac = 0;
        argv[ac++] = (char *)"openvpn";
        argv[ac++] = (char *)"--config";
        argv[ac++] = filtered_config;
        argv[ac++] = (char *)"--management";
        argv[ac++] = mgmt_path;
        argv[ac++] = (char *)"unix";                           /* Unix socket 模式 */
        argv[ac++] = (char *)"--management-client";
        argv[ac++] = (char *)"--management-query-passwords";  /* 允许通过 management 接口查询密码 */
        /* 不注入 --auth-nocache。原版重新连接只发 SIGHUP，凭据留在本次进程里，
         * 无论是否保存密码都不再向管理接口要账号。新的一次连接仍由 ovpn_start
         * 里的 ssl_purge_auth 清掉跨 main() 残留，避免换配置时跳过认证框。 */

        /* CLI 无头模式凭据文件：--auth-user-pass <file>（两行：用户名/密码）。
         * OpenVPN 初始化时直接读文件 → auth_user_pass.defined=true → 不弹密码请求，
         * 实现"命令行直接连接"（对齐原版 openvpn.exe --auth-user-pass creds.txt） */
        if (g_auth_file[0] != '\0')
        {
            argv[ac++] = (char *)"--auth-user-pass";
            argv[ac++] = g_auth_file;
            debug_log("auth-user-pass file injected");
        }

        argv[ac++] = (char *)"--connect-timeout";
        argv[ac++] = (char *)"10";                             /* TCP connect 10 秒超时（默认 120s 太久，
                                                                  服务器不可达时会长时间无反馈） */
        /* 不在命令行注入 --verb。OpenVPN 按出现顺序解析，写在 --config 后面会覆盖
         * 配置文件里的 verb。文件有 verb n 时用该级别；没有时用源码默认 1。
         * 级别只在本次进程启动时生效，已连接期间改文件要断开再连。 */

        /* 非「使用配置文件」时，由管理接口在每条远端上回答代理，而不是把用户名拼进启动参数。 */
        prepare_socks_auth_file();
        if (g_proxy_mode != 0)
        {
            argv[ac++] = (char *)"--management-query-proxy";
            debug_log("management-query-proxy enabled");
        }
        /* 对齐 Windows GUI BuildCommandLine：认证失败 SIGUSR1 重试并再次 Need 'Auth'，
         * 默认 auth-retry=none 会直接 SIGTERM/EXITING，界面无法二次弹框。 */
        argv[ac++] = (char *)"--auth-retry";
        argv[ac++] = (char *)"interact";
        argv[ac] = NULL;
        int argc = ac;

        debug_log("CALLING_MAIN_WITH_CONFIG");
        emit_status("CALLING_MAIN");

        int ret = main(argc, argv);

        debug_log("MAIN_RETURNED");

        /* management server 保持常驻（应用生命周期内只创建一次），
         * OpenVPN 下次连接（重连/切换配置）会重新连入同一个 server。
         * 不停 server，避免与下一次 ovpn_start 产生竞态。 */

        g_running = 0;
        char buf[128];
        snprintf(buf, sizeof(buf), "EXITED:%d", ret);
        debug_log(buf);
        emit_status(buf);
        return;
    }
    else
    {
        /* 没有配置文件，返回错误 */
        debug_log("ERROR:No config file");
        g_running = 0;
        emit_status("ERROR:No config file");
        return;
    }
}

/* core_thread_main：用 pthread_cleanup_push 包裹 core_thread_run。
 * openvpn_exit 在 __OHOS__ 下用 pthread_exit 退出线程，不会返回 main()，
 * 因此 main() 之后的清理代码（g_running=0）走不到；pthread_cleanup_push
 * 保证线程以任何方式结束时（pthread_exit / 正常返回）都会调用
 * core_thread_cleanup 把 g_running 归零。 */
static void *core_thread_main(void *arg)
{
    (void)arg;
    pthread_cleanup_push(core_thread_cleanup, NULL);
    core_thread_run();
    pthread_cleanup_pop(1);
    return NULL;
}

/* ---------------- 导出接口（extern C 供 napi 调用） ---------------- */

/* 停止 OpenVPN：双通道发信号（原版 Windows GUI 只用 socket，我们加强版）
 * 1. 进程内直发（register_signal 设置 OpenVPN 全局信号标志，event loop 检测后退出）
 *    —— 不依赖 management socket，即使 socket 已断（认证等待中）也能停止 OpenVPN
 * 2. management 命令（Windows GUI 同款机制，socket 连接正常时使用） */
static void ovpn_signal_stop(void)
{
    debug_log("ovpn_signal_stop: sending SIGTERM via register_signal + mgmt socket");
    register_signal(&siginfo_static, SIGTERM, "stop_from_bridge");
    mgmt_client_send_cmd("signal SIGTERM\n");
}

int ovpn_start(void)
{
    debug_log("ovpn_start() called");

    /* 如果上一个 OpenVPN 线程还在运行（例如连接失败后仍处于重试循环），
     * 先发 SIGTERM 停掉旧实例（进程内信号 + socket 双保险，不依赖 socket 连接状态），
     * 等待退出后再启动新实例。与 Windows GUI 的"先 stop 再 start"一致。
     * 注意：不停 management server（常驻，等待 OpenVPN 重连）。 */
    if (g_running)
    {
        debug_log("ovpn_start: previous instance still running, stopping it...");
        ovpn_signal_stop();  /* 双通道发 SIGTERM */

        for (int i = 0; i < 50 && g_running; i++)
        {
            usleep(100000);  /* 等待 5 秒 */
        }

        if (g_running)
        {
            debug_log("ovpn_start: previous instance did not exit in 5s");
            return -1;
        }
    }

    /* 关键修复：清除上次停止时残留的全局信号标志。
     *
     * ovpn_signal_stop() 通过 register_signal(&siginfo_static, SIGTERM, ...)
     * 设置 siginfo_static.signal_received = SIGTERM。OpenVPN 的 init_signal()
     * 只 reset SIGUSR1/SIGUSR2/SIGHUP，不 reset SIGTERM，导致该标志跨
     * main() 调用残留——下一次启动时 OpenVPN 一进主循环就检测到残留的
     * SIGTERM，立即退出（status=0，日志表现为 CALLING_MAIN 后直接 EXITED），
     * 表现为"取消认证后换配置再连接没反应"。
     *
     * signal_reset(&siginfo_static, 0) 无条件清零（signum=0 时不比较当前值）。 */
    signal_reset(&siginfo_static, 0);
    pthread_mutex_lock(&g_ipv6_config_mutex);
    clear_ipv6_cache_locked();
    pthread_mutex_unlock(&g_ipv6_config_mutex);
    debug_log("ovpn_start: signal flag cleared");

    /* 清除 OpenVPN 全局凭据缓存（auth_user_pass / auth_token 是 static 全局变量，
     * 同一进程内跨 main() 调用残留——上次连接输入的密码和服务器下发的 auth-token
     * 会让下一次连接跳过 PASSWORD 请求直接认证，导致"切换配置后不弹认证窗"。
     * 与 Windows GUI 每次连接前干净状态一致：每次连接都重新要密码。 */
    ssl_purge_auth(false);
    (void)ssl_clean_auth_token();
    debug_log("ovpn_start: auth credentials purged");

    debug_log("Creating thread...");
    g_running = 1;

    if (pthread_create(&g_core_thread, NULL, core_thread_main, NULL) != 0)
    {
        debug_log("pthread_create() FAILED");
        g_running = 0;
        return -1;
    }

    debug_log("Thread created successfully");
    return 0;
}

int ovpn_reconnect(void)
{
    if (!g_running)
    {
        debug_log("ovpn_reconnect: not running, caller should start instead");
        return -1;
    }

    /* 原版 Windows GUI 只通过 management 发 signal SIGHUP。
     * 不能再同时 register_signal：主循环看到进程内信号后会跳过 event_wait，
     * 套接字里的 "signal SIGHUP" 读不到。重启后的认证等待会把它当成新的
     * SIGHUP，management_query_user_pass 失败并 FATAL，认证框提交也接不上。 */
    pthread_mutex_lock(&g_ipv6_config_mutex);
    clear_ipv6_cache_locked();
    pthread_mutex_unlock(&g_ipv6_config_mutex);
    debug_log("ovpn_reconnect: clearing cached IPv6 config");
    debug_log("ovpn_reconnect: sending SIGHUP via management");
    if (mgmt_client_send_cmd("signal SIGHUP\n") != 0)
    {
        debug_log("ovpn_reconnect: management send failed, fallback register_signal");
        register_signal(&siginfo_static, SIGHUP, "reconnect_from_bridge");
    }
    return 0;
}

int ovpn_stop(void)
{
    if (!g_running)
    {
        return 0;
    }

    /* 通过双通道发送 SIGTERM（进程内信号 + management socket），
     * 立即返回——OpenVPN 线程自行清理退出后，
     * core_thread_main 会置 g_running=0 并推送 EXITED 状态。
     * 不能同步等待（OpenVPN 清理耗时导致 UI 卡顿），
     * 也不能直接调用 openvpn_exit()（pthread_exit 会杀掉调用线程）。 */
    ovpn_signal_stop();
    return 0;
}

int ovpn_is_running(void)
{
    return g_running;
}

int ovpn_set_tun_fd(int fd)
{
    /* 把 tun fd 通过 SCM_RIGHTS 传给 OpenVPN（OPENTUN 协议） */
    debug_log("ovpn_set_tun_fd called");
    char buf[64];
    snprintf(buf, sizeof(buf), "set_tun_fd=%d", fd);
    debug_log(buf);
    return mgmt_client_send_tun_fd(fd);
}

const char *ovpn_version(void)
{
    /* title_string 是编译期字符串字面量数组，恒非空 */
    return title_string;
}
