/**
 * 连接日志目录。与 openvpn_bridge.c 写入的 /data/storage/el2/base/cache 相同。
 * 界面 context.cacheDir 是 haps/entry/cache，不是这个目录。
 */
export const CONNECTION_LOG_DIR: string = '/data/storage/el2/base/cache';

/**
 * 连接日志文件名。
 * 与 openvpn_bridge.c 的 ovpn_set_log_name 使用同一套替换：
 * 控制字符以及 <>:"/\|?*; 换成下划线。
 */
export function connectionLogName(configName: string): string {
  let out: string = '';
  const bad: string = '<>:"/\\|?*;';
  for (let i = 0; i < configName.length; i++) {
    const ch: string = configName.substring(i, i + 1);
    const code: number = configName.charCodeAt(i);
    if (code < 32 || bad.indexOf(ch) >= 0) {
      out += '_';
    } else {
      out += ch;
    }
  }
  if (out.length === 0) {
    out = 'openvpn';
  }
  return `${out}.log`;
}

/** 该配置的连接日志完整路径。 */
export function connectionLogPath(configName: string): string {
  return `${CONNECTION_LOG_DIR}/${connectionLogName(configName)}`;
}
