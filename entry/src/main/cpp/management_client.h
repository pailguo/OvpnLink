#ifndef MANAGEMENT_CLIENT_H
#define MANAGEMENT_CLIENT_H

#ifdef __cplusplus
extern "C" {
#endif

/* 启动 management server（上层监听，OpenVPN 以 --management-client 连入） */
int mgmt_client_start(const char *socket_path, void (*auth_cb)(const char *type));

/* 发送用户名和密码到 OpenVPN */
int mgmt_client_send_auth(const char *type, const char *username, const char *password);

/* 发送任意 management 命令（如 signal SIGTERM） */
int mgmt_client_send_cmd(const char *cmd);

/* 设置 tun 设备请求回调（OpenVPN 发送 OPENTUN 时触发） */
void mgmt_client_set_tun_callback(void (*tun_cb)(const char *dev));

/* 设置 protect fd 回调（OpenVPN PROTECTFD 附带 SCM_RIGHTS fd，上层须 protect） */
void mgmt_client_set_protect_fd_callback(void (*cb)(int fd));

/* 设置流量统计回调（OpenVPN bytecount 5 推送） */
void mgmt_client_set_bytecount_callback(void (*cb)(long long bytes_in, long long bytes_out));

/* 设置连接状态回调（OpenVPN state on 推送） */
void mgmt_client_set_state_callback(void (*cb)(const char *state, const char *detail));

/* OpenVPN 推送 >PASSWORD:Verification Failed（先于下一次 Need 'Auth'） */
void mgmt_client_set_auth_verify_failed_callback(void (*cb)(void));

/* 设置日志推送回调（OpenVPN log on all 推送，格式 "level|line"） */
void mgmt_client_set_log_callback(void (*cb)(const char *formatted));

/* 设置 echo 推送回调（OpenVPN echo on all，正文是 >ECHO: 时间戳后面的消息） */
void mgmt_client_set_echo_callback(void (*cb)(const char *message));

/* 把 tun fd 通过 SCM_RIGHTS 传给 OpenVPN */
int mgmt_client_send_tun_fd(int fd);

/* 停止 management server */
void mgmt_client_stop(void);

#ifdef __cplusplus
}
#endif

#endif // MANAGEMENT_CLIENT_H
