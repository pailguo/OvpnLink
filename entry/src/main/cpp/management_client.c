/*
 * management_client.c
 * Management 服务端（对应 Windows OpenVPN GUI 的 manage.c 角色）
 *
 * 机制（与 Windows OpenVPN GUI 一致）：
 *   上层(GUI)创建 Unix socket server 并监听
 *     → OpenVPN 以 --management <path> --management-client 方式主动连接
 *     → 连接后 OpenVPN 发送 ">INFO:..." 欢迎信息
 *     → 需要认证时 OpenVPN 发送 ">PASSWORD:Need 'Auth' username/password"
 *     → 本层回调上层(NAPI → ArkTS)弹出登录框
 *     → 上层调用 mgmt_client_send_auth() 把用户名/密码发回 OpenVPN
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <hilog/log.h>

#include "core/openvpn/sig.h"  /* struct signal_info */

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "ManagementServer"

static int g_listen_sock = -1;
static int g_client_sock = -1;
/* 本进程已经把 tun fd 交给当前 OpenVPN。SIGHUP 时回复 NOACTION，避免
 * OPEN_BEFORE_CLOSE 关掉正在使用的同一个 fd。进程退出后静态变量归零。 */
static int g_tun_handed = 0;
static pthread_t g_server_thread;
static volatile int g_running = 0;

/* 回调函数：需要用户名/密码时调用 */
static void (*g_auth_request_cb)(const char *type) = NULL;

/* 回调函数：OpenVPN 请求创建 tun 设备（OPENTUN）时调用 */
static void (*g_tun_request_cb)(const char *dev) = NULL;

/* 回调函数：OpenVPN 请求保护 socket（PROTECTFD，SCM_RIGHTS 附带 fd）时调用。
 * 上层须对 fd 调用 VpnConnection.protect()，使该 socket 流量绕过 VPN 隧道
 * （防止默认路由下隧道自环）。对齐 OpenVPN for Android 的 protect 模型。 */
static void (*g_protect_fd_cb)(int fd) = NULL;

/* 回调函数：流量统计更新（>BYTECOUNT 推送） */
static void (*g_bytecount_cb)(long long bytes_in, long long bytes_out) = NULL;

/* 回调函数：连接状态更新（>STATE 推送） */
static void (*g_state_cb)(const char *state, const char *detail) = NULL;

/* >PASSWORD:Verification Failed（对齐 Windows GUI OnPassword） */
static void (*g_auth_verify_failed_cb)(void) = NULL;

/* 回调函数：日志行（>LOG 推送，log on all 机制）
 * 格式 "level|formatted_line"，level: 0=普通 1=错误 2=警告 */
static void (*g_log_push_cb)(const char *formatted) = NULL;

/* 回调函数：echo 消息（>ECHO 推送） */
static void (*g_echo_cb)(const char *message) = NULL;

/* 收到一行 management 消息时回调（用于日志/状态） */
static void (*g_line_cb)(const char *line) = NULL;

static void mgmt_log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    OH_LOG_INFO(LOG_APP, "[MgmtSrv] %{public}s", buf);

    /* 写入文件便于 hdc 定位 */
    int fd = open("/data/storage/el2/base/cache/openvpn_mgmt.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0)
    {
        write(fd, buf, strlen(buf));
        write(fd, "\n", 1);
        close(fd);
    }
}

/* >PASSWORD:Verification Failed: 'Auth' [...] — VPN 账号密码被拒 */
static void parse_auth_verify_failed(const char *line)
{
    const char *prefix = ">PASSWORD:Verification Failed:";
    if (strncmp(line, prefix, strlen(prefix)) != 0)
    {
        return;
    }
    if (strstr(line, "'Auth'") == NULL)
    {
        return;
    }
    mgmt_log("auth verification failed for Auth");
    if (g_auth_verify_failed_cb)
    {
        g_auth_verify_failed_cb();
    }
}

