import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { AppWindows, EXIT_CONFIRM_EVENT } from '../common/AppWindows';
import { ThemeManager } from '../common/ThemeManager';
import { TrayKeepAlive } from '../tray/TrayKeepAlive';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

/* CLI 命令事件（onNewWant 热更新 → 通知已运行的 Index 页面执行）。
 * 与 pages/Index.ets 中监听的事件 ID 保持一致 */
const CLI_COMMAND_EVENT: number = 0x10001;

/**
 * CLI 命令路由（对齐原版 openvpn-gui 的命令行/窗口消息机制）：
 *
 * 原版：openvpn-gui.exe --command connect <profile> → WM_COPYDATA → 常驻实例执行
 * 鸿蒙：hdc shell aa start -b com.practical.opensource.OvpnLink -a EntryAbility \
 *         --ps action connect --ps profile <name> --ps authfile <path> --ps headless 1
 *       → onCreate（冷启动）/ onNewWant（已运行）解析 want.parameters
 *       → 存入 AppStorage，Index.ets 启动完成后执行
 *
 * 支持的 action（对齐原版 --command 系列）：
 *   connect <profile>     连接指定配置（可选 authfile 指定凭据文件，可选 headless 隐藏窗口）
 *   disconnect            断开当前连接
 *   disconnect_all        断开（同 disconnect，鸿蒙单连接）
 *   rescan                重新扫描配置
 */
export default class EntryAbility extends UIAbility {
  private appliedColorMode: ConfigurationConstant.ColorMode | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.appliedColorMode = this.context.config.colorMode;
    AppStorage.setOrCreate('colorMode', this.appliedColorMode);
    ThemeManager.getInstance().init();
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    TrayKeepAlive.attach(this.context);
    this.storeCliCommand(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已运行：aa start 再次拉起 → CLI 命令（原版 WM_COPYDATA 等价）
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    const stored: boolean = this.storeCliCommand(want);
    if (stored) {
      /* 通知已运行的 Index 页面执行命令（页面不会因 onNewWant 重新初始化） */
      emitter.emit({ eventId: CLI_COMMAND_EVENT });
      hilog.info(DOMAIN, TAG, 'cli command event emitted');
    }
  }

