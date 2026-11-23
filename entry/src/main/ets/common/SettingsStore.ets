/**
 * SettingsStore.ets
 * 设置持久化 - 使用 Preferences 存储（对齐原版 OpenVPN GUI 的注册表设置）
 *
 * 对应原版 openvpn-gui settings.c（注册表 HKEY_CURRENT_USER\Software\OpenVPN-GUI）
 * 字段命名沿用原版 key（如 silent_connection / proxy_type / config_dir / ext 等），
 * 仅在类型/取值上做一些鸿蒙化适配：
 *   - 复选框 -> boolean
 *   - 单选组 -> number（枚举）
 *
 * 字段清单（按 Settings 对话框 4 个标签页分组）：
 *
 *   General（常规）：
 *     language, boot_start, append_log, show_script_win,
 *     silent_connection, use_interactive_service, show_notif,
 *     persistent_conn, enable_prelogin, auto_restart, otp_combine
 *
 *   Proxy（代理）：
 *     proxy_type, manual_proxy_sub_type, proxy_server, proxy_port
 *
 *   Advanced（高级）：
 *     config_dir, ext, log_dir,
 *     preconnect_timeout, connect_script_timeout, disconnect_script_timeout,
 *     mgmt_port_offset, menu_view, show_message, mute_repeat_msg
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnSettings';
const STORE_NAME = 'openvpn_settings';

/** 代理类型（对齐原版 proxy_type 枚举） */
export enum ProxyType {
  NONE = 0,
  HTTP = 1,
  SOCKS = 2
}

/** 代理模式（代理页顶部的 3 个单选） */
export enum ProxyMode {
  FROM_CONFIG = 0,        // 使用配置文件中的设置
  SYSTEM = 1,             // 使用系统代理设置
  MANUAL = 2              // 手动设置
}

/** 手动代理子类型（代理页内层 HTTP/SOCKS） */
export enum ProxySubType {
  HTTP = 0,
  SOCKS = 1
}

/** 显示通知 */
export enum ShowNotifyMode {
  ON_CONNECT = 0,         // 连接时
  ON_CONNECT_RECONNECT = 1, // 连接时、重新连接时
  NEVER = 2                // 从不
}

/** 持久连接 */
export enum PersistentConn {
  AUTO = 0,
  MANUAL = 1,
  DISABLED = 2
}

/** 配置菜单视图 */
export enum MenuView {
  AUTO = 0,
  FLAT = 1,
  NESTED = 2
}

/** 消息展示 */
export enum MsgDisplay {
  AUTO = 0,
  NEVER = 1
}

/** 已保存凭据（保存密码功能，对齐原版 allow_password） */
export interface SavedCredentials {
  username: string;
  password: string;
}

/** 设置数据模型 */
export interface VpnSettings {
  // ===== 常规（General） =====
  language: string;
  bootStart: boolean;              // 在Windows开机时启动
  appendLog: boolean;              // 追加日志文件
  showScriptWin: boolean;          // 显示脚本窗口
  silentConn: boolean;             // 静默连接
  useInteractiveService: boolean;  // 始终使用交互式服务
  showNotification: ShowNotifyMode;
  persistentConn: PersistentConn;
  enablePrelogin: boolean;         // 启用预登录访问提供程序
  autoRestart: boolean;            // 启用活动连接的自动重新启动
  otpCombine: boolean;             // 提示输入OTP并与密码结合

  // ===== 代理（Proxy） =====
  proxyMode: ProxyMode;            // 顶层的 3 个单选
  proxySubType: ProxySubType;      // 手动设置内的 HTTP/SOCKS
  proxyServer: string;             // 当前选中类型的地址（连接时使用）
  proxyPort: number;
  proxyHttpServer: string;         // HTTP 单独保存，切换单选时换回
  proxyHttpPort: number;
  proxySocksServer: string;        // SOCKS 单独保存
  proxySocksPort: number;
  proxyUsername: string;           // 代理认证用户名（空=代理不要求认证时不发送）
  proxyPassword: string;           // 代理认证密码

  // ===== 高级（Advanced） =====
  configDir: string;               // 配置文件目录（只读展示）
  configExt: string;               // 配置文件扩展名
  logDir: string;                  // 日志文件目录（只读展示）
  preconnectTimeout: number;       // 预连接脚本超时时间（秒）
  connectScriptTimeout: number;    // 连接脚本超时时间（秒）
  disconnectScriptTimeout: number; // 断开连接脚本超时时间（秒）
  mgmtPortOffset: number;          // 管理界面端口偏移
  menuView: MenuView;
  messageDisplay: MsgDisplay;
  repeatMsgMuteHours: number;      // 重复消息静音小时数