/* 解析一行消息：">PASSWORD:Need 'Auth' username/password" → 提取认证类型 */
static const char *parse_auth_type(const char *line)
{
    /* 形如 >PASSWORD:Need 'Auth' username/password */
    const char *need = strstr(line, ">PASSWORD:Need");
    if (!need)
    {
        return NULL;
    }
    const char *q = strchr(need, '\'');
    if (!q)
    {
        return NULL;
    }
    const char *end = strchr(q + 1, '\'');
    if (!end)
    {
        return NULL;
    }
    static char auth_type[64];
    size_t len = (size_t)(end - q - 1);
    if (len >= sizeof(auth_type))
    {
        len = sizeof(auth_type) - 1;
    }
    memcpy(auth_type, q + 1, len);
    auth_type[len] = '\0';
    return auth_type;
}

/* 解析 >BYTECOUNT:<in>,<out> 推送（Windows GUI 的 bytecount 5 机制） */
static void parse_bytecount(const char *line)
{
    const char *prefix = ">BYTECOUNT:";
    if (strncmp(line, prefix, strlen(prefix)) == 0)
    {
        const char *body = line + strlen(prefix);
        const char *comma = strchr(body, ',');
        if (comma)
        {
            long long bytes_in = atoll(body);
            long long bytes_out = atoll(comma + 1);
            if (g_bytecount_cb)
            {
                g_bytecount_cb(bytes_in, bytes_out);
            }
        }
    }
}

/* 解析 >LOG:<unix_ts>,<flags>,<msg> 推送（Windows GUI 的 log on all 机制）。
 * 颜色规则与 Windows OnLogLine 一致：
 *   flags 含 'F'(FATAL) 或 'N'(NONFATAL) → 红色
 *   flags 含 'W'(WARN) → 警告色
 *   其他 → 黑色 */
static void parse_log(const char *line)
{
    const char *prefix = ">LOG:";
    if (strncmp(line, prefix, strlen(prefix)) != 0)
    {
        return;
    }

    const char *body = line + strlen(prefix);
    const char *comma1 = strchr(body, ',');
    if (!comma1)
    {
        return;
    }
    time_t ts = (time_t)atoll(body);

    const char *flags = comma1 + 1;
    const char *comma2 = strchr(flags, ',');
    if (!comma2)
    {
        return;
    }
    size_t flags_len = (size_t)(comma2 - flags);
    const char *msg = comma2 + 1;

    /* Windows 颜色规则 */
    int level = 0;
    if (memchr(flags, 'F', flags_len) || memchr(flags, 'N', flags_len))
    {
        level = 1;  /* 红色 */
    }
    else if (memchr(flags, 'W', flags_len))
    {
        level = 2;  /* 警告色 */
    }

    /* 格式化时间戳（与 Windows 相同格式 "Thu Aug 13 10:55:26 2026"） */
    struct tm tmv;
    localtime_r(&ts, &tmv);
    char timebuf[64];
    strftime(timebuf, sizeof(timebuf), "%a %b %d %H:%M:%S %Y", &tmv);

    char out[1024];
    snprintf(out, sizeof(out), "%d|%s %s", level, timebuf, msg);

    if (g_log_push_cb)
    {
        g_log_push_cb(out);
    }
}

/* >ECHO:<unix_ts>,<message> */
static void parse_echo(const char *line)
{
    const char *prefix = ">ECHO:";
    const char *body;
    const char *comma;
    const char *msg;
    if (strncmp(line, prefix, strlen(prefix)) != 0)
    {
        return;
    }
    body = line + strlen(prefix);
    comma = strchr(body, ',');
    msg = comma != NULL ? comma + 1 : body;
    if (msg[0] == '\0' || g_echo_cb == NULL)
    {
        return;
    }
    g_echo_cb(msg);
}

