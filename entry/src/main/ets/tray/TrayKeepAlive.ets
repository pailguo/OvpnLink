/**
 * PC 托盘保活，按「PC应用通过系统托盘后台保活」：
 * 托盘图标留在主进程；另起 BackGroundAbility，用
 * NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM 绑到这个图标上。
 * 右上角关闭只 hideAbility，窗口没有了，这个后台进程还在。
 * 托盘或 Dock 的退出会拆掉后台进程，再由这里决定是弹确认框还是真正退出。
 */

import { common, contextConstant, StartOptions, Want } from '@kit.AbilityKit';
import { BusinessError, commonEventManager, emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { EXIT_CONFIRM_EVENT } from '../common/AppWindows';

const DOMAIN: number = 0x0001;
const TAG: string = 'TrayKeepAlive';
const BUNDLE: string = 'com.practical.opensource.OvpnLink';
/** 后台进程即将销毁。托盘/Dock 退出时由 BackGroundAbility 发出。 */
const TRAY_EXIT_EVENT: string = 'BackgroundAbility_onPrepareToTerminate_event';
/** 主进程确认退出后，通知后台进程自己结束。 */
const ENTRY_EXIT_EVENT: string = 'OvpnLink_exit_background';

export class TrayKeepAlive {
  private static started: boolean = false;
  private static generation: number = 0;
  private static listening: boolean = false;
  private static ability: common.UIAbilityContext | null = null;

  /** 订阅托盘退出。主 Ability onCreate 里调用一次。 */
  public static attach(context: common.UIAbilityContext): void {
    TrayKeepAlive.ability = context;
    if (TrayKeepAlive.listening) {
      return;
    }
    TrayKeepAlive.listening = true;
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [TRAY_EXIT_EVENT],
      publisherBundleName: BUNDLE
    };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err && err.code !== 0) {
          hilog.error(DOMAIN, TAG, 'tray exit subscribe: %{public}s', JSON.stringify(err));
          return;
        }
        if (data === undefined || data.event !== TRAY_EXIT_EVENT) {
          return;
        }
        TrayKeepAlive.onTrayExit();
      });
      hilog.info(DOMAIN, TAG, 'tray exit subscribed');
    }).catch((e: Object) => {
      TrayKeepAlive.listening = false;
      hilog.error(DOMAIN, TAG, 'create subscriber: %{public}s', JSON.stringify(e));
    });
  }

  /** 托盘图标加好之后调用。已经在保活就不再启动第二个后台进程。 */
  public static hold(context: common.UIAbilityContext): void {
    TrayKeepAlive.ability = context;
    if (TrayKeepAlive.started) {
      return;
    }
    TrayKeepAlive.started = true;
    const gen: number = ++TrayKeepAlive.generation;
    setTimeout(() => {
      if (!TrayKeepAlive.started || gen !== TrayKeepAlive.generation) {
        return;
      }
      TrayKeepAlive.start(context);
    }, 200);
  }

  /** 退出确认框点了否。托盘退出已经拆掉后台进程时，重新绑上。 */
  public static onUserCancelledExit(context: common.UIAbilityContext): void {
    if (TrayKeepAlive.started) {
      return;
    }
    TrayKeepAlive.hold(context);
  }

  /** 托盘退出且没有活动连接时，主进程会被系统直接结束。先通知后台进程退出。 */
  public static releaseBackground(): void {
    TrayKeepAlive.started = false;
    TrayKeepAlive.publishBackgroundExit();
  }

  /** 真正退出：先让后台进程结束，再关掉主进程。 */
  public static finishExit(context: common.UIAbilityContext): void {
    AppStorage.setOrCreate('exitConfirmed', true);
    TrayKeepAlive.started = false;
    TrayKeepAlive.publishBackgroundExit();
    try {
      statusBarManager.removeFromStatusBar(context);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove tray: %{public}s', JSON.stringify(e));
    }
    setTimeout(() => {
      context.terminateSelf().catch((termErr: Object) => {
        hilog.error(DOMAIN, TAG, 'terminateSelf: %{public}s', JSON.stringify(termErr));
      });
    }, 200);
  }

  private static publishBackgroundExit(): void {
    const options: commonEventManager.CommonEventPublishData = {
      bundleName: BUNDLE,
      data: 'exit'
    };
    commonEventManager.publish(ENTRY_EXIT_EVENT, options, (err: BusinessError) => {
      if (err && err.code !== 0) {
        hilog.warn(DOMAIN, TAG, 'ask background exit: %{public}s', JSON.stringify(err));
      }
    });
  }

  private static start(context: common.UIAbilityContext): void {
    const want: Want = {
      bundleName: BUNDLE,
      abilityName: 'BackGroundAbility'
    };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE
    };
    context.startAbility(want, options).then(() => {
      hilog.info(DOMAIN, TAG, 'background ability attached to tray');
    }).catch((e: Object) => {
      TrayKeepAlive.started = false;
      hilog.error(DOMAIN, TAG, 'hold status bar: %{public}s', JSON.stringify(e));
    });
  }

  /** 托盘或 Dock 选择退出。有连接就弹出确认框，没有连接就结束进程。 */
  private static onTrayExit(): void {
    if (AppStorage.get<boolean>('exitConfirmed') === true) {
      return;
    }
    TrayKeepAlive.started = false;
    const context: common.UIAbilityContext | null = TrayKeepAlive.ability;
    if (context === null) {
      return;
    }
    const active: boolean = AppStorage.get<boolean>('vpnActive') ?? false;
    hilog.info(DOMAIN, TAG, 'tray exit, vpnActive=%{public}s', active ? 'yes' : 'no');
    if (!active) {
      TrayKeepAlive.finishExit(context);
      return;
    }
    context.showAbility().then(() => {
      hilog.info(DOMAIN, TAG, 'window shown for exit confirm');
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'showAbility: %{public}s', JSON.stringify(e));
    });
    emitter.emit({ eventId: EXIT_CONFIRM_EVENT });
  }
}
