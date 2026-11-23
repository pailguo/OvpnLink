/**
 * VpnIpc.ets
 * UIAbility 与 VpnExtAbility 跨进程通信。
 *
 * VpnExtensionAbility 由系统放在独立进程，ArkTS 单例与 NAPI 回调均不能跨进程共享。
 * OpenVPN 核心、tun fd、protect 必须全部在扩展进程内完成；界面只收状态、发命令。
 */
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'VpnIpc';
const LOG_PATH: string = '/data/storage/el2/base/cache/vpnext.log';

export const VPN_EVENT_TO_UI: string = 'com.practical.opensource.OvpnLink.VPN_TO_UI';
export const VPN_EVENT_TO_EXT: string = 'com.practical.opensource.OvpnLink.VPN_TO_EXT';
export const VPN_BUNDLE_NAME: string = 'com.practical.opensource.OvpnLink';
export const VPN_EXT_ABILITY: string = 'VpnExtAbility';
export const PENDING_CONNECT_FILE: string = 'vpn_pending_connect.json';
const UI_LAST_EVENT_PATH: string = '/data/storage/el2/base/cache/vpn_ui_last.json';
const EXT_LAST_CMD_PATH: string = '/data/storage/el2/base/cache/vpn_ext_last.json';
let uiEventSeq: number = 0;
let extCmdSeq: number = 0;
/** 本进程启动时生成。扩展进程重建后事件序号从 1 重计，界面用它区分新旧会话。 */
let uiSessionGen: number = Date.now();

function fileLog(msg: string): void {
  try {
    const file = fs.openSync(LOG_PATH, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, `${new Date().toISOString()} [VpnIpc] ${msg}\n`);
    fs.closeSync(file);
  } catch (_e) {
    // 忽略
  }
}

export interface VpnUiMessage {
  type: string;
  payload: string;
  seq: number;
  /** 发出这条消息的扩展进程会话。进程重启后会变。 */
  gen: number;
}

export interface VpnExtMessage {
  cmd: string;
  startJson: string;
  username: string;
  password: string;
  seq: number;
}

function parseUiMessage(raw: string): VpnUiMessage {
  try {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const seqObj: Object = obj['seq'];
    let seq: number = 0;
    if (typeof seqObj === 'number') {
      seq = seqObj as number;
    } else {
      seq = parseInt(`${seqObj ?? '0'}`, 10) || 0;
    }
    const genObj: Object = obj['gen'];
    let gen: number = 0;
    if (typeof genObj === 'number') {
      gen = genObj as number;
    } else {
      gen = parseInt(`${genObj ?? '0'}`, 10) || 0;
    }
    return {
      type: `${obj['type'] ?? ''}`,
      payload: `${obj['payload'] ?? ''}`,
      seq: seq,
      gen: gen
    };
  } catch (_e) {
    return { type: '', payload: raw, seq: 0, gen: 0 };
  }
}

function parseExtMessage(raw: string): VpnExtMessage {
  try {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const seqObj: Object = obj['seq'];
    let seq: number = 0;
    if (typeof seqObj === 'number') {
      seq = seqObj as number;
    } else {
      seq = parseInt(`${seqObj ?? '0'}`, 10) || 0;
    }
    return {
      cmd: `${obj['cmd'] ?? ''}`,
      startJson: `${obj['startJson'] ?? ''}`,
      username: `${obj['username'] ?? ''}`,
      password: `${obj['password'] ?? ''}`,
      seq: seq
    };
  } catch (_e) {
    return { cmd: '', startJson: '', username: '', password: '', seq: 0 };
  }
}