/* 解析 >STATE:<ts>,<STATE_NAME>,<detail>,... 推送（Windows GUI 的 state on 机制） */
static void parse_state(const char *line)
{
    const char *prefix = ">STATE:";
    if (strncmp(line, prefix, strlen(prefix)) != 0)
    {
        return;
    }

    const char *body = line + strlen(prefix);
    /* 跳过时间戳 */
    const char *comma1 = strchr(body, ',');
    if (!comma1)
    {
        return;
    }
    const char *state = comma1 + 1;
    const char *comma2 = strchr(state, ',');
    if (!comma2)
    {
        return;
    }
    char state_name[32];
    size_t s_len = (size_t)(comma2 - state);
    if (s_len >= sizeof(state_name))
    {
        s_len = sizeof(state_name) - 1;
    }
    memcpy(state_name, state, s_len);
    state_name[s_len] = '\0';

    const char *detail = comma2 + 1;
    const char *comma3 = strchr(detail, ',');
    char detail_buf[192];
    size_t d_len = comma3 ? (size_t)(comma3 - detail) : strlen(detail);
    if (d_len >= sizeof(detail_buf))
    {
        d_len = sizeof(detail_buf) - 1;
    }
    memcpy(detail_buf, detail, d_len);
    detail_buf[d_len] = '\0';

    /* 提取 local IP（STATE 格式第 4 字段）追加到 detail（"detail|local_ip"）。
     * 实测 OpenVPN 2.7 TARGET_ANDROID 推送：
     *   ASSIGN_IP: >STATE:ts,ASSIGN_IP,,10.96.0.6,,,,   ← 第 3 字段空，IP 在第 4 字段
     *   CONNECTED: >STATE:ts,CONNECTED,SUCCESS,10.96.0.6,...
     * 因此对 ASSIGN_IP / CONNECTED 统一提取第 4 字段（local_ip），供上层
     * 动态配置 tun 地址（对齐原版 do_ifconfig）。 */
    if (comma3)
    {
        const char *local_ip = comma3 + 1;
        const char *comma4 = strchr(local_ip, ',');
        size_t ip_len = comma4 ? (size_t)(comma4 - local_ip) : strlen(local_ip);
        if (ip_len > 0 && ip_len + d_len + 2 < sizeof(detail_buf))
        {
            detail_buf[d_len++] = '|';
            memcpy(detail_buf + d_len, local_ip, ip_len);
            d_len += ip_len;
            detail_buf[d_len] = '\0';
        }
    }

    mgmt_log("state: %s (%s)", state_name, detail_buf);

    if (g_state_cb)
    {
        g_state_cb(state_name, detail_buf);
    }
}