  /**
   * 解析 want.parameters 中的 CLI 命令并存入 AppStorage。
   * 用独立 key 存储（避免 JSON.parse 的 any 类型问题）。
   * @returns 是否存入了命令（有 action 时 true）
   */
  private storeCliCommand(want: Want): boolean {
    try {
      const params = want.parameters as Record<string, Object>;
      if (params === undefined || params === null) {
        return false;
      }
      const action: string = (params['action'] as string) ?? '';
      if (action.length === 0) {
        return false;  // 无 action = 普通 GUI 启动，不走 CLI
      }
      const profile: string = (params['profile'] as string) ?? '';
      const authfile: string = (params['authfile'] as string) ?? '';
      const headless: string = (params['headless'] as string) ?? '';
      /* 命令直接传凭据（对齐原版 openvpn --auth-user-pass 控制台输入习惯）：
       * aa start --ps username xxx --ps password yyy，非空时优先于 authfile/弹窗 */
      const username: string = (params['username'] as string) ?? '';
      const password: string = (params['password'] as string) ?? '';
      AppStorage.setOrCreate('cliAction', action);
      AppStorage.setOrCreate('cliProfile', profile);
      AppStorage.setOrCreate('cliAuthfile', authfile);
      AppStorage.setOrCreate('cliHeadless', headless);
      AppStorage.setOrCreate('cliUsername', username);
      AppStorage.setOrCreate('cliPassword', password);
      hilog.info(DOMAIN, TAG, 'cli command stored: action=%{public}s profile=%{public}s headless=%{public}s user=%{public}s',
        action, profile, headless, username.length > 0 ? 'yes' : 'no');
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'storeCliCommand error: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  /**
   * 托盘、Dock 的退出会到这里。右上角关闭由 windowWillClose 收掉窗口，不进这条退出。
   * 返回 true 取消本次销毁，返回 false 允许进程结束。
   * 有活动连接时先弹出确认框；点「是」后再 terminateSelf。
   */
  onPrepareToTerminate(): boolean {
    return this.onSystemExit();
  }

  onPrepareToTerminateAsync(): Promise<boolean> {
    return Promise.resolve(this.onSystemExit());
  }

  /** 右上角关闭：窗口收掉，不最小化，进程和托盘留着。不弹退出确认。 */
  private keepAliveOnClose(main: window.Window): void {
    try {
      main.on('windowWillClose', (): Promise<boolean> => {
        AppWindows.markMainHidden();
        this.context.hideAbility().then(() => {
          hilog.info(DOMAIN, TAG, 'title bar close: window hidden, process kept');
        }).catch((err: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'hideAbility: %{public}s', JSON.stringify(err));
        });
        return Promise.resolve(true);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'windowWillClose: %{public}s', JSON.stringify(e));
    }
  }

  private onSystemExit(): boolean {
    if (AppStorage.get<boolean>('exitConfirmed') === true) {
      hilog.info(DOMAIN, TAG, 'prepare terminate: exit confirmed');
      return false;
    }
    if (AppStorage.get<boolean>('titleBarClose') === true) {
      AppStorage.setOrCreate('titleBarClose', false);
      hilog.info(DOMAIN, TAG, 'prepare terminate: title bar close, keep alive');
      return true;
    }
    const active: boolean = AppStorage.get<boolean>('vpnActive') ?? false;
    hilog.info(DOMAIN, TAG, 'prepare terminate: tray exit, vpnActive=%{public}s', active ? 'yes' : 'no');
    if (!active) {
      TrayKeepAlive.releaseBackground();
      return false;
    }
    this.context.showAbility().then(() => {
      hilog.info(DOMAIN, TAG, 'window shown for exit confirm');
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'showAbility: %{public}s', JSON.stringify(err));
    });
    emitter.emit({ eventId: EXIT_CONFIRM_EVENT });
    return true;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    AppWindows.bind(windowStage);
    AppWindows.centerMain().catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'center main: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      AppWindows.centerMain().catch((centerErr: Object) => {
        hilog.warn(DOMAIN, TAG, 'center main: %{public}s', JSON.stringify(centerErr));
      });
      try {
        this.keepAliveOnClose(windowStage.getMainWindowSync());
      } catch (closeErr) {
        hilog.error(DOMAIN, TAG, 'keep alive bind: %{public}s', JSON.stringify(closeErr));
      }

      /* 无头模式：CLI 连接/断开命令或显式 headless=1 时最小化主窗口（对齐原版
       * StartupVisibility.STARTUP_HIDE 语义；SDK 无 hide()，用 minimize() 最小化到
       * dock 栏，桌面不显示主窗口）。窗口最小化不影响 C 层 core 线程运行，
       * 连接状态走常驻通知。 */
      try {
        const headless: string = AppStorage.get<string>('cliHeadless') ?? '';
        const action: string = AppStorage.get<string>('cliAction') ?? '';
        if (headless === '1' || action === 'connect' || action === 'disconnect') {
          windowStage.getMainWindowSync().minimize().then(() => {
            hilog.info(DOMAIN, TAG, 'headless mode: window minimized');
          }).catch((e: Error) => {
            hilog.error(DOMAIN, TAG, 'minimize failed: %{public}s', JSON.stringify(e));
          });
        }
      } catch (hideErr) {
        hilog.error(DOMAIN, TAG, 'headless minimize error: %{public}s', JSON.stringify(hideErr));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    AppWindows.centerMainIfReopened().catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'center main: %{public}s', JSON.stringify(err));
    });
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    if (this.appliedColorMode === newConfig.colorMode) {
      return;
    }
    this.appliedColorMode = newConfig.colorMode;
    AppStorage.setOrCreate('colorMode', newConfig.colorMode);
    ThemeManager.getInstance().applyColorMode(newConfig.colorMode);
  }
}