export class VpnIpc {
  static publishToUi(type: string, payload: string): void {
    uiEventSeq += 1;
    const body: VpnUiMessage = { type: type, payload: payload, seq: uiEventSeq, gen: uiSessionGen };
    const encoded: string = JSON.stringify(body);
    /* 状态类事件落盘，避免日志把 CONNECTED 冲掉；日志/流量只走 commonEvent */
    if (type === 'state' || type === 'status' || type === 'error' || type === 'auth' || type === 'started') {
      VpnIpc.writeLastUiEvent(encoded);
    }
    const options: commonEventManager.CommonEventPublishData = {
      bundleName: VPN_BUNDLE_NAME,
      data: encoded
    };
    commonEventManager.publish(VPN_EVENT_TO_UI, options, (err: BusinessError) => {
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, `publishToUi error: ${JSON.stringify(err)}`);
        fileLog(`publishToUi error type=${type}: ${JSON.stringify(err)}`);
      }
    });
  }

  static publishToExt(cmd: string, startJson: string = '', username: string = '', password: string = ''): void {
    extCmdSeq += 1;
    const body: VpnExtMessage = {
      cmd: cmd,
      startJson: startJson,
      username: username,
      password: password,
      seq: extCmdSeq
    };
    const encoded: string = JSON.stringify(body);
    VpnIpc.writeLastExtCmd(encoded);
    const options: commonEventManager.CommonEventPublishData = {
      bundleName: VPN_BUNDLE_NAME,
      data: encoded
    };
    commonEventManager.publish(VPN_EVENT_TO_EXT, options, (err: BusinessError) => {
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, `publishToExt error: ${JSON.stringify(err)}`);
        fileLog(`publishToExt error cmd=${cmd}: ${JSON.stringify(err)}`);
      } else {
        fileLog(`publishToExt cmd=${cmd}`);
      }
    });
  }

  static async subscribeUi(handler: (msg: VpnUiMessage) => void): Promise<commonEventManager.CommonEventSubscriber> {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [VPN_EVENT_TO_UI],
      publisherBundleName: VPN_BUNDLE_NAME
    };
    const subscriber = await commonEventManager.createSubscriber(info);
    commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, `subscribeUi error: ${JSON.stringify(err)}`);
        return;
      }
      handler(parseUiMessage(data.data ?? ''));
    });
    return subscriber;
  }

  static async subscribeExt(handler: (msg: VpnExtMessage) => void): Promise<commonEventManager.CommonEventSubscriber> {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [VPN_EVENT_TO_EXT],
      publisherBundleName: VPN_BUNDLE_NAME
    };
    const subscriber = await commonEventManager.createSubscriber(info);
    commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (err && err.code !== 0) {
        hilog.error(DOMAIN, TAG, `subscribeExt error: ${JSON.stringify(err)}`);
        return;
      }
      handler(parseExtMessage(data.data ?? ''));
    });
    return subscriber;
  }

  static unsubscribe(subscriber: commonEventManager.CommonEventSubscriber | null): void {
    if (subscriber === null) {
      return;
    }
    try {
      commonEventManager.unsubscribe(subscriber);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `unsubscribe error: ${JSON.stringify(err)}`);
    }
  }

  static buildExtWant(bundleName: string, startJson: string): Want {
    const want: Want = {
      bundleName: bundleName,
      abilityName: VPN_EXT_ABILITY,
      moduleName: 'entry',
      parameters: {
        'action': 'connect',
        'startJson': startJson
      }
    };
    return want;
  }

  static writeLastUiEvent(encoded: string): void {
    try {
      const file = fs.openSync(UI_LAST_EVENT_PATH, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, encoded);
      fs.closeSync(file);
    } catch (_e) {
      // 忽略
    }
  }

  static readLastUiEvent(): VpnUiMessage | null {
    try {
      const stat = fs.statSync(UI_LAST_EVENT_PATH);
      if (stat.size <= 0) {
        return null;
      }
      const file = fs.openSync(UI_LAST_EVENT_PATH, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return parseUiMessage(String.fromCharCode(...new Uint8Array(buf)));
    } catch (_e) {
      return null;
    }
  }

  static writeLastExtCmd(encoded: string): void {
    try {
      const file = fs.openSync(EXT_LAST_CMD_PATH, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, encoded);
      fs.closeSync(file);
    } catch (_e) {
      // 忽略
    }
  }

  static readLastExtCmd(): VpnExtMessage | null {
    try {
      const stat = fs.statSync(EXT_LAST_CMD_PATH);
      if (stat.size <= 0) {
        return null;
      }
      const file = fs.openSync(EXT_LAST_CMD_PATH, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return parseExtMessage(String.fromCharCode(...new Uint8Array(buf)));
    } catch (_e) {
      return null;
    }
  }

  static writePending(filesDir: string, startJson: string): void {
    try {
      const path: string = `${filesDir}/${PENDING_CONNECT_FILE}`;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, startJson);
      fs.closeSync(file);
      fileLog(`writePending ${path} len=${startJson.length}`);
    } catch (err) {
      fileLog(`writePending error: ${JSON.stringify(err)}`);
    }
  }

  static readPending(filesDir: string): string {
    try {
      const path: string = `${filesDir}/${PENDING_CONNECT_FILE}`;
      const stat = fs.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return String.fromCharCode(...new Uint8Array(buf));
    } catch (_e) {
      return '';
    }
  }

  static clearPending(filesDir: string): void {
    try {
      const path: string = `${filesDir}/${PENDING_CONNECT_FILE}`;
      fs.unlinkSync(path);
    } catch (_e) {
      // 文件不存在时忽略
    }
  }
}