/* management server 主循环 */
static void *server_thread_main(void *arg)
{
    const char *socket_path = (const char *)arg;
    char buffer[4096];

    mgmt_log("server thread started, listening on %s", socket_path);

    /* 创建 Unix socket */
    g_listen_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_listen_sock < 0)
    {
        mgmt_log("socket() failed: errno=%d", errno);
        return NULL;
    }

    /* 删除可能残留的旧 socket 文件 */
    unlink(socket_path);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(g_listen_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
        mgmt_log("bind() failed: errno=%d", errno);
        close(g_listen_sock);
        g_listen_sock = -1;
        return NULL;
    }

    if (listen(g_listen_sock, 1) < 0)
    {
        mgmt_log("listen() failed: errno=%d", errno);
        close(g_listen_sock);
        g_listen_sock = -1;
        return NULL;
    }

    mgmt_log("listening OK, waiting for OpenVPN to connect...");

    /* 外层循环：OpenVPN 认证失败/重连时会断开 management 连接，
     * 保持监听并重新 accept（Android 客户端 LocalServerSocket 同款行为）。
     * 这样 signal 命令（SIGTERM/SIGHUP）在任何时候都能送达。 */
    while (g_running)
    {
        /* 等待 OpenVPN (--management-client) 连接 */
        g_client_sock = accept(g_listen_sock, NULL, NULL);
        if (g_client_sock < 0)
        {
            if (g_running)
            {
                mgmt_log("accept() failed: errno=%d", errno);
            }
            break;
        }

        mgmt_log("OpenVPN connected to management interface");

        /* 设置 socket 接收超时（1 秒），避免 recv() 无限阻塞导致无法响应停止信号 */
        struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(g_client_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        /* 与 Windows OpenVPN GUI 相同的初始化命令序列（OnReady）：
         *   state on      → OpenVPN 推送 >STATE 消息（连接状态）
         *   log on all    → OpenVPN 推送 >LOG 消息（日志）
         *   bytecount 5   → OpenVPN 每 5 秒推送 >BYTECOUNT 消息（流量） */
        send(g_client_sock, "state on\n", 9, 0);
        send(g_client_sock, "log on all\n", 11, 0);
        send(g_client_sock, "echo on all\n", 12, 0);
        send(g_client_sock, "bytecount 5\n", 12, 0);

        /* 内层循环：读取 management 消息
         * 注意：必须用 recvmsg 而非 recv —— OpenVPN TARGET_ANDROID 模式在
         * PROTECTFD 消息（man_send_with_fd）通过 SCM_RIGHTS 附带 socket fd，
         * 用 recv() 会丢弃 fd，导致上层无法 protect 导致隧道自环。 */
        while (g_running)
        {
            char control[256];
            struct iovec iov;
            struct msghdr hdr;
            int msg_fd = -1;

            iov.iov_base = buffer;
            iov.iov_len = sizeof(buffer) - 1;
            memset(&hdr, 0, sizeof(hdr));
            hdr.msg_iov = &iov;
            hdr.msg_iovlen = 1;
            hdr.msg_control = control;
            hdr.msg_controllen = sizeof(control);

            ssize_t n = recvmsg(g_client_sock, &hdr, 0);
            if (n < 0)
            {
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                {
                    /* 超时（1 秒无数据，用户可能正在输密码）→ 继续等待。
                     *
                     * 注意：这里绝不能检查 siginfo_static.signal_received 并断开！
                     * 否则 OpenVPN 在认证等待期间（用户输密码的几秒内），
                     * 若 OpenVPN 内部因连接重试/其他原因设置了任何信号，
                     * server 会误判为"停止"而掐断连接，导致 OpenVPN 报
                     * "could not read Auth username/password" 认证失败。
                     *
                     * 停止 OpenVPN 有两条正路，均不依赖此处的信号检查：
                     *   1. ovpn_signal_stop() 的 register_signal(SIGTERM) ——
                     *      OpenVPN 主循环检测到后自行退出并关闭 management 连接，
                     *      此处 recv 会返回 0 自然退出；
                     *   2. mgmt_client_send_cmd("signal SIGTERM") —— 通过 socket 命令。
                     * 本循环仅依赖 g_running 标志（mgmt_client_stop 置 0）和
                     * recv 返回 0（OpenVPN 主动断开）退出。 */
                    continue;
                }
                mgmt_log("recv error: errno=%d (g_running=%d sock=%d)", errno, g_running, g_client_sock);
                break;
            }
            if (n == 0)
            {
                mgmt_log("connection closed by OpenVPN (g_running=%d sock=%d)", g_running, g_client_sock);
                break;
            }

            /* 解析本消息附带的 fd（SCM_RIGHTS，OpenVPN 的 fdtosend 机制） */
            struct cmsghdr *cm;
            for (cm = CMSG_FIRSTHDR(&hdr); cm != NULL; cm = CMSG_NXTHDR(&hdr, cm))
            {
                if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
                {
                    msg_fd = *(int *)CMSG_DATA(cm);
                    mgmt_log("recvmsg: SCM_RIGHTS fd=%d", msg_fd);
                }
            }

            buffer[n] = '\0';

            /* 消息可能包含多行，逐行处理 */
            char *saveptr = NULL;
            char *line = strtok_r(buffer, "\r\n", &saveptr);
            while (line)
            {
                mgmt_log("recv: %s", line);

            if (g_line_cb)
            {
                g_line_cb(line);
            }

            /* 流量统计推送 */
            parse_bytecount(line);

            /* 连接状态推送 */
            parse_state(line);

            /* 日志推送（log on all） */
            parse_log(line);

            /* echo 推送（echo on all）：>ECHO:<unix_ts>,<message> */
            parse_echo(line);

            /* >PROXY:序号,TCP|UDP,主机 。必须在本线程立刻回答，OpenVPN 在等这条命令。 */
            const char *proxy_at = strstr(line, ">PROXY:");
            if (proxy_at != NULL)
            {
                extern void ovpn_reply_proxy_query(const char *body);
                ovpn_reply_proxy_query(proxy_at + 7);
            }

            parse_auth_verify_failed(line);

            /* 检查是否是密码请求 */
            const char *auth_type = parse_auth_type(line);
            if (auth_type)
            {
                mgmt_log("PASSWORD request detected, auth type: %s", auth_type);
                if (g_auth_request_cb)
                {
                    g_auth_request_cb(auth_type);
                }
            }

            /* TARGET_ANDROID 模式：OpenVPN 请求上层保护 socket 防止环路。
             * 该消息经 SCM_RIGHTS 附带 OpenVPN 的 UDP/TCP socket fd（fdtosend），
             * 上层须对 fd 调用 VpnConnection.protect() 使其绕过 VPN 隧道；
             * 否则默认路由下隧道包被引回 tun 形成自环（EHOSTUNREACH/断连）。 */
            if (strstr(line, ">NEED-OK:Need 'PROTECTFD'") != NULL)
            {
                const char *reply = "needok 'PROTECTFD' ok\n";
                send(g_client_sock, reply, strlen(reply), 0);
                if (g_protect_fd_cb && msg_fd > 0)
                {
                    mgmt_log("PROTECTFD: forwarding fd=%d to upper layer", msg_fd);
                    g_protect_fd_cb(msg_fd);
                }
                else
                {
                    mgmt_log("PROTECTFD: no fd received (msg_fd=%d), skipped protect", msg_fd);
                }
            }

            /* TARGET_ANDROID 模式：OpenVPN 请求创建 tun 设备。
             * 格式：>NEED-OK:Need 'OPENTUN' confirmation MSG:<dev>
             * 上层须创建 tun fd 并用 SCM_RIGHTS 发回（见 mgmt_client_send_tun_fd） */
            if (strstr(line, ">NEED-OK:Need 'OPENTUN'") != NULL)
            {
                char dev[64] = {0};
                const char *msg_part = strstr(line, "MSG:");
                if (msg_part)
                {
                    strncpy(dev, msg_part + 4, sizeof(dev) - 1);
                }
                else
                {
                    strncpy(dev, "tun", sizeof(dev) - 1);
                }
                mgmt_log("OPENTUN request detected, dev=%s", dev);
                if (g_tun_request_cb)
                {
                    g_tun_request_cb(dev);
                }
            }

            /* TARGET_ANDROID 模式的其他控制消息（IFCONFIG/DNSSERVER/DNSDOMAIN/
             * HTTPPROXY/PERSIST_TUN_ACTION 等）只需 needok 确认回复，
             * 具体配置由 ArkTS 层后续解析处理。 */
            const char *needok = strstr(line, ">NEED-OK:Need '");
            if (needok)
            {
                const char *type_start = needok + 15;  /* 跳过 ">NEED-OK:Need '" */
                const char *type_end = strchr(type_start, '\'');
                if (type_end)
                {
                    char type[64];
                    size_t tlen = (size_t)(type_end - type_start);
                    if (tlen >= sizeof(type))
                    {
                        tlen = sizeof(type) - 1;
                    }
                    memcpy(type, type_start, tlen);
                    type[tlen] = '\0';

                    /* PERSIST_TUN_ACTION：OpenVPN TARGET_ANDROID 询问如何处理旧 tun。
                     * 第一次还没有 fd，回复 OPEN_BEFORE_CLOSE，让它发 OPENTUN。
                     * oldtunfd < 0 时 OpenVPN 会忽略 NOACTION 并仍然 OPENTUN。
                     * 已经交过 fd 后再 SIGHUP，回复 NOACTION：保留旧 fd，不再 OPENTUN，
                     * 也不会 close 掉正在使用的描述符。VpnConnection.create 只能成功一次。 */
                    if (strcmp(type, "PERSIST_TUN_ACTION") == 0)
                    {
                        const char *reply = g_tun_handed
                            ? "needok 'PERSIST_TUN_ACTION' NOACTION\n"
                            : "needok 'PERSIST_TUN_ACTION' OPEN_BEFORE_CLOSE\n";
                        mgmt_log("replying to PERSIST_TUN_ACTION: %s",
                                 g_tun_handed ? "NOACTION" : "OPEN_BEFORE_CLOSE");
                        send(g_client_sock, reply, strlen(reply), 0);
                    }
                    /* IFCONFIG6：OpenVPN TARGET_ANDROID 推送 IPv6 地址、前缀和 MTU。
                     * 格式：>NEED-OK:Need 'IFCONFIG6' confirmation MSG:<addr>/<prefix> <mtu>
                     * 必须在 OPENTUN 前上报给 ArkTS，供 VpnConfig.addresses 配置 family=2 地址。 */
                    else if (strcmp(type, "IFCONFIG6") == 0)
                    {
                        const char *msg_part = strstr(line, "MSG:");
                        if (msg_part)
                        {
                            extern void ovpn_emit_ipv6_config(const char *config);
                            ovpn_emit_ipv6_config(msg_part + 4);
                        }
                        char reply[128];
                        snprintf(reply, sizeof(reply), "needok '%s' ok\n", type);
                        send(g_client_sock, reply, strlen(reply), 0);
                    }
                    /* ROUTE6：OpenVPN TARGET_ANDROID 在 OPENTUN 之前推送 IPv6 路由。
                     * 格式：>NEED-OK:Need 'ROUTE6' confirmation MSG:<network>/<prefix> <device>
                     * redirect-gateway ipv6 为 ::/3、2000::/4、3000::/4、fc00::/7。 */
                    else if (strcmp(type, "ROUTE6") == 0)
                    {
                        const char *msg_part = strstr(line, "MSG:");
                        if (msg_part)
                        {
                            extern void ovpn_add_ipv6_route(const char *route);
                            ovpn_add_ipv6_route(msg_part + 4);
                        }
                        char reply[128];
                        snprintf(reply, sizeof(reply), "needok '%s' ok\n", type);
                        send(g_client_sock, reply, strlen(reply), 0);
                    }
                    /* DNSSERVER/DNS6SERVER：OpenVPN TARGET_ANDROID 通过 management 推送服务端 DNS
                     * （对齐原版 Android 客户端 DNS 推送；FR-4.18-10）。
                     * 格式：>NEED-OK:Need 'DNSSERVER' confirmation MSG:10.96.0.1
                     * 或：>NEED-OK:Need 'DNS6SERVER' confirmation MSG:2001:db8::53
                     * 提取 MSG: 后地址 → ovpn_emit_dns → ArkTS VpnConfig.dnsAddresses */
                    else if (strcmp(type, "DNSSERVER") == 0 || strcmp(type, "DNS6SERVER") == 0)
                    {
                        const char *msg_part = strstr(line, "MSG:");
                        if (msg_part)
                        {
                            extern void ovpn_emit_dns(const char *addrs);
                            ovpn_emit_dns(msg_part + 4);
                        }
                        char reply[128];
                        snprintf(reply, sizeof(reply), "needok '%s' ok\n", type);
                        send(g_client_sock, reply, strlen(reply), 0);
                    }
                    /* OPENTUN 和 PROTECTFD 已单独处理，其他全部自动确认 */
                    else if (strcmp(type, "OPENTUN") != 0
                             && strcmp(type, "PROTECTFD") != 0)
                    {
                        char reply[128];
                        snprintf(reply, sizeof(reply), "needok '%s' ok\n", type);
                        mgmt_log("auto-replying to NEED-OK: %s", type);
                        send(g_client_sock, reply, strlen(reply), 0);
                    }
                }
            }

            line = strtok_r(NULL, "\r\n", &saveptr);
        }   /* while (line) 行处理结束 */

        /* 内层 while (g_running) 循环在此结束：只有 g_running 变 0、
         * recv 出错或 OpenVPN 主动断开时才会走到这里。
         * 注意：close + waiting 必须在循环外，否则每次收到消息就关 socket！ */
        }

        /* 关闭当前连接，回到外层重新 accept，
         * 等待 OpenVPN 重连（认证失败/重启后 OpenVPN 会重新连入） */
        if (g_client_sock >= 0)
        {
            close(g_client_sock);
            g_client_sock = -1;
        }
        mgmt_log("waiting for OpenVPN to reconnect...");
    }

    /* 外层循环结束（g_running=0）：清理并退出 */
    if (g_client_sock >= 0)
    {
        close(g_client_sock);
        g_client_sock = -1;
    }
    if (g_listen_sock >= 0)
    {
        close(g_listen_sock);
        g_listen_sock = -1;
    }
    unlink(socket_path);

    mgmt_log("server thread exiting");
    return NULL;
}

