/**
 * Index.ets - OpenVPN GUI 主界面
 *
 * 完全参考 Windows OpenVPN GUI 的实现逻辑
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { window, promptAction } from '@kit.ArkUI';
import { emitter, commonEventManager } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import fs from '@ohos.file.fs';
import { fileIo as fileFs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { VpnServiceManager } from '../common/VpnServiceManager';
import { VpnIpc, VpnUiMessage } from '../common/VpnIpc';
import { VpnNotification, NotifyState } from '../notification/VpnNotification';
import { VpnTray, TrayCommand, TrayLinkState } from '../tray/VpnTray';
import { TrayKeepAlive } from '../tray/TrayKeepAlive';
import { AppWindows, EXIT_CONFIRM_EVENT, PROFILE_IMPORTED_EVENT, SETTINGS_SAVED_EVENT } from '../common/AppWindows';
import { theme } from '../common/ThemeManager';
import { connectionLogPath } from '../common/ProfileLog';
import {
  SettingsStore,
  VpnSettings,
  SavedCredentials,
  defaultSettings,
  ShowNotifyMode,
  PersistentConn
} from '../common/SettingsStore';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnGui';
/* CLI 命令事件 ID（与 EntryAbility 一致）：应用已运行时 onNewWant 通知本页执行 */
const CLI_COMMAND_EVENT: number = 0x10001;
const APP_LOG_PATH: string = '/data/storage/el2/base/cache/vpnext.log';

/** 文件日志（hilog 抓不到时用，便于 hdc 定位） */
function appFileLog(msg: string): void {
  try {
    const file = fileFs.openSync(APP_LOG_PATH, fileFs.OpenMode.READ_WRITE | fileFs.OpenMode.CREATE | fileFs.OpenMode.APPEND);
    fileFs.writeSync(file.fd, `${new Date().toISOString()} [Index] ${msg}\n`);
    fileFs.closeSync(file);
  } catch (e) {
    // 忽略
  }
}

interface LogLine {
  text: string;
  level: number;  // 0=普通 1=错误 2=警告
}

@Entry
@Component
struct Index {
  @StorageLink('isDark') @Watch('onThemeChanged') isDark: boolean = false;
  // 配置相关
  @State hasConfig: boolean = false;
  @State configName: string = '';
  @State configFilePath: string = '';
  @State allConfigs: string[] = [];       // 所有配置文件（原版托盘菜单等效）
  @State selectedConfigIndex: number = 0; // 当前选中的配置

  // 连接状态
  @State @Watch('syncStatusColor') statusText: string = '连接中';
  @State logLines: LogLine[] = [];
  @State statusColor: string = '#64bb5c';
  private logScroller: Scroller = new Scroller();
  /** 停在最后一行时，新日志继续滚到底。手动离开底部后保持当前位置。 */
  private logFollowTail: boolean = true;
  private logUserScrolling: boolean = false;
  private logScrollQueued: boolean = false;
  @State bytesIn: number = 0;
  @State bytesOut: number = 0;
  @State @Watch('syncVpnActive') isConnected: boolean = false;
  @State @Watch('syncVpnActive') isConnecting: boolean = false;

  // 对话框
  @State showNoConfigDialog: boolean = false;
  @State @Watch('onAuthDialogVisibility') showAuthDialog: boolean = false;
  @State showExitDialog: boolean = false;
  @State authUsername: string = '';
  @State authPassword: string = '';
  @State savePassword: boolean = false;
  @State authIsProxy: boolean = false;
  @State authCaption: string = '';
  /** 已保存密码时，认证框底部的自动连接倒计时。0 表示不显示。 */
  @State authAutoSeconds: number = 0;
  /** 凭证被拒后再次弹出认证框时的提示。对应原版 IDS_NFO_AUTH_PASS_RETRY。 */
  @State authRetryHint: string = '';
  @State authPasswordVisible: boolean = false;

  /* C 层 OpenVPN 是否在运行（定时查询，用于按钮权威状态） */
  @State @Watch('syncVpnActive') coreRunning: boolean = false;
  /* 会话内缓存凭据（与原版 GUI 行为一致：自动重试时静默重新提交） */
  private cachedUsername: string = '';
  /** 每次真正发起新连接时加一。旧连接的延迟停止看到代际变了就不再拆扩展进程。 */
  private sessionEpoch: number = 0;
  /** 用户主动断开。持久连接「自动」只在隧道自己断开后重连。 */
  private userStopped: boolean = false;
  /** 这次会话曾经连上。避免连接失败后被「自动」反复拉起。 */
  private persistHadConnected: boolean = false;
  private lastEchoText: string = '';
  private lastEchoMs: number = 0;
  /** 同一次认证请求会从 auth 和 AUTH_REQUEST 各到一次，短时间内只处理一次。 */
  private lastAuthPromptMs: number = 0;
  /** 本次连接里用户名密码被拒绝的次数。大于 0 时不再静默重发，重新弹出认证框。 */
  private failedAuthAttempts: number = 0;
  /** 同一次失败可能先到 Verification Failed 再到 RECONNECTING|auth-failure，去重计数。 */
  private lastAuthFailureMs: number = 0;
  private cachedPassword: string = '';
  private authTimer: number = -1;

  private readonly versionText: string = 'OvpnLink 1.0.0/2.7.6';
  private configDir: string = '';

  /* 应用设置（连接前从 SettingsStore 加载；注意：成员变量不会触发 UI 重渲染，
   * 仅用于连接参数，符合"设置 → 下一次连接生效"的原版行为） */
  private appSettings: VpnSettings = defaultSettings();

  /* 服务端分配的真实 tun IP（ASSIGN_IP/CONNECTED 状态解析，如 10.96.0.17），
   * 用于 setupTun 动态配置 VpnConfig 地址（对齐原版 do_ifconfig 行为） */
  private assignedIp: string = '';

  /* CLI 凭据文件路径（aa start --ps authfile，透传给 C 层 --auth-user-pass） */
  private cliAuthfile: string = '';
  /* CLI 直接传凭据（aa start --ps username xxx --ps password yyy：
   * 非空时优先于 authfile/弹窗，对齐原版 openvpn --auth-user-pass 控制台输入习惯） */
  private cliUsername: string = '';
  private cliPassword: string = '';

  /* 重复通知静音状态（对齐原版 popup_mute_interval：N 小时内同一状态不重复通知） */
  private lastNotifyTime: number = 0;
  private lastNotifyState: number = -1;

  /* 扩展进程 → UI 的状态订阅 */
  private uiSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private lastUiSeq: number = 0;
  private lastUiGen: number = 0;
  private uiPollTimer: number = -1;

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.configDir = `${context.filesDir}/config`;

      hilog.info(DOMAIN, TAG, `Config directory: ${this.configDir}`);
      VpnTray.setHandler((cmd: TrayCommand) => {
        this.onTrayCommand(cmd);
      });

      // 读取调试日志（如果存在）
      this.readDebugLog();

      // 请求通知授权（真机默认关闭，1600004；GUI 启动时弹窗请求一次，CLI 无头场景跳过）
      this.ensureNotificationEnabled();

