/*
 * openvpn_bridge.cpp (napi_init.cpp)
 * NAPI 外壳：ArkTS <-> OpenVPN core
 *
 * 架构：
 *   ArkTS (UI) <--NAPI--> napi_init.cpp <--extern "C"--> openvpn_bridge.c <--> OpenVPN core
 *
 * OpenVPN core 是纯 C 代码，头文件不兼容 C++（protected 关键字冲突等），
 * 因此所有 core 交互都在 openvpn_bridge.c (C 编译) 中完成，
 * 本文件只做 NAPI 接口封装，不 include 任何 OpenVPN 头。
 */
#include "napi/native_api.h"
#include <hilog/log.h>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <cstring>
#include <cstdlib>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "OpenVpnNAPI"

/* bridge C 接口（openvpn_bridge.c） */
extern "C" {
int ovpn_start(void);
int ovpn_stop(void);
int ovpn_reconnect(void);  /* 新增：SIGHUP 重连（原版机制） */
int ovpn_is_running(void);
int ovpn_set_tun_fd(int fd);
const char *ovpn_version(void);
void ovpn_set_callbacks(void (*status_cb)(const char *), void (*log_cb)(const char *));
void ovpn_set_config_path(const char *path);
void ovpn_set_log_name(const char *name);
void ovpn_set_auth_callback(void (*auth_cb)(const char *type));  /* 新增：设置认证请求回调 */
void ovpn_set_tun_callback(void (*tun_cb)(const char *dev));      /* 新增：设置 tun 请求回调 */
void ovpn_set_protect_fd_callback(void (*fd_cb)(int fd));         /* 新增：设置 protect fd 回调 */
int ovpn_send_auth(const char *username, const char *password);  /* 新增：发送认证信息 */
void ovpn_set_log_forward(void (*log_cb)(const char *line));     /* 新增：OpenVPN 消息转发 */
void ovpn_set_mgmt_log_callback(void (*log_cb)(const char *formatted));  /* 新增：management log on all 日志 */
void ovpn_set_bytecount_callback(void (*cb)(long long bytes_in, long long bytes_out));  /* 新增：流量统计 */
void ovpn_set_start_options(int proxy_mode, int proxy_sub_type,
                            const char *proxy_server, int proxy_port,
                            int append_log, int mgmt_offset,
                            const char *proxy_username, const char *proxy_password);  /* 连接选项（设置页+代理认证） */
void ovpn_set_auth_file(const char *path);                      /* 新增：CLI 凭据文件（--auth-user-pass） */
void ovpn_set_state_callback(void (*cb)(const char *state, const char *detail));  /* 新增：连接状态 */
int ovpn_get_ipv6_config(char *config, size_t config_size);  /* 当前连接的 IFCONFIG6 配置 */
int ovpn_get_ipv6_routes(char *routes, size_t routes_size);  /* 逗号分隔的 ROUTE6 列表 */
}

/* ---------------- 全局状态 ---------------- */
static napi_ref g_cb_status = nullptr;
static napi_ref g_cb_log = nullptr;
static napi_ref g_cb_tun = nullptr;
static napi_ref g_cb_auth = nullptr;
static napi_env g_env = nullptr;

/* 线程安全函数 */
static napi_threadsafe_function g_tsfn_status = nullptr;
static napi_threadsafe_function g_tsfn_log = nullptr;
static napi_threadsafe_function g_tsfn_auth = nullptr;  /* 新增：认证请求 */
static napi_threadsafe_function g_tsfn_tun = nullptr;   /* 新增：tun 请求 */
static napi_threadsafe_function g_tsfn_bytes = nullptr; /* 新增：流量统计 */
static napi_threadsafe_function g_tsfn_state = nullptr; /* 新增：连接状态 */
static napi_threadsafe_function g_tsfn_protect = nullptr; /* 新增：protect fd 请求 */

/* 线程安全回调的数据结构 */
struct CallData {
    char msg[512];
};

