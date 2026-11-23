/**
 * 绑在状态栏图标上的后台进程。本身不显示窗口。
 * 用户从托盘或 Dock 退出时，系统销毁这个进程；这里通知主进程，再允许自己结束。
 */

import { UIAbility } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackGroundAbility';
const BUNDLE: string = 'com.practical.opensource.OvpnLink';
const TRAY_EXIT_EVENT: string = 'BackgroundAbility_onPrepareToTerminate_event';
const ENTRY_EXIT_EVENT: string = 'OvpnLink_exit_background';

export default class BackGroundAbility extends UIAbility {
  private notified: boolean = false;
  private exiting: boolean = false;

  onCreate(): void {
    hilog.info(DOMAIN, TAG, 'background ability onCreate');
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [ENTRY_EXIT_EVENT],
      publisherBundleName: BUNDLE
    };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err && err.code !== 0) {
          hilog.error(DOMAIN, TAG, 'exit subscribe: %{public}s', JSON.stringify(err));
          return;
        }
        if (data === undefined || data.event !== ENTRY_EXIT_EVENT) {
          return;
        }
        if (this.exiting) {
          return;
        }
        this.exiting = true;
        this.context.terminateSelf().catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'terminateSelf: %{public}s', JSON.stringify(e));
        });
      });
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'create subscriber: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 必须等公共事件写进系统后再允许结束本进程。
   * 若在 publish 完成前返回 false，进程会被立刻拆掉，主进程收不到退出，第一次点击没有界面。
   */
  onPrepareToTerminateAsync(): Promise<boolean> {
    return this.publishOnce();
  }

  private publishOnce(): Promise<boolean> {
    if (this.notified) {
      return Promise.resolve(false);
    }
    this.notified = true;
    const options: commonEventManager.CommonEventPublishData = {
      bundleName: BUNDLE,
      data: 'initial data',
      code: 1
    };
    return new Promise<boolean>((resolve) => {
      try {
        commonEventManager.publish(TRAY_EXIT_EVENT, options, (err: BusinessError) => {
          if (err && err.code !== 0) {
            hilog.error(DOMAIN, TAG, 'publish tray exit: %{public}s', JSON.stringify(err));
          } else {
            hilog.info(DOMAIN, TAG, 'published tray exit');
          }
          resolve(false);
        });
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'publish tray exit: %{public}s', JSON.stringify(e));
        resolve(false);
      }
    });
  }
}