/* 启动 management server（幂等：常驻，已运行时复用） */
int mgmt_client_start(const char *socket_path, void (*auth_cb)(const char *type))
{
    /* 始终更新回调（重连时回调对象可能已变化） */
    g_auth_request_cb = auth_cb;

    if (g_running)
    {
        mgmt_log("management server already running, reusing it");
        return 0;
    }

    g_running = 1;

    /* socket_path 必须长期有效，这里复制一份 */
    static char path_buf[256];
    snprintf(path_buf, sizeof(path_buf), "%s", socket_path);

    if (pthread_create(&g_server_thread, NULL, server_thread_main, path_buf) != 0)
    {
        mgmt_log("pthread_create failed");
        g_running = 0;
        return -1;
    }

    pthread_detach(g_server_thread);
    return 0;
}

/* 设置行回调（日志） */
void mgmt_client_set_line_callback(void (*line_cb)(const char *line))
{
    g_line_cb = line_cb;
}

/* 设置 tun 请求回调 */
void mgmt_client_set_tun_callback(void (*tun_cb)(const char *dev))
{
    g_tun_request_cb = tun_cb;
}

/* 设置 protect fd 回调 */
void mgmt_client_set_protect_fd_callback(void (*cb)(int fd))
{
    g_protect_fd_cb = cb;
}