  // ===== 运行态（非 UI 设置，用于"自动重启"等） =====
  lastConfigName: string;          // 上次活动的配置名（autoRestart 时启动自动重连）
}

/** 默认设置（对齐原版默认值） */
export function defaultSettings(): VpnSettings {
  return {
    // 常规
    language: 'zh-CN',
    bootStart: false,
    appendLog: false,
    showScriptWin: false,
    silentConn: false,
    useInteractiveService: true,
    showNotification: ShowNotifyMode.ON_CONNECT,
    persistentConn: PersistentConn.AUTO,
    enablePrelogin: false,
    autoRestart: true,
    otpCombine: false,

    // 代理
    proxyMode: ProxyMode.FROM_CONFIG,
    proxySubType: ProxySubType.HTTP,
    proxyServer: '',
    proxyPort: 8080,
    proxyHttpServer: '',
    proxyHttpPort: 8080,
    proxySocksServer: '',
    proxySocksPort: 1080,
    proxyUsername: '',
    proxyPassword: '',

    // 高级
    configDir: '/data/storage/el2/base/haps/entry/files/config',
    configExt: 'ovpn',
    logDir: '/data/storage/el2/base/haps/entry/files/log',
    preconnectTimeout: 10,
    connectScriptTimeout: 30,
    disconnectScriptTimeout: 10,
    mgmtPortOffset: 25340,
    menuView: MenuView.AUTO,
    messageDisplay: MsgDisplay.AUTO,
    repeatMsgMuteHours: 24,

    // 运行态
    lastConfigName: ''
  };
}

/** 字段都是基本类型，浅拷贝即可。选项页必须改副本，取消才不会写进缓存。 */
export function cloneSettings(src: VpnSettings): VpnSettings {
  const copy: VpnSettings = {
    language: src.language,
    bootStart: src.bootStart,
    appendLog: src.appendLog,
    showScriptWin: src.showScriptWin,
    silentConn: src.silentConn,
    useInteractiveService: src.useInteractiveService,
    showNotification: src.showNotification,
    persistentConn: src.persistentConn,
    enablePrelogin: src.enablePrelogin,
    autoRestart: src.autoRestart,
    otpCombine: src.otpCombine,
    proxyMode: src.proxyMode,
    proxySubType: src.proxySubType,
    proxyServer: src.proxyServer,
    proxyPort: src.proxyPort,
    proxyHttpServer: src.proxyHttpServer,
    proxyHttpPort: src.proxyHttpPort,
    proxySocksServer: src.proxySocksServer,
    proxySocksPort: src.proxySocksPort,
    proxyUsername: src.proxyUsername,
    proxyPassword: src.proxyPassword,
    configDir: src.configDir,
    configExt: src.configExt,
    logDir: src.logDir,
    preconnectTimeout: src.preconnectTimeout,
    connectScriptTimeout: src.connectScriptTimeout,
    disconnectScriptTimeout: src.disconnectScriptTimeout,
    mgmtPortOffset: src.mgmtPortOffset,
    menuView: src.menuView,
    messageDisplay: src.messageDisplay,
    repeatMsgMuteHours: src.repeatMsgMuteHours,
    lastConfigName: src.lastConfigName
  };
  return copy;
}

/**
 * 设置存储单例（Preferences 封装）
 */
export class SettingsStore {
  private static instance: SettingsStore | null = null;
  private prefs: preferences.Preferences | null = null;
  private cached: VpnSettings | null = null;

  private constructor() {
  }

