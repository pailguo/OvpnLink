/**
 * VpnNotification.ets
 * 通知栏常驻通知 - 替代原版 OpenVPN GUI 的系统托盘图标
 *
 * 原版托盘图标（main.c TrayIcon）：右键菜单显示状态 + 点击切换连接状态。
 * 鸿蒙实现：PC/2in1 右下角横幅显示连接状态，停留数秒后自动消失，并带操作按钮。
 *
 * 说明：普通应用发通知无需声明特殊权限（方案中的 NOTIFICATION_CONTROLLER
 * 是系统权限，不可申请），发布通知是应用默认能力。
 */

import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnNotify';
/** 横幅停留时间。autoDeletedTime 为绝对时间戳，到期后通知从右下角和通知中心清除。 */
const BANNER_HOLD_MS: number = 5000;
/** 导入成功横幅单独编号，避免盖掉连接状态通知。 */
const IMPORT_NOTIFICATION_ID: number = 20260814;

/** 连接状态（用于通知内容映射，对齐原版托盘图标颜色） */
export enum NotifyState {
  DISCONNECTED = 0,   // 灰色
  CONNECTING = 1,     // 黄色
  CONNECTED = 2,      // 绿色
  DISCONNECTING = 3   // 黄色
}

/**
 * 通知管理单例
 */
export class VpnNotification {
  private static instance: VpnNotification | null = null;
  private context: common.UIAbilityContext | null = null;
  private readonly notificationId: number = 20260813;

  private constructor() {
  }

  public static getInstance(): VpnNotification {
    if (!VpnNotification.instance) {
      VpnNotification.instance = new VpnNotification();
    }
    return VpnNotification.instance;
  }

  /** 状态 → 通知标题 */
  private titleFor(state: NotifyState, configName: string): string {
    switch (state) {
      case NotifyState.CONNECTED:
        return '连接成功';
      case NotifyState.CONNECTING:
        return `正在连接 ${configName}...`;
      case NotifyState.DISCONNECTING:
        return '已断开';
      default:
        return 'OpenVPN 未连接';
    }
  }

  /** 状态 → 通知正文。连接成功时带上配置名和隧道地址。 */
  private bodyFor(state: NotifyState, configName: string, detail: string): string {
    const name: string = configName.length > 0 ? configName : 'VPN';
    if (state === NotifyState.CONNECTED) {
      if (detail.length > 0) {
        return `${name} 已连接，${detail}`;
      }
      return `${name} 已连接`;
    }
    if (state === NotifyState.DISCONNECTING) {
      return `${name} 已断开`;
    }
    return '点击打开 OpenVPN 管理界面';
  }

  /**
   * 发布前授权：isNotificationEnabled → 未授权则 requestEnableNotification。
   * 鸿蒙 PC 默认关闭应用通知，未授权时 publish 返回 1600004。
   */
  private async ensureEnabled(context: common.UIAbilityContext): Promise<void> {
    const enabled: boolean = await notificationManager.isNotificationEnabled();
    if (!enabled) {
      hilog.info(DOMAIN, TAG, 'notification disabled, requesting enable');
      await notificationManager.requestEnableNotification(context);
    }
  }

