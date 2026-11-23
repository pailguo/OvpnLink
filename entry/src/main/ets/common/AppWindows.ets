/**
 * 主窗口之外的界面：
 * 设置用子窗口打开；编辑配置用系统文本方式打开文件。
 */

import { display, window } from '@kit.ArkUI';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppWindows';
const SETTINGS_NAME: string = 'ovpnSettings';
const IMPORT_NAME: string = 'ovpnImport';
/** 设置窗口点确定后通知主界面重新读取设置。 */
export const SETTINGS_SAVED_EVENT: number = 0x10002;
/** 从 Access Server 或 URL 导入成功后通知主界面重新扫描。 */
export const PROFILE_IMPORTED_EVENT: number = 0x10003;
/** 托盘或 Dock 退出、且还有活动连接时，通知主界面弹出确认框。关主窗口不发这个事件。 */
export const EXIT_CONFIRM_EVENT: number = 0x10004;

export class AppWindows {
  private static stage: window.WindowStage | null = null;
  private static mainNeedsCenter: boolean = false;
  private static settingsChain: Promise<void> = Promise.resolve();
  private static importChain: Promise<void> = Promise.resolve();
  /** 最近一次要求的隐私模式。异步设置完成前若又切换，以最后一次为准。 */
  private static privacyWanted: boolean = false;
  private static privacyChain: Promise<void> = Promise.resolve();

  public static bind(stage: window.WindowStage): void {
    AppWindows.stage = stage;
  }

  /** 主窗口被收起。下次再显示时重新居中，避免系统把上次的左上角位置带回来。 */
  public static markMainHidden(): void {
    AppWindows.mainNeedsCenter = true;
  }

  /** 冷启动或再次打开后，把主窗口移到当前屏幕正中。 */
  public static centerMain(): Promise<void> {
    const main: window.Window | null = AppWindows.mainWindow();
    if (main === null) {
      return Promise.resolve();
    }
    return AppWindows.centerOnScreen(main);
  }

  /** 仅在窗口曾被收起后再打开时居中。已经在前台切换焦点时不动。 */
  public static centerMainIfReopened(): Promise<void> {
    if (!AppWindows.mainNeedsCenter) {
      return Promise.resolve();
    }
    AppWindows.mainNeedsCenter = false;
    return AppWindows.centerMain();
  }

  /**
   * 主窗口隐私模式。开启后该窗口无法被截屏或录屏。
   * 认证框显示密码时开启，关闭认证框后取消。必须作用在主窗口上：
   * getLastWindow 在设置或导入子窗口打开时拿到的不是主界面。
   */
  public static setMainPrivacyMode(enabled: boolean): void {
    AppWindows.privacyWanted = enabled;
    const run: Promise<void> = AppWindows.privacyChain.then(() => {
      if (AppWindows.privacyWanted !== enabled) {
        return;
      }
      return AppWindows.applyMainPrivacyMode(enabled);
    });
    AppWindows.privacyChain = run.catch(() => {
    });
  }

  private static async applyMainPrivacyMode(enabled: boolean): Promise<void> {
    const main: window.Window | null = AppWindows.mainWindow();
    if (main === null) {
      hilog.error(DOMAIN, TAG, 'privacy mode: main window missing');
      return;
    }
    try {
      await main.setWindowPrivacyMode(enabled);
      hilog.info(DOMAIN, TAG, 'privacy mode %{public}s', enabled ? 'on' : 'off');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setWindowPrivacyMode: %{public}s', JSON.stringify(err));
    }
  }

  /** 主窗口。设置子窗口打开后，getLastWindow 可能拿到的是设置窗口。 */
  public static mainWindow(): window.Window | null {
    if (AppWindows.stage === null) {
      return null;
    }
    try {
      return AppWindows.stage.getMainWindowSync();
    } catch (e) {
      return null;
    }
  }

  /** 在独立窗口中显示设置页。已打开时只把该窗口带到前台。 */
  public static showSettings(): Promise<void> {
    const run: Promise<void> = AppWindows.settingsChain.then(() => {
      return AppWindows.openSettings();
    });
    AppWindows.settingsChain = run.catch(() => {
    });
    return run;
  }