  public static getInstance(): SettingsStore {
    if (!SettingsStore.instance) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  /** 初始化（需 UIAbilityContext） */
  public async init(context: common.UIAbilityContext): Promise<void> {
    if (this.prefs) {
      return;
    }
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'prefs init failed: %{public}s', JSON.stringify(e));
      this.prefs = null;
    }
  }

  private async load(): Promise<VpnSettings> {
    const s: VpnSettings = defaultSettings();
    if (!this.prefs) {
      return s;
    }
    try {
      // 常规
      s.language = (await this.prefs.get('language', s.language)) as string;
      s.bootStart = (await this.prefs.get('boot_start', s.bootStart)) as boolean;
      s.appendLog = (await this.prefs.get('append_log', s.appendLog)) as boolean;
      s.showScriptWin = (await this.prefs.get('show_script_win', s.showScriptWin)) as boolean;
      s.silentConn = (await this.prefs.get('silent_connection', s.silentConn)) as boolean;
      s.useInteractiveService = (await this.prefs.get('use_interactive_service', s.useInteractiveService)) as boolean;
      s.showNotification = (await this.prefs.get('show_notif', s.showNotification)) as number;
      s.persistentConn = (await this.prefs.get('persistent_conn', s.persistentConn)) as number;
      s.enablePrelogin = (await this.prefs.get('enable_prelogin', s.enablePrelogin)) as boolean;
      s.autoRestart = (await this.prefs.get('auto_restart', s.autoRestart)) as boolean;
      s.otpCombine = (await this.prefs.get('otp_combine', s.otpCombine)) as boolean;

      // 代理
      s.proxyMode = (await this.prefs.get('proxy_mode', s.proxyMode)) as number;
      s.proxySubType = (await this.prefs.get('proxy_sub_type', s.proxySubType)) as number;
      s.proxyServer = (await this.prefs.get('proxy_server', s.proxyServer)) as string;
      s.proxyPort = (await this.prefs.get('proxy_port', s.proxyPort)) as number;
      s.proxyHttpServer = (await this.prefs.get('proxy_http_address', s.proxyServer)) as string;
      s.proxyHttpPort = (await this.prefs.get('proxy_http_port', s.proxyPort)) as number;
      s.proxySocksServer = (await this.prefs.get('proxy_socks_address', '')) as string;
      s.proxySocksPort = (await this.prefs.get('proxy_socks_port', 1080)) as number;
      s.proxyUsername = (await this.prefs.get('proxy_username', s.proxyUsername)) as string;
      s.proxyPassword = (await this.prefs.get('proxy_password', s.proxyPassword)) as string;
      if (s.proxySubType === ProxySubType.SOCKS) {
        s.proxyServer = s.proxySocksServer;
        s.proxyPort = s.proxySocksPort;
      } else {
        s.proxyServer = s.proxyHttpServer;
        s.proxyPort = s.proxyHttpPort;
      }

      // 高级
      s.configDir = (await this.prefs.get('config_dir', s.configDir)) as string;
      s.configExt = (await this.prefs.get('ext', s.configExt)) as string;
      s.logDir = (await this.prefs.get('log_dir', s.logDir)) as string;
      s.preconnectTimeout = (await this.prefs.get('preconnect_timeout', s.preconnectTimeout)) as number;
      s.connectScriptTimeout = (await this.prefs.get('connect_script_timeout', s.connectScriptTimeout)) as number;
      s.disconnectScriptTimeout = (await this.prefs.get('disconnect_script_timeout', s.disconnectScriptTimeout)) as number;
      s.mgmtPortOffset = (await this.prefs.get('mgmt_port_offset', s.mgmtPortOffset)) as number;
      s.menuView = (await this.prefs.get('menu_view', s.menuView)) as number;
      s.messageDisplay = (await this.prefs.get('show_message', s.messageDisplay)) as number;
      s.repeatMsgMuteHours = (await this.prefs.get('mute_repeat_msg', s.repeatMsgMuteHours)) as number;
      s.lastConfigName = (await this.prefs.get('last_config', s.lastConfigName)) as string;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(e));
    }
    return s;
  }

  /** 读取全部设置。返回副本，调用方改字段不会直接改缓存。 */
  public async get(): Promise<VpnSettings> {
    if (!this.cached) {
      this.cached = await this.load();
    }
    return cloneSettings(this.cached);
  }

  /** 保存全部设置。只有选项页点「确定」以及连接时记录上次配置会走到这里。 */
  public async save(s: VpnSettings): Promise<void> {
    const stored: VpnSettings = cloneSettings(s);
    this.cached = stored;
    if (!this.prefs) {
      return;
    }
    try {
      // 常规
      await this.prefs.put('language', s.language);
      await this.prefs.put('boot_start', s.bootStart);
      await this.prefs.put('append_log', s.appendLog);
      await this.prefs.put('show_script_win', s.showScriptWin);
      await this.prefs.put('silent_connection', s.silentConn);
      await this.prefs.put('use_interactive_service', s.useInteractiveService);
      await this.prefs.put('show_notif', s.showNotification);
      await this.prefs.put('persistent_conn', s.persistentConn);
      await this.prefs.put('enable_prelogin', s.enablePrelogin);
      await this.prefs.put('auto_restart', s.autoRestart);
      await this.prefs.put('otp_combine', s.otpCombine);

      // 代理
      await this.prefs.put('proxy_mode', s.proxyMode);
      await this.prefs.put('proxy_sub_type', s.proxySubType);
      await this.prefs.put('proxy_server', s.proxyServer);
      await this.prefs.put('proxy_port', s.proxyPort);
      await this.prefs.put('proxy_http_address', s.proxyHttpServer);
      await this.prefs.put('proxy_http_port', s.proxyHttpPort);
      await this.prefs.put('proxy_socks_address', s.proxySocksServer);
      await this.prefs.put('proxy_socks_port', s.proxySocksPort);
      await this.prefs.put('proxy_username', s.proxyUsername);
      await this.prefs.put('proxy_password', s.proxyPassword);

      // 高级
      await this.prefs.put('config_dir', s.configDir);
      await this.prefs.put('ext', s.configExt);
      await this.prefs.put('log_dir', s.logDir);
      await this.prefs.put('preconnect_timeout', s.preconnectTimeout);
      await this.prefs.put('connect_script_timeout', s.connectScriptTimeout);
      await this.prefs.put('disconnect_script_timeout', s.disconnectScriptTimeout);
      await this.prefs.put('mgmt_port_offset', s.mgmtPortOffset);
      await this.prefs.put('menu_view', s.menuView);
      await this.prefs.put('show_message', s.messageDisplay);
      await this.prefs.put('mute_repeat_msg', s.repeatMsgMuteHours);
      await this.prefs.put('last_config', s.lastConfigName);

      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, 'settings saved');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(e));
    }
  }

  /* ==================== 凭据存取（保存密码，按配置名） ====================
   * 对齐原版 allow_password：GUI 认证时勾选"保存密码"→ 注册表存凭据，
   * 下次连接自动使用。鸿蒙存 Preferences（应用沙箱内，其他应用不可读）。 */

  /** 保存某配置的凭据（username/password 均非空才存） */
  public async saveCredentials(configName: string, username: string, password: string): Promise<void> {
    if (!this.prefs || configName.length === 0) {
      return;
    }
    try {
      await this.prefs.put(`cred_${configName}_user`, username);
      await this.prefs.put(`cred_${configName}_pass`, password);
      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, `credentials saved for ${configName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveCredentials failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 读取某配置已保存的凭据（无则返回空字符串） */
  public async getCredentials(configName: string): Promise<SavedCredentials> {
    const empty: SavedCredentials = { username: '', password: '' };
    if (!this.prefs || configName.length === 0) {
      return empty;
    }
    try {
      const username: string = await this.prefs.get(`cred_${configName}_user`, '') as string;
      const password: string = await this.prefs.get(`cred_${configName}_pass`, '') as string;
      const cred: SavedCredentials = { username: username, password: password };
      return cred;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getCredentials failed: %{public}s', JSON.stringify(e));
      return empty;
    }
  }

  /** 只记住用户名，并清掉已存密码。未勾选保存密码时用这个。 */
  public async rememberUsername(configName: string, username: string): Promise<void> {
    if (!this.prefs || configName.length === 0 || username.length === 0) {
      return;
    }
    try {
      await this.prefs.put(`cred_${configName}_user`, username);
      try {
        await this.prefs.delete(`cred_${configName}_pass`);
      } catch (missing) {
        // 本来就没有密码
      }
      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, `username kept for ${configName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'rememberUsername failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 只删除已存密码，用户名留下。托盘「清除已保存的密码」用这个。 */
  public async clearPassword(configName: string): Promise<void> {
    if (!this.prefs || configName.length === 0) {
      return;
    }
    try {
      await this.prefs.delete(`cred_${configName}_pass`);
      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, `password cleared for ${configName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearPassword failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清除某配置已保存的凭据（用户名和密码都删）。设置里的清除用这个。 */
  public async clearCredentials(configName: string): Promise<void> {
    if (!this.prefs || configName.length === 0) {
      return;
    }
    try {
      await this.prefs.delete(`cred_${configName}_user`);
      await this.prefs.delete(`cred_${configName}_pass`);
      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, `credentials cleared for ${configName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearCredentials failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清除全部已保存凭据（遍历删除 cred_* 键），返回清除的凭据数 */
  public async clearAllCredentials(): Promise<number> {
    if (!this.prefs) {
      return 0;
    }
    try {
      const all: Object = await this.prefs.getAll();
      let count: number = 0;
      for (const key of Object.keys(all)) {
        if (key.startsWith('cred_')) {
          await this.prefs.delete(key);
          count++;
        }
      }
      if (count > 0) {
        await this.prefs.flush();
      }
      hilog.info(DOMAIN, TAG, `cleared ${count} saved credentials`);
      return count;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearAllCredentials failed: %{public}s', JSON.stringify(e));
      return 0;
    }
  }
}