/* 设置流量统计回调 */
void mgmt_client_set_bytecount_callback(void (*cb)(long long bytes_in, long long bytes_out))
{
    g_bytecount_cb = cb;
}

/* 设置连接状态回调 */
void mgmt_client_set_state_callback(void (*cb)(const char *state, const char *detail))
{
    g_state_cb = cb;
}

void mgmt_client_set_auth_verify_failed_callback(void (*cb)(void))
{
    g_auth_verify_failed_cb = cb;
}

/* 设置日志推送回调 */
void mgmt_client_set_log_callback(void (*cb)(const char *formatted))
{
    g_log_push_cb = cb;
}

void mgmt_client_set_echo_callback(void (*cb)(const char *message))
{
    g_echo_cb = cb;
}

/* 把 tun fd 通过 SCM_RIGHTS 传给 OpenVPN（TARGET_ANDROID 的 OPENTUN 协议）。
 * 与 OpenVPN for Android 客户端相同的机制。 */
int mgmt_client_send_tun_fd(int fd)
{
    if (g_client_sock < 0)
    {
        mgmt_log("send_tun_fd: not connected");
        return -1;
    }

    /* 消息正文：needok 'OPENTUN' ok */
    char data[] = "needok 'OPENTUN' ok\n";

    struct iovec iov;
    iov.iov_base = data;
    iov.iov_len = sizeof(data) - 1;

    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    memset(cmsg_buf, 0, sizeof(cmsg_buf));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
    msg.msg_controllen = CMSG_SPACE(sizeof(int));

    ssize_t n = sendmsg(g_client_sock, &msg, 0);
    if (n < 0)
    {
        mgmt_log("send_tun_fd: sendmsg failed, errno=%d", errno);
        return -1;
    }

    g_tun_handed = 1;
    mgmt_log("send_tun_fd: fd=%d sent (%zd bytes)", fd, n);
    return 0;
}