  private static async openSettings(): Promise<void> {
    const stage: window.WindowStage | null = AppWindows.stage;
    if (stage === null) {
      hilog.error(DOMAIN, TAG, 'window stage missing');
      return;
    }
    const old: window.Window | null = AppWindows.find(SETTINGS_NAME);
    if (old !== null) {
      try {
        await old.destroyWindow();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'recreate settings: %{public}s', JSON.stringify(err));
      }
    }
    const screen = display.getDefaultDisplaySync();
    const placed: window.Rect = AppWindows.centeredRect(screen.width, screen.height);
    const options: window.SubWindowOptions = {
      title: 'OpenVPN',
      decorEnabled: true,
      maximizeSupported: true,
      windowRect: placed
    };
    const created: window.Window = await stage.createSubWindowWithOptions(SETTINGS_NAME, options);
    await created.resize(placed.width, placed.height);
    try {
      await created.setWindowLimits({
        minWidth: 1500,
        minHeight: 1300,
        maxWidth: screen.width,
        maxHeight: screen.height
      });
    } catch (limitErr) {
      hilog.warn(DOMAIN, TAG, 'setWindowLimits: %{public}s', JSON.stringify(limitErr));
    }
    await created.setUIContent('pages/Settings');
    await created.showWindow();
    await AppWindows.showSettingsTitleBar(created);
    await AppWindows.centerOnScreen(created);
    hilog.info(DOMAIN, TAG, 'settings window shown');
  }

  /** 按最终宽高（含最小尺寸限制）计算相对当前屏幕左上角的居中矩形。 */
  private static centeredRect(screenWidth: number, screenHeight: number): window.Rect {
    const wanted: window.Size = AppWindows.settingsSize();
    let width: number = wanted.width;
    let height: number = wanted.height;
    if (width < 1400) {
      width = 1400;
    }
    if (height < 1300) {
      height = 1300;
    }
    if (width > screenWidth) {
      width = screenWidth;
    }
    if (height > screenHeight) {
      height = screenHeight;
    }
    const left: number = Math.round((screenWidth - width) / 2);
    const top: number = Math.round((screenHeight - height) / 2);
    const rect: window.Rect = {
      left: left,
      top: top,
      width: width,
      height: height
    };
    return rect;
  }

  /** 窗口显示后按实际宽高再移一次，避免最小尺寸把窗口撑大后偏离中心。 */
  private static async centerOnScreen(sub: window.Window): Promise<void> {
    let screenW: number = 0;
    let screenH: number = 0;
    const fallback = display.getDefaultDisplaySync();
    screenW = fallback.width;
    screenH = fallback.height;
    const main: window.Window | null = AppWindows.mainWindow();
    if (main !== null) {
      try {
        const displayId: number | undefined = main.getWindowProperties().displayId;
        if (displayId !== undefined) {
          const current = display.getDisplayByIdSync(displayId);
          screenW = current.width;
          screenH = current.height;
        }
      } catch (ignored) {
      }
    }
    const shown: window.Rect = sub.getWindowProperties().windowRect;
    if (shown.width <= 0 || shown.height <= 0) {
      return;
    }
    const x: number = Math.round((screenW - shown.width) / 2);
    const y: number = Math.round((screenH - shown.height) / 2);
    try {
      await sub.moveWindowToGlobal(x, y);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'moveWindowToGlobal: %{public}s', JSON.stringify(err));
    }
  }

  /** 系统标题栏：应用图标、OpenVPN，以及最大化、最小化、关闭。 */
  private static async showSettingsTitleBar(sub: window.Window): Promise<void> {
    try {
      await sub.setWindowTitle('OpenVPN');
    } catch (titleErr) {
      hilog.warn(DOMAIN, TAG, 'setWindowTitle: %{public}s', JSON.stringify(titleErr));
    }
    try {
      await sub.setWindowDecorVisible(true);
    } catch (decorErr) {
      hilog.warn(DOMAIN, TAG, 'setWindowDecorVisible: %{public}s', JSON.stringify(decorErr));
    }
    try {
      await sub.setWindowTitleButtonVisible(true, true, true);
    } catch (btnErr) {
      hilog.warn(DOMAIN, TAG, 'setWindowTitleButtonVisible: %{public}s', JSON.stringify(btnErr));
    }
  }

  /** Access Server 与 URL 导入共用。 */
  private static importSize(): window.Size {
    const size: window.Size = { width: 800, height: 800 };
    return size;
  }

  /** 宽度够放下四列选项，高度贴住卡片和底部按钮，避免下面空一大块。 */
  private static settingsSize(): window.Size {
    const screen = display.getDefaultDisplaySync();
    let width: number = Math.round(screen.width * 0.56);
    let height: number = Math.round(screen.height * 0.62);
    const maxW: number = Math.max(screen.width - 48, 1);
    const maxH: number = Math.max(screen.height - 48, 1);
    if (width < 960) {
      width = 960;
    }
    if (width > 1120) {
      width = 1120;
    }
    if (height < 640) {
      height = 640;
    }
    if (height > 760) {
      height = 760;
    }
    if (width > maxW) {
      width = maxW;
    }
    if (height > maxH) {
      height = maxH;
    }
    const size: window.Size = { width: width, height: height };
    return size;
  }

  /** 第一次打开时放到当前屏幕正中。之后再打开保留用户拖过的位置。 */
  private static async centerSettings(width: number, height: number): Promise<void> {
    await AppWindows.moveToCenter(SETTINGS_NAME, width, height);
  }

  private static async moveToCenter(name: string, width: number, height: number): Promise<void> {
    const sub: window.Window | null = AppWindows.find(name);
    if (sub === null) {
      return;
    }
    const screen = display.getDefaultDisplaySync();
    const x: number = Math.round(Math.max(0, (screen.width - width) / 2));
    const y: number = Math.round(Math.max(0, (screen.height - height) / 2));
    try {
      await sub.moveWindowToGlobal(x, y);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'moveWindowToGlobal: %{public}s', JSON.stringify(err));
      await sub.moveWindowTo(x, y);
    }
  }

  /** 在标题栏按下时交给系统跟着鼠标移动。必须在按下回调里同步调用。 */
  public static startMoveSettings(): void {
    AppWindows.startMove(SETTINGS_NAME);
  }

  public static startMoveImport(): void {
    AppWindows.startMove(IMPORT_NAME);
  }

  private static startMove(name: string): void {
    const sub: window.Window | null = AppWindows.find(name);
    if (sub === null) {
      return;
    }
    sub.startMoving().catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'startMoving: %{public}s', JSON.stringify(err));
    });
  }

  /**
   * 打开导入窗口。kind 为 as（Access Server）或 url。
   * 每次新建，避免上次填写的地址还留在表单里。
   */
  public static showImport(kind: string): Promise<void> {
    AppStorage.setOrCreate('importKind', kind);
    const run: Promise<void> = AppWindows.importChain.then(() => {
      return AppWindows.openImport();
    });
    AppWindows.importChain = run.catch(() => {
    });
    return run;
  }

  public static closeImport(): void {
    const sub: window.Window | null = AppWindows.find(IMPORT_NAME);
    if (sub === null) {
      return;
    }
    sub.destroyWindow().catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'close import: %{public}s', JSON.stringify(err));
    });
  }

  private static async openImport(): Promise<void> {
    const stage: window.WindowStage | null = AppWindows.stage;
    if (stage === null) {
      hilog.error(DOMAIN, TAG, 'window stage missing');
      return;
    }
    const old: window.Window | null = AppWindows.find(IMPORT_NAME);
    if (old !== null) {
      await old.destroyWindow();
    }
    const sub: window.Window = await stage.createSubWindow(IMPORT_NAME);
    const size: window.Size = AppWindows.importSize();
    const width: number = size.width;
    const height: number = size.height;
    try {
      await sub.setWindowLimits({
        minWidth: width,
        minHeight: height,
        maxWidth: width,
        maxHeight: height
      });
    } catch (limitErr) {
      hilog.warn(DOMAIN, TAG, 'import setWindowLimits: %{public}s', JSON.stringify(limitErr));
    }
    await sub.resize(width, height);
    try {
      await sub.setWindowTitle('导入配置');
    } catch (titleErr) {
      hilog.warn(DOMAIN, TAG, 'setWindowTitle: %{public}s', JSON.stringify(titleErr));
    }
    await sub.setUIContent('pages/ImportProfile');
    await sub.showWindow();
    await sub.resize(width, height);
    await AppWindows.moveToCenter(IMPORT_NAME, width, height);
  }

  public static closeSettings(): void {
    const sub: window.Window | null = AppWindows.find(SETTINGS_NAME);
    if (sub === null) {
      return;
    }
    sub.destroyWindow().catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'close settings: %{public}s', JSON.stringify(err));
    });
  }

  /** 用文本类型拉起系统应用打开配置文件，可读取也可写回。 */
  public static async openConfigAsText(context: common.UIAbilityContext, path: string): Promise<void> {
    const uri: string = fileUri.getUriFromPath(path);
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: 'general.text',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION | wantConstant.Flags.FLAG_AUTH_WRITE_URI_PERMISSION
    };
    await context.startAbility(want);
    hilog.info(DOMAIN, TAG, 'opened config as text');
  }

  private static find(name: string): window.Window | null {
    try {
      return window.findWindow(name);
    } catch (e) {
      return null;
    }
  }
}