/* 在 JS 线程中调用的函数 */
static void CallJsStatus(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void CallJsLog(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

/* ---------------- C 回调 → NAPI 回调（线程安全版本）---------------- */
static void OnCoreStatus(const char *msg)
{
    /* 添加简单的 stderr 输出用于调试 */
    fprintf(stderr, "[OnCoreStatus] msg=%s, tsfn=%p\n", msg ? msg : "NULL", g_tsfn_status);

    if (g_tsfn_status != nullptr && msg != nullptr) {
        CallData* data = new CallData();
        strncpy(data->msg, msg, sizeof(data->msg) - 1);
        data->msg[sizeof(data->msg) - 1] = '\0';
        napi_status status = napi_call_threadsafe_function(g_tsfn_status, data, napi_tsfn_nonblocking);
        fprintf(stderr, "[OnCoreStatus] napi_call_threadsafe_function returned %d\n", status);
    }
}

static void OnCoreLog(const char *line)
{
    fprintf(stderr, "[OnCoreLog] line=%s, tsfn=%p\n", line ? line : "NULL", g_tsfn_log);

    if (g_tsfn_log != nullptr && line != nullptr) {
        CallData* data = new CallData();
        strncpy(data->msg, line, sizeof(data->msg) - 1);
        data->msg[sizeof(data->msg) - 1] = '\0';
        napi_status status = napi_call_threadsafe_function(g_tsfn_log, data, napi_tsfn_nonblocking);
        fprintf(stderr, "[OnCoreLog] napi_call_threadsafe_function returned %d\n", status);
    }
}

/* 认证请求回调 */
static void CallJsAuth(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void OnAuthRequestNative(const char *type)
{
    fprintf(stderr, "[OnAuthRequest] type=%s, tsfn=%p\n", type ? type : "NULL", g_tsfn_auth);

    if (g_tsfn_auth != nullptr && type != nullptr) {
        CallData* data = new CallData();
        strncpy(data->msg, type, sizeof(data->msg) - 1);
        data->msg[sizeof(data->msg) - 1] = '\0';
        napi_status status = napi_call_threadsafe_function(g_tsfn_auth, data, napi_tsfn_nonblocking);
        fprintf(stderr, "[OnAuthRequest] napi_call_threadsafe_function returned %d\n", status);
    }
}

/* tun 请求回调（C 线程 → JS） */
static void CallJsTun(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void OnTunRequestNative(const char *dev)
{
    fprintf(stderr, "[OnTunRequest] dev=%s, tsfn=%p\n", dev ? dev : "NULL", g_tsfn_tun);

    if (g_tsfn_tun != nullptr && dev != nullptr) {
        CallData* data = new CallData();
        strncpy(data->msg, dev, sizeof(data->msg) - 1);
        data->msg[sizeof(data->msg) - 1] = '\0';
        napi_status status = napi_call_threadsafe_function(g_tsfn_tun, data, napi_tsfn_nonblocking);
        fprintf(stderr, "[OnTunRequest] napi_call_threadsafe_function returned %d\n", status);
    }
}

/* protect fd 回调（PROTECTFD，OpenVPN 附带 SCM_RIGHTS fd）。
 * 上层须对 fd 调用 VpnConnection.protect()，防止默认路由下隧道自环 */
static void CallJsProtect(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void OnProtectFdNative(int fd)
{
    fprintf(stderr, "[OnProtectFd] fd=%d, tsfn=%p\n", fd, g_tsfn_protect);

    if (g_tsfn_protect != nullptr && fd > 0) {
        CallData* data = new CallData();
        snprintf(data->msg, sizeof(data->msg), "%d", fd);
        napi_status status = napi_call_threadsafe_function(g_tsfn_protect, data, napi_tsfn_nonblocking);
        fprintf(stderr, "[OnProtectFd] napi_call_threadsafe_function returned %d\n", status);
    }
}

/* 流量统计回调（management status 2 轮询触发） */
static void CallJsBytes(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void OnByteCountNative(long long bytes_in, long long bytes_out)
{
    if (g_tsfn_bytes != nullptr) {
        CallData* data = new CallData();
        snprintf(data->msg, sizeof(data->msg), "%lld,%lld", bytes_in, bytes_out);
        napi_call_threadsafe_function(g_tsfn_bytes, data, napi_tsfn_nonblocking);
    }
}

/* 连接状态回调（management state on 推送） */
static void CallJsState(napi_env env, napi_value js_callback, void* context, void* data)
{
    if (data == nullptr) return;

    CallData* call_data = static_cast<CallData*>(data);

    if (env != nullptr && js_callback != nullptr) {
        napi_value str;
        napi_create_string_utf8(env, call_data->msg, NAPI_AUTO_LENGTH, &str);
        napi_value argv[1] = {str};
        napi_value result;
        napi_call_function(env, nullptr, js_callback, 1, argv, &result);
    }

    delete call_data;
}

static void OnStateChange(const char *state, const char *detail)
{
    if (g_tsfn_state != nullptr) {
        CallData* data = new CallData();
        snprintf(data->msg, sizeof(data->msg), "%s|%s",
                 state ? state : "", detail ? detail : "");
        napi_call_threadsafe_function(g_tsfn_state, data, napi_tsfn_nonblocking);
    }
}

/* ---------------- NAPI 导出 ---------------- */
/* 兼容默认模板 UI：add(a,b) 冒烟测试接口 */
static napi_value Add(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double value0 = 0;
    double value1 = 0;
    napi_get_value_double(env, args[0], &value0);
    napi_get_value_double(env, args[1], &value1);
    napi_value sum;
    napi_create_double(env, value0 + value1, &sum);
    return sum;
}

static napi_value SendAuth(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    // 获取用户名
    char username[256] = {0};
    size_t username_len = 0;
    napi_get_value_string_utf8(env, args[0], username, sizeof(username), &username_len);

    // 获取密码
    char password[256] = {0};
    size_t password_len = 0;
    napi_get_value_string_utf8(env, args[1], password, sizeof(password), &password_len);

    OH_LOG_INFO(LOG_APP, "[NAPI] SendAuth called: username=%{public}s", username);

    // 调用 C 层发送认证
    int ret = ovpn_send_auth(username, password);

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    /* 解析 profile JSON，提取配置文件路径 */
    size_t len = 0;
    char buf[4096] = {0};
    if (argc >= 1 && args[0])
    {
        napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);
    }

    /* 简单解析 JSON: {"name":"xxx","configFile":"/path/to/file.ovpn","proxyMode":..,...}
     * 查找 "configFile":"<path>" */
    char config_path[512] = {0};
    const char *key = "\"configFile\":\"";
    char *start = strstr(buf, key);
    if (start)
    {
        start += strlen(key);
        char *end = strchr(start, '\"');
        if (end && (end - start) < (int)sizeof(config_path))
        {
            strncpy(config_path, start, end - start);
            config_path[end - start] = '\0';

            // 使用 hilog 输出配置路径
            OH_LOG_INFO(LOG_APP, "[NAPI] Setting config path: %{public}s", config_path);

            ovpn_set_config_path(config_path);
        }
    }

    /* 配置名决定连接日志文件 cache/<配置名>.log，与界面「显示日志」使用同一规则。 */
    {
        const char *name_key = "\"name\":\"";
        char *name_at = strstr(buf, name_key);
        char log_name[256] = {0};
        if (name_at)
        {
            name_at += strlen(name_key);
            char *name_end = strchr(name_at, '\"');
            if (name_end && (name_end - name_at) < (int)sizeof(log_name))
            {
                strncpy(log_name, name_at, name_end - name_at);
                log_name[name_end - name_at] = '\0';
            }
        }
        ovpn_set_log_name(log_name);
    }

    /* 解析设置页传入的连接选项（对齐原版 GUI：代理/日志/管理端口）。
     * 简单字符串解析，缺省用默认值；这些值传给 bridge 在下次连接生效。 */
    int proxy_mode = 0;
    int proxy_sub_type = 0;
    char proxy_server[256] = {0};
    int proxy_port = 0;
    int append_log = 1;
    int mgmt_offset = 25340;

    /* proxyMode */
    start = strstr(buf, "\"proxyMode\":");
    if (start)
    {
        proxy_mode = atoi(start + strlen("\"proxyMode\":"));
    }
    /* proxySubType */
    start = strstr(buf, "\"proxySubType\":");
    if (start)
    {
        proxy_sub_type = atoi(start + strlen("\"proxySubType\":"));
    }
    /* proxyServer */
    const char *skey = "\"proxyServer\":\"";
    start = strstr(buf, skey);
    if (start)
    {
        start += strlen(skey);
        char *end = strchr(start, '\"');
        if (end && (end - start) < (int)sizeof(proxy_server))
        {
            strncpy(proxy_server, start, end - start);
            proxy_server[end - start] = '\0';
        }
    }
    /* proxyPort */
    start = strstr(buf, "\"proxyPort\":");
    if (start)
    {
        proxy_port = atoi(start + strlen("\"proxyPort\":"));
    }
    /* proxyUsername / proxyPassword：代理认证（--http-proxy host port user pass） */
    char proxy_username[128] = {0};
    char proxy_password[128] = {0};
    const char *pukey = "\"proxyUsername\":\"";
    start = strstr(buf, pukey);
    if (start)
    {
        start += strlen(pukey);
        char *end = strchr(start, '\"');
        if (end && (end - start) < (int)sizeof(proxy_username))
        {
            strncpy(proxy_username, start, end - start);
            proxy_username[end - start] = '\0';
        }
    }
    const char *ppkey = "\"proxyPassword\":\"";
    start = strstr(buf, ppkey);
    if (start)
    {
        start += strlen(ppkey);
        char *end = strchr(start, '\"');
        if (end && (end - start) < (int)sizeof(proxy_password))
        {
            strncpy(proxy_password, start, end - start);
            proxy_password[end - start] = '\0';
        }
    }
    /* appendLog：JSON 布尔是 true/false，atoi 会把两者都读成 0。 */
    start = strstr(buf, "\"appendLog\":");
    if (start)
    {
        const char *val = start + strlen("\"appendLog\":");
        while (*val == ' ' || *val == '\t')
        {
            val++;
        }
        if (strncmp(val, "true", 4) == 0 || *val == '1')
        {
            append_log = 1;
        }
        else if (strncmp(val, "false", 5) == 0 || *val == '0')
        {
            append_log = 0;
        }
    }
    /* mgmtPortOffset */
    start = strstr(buf, "\"mgmtPortOffset\":");
    if (start)
    {
        mgmt_offset = atoi(start + strlen("\"mgmtPortOffset\":"));
        if (mgmt_offset <= 0)
        {
            mgmt_offset = 25340;
        }
    }

    /* authFile：CLI 无头模式凭据文件（--auth-user-pass <file>，两行：用户名/密码） */
    char auth_file[512] = {0};
    const char *akey = "\"authFile\":\"";
    start = strstr(buf, akey);
    if (start)
    {
        start += strlen(akey);
        char *end = strchr(start, '\"');
        if (end && (end - start) < (int)sizeof(auth_file))
        {
            strncpy(auth_file, start, end - start);
            auth_file[end - start] = '\0';
            ovpn_set_auth_file(auth_file);
            OH_LOG_INFO(LOG_APP, "[NAPI] auth file: %{public}s", auth_file);
        }
    }

    ovpn_set_start_options(proxy_mode, proxy_sub_type, proxy_server, proxy_port,
                           append_log, mgmt_offset, proxy_username, proxy_password);
    OH_LOG_INFO(LOG_APP, "[NAPI] start options: mode=%{public}d sub=%{public}d server=%{public}s port=%{public}d append=%{public}d mgmt=%{public}d",
                proxy_mode, proxy_sub_type, proxy_server, proxy_port, append_log, mgmt_offset);

    g_env = env;

    OH_LOG_INFO(LOG_APP, "[NAPI] About to call ovpn_start()");
    int ret = ovpn_start();
    OH_LOG_INFO(LOG_APP, "[NAPI] ovpn_start() returned: %{public}d", ret);

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value Stop(napi_env env, napi_callback_info info)
{
    int ret = ovpn_stop();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value Reconnect(napi_env env, napi_callback_info info)
{
    int ret = ovpn_reconnect();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value IsRunning(napi_env env, napi_callback_info info)
{
    int ret = ovpn_is_running();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value SetTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = 0;
    napi_get_value_int32(env, args[0], &fd);
    int ret = ovpn_set_tun_fd(fd);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value GetIpv6Config(napi_env env, napi_callback_info info)
{
    char config[128] = {0};
    ovpn_get_ipv6_config(config, sizeof(config));
    napi_value result;
    napi_create_string_utf8(env, config, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value GetIpv6Routes(napi_env env, napi_callback_info info)
{
    char routes[4096] = {0};
    ovpn_get_ipv6_routes(routes, sizeof(routes));
    napi_value result;
    napi_create_string_utf8(env, routes, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value SetCredentials(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char buf[2048] = {0};
    size_t len = 0;
    if (argc >= 1 && args[0])
    {
        napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);
    }
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

static napi_value GetVersion(napi_env env, napi_callback_info info)
{
    const char *ver = ovpn_version();
    napi_value result;
    napi_create_string_utf8(env, ver, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value OnStatus(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_status != nullptr) {
        napi_release_threadsafe_function(g_tsfn_status, napi_tsfn_release);
        g_tsfn_status = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnStatus", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsStatus,
        &g_tsfn_status
    );

    // 保持旧的引用以兼容
    napi_create_reference(env, args[0], 1, &g_cb_status);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnLog(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_log != nullptr) {
        napi_release_threadsafe_function(g_tsfn_log, napi_tsfn_release);
        g_tsfn_log = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnLog", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsLog,
        &g_tsfn_log
    );

    // 保持旧的引用以兼容
    napi_create_reference(env, args[0], 1, &g_cb_log);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnAuthRequest(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_auth != nullptr) {
        napi_release_threadsafe_function(g_tsfn_auth, napi_tsfn_release);
        g_tsfn_auth = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnAuthRequest", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsAuth,
        &g_tsfn_auth
    );

    // 注册 C 层回调
    ovpn_set_auth_callback(OnAuthRequestNative);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnTunRequest(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_tun != nullptr) {
        napi_release_threadsafe_function(g_tsfn_tun, napi_tsfn_release);
        g_tsfn_tun = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnTunRequest", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsTun,
        &g_tsfn_tun
    );

    // 注册 C 层回调
    ovpn_set_tun_callback(OnTunRequestNative);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnProtectFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_protect != nullptr) {
        napi_release_threadsafe_function(g_tsfn_protect, napi_tsfn_release);
        g_tsfn_protect = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnProtectFd", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsProtect,
        &g_tsfn_protect
    );

    // 注册 C 层回调
    ovpn_set_protect_fd_callback(OnProtectFdNative);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnByteCount(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_bytes != nullptr) {
        napi_release_threadsafe_function(g_tsfn_bytes, napi_tsfn_release);
        g_tsfn_bytes = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnByteCount", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsBytes,
        &g_tsfn_bytes
    );

    // 注册 C 层回调
    ovpn_set_bytecount_callback(OnByteCountNative);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value OnState(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果已经存在旧的，先释放
    if (g_tsfn_state != nullptr) {
        napi_release_threadsafe_function(g_tsfn_state, napi_tsfn_release);
        g_tsfn_state = nullptr;
    }

    // 创建线程安全函数
    napi_value resource_name;
    napi_create_string_utf8(env, "OnState", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        CallJsState,
        &g_tsfn_state
    );

    // 注册 C 层回调
    ovpn_set_state_callback(::OnStateChange);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------------- 模块注册 ---------------- */
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    /* 注册 C 层回调 */
    ovpn_set_callbacks(OnCoreStatus, OnCoreLog);
    /* 界面日志走 management 的 log on all 推送（Windows 同款机制） */
    ovpn_set_mgmt_log_callback(OnCoreLog);

    napi_property_descriptor desc[] = {
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reconnect", nullptr, Reconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTunFd", nullptr, SetTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getIpv6Config", nullptr, GetIpv6Config, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getIpv6Routes", nullptr, GetIpv6Routes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCredentials", nullptr, SetCredentials, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onStatus", nullptr, OnStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onLog", nullptr, OnLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onTunRequest", nullptr, OnTunRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onProtectFd", nullptr, OnProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onAuthRequest", nullptr, OnAuthRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendAuth", nullptr, SendAuth, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onByteCount", nullptr, OnByteCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onState", nullptr, OnState, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