  /**
   * 服务提醒渠道对应 SlotLevel.LEVEL_HIGH，系统才会以横幅提醒。
   * 2in1 上横幅由系统画在屏幕右下角，应用不能指定坐标。
   * 同类型渠道只能创建一个，重复创建时忽略错误继续发布。
   */
  private async ensureSlot(): Promise<void> {
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'addSlot skipped: %{public}s', JSON.stringify(e));
    }
  }

  /** 创建拉起主界面的 WantAgent（对齐原版托盘左键打开窗口） */
  private async makeOpenAgent(): Promise<WantAgent | null> {
    if (!this.context) {
      return null;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'makeOpenAgent failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** 创建带 CLI 命令参数的 WantAgent（通知按钮 → 复用 CLI 路由执行） */
  private async makeActionAgent(action: string, profile: string): Promise<WantAgent | null> {
    if (!this.context) {
      return null;
    }
    let requestCode: number = 2;
    if (action === 'disconnect') {
      requestCode = 1;
    } else if (action === 'reconnect') {
      requestCode = 3;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name,
            parameters: { action: action, profile: profile, headless: '1' }
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'makeActionAgent failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** 打开 / 断开 / 重新连接。断开后的第二个按钮重新连上当前配置。 */
  private async collectButtons(state: NotifyState, configName: string,
    openAgent: WantAgent | null): Promise<notificationManager.NotificationActionButton[]> {
    const buttons: notificationManager.NotificationActionButton[] = [];
    if (openAgent) {
      buttons.push({ title: '打开', wantAgent: openAgent });
    }
    if (state === NotifyState.CONNECTED) {
      const agent: WantAgent | null = await this.makeActionAgent('disconnect', configName);
      if (agent) {
        buttons.push({ title: '断开', wantAgent: agent });
      }
    } else if (state === NotifyState.DISCONNECTING || state === NotifyState.DISCONNECTED) {
      const agent: WantAgent | null = await this.makeActionAgent('reconnect', configName);
      if (agent) {
        buttons.push({ title: '重新连接', wantAgent: agent });
      }
    } else {
      const agent: WantAgent | null = await this.makeActionAgent('connect', configName);
      if (agent) {
        buttons.push({ title: '连接', wantAgent: agent });
      }
    }
    return buttons;
  }

  /** 组装通知。buttons 为空时只发标题正文，避免 PC 上按钮参数导致整条发布失败。 */
  private buildRequest(state: NotifyState, configName: string, detail: string,
    openAgent: WantAgent | null, buttons: notificationManager.NotificationActionButton[]): notificationManager.NotificationRequest {
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.titleFor(state, configName),
          text: this.bodyFor(state, configName, detail)
        }
      },
      tapDismissed: true,
      isAlertOnce: false,
      autoDeletedTime: new Date().getTime() + BANNER_HOLD_MS
    };
    if (openAgent) {
      request.wantAgent = openAgent;
    }
    if (buttons.length > 0) {
      request.actionButtons = buttons;
    }
    return request;
  }

  /**
   * 发布横幅通知。
   * 连接成功时先取消同 ID 旧通知，避免更新已有通知而不再弹出横幅。
   * autoDeletedTime 到期后通知自行消失。
   */
  public async publish(context: common.UIAbilityContext, state: NotifyState, configName: string,
    detail: string = ''): Promise<void> {
    this.context = context;
    try {
      await this.ensureEnabled(context);
      await this.ensureSlot();
      if (state === NotifyState.CONNECTED || state === NotifyState.DISCONNECTING) {
        try {
          await notificationManager.cancel(this.notificationId);
        } catch (cancelErr) {
          hilog.info(DOMAIN, TAG, 'cancel before push: %{public}s', JSON.stringify(cancelErr));
        }
      }
      const openAgent: WantAgent | null = await this.makeOpenAgent();
      const buttons: notificationManager.NotificationActionButton[] = await this.collectButtons(state, configName, openAgent);
      try {
        await notificationManager.publish(this.buildRequest(state, configName, detail, openAgent, buttons));
        hilog.info(DOMAIN, TAG, 'notification published: state=%{public}d buttons=%{public}d', state, buttons.length);
      } catch (publishErr) {
        hilog.warn(DOMAIN, TAG, 'publish with actions failed, retry basic: %{public}s', JSON.stringify(publishErr));
        const emptyButtons: notificationManager.NotificationActionButton[] = [];
        await notificationManager.publish(this.buildRequest(state, configName, detail, null, emptyButtons));
        hilog.info(DOMAIN, TAG, 'basic notification published: state=%{public}d', state);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'publish failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 导入成功横幅，对齐原版托盘气球：标题「已成功导入文件。」，正文为配置名。
   * 不带连接按钮，数秒后自行消失，也不取消正在显示的连接通知。
   */
  public async publishImported(context: common.UIAbilityContext, configName: string): Promise<void> {
    this.context = context;
    try {
      await this.ensureEnabled(context);
      await this.ensureSlot();
      const request: notificationManager.NotificationRequest = {
        id: IMPORT_NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '已成功导入文件。',
            text: configName
          }
        },
        tapDismissed: true,
        isAlertOnce: false,
        autoDeletedTime: new Date().getTime() + BANNER_HOLD_MS
      };
      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, 'import notification published: %{public}s', configName);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'import notification failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 取消常驻通知 */
  public async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(this.notificationId);
      hilog.info(DOMAIN, TAG, 'notification cancelled');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'cancel failed: %{public}s', JSON.stringify(e));
    }
  }
}