/* management 协议转义（parse_line 双引号规则）：
 * 反斜杠和双引号必须加反斜杠前缀，否则密码会被解析错误 */
static void mgmt_escape(char *dst, size_t dst_size, const char *src)
{
    size_t o = 0;
    for (size_t i = 0; src[i] && o + 2 < dst_size; i++)
    {
        if (src[i] == '\\' || src[i] == '"')
        {
            if (o + 2 < dst_size)
            {
                dst[o++] = '\\';
                dst[o++] = src[i];
            }
        }
        else
        {
            dst[o++] = src[i];
        }
    }
    dst[o] = '\0';
}

/* 发送任意 management 命令 */
int mgmt_client_send_cmd(const char *cmd)
{
    if (g_client_sock < 0)
    {
        mgmt_log("send_cmd: not connected");
        return -1;
    }
    mgmt_log("send_cmd: %s", cmd);
    if (send(g_client_sock, cmd, strlen(cmd), 0) < 0)
    {
        mgmt_log("send_cmd failed: errno=%d", errno);
        return -1;
    }
    return 0;
}

/* 发送用户名和密码到 OpenVPN（与 Windows GUI 相同的协议） */
int mgmt_client_send_auth(const char *type, const char *username, const char *password)
{
    if (g_client_sock < 0)
    {
        mgmt_log("not connected yet");
        return -1;
    }

    char cmd[1024];
    char esc_user[256];
    char esc_pass[256];
    int ret = 0;

    mgmt_escape(esc_user, sizeof(esc_user), username);
    mgmt_escape(esc_pass, sizeof(esc_pass), password);

    /* username "Auth" "<escaped username>" */
    snprintf(cmd, sizeof(cmd), "username \"%s\" \"%s\"\n", type, esc_user);
    mgmt_log("sending username");
    if (send(g_client_sock, cmd, strlen(cmd), 0) < 0)
    {
        mgmt_log("send username failed: errno=%d", errno);
        ret = -1;
    }

    /* password "Auth" "<escaped password>" */
    snprintf(cmd, sizeof(cmd), "password \"%s\" \"%s\"\n", type, esc_pass);
    mgmt_log("sending password (hidden)");
    if (send(g_client_sock, cmd, strlen(cmd), 0) < 0)
    {
        mgmt_log("send password failed: errno=%d", errno);
        ret = -1;
    }

    return ret;
}

/* 停止 management server */
void mgmt_client_stop(void)
{
    g_running = 0;
    if (g_client_sock >= 0)
    {
        close(g_client_sock);
        g_client_sock = -1;
    }
    if (g_listen_sock >= 0)
    {
        close(g_listen_sock);
        g_listen_sock = -1;
    }
}