      // 先订阅扩展进程事件，再扫描配置（避免自动连接时丢掉状态推送）
      this.setupCallbacks().then(() => {
        this.initSettingsAndScan();
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, `setupCallbacks error: ${JSON.stringify(err)}`);
        this.initSettingsAndScan();
      });

      /* CLI 命令热更新监听：应用已在运行时，EntryAbility.onNewWant 收到
       * aa start 命令 → emitter 通知本页执行（原版 WM_COPYDATA 等价） */
      emitter.on({ eventId: SETTINGS_SAVED_EVENT }, () => {
        this.reloadSettings();
      });
      emitter.on({ eventId: PROFILE_IMPORTED_EVENT }, () => {
        this.onProfileImported();
      });

      emitter.on({ eventId: CLI_COMMAND_EVENT }, () => {
        hilog.info(DOMAIN, TAG, 'CLI command event received');
        this.processCliCommand();
      });
      emitter.on({ eventId: EXIT_CONFIRM_EVENT }, () => {
        hilog.info(DOMAIN, TAG, 'exit confirm requested by prepare-to-terminate');
        this.requestExit();
      });
      this.syncVpnActive();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `aboutToAppear error: ${JSON.stringify(err)}`);
      this.showNoConfigDialog = true;
    }
  }

  aboutToDisappear(): void {
    this.stopAuthCountdown();
    AppWindows.setMainPrivacyMode(false);
    this.stopUiPoll();
    VpnIpc.unsubscribe(this.uiSubscriber);
    this.uiSubscriber = null;
  }

  /** 认证框露出用户名和密码时禁止截屏、录屏，框关闭后恢复。 */
  private onAuthDialogVisibility(): void {
    AppWindows.setMainPrivacyMode(this.showAuthDialog);
  }

  /**
   * 请求通知授权（错误码 1600004 = 应用通知开关关闭）。
   * 真机默认关闭，必须 requestEnableNotification 弹窗授权一次；
   * CLI 无头启动（aa start --ps action=...）时跳过，避免打断无头流程。
   */
  private ensureNotificationEnabled(): void {
    try {
      /* CLI 命令场景跳过授权请求（无头模式不应弹窗） */
      const cliAction: string = AppStorage.get<string>('cliAction') ?? '';
      if (cliAction.length > 0) {
        return;
      }
      notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        if (!enabled) {
          hilog.info(DOMAIN, TAG, 'notification disabled, requesting enable...');
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          notificationManager.requestEnableNotification(context).then(() => {
            hilog.info(DOMAIN, TAG, 'notification enabled by user');
          }).catch((e: Error) => {
            hilog.warn(DOMAIN, TAG, 'notification enable rejected: %{public}s', JSON.stringify(e));
          });
        }
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'isNotificationEnabled error: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ensureNotificationEnabled error: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 加载设置后扫描配置目录；若开启"自动重启"则自动连接上次活动的配置
   * （对齐原版 enable_auto_restart：启动时恢复活动连接）
   */
  private async initSettingsAndScan(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.getInstance().init(context);
      this.appSettings = await SettingsStore.getInstance().get();
      if (this.appSettings.configDir.length > 0) {
        this.configDir = this.appSettings.configDir;
      }
      hilog.info(DOMAIN, TAG, `settings loaded, configDir=${this.configDir} ext=${this.appSettings.configExt}`);

      // 扫描配置目录
      this.scanConfigDirectory(false);

      /* 自动重启：只在勾选时连接。多个配置连上次那个；只有一个配置且没有记录时连这一个。 */
      if (this.appSettings.autoRestart && !this.isConnecting && !this.isConnected) {
        let idx: number = -1;
        if (this.appSettings.lastConfigName !== '') {
          idx = this.allConfigs.indexOf(this.appSettings.lastConfigName);
        } else if (this.allConfigs.length === 1) {
          idx = 0;
        }
        if (idx >= 0) {
          hilog.info(DOMAIN, TAG, `auto-restart: connecting to ${this.allConfigs[idx]}`);
          this.selectConfig(idx);
          this.startConnection();
        }
      }

      /* CLI 命令（aa start --ps action=...）：在设置/扫描完成后执行。
       * 优先级高于自动重启（CLI 显式命令优先） */
      this.processCliCommand();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `initSettingsAndScan error: ${JSON.stringify(err)}`);
    }
  }

  /** 设置窗口确定后刷新内存中的设置。配置目录或扩展名变了才重新扫描。 */
  private async reloadSettings(): Promise<void> {
    try {
      const prevDir: string = this.configDir;
      const prevExt: string = this.appSettings.configExt;
      const prevMenu: number = this.appSettings.menuView;
      this.appSettings = await SettingsStore.getInstance().get();
      if (this.appSettings.configDir.length > 0) {
        this.configDir = this.appSettings.configDir;
      }
      hilog.info(DOMAIN, TAG, 'settings reloaded');
      if (this.configDir !== prevDir || this.appSettings.configExt !== prevExt
        || this.appSettings.menuView !== prevMenu) {
        this.scanConfigDirectory(false);
      } else {
        this.refreshTray();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'reloadSettings: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 执行 CLI 命令（对齐原版 openvpn-gui --command 系列）。
   * 命令由 EntryAbility.onCreate/onNewWant 解析 aa start 的 --ps 参数存入 AppStorage。
   */
  private async processCliCommand(): Promise<void> {
    try {
      const action: string = AppStorage.get<string>('cliAction') ?? '';
      if (action.length === 0) {
        return;
      }
      /* 读取后立即清空，避免同进程后续启动重复执行 */
      AppStorage.setOrCreate('cliAction', '');
      const profile: string = AppStorage.get<string>('cliProfile') ?? '';
      const authfile: string = AppStorage.get<string>('cliAuthfile') ?? '';
      const headless: string = AppStorage.get<string>('cliHeadless') ?? '';
      const username: string = AppStorage.get<string>('cliUsername') ?? '';
      const password: string = AppStorage.get<string>('cliPassword') ?? '';
      AppStorage.setOrCreate('cliProfile', '');
      AppStorage.setOrCreate('cliAuthfile', '');
      AppStorage.setOrCreate('cliHeadless', '');
      AppStorage.setOrCreate('cliUsername', '');
      AppStorage.setOrCreate('cliPassword', '');
      this.cliAuthfile = authfile;
      this.cliUsername = username;
      this.cliPassword = password;
      hilog.info(DOMAIN, TAG, `CLI command: action=${action} profile=${profile} authfile=${authfile} headless=${headless}`);
      appFileLog(`CLI command: action=${action} profile=${profile} authfile=${authfile} headless=${headless}`);

      if (action === 'version') {
        /* FR-4.18-12 版本与帮助：对齐原版 openvpn --version */
        const ver: string = 'OpenVPN 2.7.6 [git:v2.7.6/327a33de2aa21883] (OpenSSL 3.x, LZO, LZ4, AEAD, DCO)';
        const info: string = `${this.versionText}\n${ver}`;
        hilog.info(DOMAIN, TAG, `version: ${ver}`);
        appFileLog(`version: ${ver}`);
        this.appendLog(info);
        return;
      }

      if (action === 'help') {
        /* FR-4.18-12 帮助：对齐原版 openvpn --help（独立命令） */
        const help: string = `${this.versionText}\n` +
          'OvpnLink\n' +
          '用法：aa start -b com.practical.opensource.OvpnLink -a EntryAbility --ps action <命令>\n' +
          '命令列表：\n' +
          '  connect <profile>   连接指定配置（可加 --ps username/password 或 --ps authfile <路径>）\n' +
          '  disconnect          断开当前连接\n' +
          '  rescan              重新扫描配置目录\n' +
          '  version             显示版本信息\n' +
          '  help                显示本帮助\n' +
          '  smoke               双隧道冒烟测试';
        hilog.info(DOMAIN, TAG, `help: ${help}`);
        appFileLog(`help: ${help}`);
        this.appendLog(help);
        return;
      }

      if (action === 'connect' || action === 'reconnect') {
        /* CLI 直接传凭据 → 存入会话缓存，onAuthRequest 自动认证（优先于 authfile/弹窗） */
        if (this.cliUsername.length > 0) {
          this.cachedUsername = this.cliUsername;
          this.cachedPassword = this.cliPassword;
          this.authUsername = this.cliUsername;
          this.authPassword = this.cliPassword;
          appFileLog(`CLI credentials provided for ${profile}: user=${this.cliUsername}`);
        }
        if (profile.length > 0) {
          const idx: number = this.allConfigs.indexOf(profile);
          if (idx >= 0) {
            /* 已连接/连接中先断开（对齐原版 reconnect 语义） */
            if (this.isConnected || this.isConnecting || this.coreRunning) {
              await this.stopVpnSession();
              this.isConnected = false;
              this.isConnecting = false;
              this.statusText = '已断开';
            }
            this.selectConfig(idx);
            this.startConnection();
          } else {
            hilog.error(DOMAIN, TAG, `CLI: config not found: ${profile}`);
            appFileLog(`CLI: config not found: ${profile}`);
          }
        } else {
          /* 无 profile：连接当前选中配置（原版 --connect 不带参数的等价） */
          this.startConnection();
        }
      } else if (action === 'disconnect' || action === 'disconnect_all') {
        try {
          await this.stopVpnSession();
          this.isConnected = false;
          this.isConnecting = false;
          this.statusText = '已断开';
          hilog.info(DOMAIN, TAG, 'CLI: disconnected');
          appFileLog('CLI: disconnected');
        } catch (e) {
          hilog.error(DOMAIN, TAG, `CLI disconnect error: ${JSON.stringify(e)}`);
        }
      } else if (action === 'rescan') {
        this.scanConfigDirectory(false);
        hilog.info(DOMAIN, TAG, 'CLI: rescan done');
      } else if (action === 'smoke') {
        /* 双隧道冒烟验证（多连接前置闸门）：验证系统是否支持并发多 VPN */
        appFileLog('CLI: smoke test start');
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const result: string = await VpnServiceManager.getInstance().smokeTestDualTunnel(context as object);
        appFileLog(`CLI: smoke test result -> ${result}`);
        hilog.info(DOMAIN, TAG, `CLI: smoke test result -> ${result}`);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `processCliCommand error: ${JSON.stringify(err)}`);
      appFileLog(`processCliCommand CATCH: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 读取 C++ 层的调试日志
   */
  private readDebugLog(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

      interface LogFile {
        name: string;
        label: string;
      }

      const logFiles: LogFile[] = [
        { name: 'openvpn_debug.log', label: 'C++' },
        { name: 'openvpn_exit.log', label: '退出' },
        { name: 'openvpn_signal.log', label: '信号' },
        { name: 'parse_argv.log', label: 'parse_argv' },
      ];

      for (const logFile of logFiles) {
        const logPath = `${context.cacheDir}/${logFile.name}`;
        try {
          const stat = fs.statSync(logPath);
          if (stat.size > 0) {
            const file = fs.openSync(logPath, fs.OpenMode.READ_ONLY);
            const buf = new ArrayBuffer(stat.size);
            fs.readSync(file.fd, buf);
            fs.closeSync(file);

            const content = String.fromCharCode(...new Uint8Array(buf));
            /* 仅输出到 hilog 调试，不显示在界面（与 Windows 原版一致） */
            hilog.info(DOMAIN, TAG, `=== ${logFile.label} Log ===\n${content}`);
          }
        } catch (err) {
          // 文件不存在或读取失败，忽略
        }
      }
    } catch (err) {
      // 整体读取失败，忽略
    }
  }

  /**
   * 扫描配置目录 - 参考 Windows 的 BuildFileList 逻辑
   */
  private scanConfigDirectory(keepCurrent: boolean): void {
    try {
      // 检查目录是否存在
      const stat = fs.statSync(this.configDir);
      if (!stat.isDirectory()) {
        hilog.warn(DOMAIN, TAG, 'Config path is not a directory');
        this.allConfigs = [];
        this.showNoConfigDialog = true;
        this.refreshTray();
        return;
      }

      // 列出目录中的文件
      const files = fs.listFileSync(this.configDir);
      hilog.info(DOMAIN, TAG, `Found ${files.length} items in config directory`);

      // 扩展名（对齐原版 Advanced 页 ext_string：默认 ovpn，可自定义）
      const ext: string = (this.appSettings.configExt && this.appSettings.configExt.length > 0)
        ? this.appSettings.configExt.toLowerCase() : 'ovpn';
      const suffix: string = ext.startsWith('.') ? ext : `.${ext}`;

      /* 配置菜单视图（鸿蒙化语义，对齐原版 config_menu_view）：
       * - 扁平化：只扫描根目录（平铺）
       * - 自动/嵌套化：递归子目录，配置名显示为 "子目录/文件名" */
      const nested: boolean = (this.appSettings.menuView !== 1);  // 0=auto, 2=nested
      const ovpnFiles: string[] = [];
      this.collectConfigs(this.configDir, suffix, nested, '', ovpnFiles);

      if (ovpnFiles.length === 0) {
        hilog.info(DOMAIN, TAG, 'No .ovpn files found');
        this.allConfigs = [];
        this.hasConfig = false;
        this.showNoConfigDialog = true;
        this.refreshTray();
        return;
      }

      // 保存所有配置（原版托盘菜单列出全部配置供选择）
      this.allConfigs = ovpnFiles.map((f: string) => {
        if (f.toLowerCase().endsWith(suffix)) {
          return f.substring(0, f.length - suffix.length);
        }
        return f;
      });
      this.hasConfig = true;
      this.showNoConfigDialog = false;

      /* 导入时保留当前配置和连接，只把新文件加进托盘。启动扫描才选中第一项。 */
      if (keepCurrent && this.configName.length > 0) {
        const kept: number = this.allConfigs.indexOf(this.configName);
        if (kept >= 0) {
          this.assignConfig(kept);
        }
        hilog.info(DOMAIN, TAG, `Rescan kept config: ${this.configName}`);
        this.refreshTray();
        return;
      }

      this.selectedConfigIndex = 0;
      this.selectConfig(0);

      hilog.info(DOMAIN, TAG, `Loaded config: ${this.configName}`);
      this.refreshTray();
    } catch (err) {
      const error = err as Error;
      hilog.error(DOMAIN, TAG, `scanConfigDirectory error: ${error.message}`);
      this.hasConfig = false;
      this.showNoConfigDialog = true;
      this.refreshTray();
    }
  }

  /**
   * 递归收集配置文件（菜单视图分组，对齐原版 config_menu_view）
   * @param dir    当前目录
   * @param suffix 配置扩展名（含点）
   * @param nested 是否递归子目录（flat 时 false）
   * @param prefix 目录前缀（如 "sub/"），用于分组显示
   * @param out    收集结果（相对 configDir 的路径，如 "sub/name.ovpn"）
   */
  private collectConfigs(dir: string, suffix: string, nested: boolean, prefix: string, out: string[]): void {
    try {
      const items = fs.listFileSync(dir);
      for (const item of items) {
        const full = `${dir}/${item}`;
        try {
          const st = fs.statSync(full);
          if (st.isDirectory()) {
            if (nested) {
              this.collectConfigs(full, suffix, nested, `${prefix}${item}/`, out);
            }
          } else if (item.toLowerCase().endsWith(suffix)) {
            out.push(`${prefix}${item}`);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `collectConfigs stat failed: ${item}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `collectConfigs list failed: ${dir}`);
    }
  }

  /* 选中一个配置文件（等效原版托盘菜单点击配置项）。
   * 切换配置时若正在连接/已连接，必须先停掉旧连接（原版 GUI 切换配置 = 断开+换配置），
   * 否则 C 层 g_config_path 与旧连接状态不一致，导致后续连接失效。 */
  private selectConfig(index: number): void {
    if (index < 0 || index >= this.allConfigs.length) {
      return;
    }
    if (this.selectedConfigIndex === index && (this.isConnected || this.isConnecting)) {
      return;
    }
    /* 切换前停止旧连接 */
    if (this.isConnected || this.isConnecting || this.coreRunning) {
      hilog.info(DOMAIN, TAG, 'selectConfig: stopping previous connection');
      this.stopVpnSession();
      this.isConnected = false;
      this.isConnecting = false;
      this.statusText = '已断开';
      this.cachedUsername = '';
      this.cachedPassword = '';
    }
    this.assignConfig(index);
  }

  /** 先等旧会话停完，再改选中项。托盘换配置连接走这里，避免延迟停止拆掉新进程。 */
  private async switchToConfig(index: number): Promise<void> {
    if (index < 0 || index >= this.allConfigs.length) {
      return;
    }
    if (this.isConnected || this.isConnecting || this.coreRunning) {
      hilog.info(DOMAIN, TAG, 'switchToConfig: stopping previous connection');
      await this.stopVpnSession();
      this.isConnected = false;
      this.isConnecting = false;
      this.statusText = '已断开';
      this.cachedUsername = '';
      this.cachedPassword = '';
    }
    this.assignConfig(index);
  }

  private assignConfig(index: number): void {
    this.selectedConfigIndex = index;
    this.configName = this.allConfigs[index];
    const ext: string = (this.appSettings.configExt && this.appSettings.configExt.length > 0)
      ? this.appSettings.configExt.toLowerCase() : 'ovpn';
    const suffix: string = ext.startsWith('.') ? ext : `.${ext}`;
    this.configFilePath = `${this.configDir}/${this.allConfigs[index]}${suffix}`;
    hilog.info(DOMAIN, TAG, `Selected config: ${this.configName}`);
  }

  /**
   * 启动 OpenVPN 连接：先拉起 VpnExtAbility，在扩展进程内创建 tun 并运行核心。
   */
  private startConnection(preserveAuthSession: boolean = false): void {
    this.startConnectionAsync(preserveAuthSession);
  }

  private async startConnectionAsync(preserveAuthSession: boolean = false): Promise<void> {
    if (this.configName.length === 0 || this.configFilePath.length === 0) {
      hilog.info(DOMAIN, TAG, 'startConnection: no config selected');
      return;
    }
    this.sessionEpoch++;
    try {
      hilog.info(DOMAIN, TAG, `Starting OpenVPN for config: ${this.configName}`);
      hilog.info(DOMAIN, TAG, `Config file path: ${this.configFilePath}`);

      this.isConnecting = true;
      this.isConnected = false;
      this.statusText = '连接中';
      this.coreRunning = true;
      this.assignedIp = '';
      /* 新的一次界面连接重新弹出认证框。命令行已经放入的凭据保留。
       * preserveAuthSession：认证失败核心已退出时只重启隧道，保留失败计数与重试提示。 */
      if (!preserveAuthSession) {
        if (this.cliUsername.length === 0) {
          this.cachedUsername = '';
          this.cachedPassword = '';
        }
        this.lastAuthPromptMs = 0;
        this.failedAuthAttempts = 0;
        this.lastAuthFailureMs = 0;
        this.authRetryHint = '';
        this.showAuthDialog = false;
        this.stopAuthCountdown();
      } else {
        this.lastAuthPromptMs = 0;
      }

      try {
        const stat = fs.statSync(this.configFilePath);
        hilog.info(DOMAIN, TAG, `Config file size: ${stat.size} bytes`);
      } catch (fileErr) {
        const error = fileErr as Error;
        hilog.error(DOMAIN, TAG, `Config file not accessible: ${error.message}`);
        this.appendLog(`配置文件不可读: ${error.message}`);
        this.isConnecting = false;
        this.coreRunning = false;
        this.statusText = '配置文件错误';
        return;
      }

      const startJson: string = JSON.stringify({
        name: this.configName,
        configFile: this.configFilePath,
        proxyMode: this.appSettings.proxyMode,
        proxySubType: this.appSettings.proxySubType,
        proxyServer: this.appSettings.proxyServer,
        proxyPort: this.appSettings.proxyPort,
        proxyUsername: this.appSettings.proxyUsername,
        proxyPassword: this.appSettings.proxyPassword,
        silent: this.appSettings.silentConn,
        appendLog: this.appSettings.appendLog,
        mgmtPortOffset: this.appSettings.mgmtPortOffset,
        authFile: this.cliAuthfile
      });

      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bundleName: string = context.abilityInfo.bundleName;
      VpnIpc.writePending(context.filesDir, startJson);
      const want: Want = VpnIpc.buildExtWant(bundleName, startJson);

      hilog.info(DOMAIN, TAG, 'Calling startVpnExtensionAbility');
      appFileLog('startVpnExtensionAbility + connect command');
      try {
        await vpnExtension.startVpnExtensionAbility(want);
        appFileLog('startVpnExtensionAbility resolved');
      } catch (extErr) {
        /* 扩展已在运行时再次 start 可能报错，仍然下发 connect 命令 */
        appFileLog(`startVpnExtensionAbility: ${JSON.stringify(extErr)}`);
        hilog.warn(DOMAIN, TAG, `startVpnExtensionAbility: ${JSON.stringify(extErr)}`);
      }
      VpnIpc.publishToExt('connect', startJson);

      this.appSettings.lastConfigName = this.configName;
      SettingsStore.getInstance().save(this.appSettings);
    } catch (err) {
      const error = err as Error;
      hilog.error(DOMAIN, TAG, `startConnection error: ${error.message}`);
      this.appendLog(`启动失败: ${error.message}`);
      this.isConnecting = false;
      this.coreRunning = false;
      this.statusText = '启动失败';
    }
  }

  private async stopVpnSession(): Promise<void> {
    this.userStopped = true;
    const epoch: number = this.sessionEpoch;
    VpnIpc.publishToExt('stop');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'VpnExtAbility',
        moduleName: 'entry'
      };
      /* 给扩展一点时间 stop 核心并 destroy tun，再停扩展进程 */
      await this.sleep(500);
      if (epoch !== this.sessionEpoch) {
        appFileLog('stopVpnExtensionAbility skipped, newer session started');
        return;
      }
      await vpnExtension.stopVpnExtensionAbility(want);
      appFileLog('stopVpnExtensionAbility resolved');
    } catch (err) {
      appFileLog(`stopVpnExtensionAbility: ${JSON.stringify(err)}`);
    }
    if (epoch === this.sessionEpoch) {
      this.coreRunning = false;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 创建配置目录
   */
  private createConfigDirectory(): void {
    try {
      fs.mkdirSync(this.configDir);
      hilog.info(DOMAIN, TAG, `Config directory created: ${this.configDir}`);

      this.getUIContext().showAlertDialog({
        message: `配置目录已创建：\n${this.configDir}\n\n请将 .ovpn 配置文件放入该目录，然后重启应用。`,
        confirm: {
          value: '确定',
          action: () => {}
        }
      });
    } catch (err) {
      const error = err as Error;
      if (error.message.includes('File exists')) {
        this.getUIContext().showAlertDialog({
          message: `配置目录已存在：\n${this.configDir}\n\n请将 .ovpn 配置文件放入该目录，然后重启应用。`,
          confirm: {
            value: '确定',
            action: () => {}
          }
        });
      } else {
        hilog.error(DOMAIN, TAG, `Create directory error: ${error.message}`);
        this.getUIContext().showAlertDialog({
          message: `创建目录失败：${error.message}`,
          confirm: {
            value: '确定',
            action: () => {}
          }
        });
      }
    }
  }

  private async setupCallbacks(): Promise<void> {
    try {
      this.uiSubscriber = await VpnIpc.subscribeUi((msg: VpnUiMessage) => {
        this.onVpnUiMessage(msg);
      });
      appFileLog('UI vpn event subscriber ready');
      this.startUiPoll();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `setupCallbacks error: ${JSON.stringify(err)}`);
      this.startUiPoll();
    }
  }

  private startUiPoll(): void {
    if (this.uiPollTimer >= 0) {
      return;
    }
    this.uiPollTimer = setInterval(() => {
      this.drainUiFile();
    }, 250);
  }

  private stopUiPoll(): void {
    if (this.uiPollTimer >= 0) {
      clearInterval(this.uiPollTimer);
      this.uiPollTimer = -1;
    }
  }

  private drainUiFile(): void {
    const msg: VpnUiMessage | null = VpnIpc.readLastUiEvent();
    if (msg !== null) {
      this.onVpnUiMessage(msg);
    }
  }

  private onVpnUiMessage(msg: VpnUiMessage): void {
    /* 扩展进程每次重建都会把序号从 1 重计。比已记录会话更新的 gen 才清掉旧序号，
     * 否则重连后的 THREAD_STARTED / CONNECTED 会被当成重复事件丢掉，界面停在连接中。 */
    if (msg.gen > this.lastUiGen) {
      this.lastUiGen = msg.gen;
      this.lastUiSeq = 0;
    } else if (msg.gen > 0 && msg.gen < this.lastUiGen) {
      return;
    }
    if (msg.seq > 0 && msg.seq <= this.lastUiSeq) {
      return;
    }
    if (msg.seq > this.lastUiSeq) {
      this.lastUiSeq = msg.seq;
    }
    if (msg.type === 'status') {
      this.onExtStatus(msg.payload);
    } else if (msg.type === 'log') {
      this.onExtLog(msg.payload);
    } else if (msg.type === 'state') {
      this.onExtState(msg.payload);
    } else if (msg.type === 'bytecount') {
      const parts = msg.payload.split(',');
      if (parts.length === 2) {
        this.bytesIn = parseInt(parts[0]);
        this.bytesOut = parseInt(parts[1]);
      }
    } else if (msg.type === 'auth') {
      this.onExtAuth(msg.payload);
    } else if (msg.type === 'error') {
      hilog.error(DOMAIN, TAG, `ext error: ${msg.payload}`);
      this.appendLog(msg.payload);
      if (msg.payload.indexOf('虚拟网卡') >= 0 || msg.payload.indexOf('启动失败') >= 0) {
        this.isConnecting = false;
        this.isConnected = false;
        this.coreRunning = false;
        this.statusText = '连接失败';
      }
    } else if (msg.type === 'started') {
      hilog.info(DOMAIN, TAG, 'OpenVPN started in VpnExtAbility');
      appFileLog('OpenVPN started in VpnExtAbility');
    }
  }

  private onExtStatus(msg: string): void {
    hilog.info(DOMAIN, TAG, `Status: ${msg}`);
    if (msg.startsWith('ECHO:')) {
      this.onEchoMessage(msg.substring(5));
      return;
    }
    /* 重新连接不弹认证框。若 SIGHUP 后核心仍再要一次密码，用本次会话里的凭据静默送回。 */
    if (msg === 'AUTH_VERIFY_FAILED') {
      this.noteAuthFailure();
      if (!this.authIsProxy && this.cliUsername.length === 0) {
        this.showAuthRetry();
      }
      return;
    }
    if (msg === 'AUTH_REQUEST') {
      this.onExtAuth(msg);
    }
    if (msg.includes('EXITED')) {
      if (this.failedAuthAttempts > 0 && !this.userStopped && this.cliUsername.length === 0
        && !this.authIsProxy) {
        hilog.info(DOMAIN, TAG, 'core exited after auth-failure, restart for retry');
        if (!this.showAuthDialog) {
          this.showAuthRetry();
        }
        this.startConnection(true);
        return;
      }
      this.isConnected = false;
      this.isConnecting = false;
      this.coreRunning = false;
      this.statusText = '已断开';
      const stopped: boolean = this.userStopped;
      const canPersist: boolean = this.persistHadConnected && !stopped
        && this.appSettings.persistentConn === PersistentConn.AUTO
        && this.configName.length > 0;
      this.persistHadConnected = false;
      if (this.appSettings.persistentConn === PersistentConn.DISABLED) {
        this.configName = '';
        this.configFilePath = '';
        this.selectedConfigIndex = -1;
        hilog.info(DOMAIN, TAG, 'persistent-conn disabled: cleared config selection');
      } else if (canPersist) {
        hilog.info(DOMAIN, TAG, 'persistent-conn auto: reconnect %{public}s', this.configName);
        this.startConnection();
      }
    }
  }

  /** 配置里的 echo。永不则不弹窗；静音小时内同一条消息只弹一次。 */
  private onEchoMessage(text: string): void {
    const msg: string = text.trim();
    if (msg.length === 0) {
      return;
    }
    this.appendLog(`ECHO: ${msg}`);
    if (this.appSettings.messageDisplay === 1) {
      return;
    }
    const muteMs: number = this.appSettings.repeatMsgMuteHours * 3600 * 1000;
    const nowMs: number = Date.now();
    if (muteMs > 0 && msg === this.lastEchoText && nowMs - this.lastEchoMs < muteMs) {
      return;
    }
    this.lastEchoText = msg;
    this.lastEchoMs = nowMs;
    promptAction.showDialog({
      title: 'OpenVPN',
      message: msg,
      buttons: [{ text: '确定', color: theme.accentColor }]
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'echo dialog skipped: %{public}s', JSON.stringify(e));
    });
  }

  private onExtLog(line: string): void {
    const sep = line.indexOf('|');
    if (sep > 0 && sep < 3) {
      const level = parseInt(line.substring(0, sep));
      const text = line.substring(sep + 1);
      this.appendLogLevel(text, level);
    } else {
      this.appendLog(line);
    }
  }

  private onExtAuth(info: string): void {
    this.authPasswordVisible = false;
    if (info === 'HTTP Proxy' || info === 'SOCKS Proxy') {
      this.stopAuthCountdown();
      this.authIsProxy = true;
      this.authCaption = info === 'HTTP Proxy' ? 'HTTP 代理认证' : 'SOCKS 代理认证';
      this.authUsername = '';
      this.authPassword = '';
      this.savePassword = false;
      this.authRetryHint = '';
      this.showAuthDialog = true;
      this.showMainWindow();
      return;
    }
    this.authIsProxy = false;
    this.authCaption = '';
    const nowMs: number = Date.now();
    if (this.showAuthDialog) {
      return;
    }
    /* 原版：RECONNECTING 且 message 为 auth-failure 后，下一次 Need 'Auth' 重新弹框，
     * 不把刚才失败的密码再送回去，也不走已存密码的自动连接。 */
    if (this.failedAuthAttempts > 0) {
      this.lastAuthPromptMs = nowMs;
      this.showAuthRetry();
      return;
    }
    /* auth 与 AUTH_REQUEST 会各到一次。对话框还开着时忽略；已经提交过的凭据要再送一次，
     * 否则重连后的第二次询问会停在管理接口上。 */
    if (nowMs - this.lastAuthPromptMs < 1500) {
      if (this.cachedUsername !== '' && this.failedAuthAttempts === 0) {
        hilog.info(DOMAIN, TAG, 'Auth request within debounce, resend cached credentials');
        VpnIpc.publishToExt('sendAuth', '', this.cachedUsername, this.cachedPassword);
      }
      return;
    }
    this.lastAuthPromptMs = nowMs;
    hilog.info(DOMAIN, TAG, 'Auth request received');
    /* 命令行直接给了账号密码时仍静默提交。界面连接每次都弹出认证框。 */
    if (this.cliUsername.length > 0 && this.cachedUsername !== '') {
      hilog.info(DOMAIN, TAG, 'Using CLI credentials');
      VpnIpc.publishToExt('sendAuth', '', this.cachedUsername, this.cachedPassword);
      return;
    }
    /* 同一次连接里用户已经点过确定，OpenVPN 可能再问一次；认证失败后必须弹框重试。 */
    if (this.cachedUsername !== '' && this.failedAuthAttempts === 0) {
      hilog.info(DOMAIN, TAG, 'Resend credentials for this connection');
      VpnIpc.publishToExt('sendAuth', '', this.cachedUsername, this.cachedPassword);
      return;
    }
    const store = SettingsStore.getInstance();
    store.getCredentials(this.configName).then((cred: SavedCredentials) => {
      this.authUsername = cred.username;
      const keptPass: boolean = cred.password.length > 0;
      this.authPassword = keptPass ? cred.password : '';
      this.savePassword = keptPass;
      this.authRetryHint = '';
      this.showAuthDialog = true;
      this.showMainWindow();
      if (keptPass) {
        this.startAuthCountdown();
      } else {
        this.stopAuthCountdown();
      }
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, `getCredentials error: ${JSON.stringify(e)}`);
      this.authUsername = '';
      this.authPassword = '';
      this.savePassword = false;
      this.authRetryHint = '';
      this.stopAuthCountdown();
      this.showAuthDialog = true;
      this.showMainWindow();
    });
  }

  private onExtState(data: string): void {
    const sep = data.indexOf('|');
    const state = sep >= 0 ? data.substring(0, sep) : data;
    const detail = sep >= 0 ? data.substring(sep + 1) : '';

    if (state === 'ASSIGN_IP' || state === 'CONNECTED' || state === 'RECONNECTING') {
      const ipSep = detail.lastIndexOf('|');
      if (ipSep >= 0 && ipSep + 1 < detail.length) {
        this.assignedIp = detail.substring(ipSep + 1);
        appFileLog(`assignedIp updated (${state}): ${this.assignedIp}`);
      }
    }
    hilog.info(DOMAIN, TAG, `State: ${state} (${detail})`);

    let notifyState: NotifyState = NotifyState.DISCONNECTED;
    if (state === 'CONNECTED') {
      this.isConnected = true;
      this.isConnecting = false;
      this.coreRunning = true;
      this.statusText = '已连接';
      notifyState = NotifyState.CONNECTED;
      this.persistHadConnected = true;
      this.userStopped = false;
      if (this.showAuthDialog) {
        this.stopAuthCountdown();
        this.showAuthDialog = false;
        hilog.info(DOMAIN, TAG, 'auth dialog closed on CONNECTED');
      }
      this.failedAuthAttempts = 0;
      this.authRetryHint = '';
    } else if (state === 'CONNECTING' || state === 'WAIT' || state === 'AUTH' || state === 'GET_CONFIG' || state === 'ASSIGN_IP') {
      this.isConnecting = true;
      this.isConnected = false;
      this.statusText = '连接中...';
      notifyState = NotifyState.CONNECTING;
    } else if (state === 'RECONNECTING') {
      this.isConnecting = true;
      this.isConnected = false;
      this.statusText = '重新连接中...';
      notifyState = NotifyState.CONNECTING;
      /* 原版 OnState：message 为 auth-failure 时 failed_auth_attempts++。
       * 管理接口第三字段就是这个原因；AUTH_FAILED 在核心里也会记成 auth-failure。 */
      if (detail.indexOf('auth-failure') >= 0 || detail.indexOf('auth-failed') >= 0) {
        this.noteAuthFailure();
      }
    } else if (state === 'EXITING') {
      this.isConnected = false;
      this.isConnecting = false;
      this.coreRunning = false;
      this.statusText = '已断开';
      notifyState = NotifyState.DISCONNECTING;
    }

    let shouldNotify: boolean = false;
    const showNotif: ShowNotifyMode = this.appSettings.showNotification;
    if (!this.appSettings.silentConn && showNotif !== ShowNotifyMode.NEVER
      && this.appSettings.messageDisplay !== 1) {
      if (showNotif === ShowNotifyMode.ON_CONNECT_RECONNECT) {
        shouldNotify = (state === 'CONNECTED' || state === 'RECONNECTING' || state === 'EXITING');
      } else {
        shouldNotify = (state === 'CONNECTED' || state === 'EXITING');
      }
    }

    const muteMs: number = this.appSettings.repeatMsgMuteHours * 3600 * 1000;
    const nowMs: number = Date.now();
    if (shouldNotify && muteMs > 0 && notifyState === this.lastNotifyState
      && nowMs - this.lastNotifyTime < muteMs) {
      shouldNotify = false;
    }

    if (shouldNotify) {
      try {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        let detail: string = '';
        if (state === 'CONNECTED' && this.assignedIp.length > 0) {
          detail = `IP ${this.assignedIp}`;
        }
        VpnNotification.getInstance().publish(ctx, notifyState, this.configName, detail);
        this.lastNotifyState = notifyState;
        this.lastNotifyTime = nowMs;
        appFileLog(`notify publish state=${state} config=${this.configName} detail=${detail}`);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'notify update skipped: %{public}s', JSON.stringify(e));
        appFileLog(`notify publish skipped: ${JSON.stringify(e)}`);
      }
    }
    this.refreshTray();
  }

  private appendLog(line: string): void {
    this.appendLogLevel(line, 0);
  }

  private appendLogLevel(line: string, level: number): void {
    try {
      /* 日志行已由 C 层带上 OpenVPN 时间戳（Windows 同款格式），直接显示 */
      this.logLines.push({ text: line, level: level });

      if (this.logLines.length > 500) {
        this.logLines.splice(0, 100);
      }
      this.followLogTail();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `appendLog error`);
    }
  }

  private isUserLogScroll(source: ScrollSource): boolean {
    return source === ScrollSource.DRAG || source === ScrollSource.FLING
      || source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR
      || source === ScrollSource.SCROLL_BAR_FLING;
  }

  /** 手指、滚轮或滚动条离开底部时停住；回到最后一行后再跟随新日志。 */
  private syncLogFollowTail(): void {
    if (!this.logUserScrolling) {
      return;
    }
    try {
      this.logFollowTail = this.logScroller.isAtEnd();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'log follow: %{public}s', JSON.stringify(e));
    }
  }

  private onLogWillScroll(xOffset: number, yOffset: number, scrollState: ScrollState,
    scrollSource: ScrollSource): void {
    if (xOffset === 0 && yOffset === 0 && scrollState === ScrollState.Idle) {
      return;
    }
    if (this.isUserLogScroll(scrollSource)) {
      this.logUserScrolling = true;
    }
  }

  private followLogTail(): void {
    if (!this.logFollowTail || this.logScrollQueued) {
      return;
    }
    this.logScrollQueued = true;
    setTimeout(() => {
      this.logScrollQueued = false;
      if (!this.logFollowTail) {
        return;
      }
      try {
        this.logScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'log scroll: %{public}s', JSON.stringify(e));
      }
    }, 32);
  }

  private onThemeChanged(): void {
    this.syncStatusColor();
  }

  private syncStatusColor(): void {
    const text: string = this.statusText;
    if (text.indexOf('失败') >= 0 || text.indexOf('错误') >= 0 || text.indexOf('警告') >= 0) {
      this.statusColor = theme.dangerColor;
    } else if (text === '已连接') {
      this.statusColor = '#64BB5C';
    } else if (text.indexOf('连接') >= 0 || text.indexOf('断开中') >= 0) {
      this.statusColor = theme.accentColor;
    } else {
      this.statusColor = this.isDark ? '#8A8A8A' : '#C1C1C1';
    }
  }

  /* 日志颜色（参考 Windows OpenVPN GUI） */
  private logColor(level: number): string {
    if (level === 1) {
      return theme.logErrorColor;
    }
    if (level === 2) {
      return theme.logWarnColor;
    }
    return this.isDark ? theme.textColor : theme.textColor;
  }

  /** 托盘图标：未连接 / 连接中 / 已连接。 */
  private trayIconName(): string {
    if (this.isConnected) {
      return 'connected';
    }
    if (this.isConnecting) {
      return 'connecting';
    }
    return 'disconnected';
  }

  private trayLinkState(): TrayLinkState {
    if (this.isConnected) {
      return 'connected';
    }
    if (this.isConnecting) {
      return 'connecting';
    }
    return 'idle';
  }

  private refreshTray(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const tip: string = this.configName.length > 0 ? `${this.statusText} ${this.configName}` : this.statusText;
      const link: TrayLinkState = this.trayLinkState();
      const activeName: string = link === 'idle' ? '' : this.configName;
      VpnTray.sync(context, this.allConfigs, tip, this.trayIconName(), activeName, link,
        this.appSettings.menuView);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refreshTray skipped: %{public}s', JSON.stringify(e));
    }
  }

  /** 用文本打开该配置的连接日志。还没有日志文件时只提示。 */
  private async openProfileLog(name: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path: string = connectionLogPath(name);
      let size: number = 0;
      try {
        size = fs.statSync(path).size;
      } catch (missing) {
        size = 0;
      }
      if (size <= 0) {
        promptAction.showToast({ message: '尚无日志', duration: 2000 });
        return;
      }
      await AppWindows.openConfigAsText(context, path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open log: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '无法打开日志', duration: 2000 });
    }
  }

  private onProfileImported(): void {
    const imported: string = AppStorage.get<string>('importedConfigName') ?? '';
    AppStorage.setOrCreate('importedConfigName', '');
    this.scanConfigDirectory(true);
    if (imported.length > 0) {
      this.notifyImported(imported);
    }
  }

  /** 导入成功横幅。配置名不含 .ovpn，与原版气球第二行一致。 */
  private notifyImported(configName: string): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      VpnNotification.getInstance().publishImported(context, configName);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'import notify: %{public}s', JSON.stringify(e));
    }
  }

  private pathOf(name: string): string {
    const ext: string = (this.appSettings.configExt && this.appSettings.configExt.length > 0)
      ? this.appSettings.configExt.toLowerCase() : 'ovpn';
    const suffix: string = ext.startsWith('.') ? ext : `.${ext}`;
    return `${this.configDir}/${name}${suffix}`;
  }

  /** 托盘左键、显示状态把 hideAbility 收起的主界面再打开。 */
  private async showMainWindow(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.showAbility();
      const main: window.Window | null = AppWindows.mainWindow();
      const win: window.Window = main !== null ? main : await window.getLastWindow(context);
      if (win.getWindowStatus() === window.WindowStatusType.MINIMIZE) {
        await win.restore();
      }
      await win.showWindow();
      await AppWindows.centerMainIfReopened();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'showMainWindow: %{public}s', JSON.stringify(e));
    }
  }

  /** 托盘点另一份配置的「连接」：先停掉当前会话，再启动新配置。同一份且已连接则不动。 */
  private connectFromTray(idx: number): void {
    const switching: boolean = this.selectedConfigIndex !== idx;
    const ready: Promise<void> = switching ? this.switchToConfig(idx) : Promise.resolve();
    ready.then(() => {
      if (!this.isConnected && !this.isConnecting) {
        this.startConnection();
      }
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'connectFromTray: %{public}s', JSON.stringify(e));
    });
  }

  /** 托盘点另一份配置的「重新连接」同样先停旧会话。同一份配置仍走 SIGHUP。 */
  private reconnectFromTray(idx: number): void {
    const switching: boolean = this.selectedConfigIndex !== idx;
    const ready: Promise<void> = switching ? this.switchToConfig(idx) : Promise.resolve();
    ready.then(() => {
      this.onReconnect();
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'reconnectFromTray: %{public}s', JSON.stringify(e));
    });
  }

  private onTrayCommand(cmd: TrayCommand): void {
    hilog.info(DOMAIN, TAG, 'tray command: %{public}s %{public}s', cmd.action, cmd.configName);
    if (cmd.action === 'show' || cmd.action === 'status') {
      this.showMainWindow();
      return;
    }
    if (cmd.action === 'log') {
      this.openProfileLog(cmd.configName);
      return;
    }
    if (cmd.action === 'import') {
      this.showMainWindow().then(() => {
        this.importConfig();
      });
      return;
    }
    if (cmd.action === 'import-as' || cmd.action === 'import-url') {
      const kind: string = cmd.action === 'import-as' ? 'as' : 'url';
      AppWindows.showImport(kind).catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'show import: %{public}s', JSON.stringify(e));
        promptAction.showToast({ message: '无法打开导入窗口', duration: 2000 });
      });
      return;
    }
    if (cmd.action === 'settings') {
      AppWindows.showSettings().catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'show settings: %{public}s', JSON.stringify(e));
        promptAction.showToast({ message: '无法打开设置窗口', duration: 2000 });
      });
      return;
    }
    if (cmd.action === 'exit') {
      this.requestExit();
      return;
    }
    if (cmd.action === 'edit') {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      AppWindows.openConfigAsText(context, this.pathOf(cmd.configName)).catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'open config as text: %{public}s', JSON.stringify(e));
        promptAction.showToast({ message: `无法用文本打开 ${cmd.configName}`, duration: 2500 });
      });
      return;
    }
    if (cmd.action === 'clearpass') {
      this.confirmClearPassword(cmd.configName);
      return;
    }
    const idx: number = this.allConfigs.indexOf(cmd.configName);
    if (idx < 0) {
      return;
    }
    if (cmd.action === 'disconnect') {
      if (this.configName === cmd.configName && (this.isConnected || this.isConnecting || this.coreRunning)) {
        this.onDisconnect();
      }
      return;
    }
    if (cmd.action === 'connect') {
      this.showMainWindow();
      this.connectFromTray(idx);
      return;
    }
    if (cmd.action === 'reconnect') {
      this.showMainWindow();
      this.reconnectFromTray(idx);
    }
  }

  /** 把连接状态交给托盘退出。关主窗口不看它，也不弹确认框。 */
  private syncVpnActive(): void {
    const active: boolean = this.isConnected || this.isConnecting || this.coreRunning;
    AppStorage.setOrCreate('vpnActive', active);
  }

  /** 有活动连接时先确认。没有连接则直接退出。 */
  private requestExit(): void {
    if (this.isConnected || this.isConnecting || this.coreRunning) {
      this.showExitDialog = true;
      this.showMainWindow();
      return;
    }
    this.performExit();
  }

  private confirmExit(): void {
    this.showExitDialog = false;
    this.performExit();
  }

  private cancelExit(): void {
    this.showExitDialog = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    TrayKeepAlive.onUserCancelledExit(context);
  }

  private performExit(): void {
    this.stopVpnSession().then(() => {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      TrayKeepAlive.finishExit(context);
    });
  }

  /* 与右上角关闭相同：hideAbility 收掉窗口，进程和托盘留着，不最小化。 */
  private async hideWindow(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.hideAbility();
      AppWindows.markMainHidden();
      hilog.info(DOMAIN, TAG, 'window hidden, process kept');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'hide window failed: %{public}s', JSON.stringify(e));
    }
  }

  private stopAuthCountdown(): void {
    if (this.authTimer >= 0) {
      clearInterval(this.authTimer);
      this.authTimer = -1;
    }
    this.authAutoSeconds = 0;
  }

  /** 记录一次 VPN 用户名/密码认证失败（对齐 Windows failed_auth_attempts++）。 */
  private noteAuthFailure(): void {
    const nowMs: number = Date.now();
    if (nowMs - this.lastAuthFailureMs < 800) {
      return;
    }
    this.lastAuthFailureMs = nowMs;
    this.failedAuthAttempts++;
    hilog.info(DOMAIN, TAG, 'auth-failure, attempt=%{public}d', this.failedAuthAttempts);
  }

  /** 凭证被拒后重新弹出认证框。用户名和上次输入的密码留在框里，不自动提交。 */
  private showAuthRetry(): void {
    this.stopAuthCountdown();
    this.authIsProxy = false;
    this.authCaption = '';
    this.authRetryHint = '错误的凭据。请重试...';
    if (this.cachedUsername.length > 0) {
      this.authUsername = this.cachedUsername;
    }
    if (this.cachedPassword.length > 0) {
      this.authPassword = this.cachedPassword;
    }
    this.showAuthDialog = true;
    this.showMainWindow();
    hilog.info(DOMAIN, TAG, 'auth dialog reopened after auth-failure');
  }

  /** 已保存密码时从 5 秒倒数，到 0 等同点确定。 */
  private startAuthCountdown(): void {
    this.stopAuthCountdown();
    this.authAutoSeconds = 5;
    this.authTimer = setInterval(() => {
      if (!this.showAuthDialog) {
        this.stopAuthCountdown();
        return;
      }
      if (this.authAutoSeconds <= 1) {
        this.stopAuthCountdown();
        this.submitAuth();
        return;
      }
      this.authAutoSeconds = this.authAutoSeconds - 1;
    }, 1000);
  }

  /** 确定或倒计时结束：提交当前框里的账号密码，并按勾选情况保存。 */
  private submitAuth(): void {
    if (!this.showAuthDialog) {
      return;
    }
    if (this.authPassword.length === 0) {
      return;
    }
    this.stopAuthCountdown();
    try {
      VpnIpc.publishToExt('sendAuth', '', this.authUsername, this.authPassword);
      hilog.info(DOMAIN, TAG, 'sendAuth posted to VpnExtAbility');
      this.showAuthDialog = false;
      if (!this.authIsProxy) {
        this.cachedUsername = this.authUsername;
        this.cachedPassword = this.authPassword;
        const store = SettingsStore.getInstance();
        if (this.authUsername.length > 0) {
          if (this.savePassword && this.authPassword.length > 0) {
            store.saveCredentials(this.configName, this.authUsername, this.authPassword);
            appFileLog(`credentials saved for ${this.configName}`);
          } else {
            store.rememberUsername(this.configName, this.authUsername);
            appFileLog(`username kept for ${this.configName}`);
          }
        }
      }
      this.authIsProxy = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Auth error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 托盘「清除已保存的密码」。没有已存密码时不做任何事。
   * 确定后只删密码，用户名留着。
   */
  private confirmClearPassword(configName: string): void {
    const store = SettingsStore.getInstance();
    store.getCredentials(configName).then((cred: SavedCredentials) => {
      if (cred.password.length === 0) {
        return;
      }
      promptAction.showDialog({
        title: 'OpenVPN GUI',
        message: `请按「确定」删除 [${configName}] 连接配置文件的已存密码。`,
        buttons: [
          { text: '确定', color: theme.accentColor },
          { text: '取消', color: theme.textColor }
        ]
      }).then((choice: promptAction.ShowDialogSuccessResponse) => {
        if (choice.index !== 0) {
          return;
        }
        store.clearPassword(configName).then(() => {
          if (this.configName === configName) {
            this.cachedPassword = '';
            this.authPassword = '';
            this.savePassword = false;
          }
          hilog.info(DOMAIN, TAG, 'password cleared for %{public}s', configName);
        });
      });
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'clearpass: %{public}s', JSON.stringify(e));
    });
  }

  /* 取消认证：与原版 Windows OpenVPN GUI 一致——用户取消认证即拒绝连接。 */
  private cancelAuth(): void {
    try {
      hilog.info(DOMAIN, TAG, 'Auth cancelled, stopping connection');
      this.stopAuthCountdown();
      this.showAuthDialog = false;
      this.authIsProxy = false;
      this.cachedUsername = '';
      this.cachedPassword = '';
      this.failedAuthAttempts = 0;
      this.authRetryHint = '';
      this.stopVpnSession();
      this.isConnecting = false;
      this.isConnected = false;
      this.statusText = '已断开';
    } catch (err) {
      hilog.error(DOMAIN, TAG, `cancelAuth error: ${JSON.stringify(err)}`);
    }
  }

  private onDisconnect(): void {
    try {
      hilog.info(DOMAIN, TAG, 'Disconnect requested');
      this.stopVpnSession();
      this.isConnecting = false;
      this.statusText = '断开中...';
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Disconnect error`);
    }
  }

  private onReconnect(): void {
    try {
      if (this.isConnected || this.isConnecting) {
        hilog.info(DOMAIN, TAG, 'Reconnect: SIGHUP via extension');
        /* 对齐原版：重新连接不区分是否保存密码，都不弹认证框。
         * 本次连接已经输入过的账号密码留在会话里；保存密码只影响下一次全新连接。 */
        VpnIpc.publishToExt('reconnect');
        this.isConnecting = true;
        this.isConnected = false;
        this.statusText = '重新连接中...';
      } else if (this.configName.length === 0) {
        hilog.info(DOMAIN, TAG, 'Reconnect: no config selected');
      } else {
        hilog.info(DOMAIN, TAG, 'Reconnect: start new connection');
        this.startConnection();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Reconnect error`);
    }
  }

  /**
   * 从选择器 URI 取出真实文件名。
   * 非字母数字会被百分号编码，先解码，只认末尾的 .ovpn。
   * jp-free-19.protonvpn.udp.ovpn 与 jp-free-19.protonvpn.tcp.ovpn 因此仍是两份配置。
   */
  private importFileName(uri: string): string {
    let end: number = uri.length;
    const query: number = uri.indexOf('?');
    const hash: number = uri.indexOf('#');
    if (query >= 0) {
      end = Math.min(end, query);
    }
    if (hash >= 0) {
      end = Math.min(end, hash);
    }
    const path: string = uri.substring(0, end);
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    let name: string = slash >= 0 ? path.substring(slash + 1) : path;
    try {
      name = decodeURIComponent(name);
    } catch (ignored) {
      // 非法编码时保留原片段
    }
    if (name.length === 0) {
      name = 'imported.ovpn';
    }
    if (!name.toLowerCase().endsWith('.ovpn')) {
      name = `${name}.ovpn`;
    }
    return name;
  }

  /** 去掉末尾扩展名，中间的 .udp / .tcp 留在配置名里。 */
  private profileStem(fileName: string): string {
    if (fileName.toLowerCase().endsWith('.ovpn')) {
      return fileName.substring(0, fileName.length - '.ovpn'.length);
    }
    return fileName;
  }

  /**
   * statSync 在文件不存在时抛错。
   * accessSync 在当前接口下不存在则返回 false 且不抛错，不能把“没抛错”当成已存在。
   */
  private fileExists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (missing) {
      return false;
    }
  }

  /**
   * 托盘里已经有这份配置名，或目标文件已在配置目录时，先问是否替换。
   * 选「否」则这次导入取消。比较的是完整配置名，udp 与 tcp 互不覆盖。
   */
  private async confirmReplaceExisting(configName: string, destPath: string): Promise<boolean> {
    const exists: boolean = this.allConfigs.indexOf(configName) >= 0 || this.fileExists(destPath);
    if (!exists) {
      return true;
    }
    const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
      title: 'OpenVPN GUI',
      message: `名为'${configName}'的配置已存在。您想替换它吗？`,
      buttons: [
        { text: '是', color: theme.accentColor },
        { text: '否', color: theme.textColor }
      ]
    });
    return choice.index === 0;
  }

  /** 设置页扩展名。空则用 ovpn，已带点则不再加。 */
  private configSuffix(): string {
    const raw: string = (this.appSettings.configExt ?? '').trim().toLowerCase();
    const ext: string = raw.length > 0 ? raw : 'ovpn';
    return ext.startsWith('.') ? ext : `.${ext}`;
  }

  /* 导入配置（对齐原版 --import）：文件选择器按设置的后缀筛选 → 复制到 config 目录 → 重新扫描 */
  private async importConfig(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const suffix: string = this.configSuffix();
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        fileSuffixFilters: [`配置文件(${suffix})|${suffix}`]
      };
      const uris: Array<string> = await documentPicker.select(options);
      if (uris.length === 0) {
        return;  // 用户取消选择
      }
      const srcUri: string = uris[0];
      const fileName: string = this.importFileName(srcUri);
      const destPath: string = `${this.configDir}/${fileName}`;
      hilog.info(DOMAIN, TAG, `import: ${srcUri} -> ${destPath}`);
      const configName: string = this.profileStem(fileName);
      if (await this.confirmReplaceExisting(configName, destPath) === false) {
        return;
      }

      /* 选择器把空格编成 %20。按编码后的路径打开会报 13900002（文件不存在）。 */
      let openUri: string = srcUri;
      try {
        openUri = decodeURI(srcUri);
      } catch (ignored) {
        openUri = srcUri;
      }
      if (!this.fileExists(this.configDir)) {
        fs.mkdirSync(this.configDir);
      }

      /* 读源文件 → 写目标（pick uri 不能直接 fs.copy，需 open + read/write） */
      const srcFile = fs.openSync(openUri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(srcFile.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(srcFile.fd, buf);
      fs.closeSync(srcFile);

      const destFile = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(destFile.fd, buf);
      fs.closeSync(destFile);

      hilog.info(DOMAIN, TAG, `imported: ${fileName}`);
      appFileLog(`config imported: ${fileName}`);
      /* 重新扫描。已有连接时不改选中项、不断开，只在托盘增加这一项。 */
      this.scanConfigDirectory(true);
      this.notifyImported(configName);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `importConfig error: ${JSON.stringify(err)}`);
      appFileLog(`importConfig CATCH: ${JSON.stringify(err)}`);
    }
  }

  private formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    if (bytes < 1024) return `${bytes} B`;
    return `${(bytes / 1024).toFixed(1)} KB`;
  }

  // ========== 无配置提示对话框 ==========
  @Builder
  NoConfigDialog() {
    Column() {
      Text('OvpnLink')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(theme.textColor)
        .width('100%')

      Text('没有找到可读取的连接配置文件。')
        .fontSize(16)
        .fontColor(theme.textColor)
        .width('100%')
        .margin({ top: 16 })

      Text(`请使用「导入配置文件...」菜单，或将配置文件复制到「${this.configDir}」。`)
        .fontSize(16)
        .fontColor(theme.secondaryTextColor)
        .width('100%')
        .lineHeight(24)
        .margin({ top: 8 })

      Row({ space: 12 }) {
        Button('创建配置目录')
          .height(36)
          .fontSize(16)
          .fontColor(theme.accentColor)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.createConfigDirectory();
          })

        Blank()

        Button('确定')
          .width(96)
          .height(36)
          .fontSize(16)
          .fontColor(theme.selectedTextColor)
          .backgroundColor(theme.accentColor)
          .borderRadius(18)
          .onClick(() => {
            this.hideWindow();
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width(460)
    .padding(24)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .shadow({ radius: 16, color: theme.shadowColor, offsetX: 0, offsetY: 8 })
  }

  // ========== 退出确认（有活动连接时） ==========
  @Builder
  ExitDialog() {
    Column() {
      Text('Exit OvpnLink')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(theme.textColor)
        .width('100%')

      Text('当前还有活动的连接，您若退出 OpenVPN GUI 该连接将被中断。您确定要退出吗？')
        .fontSize(16)
        .fontColor(theme.textColor)
        .width('100%')
        .lineHeight(24)
        .margin({ top: 12 })

      Row({ space: 12 }) {
        Blank()

        Button('否')
          .width(88)
          .height(36)
          .fontSize(16)
          .fontColor(theme.accentColor)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.cancelExit();
          })

        Button('是')
          .width(88)
          .height(36)
          .fontSize(16)
          .fontColor(theme.selectedTextColor)
          .backgroundColor(theme.accentColor)
          .borderRadius(18)
          .onClick(() => {
            this.confirmExit();
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width(420)
    .padding(24)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .shadow({ radius: 16, color: theme.shadowColor, offsetX: 0, offsetY: 8 })
  }

  // ========== 认证对话框 ==========
  @Builder
  AuthDialog() {
    Column({space:24}) {

      Row() {
        Row(){
          Image($r('app.media.Logo_Foreground'))
            .width(40)
            .height(40)
            .margin({ right: 12 })
            .objectFit(ImageFit.Contain)

          Text('OvpnLink')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(theme.textColor)
        }
        Row(){
          Image($r('app.media.Close_Btn'))
            .height(24)
            .width(24)
            .fillColor(theme.textColor)
            .onClick(()=>{
              this.cancelAuth()
            })
        }.height('100%')
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween)

      Text(this.authIsProxy ? this.authCaption : '身份验证')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(theme.textColor)
        .width('100%')
      Column({space:9}){
        Text('用户名')
          .fontSize(16)
          .fontColor(theme.textColor)
          .width('100%')
          .fontWeight(FontWeight.Normal)

        TextInput({ text: this.authUsername, placeholder: '请输入用户名' })
          .width('100%')
          .height(40)
          .fontSize(16)
          .fontColor(theme.textColor)
          .caretColor(theme.accentColor)
          .backgroundColor(theme.componentBgColor)
          .placeholderColor(theme.secondaryTextColor)
          .borderRadius(8)
          .margin({ top: 8 })
          .onChange((value: string) => {
            this.authUsername = value;
          })
      }.width('100%')

      Column({space:9}) {
        Text('密码')
          .fontSize(16)
          .fontColor(theme.textColor)
          .width('100%')
          .fontWeight(FontWeight.Normal)

        TextInput({ text: this.authPassword, placeholder: '请输入密码' })
          .width('100%')
          .height(40)
          .fontSize(16)
          .type(this.authPasswordVisible ? InputType.Normal : InputType.Password)
          .fontColor(theme.textColor)
          .caretColor(theme.accentColor)
          .backgroundColor(theme.componentBgColor)
          .placeholderColor(theme.secondaryTextColor)
          .onChange((value: string) => {
            this.authPassword = value;
          })
          .borderRadius(8)

        if (this.appSettings.otpCombine && !this.authIsProxy) {
          Text('OTP 已启用：请在密码后直接输入动态口令（密码+OTP）')
            .fontSize(14)
            .fontColor(theme.secondaryTextColor)
            .width('100%')
            .margin({ top: 3 })
        }
      }

      if (!this.authIsProxy) {
        Row() {
          Checkbox({ name: 'save' })
            .shape(CheckBoxShape.ROUNDED_SQUARE)
            .select(this.savePassword)
            .selectedColor(theme.accentColor)
            .width(20)
            .height(20)
            .onChange((value: boolean) => {
              this.savePassword = value;
              if (!value) {
                this.stopAuthCountdown();
              }
            })

          Text('保存密码')
            .fontSize(16)
            .fontColor(theme.textColor)
            .margin({ left: 14 })
        }
        .width('100%')

      }

      Row() {
        if (this.authRetryHint.length > 0) {
          Text(this.authRetryHint)
            .fontSize(16)
            .fontColor(theme.dangerColor)
            .fontWeight(FontWeight.Normal)
            .layoutWeight(1)
        } else if (this.authAutoSeconds > 0) {
          Text(`在${this.authAutoSeconds}秒后自动连接...`)
            .fontSize(16)
            .fontColor(theme.textColor)
            .fontWeight(FontWeight.Normal)
            .layoutWeight(1)
        } else {
          Blank()
        }

        Button('取消')
          .width(120)
          .height(40)
          .fontSize(16)
          .fontColor(theme.accentColor)
          .backgroundColor(theme.componentBgColor)
          .onClick(() => {
            this.cancelAuth();
          })
          .borderRadius(8)

        Button('确定')
          .width(120)
          .height(40)
          .fontSize(16)
          .fontColor(this.authPassword.length > 0 ? theme.selectedTextColor : theme.mutedTextColor)
          .backgroundColor(this.authPassword.length > 0 ? theme.accentColor : theme.componentBgColor)
          .enabled(this.authPassword.length > 0)
          .borderRadius(18)
          .margin({ left: 8 })
          .onClick(() => {
            this.submitAuth();
          })
          .borderRadius(8)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width(470)
    .padding({ left: 22, right: 22, top: 16, bottom: 16 })
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .shadow({ radius: 16, color: theme.shadowColor, offsetX: 0, offsetY: 8 })
  }

  // ========== 连接窗口 ==========
  @Builder
  ConnectionWindow() {
    Column({space:16}) {

      Row() {
        Image($r('app.media.Doc_Text'))
          .width(20)
          .height(20)
          .margin({ right: 10 })

        Text(`配置文件：${this.configName}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.textColor)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .border({ width: 1, color: theme.hairlineColor })
      .borderRadius(8)

      Row() {
        Column()
          .width(17)
          .height(17)
          .backgroundColor(this.statusColor)
          .borderRadius('50%')
          .margin({ right: 14 })

        Text(`当前状态：${this.statusText}`)
          .fontSize(18)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Normal)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll(this.logScroller) {
        Column({ space: 4 }) {
          ForEach(this.logLines, (line: LogLine) => {
            Text(line.text)
              .fontSize(12)
              .fontFamily('HarmonyOS Sans')
              .fontColor(this.logColor(line.level))
              .fontWeight(FontWeight.Normal)
              .width('100%')
          }, (line: LogLine, index: number) => `${index}`)
        }
        .alignItems(HorizontalAlign.Start)
        .margin(20)
      }

      .width('100%')
      .margin({left: 9, right: 9})
      .layoutWeight(1)
      .backgroundColor(theme.accentSoftBgColor)
      .border({ width: 1, color: theme.hairlineColor })
      .borderRadius(16)
      .scrollBar(BarState.On)
      .align(Alignment.TopStart)
      .onWillScroll((xOffset: number, yOffset: number, scrollState: ScrollState, scrollSource: ScrollSource) => {
        this.onLogWillScroll(xOffset, yOffset, scrollState, scrollSource);
      })
      .onDidScroll(() => {
        this.syncLogFollowTail();
      })
      .onScrollStop(() => {
        this.syncLogFollowTail();
        this.logUserScrolling = false;
      })

      Row() {
        Text(`接收字节：${this.formatBytes(this.bytesIn)}`)
          .fontSize(16)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Normal)

        Text(`发送字节：${this.formatBytes(this.bytesOut)}`)
          .fontSize(16)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Normal)
          .margin({ left: 70 })

        Blank()

        Text(this.versionText)
          .fontSize(16)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Normal)
      }
      .width('100%')


      Row() {
        Button('断开连接')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isConnected || this.isConnecting ? theme.textColor : theme.mutedTextColor)
          .backgroundColor(theme.componentBgColor)
          .enabled(this.isConnected || this.isConnecting)
          .onClick(() => this.onDisconnect())
          .width(198)


        Button(this.isConnected || this.isConnecting ? '重新连接' : '连接')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isConnected || this.isConnecting || this.configName.length > 0 ? theme.accentColor : theme.mutedTextColor)
          .backgroundColor(theme.componentBgColor)
          .margin({ left: 35 })
          .enabled(this.isConnected || this.isConnecting || this.configName.length > 0)
          .onClick(() => this.onReconnect())
          .width(198)

        Blank()

        Button('隐藏')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.textColor)
          .backgroundColor(Color.Transparent)
          .borderColor(theme.hairlineColor)
          .width(120)
          .borderWidth(1)
          .onClick(() => {
            this.hideWindow();
          })
          .borderRadius(8)
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .padding(15)
    .backgroundColor(theme.contentBgColor)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.hasConfig && !this.showNoConfigDialog) {
        this.ConnectionWindow()
      }

      if (this.showNoConfigDialog) {
        this.NoConfigDialog()
      }

      if (this.showAuthDialog) {
        Column() {
          this.AuthDialog()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(theme.overlayColor)
        .justifyContent(FlexAlign.Center)
      }

      if (this.showExitDialog) {
        Column() {
          this.ExitDialog()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(theme.overlayColor)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? theme.contentBgColor : theme.contentBgColor)
  }
}
