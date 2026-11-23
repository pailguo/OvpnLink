/**
 * VpnExtAbility.ets
 * VPN 扩展能力：在扩展进程内创建 VpnConnection，并运行 OpenVPN 核心。
 *
 * 鸿蒙第三方 VPN 要求：
 *   1. 先 startVpnExtensionAbility
 *   2. 用 VpnExtensionContext 调用 createVpnConnection
 *   3. 在本进程内 VpnConnection.create() 拿 tun fd
 *
 * OpenVPN 以 NAPI 线程跑在本进程，OPENTUN / PROTECTFD 才能拿到合法 fd。
 */
import { VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { VpnServiceManager } from '../common/VpnServiceManager';
import { VpnIpc, VpnExtMessage } from '../common/VpnIpc';

const TAG: string = 'VpnExtAbility';
const DOMAIN: number = 0x0001;
const LOG_PATH: string = '/data/storage/el2/base/cache/vpnext.log';

function fileLog(msg: string): void {
  try {
    const file = fs.openSync(LOG_PATH, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, `${new Date().toISOString()} [VpnExt] ${msg}\n`);
    fs.closeSync(file);
  } catch (_e) {
    // 忽略
  }
}

export default class VpnExtAbility extends VpnExtensionAbility {
  private cmdSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private assignedIp: string = '';
  private napiReady: boolean = false;
  private connecting: boolean = false;
  private lastStartJson: string = '';
  private lastExtSeq: number = 0;
  private cmdPollTimer: number = -1;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate want=%{public}s', JSON.stringify(want));
    fileLog(`onCreate want=${JSON.stringify(want)}`);
    this.boot(want);
  }

  private async boot(want: Want): Promise<void> {
    try {
      VpnServiceManager.getInstance().init(this.context);
      this.setupNapiCallbacks();
      await this.subscribeCommands();
      this.startCmdPoll();
      const fromWant: string = this.startJsonFromWant(want);
      const pending: string = VpnIpc.readPending(this.context.filesDir);
      const startJson: string = fromWant.length > 0 ? fromWant : pending;
      if (startJson.length > 0) {
        await this.startOpenVpn(startJson);
      }
      fileLog('onCreate done');
    } catch (err) {
      fileLog(`onCreate error: ${JSON.stringify(err)}`);
      hilog.error(DOMAIN, TAG, `onCreate error: ${JSON.stringify(err)}`);
      VpnIpc.publishToUi('error', `VPN 扩展启动失败: ${JSON.stringify(err)}`);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    fileLog('onDestroy');
    try {
      testNapi.stop();
    } catch (_e) {
      // 忽略
    }
    VpnServiceManager.getInstance().destroy();
    this.stopCmdPoll();
    VpnIpc.unsubscribe(this.cmdSubscriber);
    this.cmdSubscriber = null;
    VpnIpc.publishToUi('status', 'EXITED');
  }

  private startJsonFromWant(want: Want): string {
    try {
      const params = want.parameters as Record<string, Object>;
      if (params === undefined || params === null) {
        return '';
      }
      return (params['startJson'] as string) ?? '';
    } catch (_e) {
      return '';
    }
  }

  private startCmdPoll(): void {
    if (this.cmdPollTimer >= 0) {
      return;
    }
    this.cmdPollTimer = setInterval(() => {
      const msg: VpnExtMessage | null = VpnIpc.readLastExtCmd();
      if (msg !== null && msg.seq > this.lastExtSeq) {
        this.onCommand(msg);
      }
    }, 250);
  }

  private stopCmdPoll(): void {
    if (this.cmdPollTimer >= 0) {
      clearInterval(this.cmdPollTimer);
      this.cmdPollTimer = -1;
    }
  }

  private async subscribeCommands(): Promise<void> {
    try {
      const sub: commonEventManager.CommonEventSubscriber = await VpnIpc.subscribeExt((msg: VpnExtMessage) => {
        this.onCommand(msg);
      });
      this.cmdSubscriber = sub;
      fileLog('command subscriber ready');
    } catch (err) {
      fileLog(`subscribeExt error: ${JSON.stringify(err)}`);
    }
  }

  private onCommand(msg: VpnExtMessage): void {
    if (msg.seq > 0 && msg.seq <= this.lastExtSeq) {
      return;
    }
    if (msg.seq > this.lastExtSeq) {
      this.lastExtSeq = msg.seq;
    }
    fileLog(`command: ${msg.cmd}`);
    if (msg.cmd === 'connect') {
      this.handleConnect(msg.startJson);
    } else if (msg.cmd === 'stop') {
      this.handleStop();
    } else if (msg.cmd === 'reconnect') {
      this.handleReconnect();
    } else if (msg.cmd === 'sendAuth') {
      try {
        const ret: number = testNapi.sendAuth(msg.username, msg.password);
        fileLog(`sendAuth ret=${ret}`);
      } catch (err) {
        fileLog(`sendAuth error: ${JSON.stringify(err)}`);
      }
    }
  }

  private handleConnect(startJson: string): void {
    if (startJson.length === 0) {
      const pending: string = VpnIpc.readPending(this.context.filesDir);
      if (pending.length === 0) {
        fileLog('handleConnect: empty startJson');
        VpnIpc.publishToUi('error', '缺少连接参数');
        return;
      }
      this.startOpenVpn(pending);
      return;
    }
    this.startOpenVpn(startJson);
  }

  private async startOpenVpn(startJson: string): Promise<void> {
    if (startJson.length === 0) {
      fileLog('startOpenVpn: empty startJson');
      return;
    }
    if (this.connecting && startJson === this.lastStartJson) {
      fileLog('startOpenVpn: duplicate connect skipped');
      return;
    }
    fileLog(`startOpenVpn jsonLen=${startJson.length}`);
    this.connecting = true;
    this.lastStartJson = startJson;
    this.assignedIp = '';
    VpnIpc.clearPending(this.context.filesDir);

    try {
      if (testNapi.isRunning() !== 0) {
        fileLog('startOpenVpn: stopping previous core');
        testNapi.stop();
        await this.waitCoreStop(2000);
        await VpnServiceManager.getInstance().destroy();
      }
    } catch (err) {
      fileLog(`startOpenVpn stop previous error: ${JSON.stringify(err)}`);
    }

    if (!VpnServiceManager.getInstance().isInitialized()) {
      VpnServiceManager.getInstance().init(this.context);
    }

    try {
      const ret: number = testNapi.start(startJson);
      fileLog(`testNapi.start ret=${ret}`);
      if (ret !== 0) {
        this.connecting = false;
        VpnIpc.publishToUi('error', `启动失败，错误代码: ${ret}`);
        VpnIpc.publishToUi('status', 'EXITED');
        return;
      }
      VpnIpc.publishToUi('started', 'ok');
    } catch (err) {
      this.connecting = false;
      fileLog(`testNapi.start error: ${JSON.stringify(err)}`);
      VpnIpc.publishToUi('error', `NAPI 启动失败: ${JSON.stringify(err)}`);
      VpnIpc.publishToUi('status', 'EXITED');
    }
  }

  private handleStop(): void {
    fileLog('handleStop');
    try {
      testNapi.stop();
    } catch (err) {
      fileLog(`handleStop error: ${JSON.stringify(err)}`);
    }
  }

  private handleReconnect(): void {
    fileLog('handleReconnect');
    try {
      if (testNapi.isRunning() !== 0) {
        const ret: number = testNapi.reconnect();
        fileLog(`reconnect ret=${ret}`);
        VpnIpc.publishToUi('state', 'RECONNECTING|');
      } else {
        const pending: string = VpnIpc.readPending(this.context.filesDir);
        if (pending.length > 0) {
          this.startOpenVpn(pending);
        }
      }
    } catch (err) {
      fileLog(`handleReconnect error: ${JSON.stringify(err)}`);
    }
  }

  private setupNapiCallbacks(): void {
    if (this.napiReady) {
      return;
    }
    this.napiReady = true;
    try {
      testNapi.onStatus((msg: string) => {
        fileLog(`status: ${msg}`);
        if (msg.startsWith('DNS:')) {
          const dnsPart: string = msg.substring(4);
          const dnsList: string[] = dnsPart.split(',').filter((s: string) => s.length > 0);
          if (dnsList.length > 0) {
            VpnServiceManager.getInstance().setDnsAddresses(dnsList);
            fileLog(`dns push: ${dnsPart}`);
          }
        }
        if (msg.startsWith('IFCONFIG6:')) {
          VpnServiceManager.getInstance().applyIfconfig6(msg.substring(10));
        }
        if (msg.startsWith('ROUTE6:')) {
          VpnServiceManager.getInstance().addIpv6RouteToken(msg.substring(7));
        }
        if (msg.includes('EXITED')) {
          this.connecting = false;
          this.lastStartJson = '';
          VpnServiceManager.getInstance().destroy();
        }
        VpnIpc.publishToUi('status', msg);
      });

      testNapi.onLog((line: string) => {
        VpnIpc.publishToUi('log', line);
      });

      testNapi.onTunRequest((info: string) => {
        fileLog(`TUN_REQUEST: ${info}`);
        VpnIpc.publishToUi('status', 'TUN_REQUEST');
        this.requestTunFd();
      });

      testNapi.onAuthRequest((info: string) => {
        fileLog(`AUTH_REQUEST: ${info}`);
        VpnIpc.publishToUi('auth', info);
      });

      testNapi.onByteCount((data: string) => {
        VpnIpc.publishToUi('bytecount', data);
      });

      testNapi.onState((data: string) => {
        const sep: number = data.indexOf('|');
        const state: string = sep >= 0 ? data.substring(0, sep) : data;
        const detail: string = sep >= 0 ? data.substring(sep + 1) : '';
        if (state === 'ASSIGN_IP' || state === 'CONNECTED' || state === 'RECONNECTING') {
          const ipSep: number = detail.lastIndexOf('|');
          if (ipSep >= 0 && ipSep + 1 < detail.length) {
            this.assignedIp = detail.substring(ipSep + 1);
            fileLog(`assignedIp (${state}): ${this.assignedIp}`);
          }
        }
        if (state === 'EXITING' || state === 'EXITED') {
          this.connecting = false;
        }
        VpnIpc.publishToUi('state', data);
      });

      testNapi.onProtectFd((fdStr: string) => {
        const fd: number = parseInt(fdStr, 10);
        fileLog(`onProtectFd: fd=${fd}`);
        if (!Number.isNaN(fd) && fd > 0) {
          VpnServiceManager.getInstance().protectFd(fd);
        }
      });
      fileLog('napi callbacks registered');
    } catch (err) {
      fileLog(`setupNapiCallbacks error: ${JSON.stringify(err)}`);
    }
  }

  private async requestTunFd(): Promise<void> {
    fileLog(`requestTunFd assignedIp=${this.assignedIp}`);
    try {
      const manager = VpnServiceManager.getInstance();
      /* IFCONFIG6 / ROUTE6 都在 OPENTUN 之前由 core 同步写入，这里再读一次，
       * 避免状态回调晚于建隧道导致 addresses 里没有 family=2 地址。 */
      manager.applyIfconfig6(testNapi.getIpv6Config());
      manager.applyIpv6RouteList(testNapi.getIpv6Routes());
      if (!manager.isInitialized()) {
        manager.init(this.context);
      }
      if (!manager.isInitialized()) {
        fileLog('requestTunFd: VpnConnection 初始化失败');
        VpnIpc.publishToUi('error', '创建虚拟网卡失败：VpnConnection 未初始化');
        return;
      }
      const fd: number = await manager.setupTun(this.assignedIp);
      fileLog(`setupTun fd=${fd}`);
      if (fd < 0) {
        VpnIpc.publishToUi('error', '创建虚拟网卡失败');
        return;
      }
      const ret: number = testNapi.setTunFd(fd);
      fileLog(`setTunFd ret=${ret} fd=${fd}`);
    } catch (err) {
      fileLog(`requestTunFd CATCH: ${JSON.stringify(err)}`);
      VpnIpc.publishToUi('error', `VPN 授权失败: ${JSON.stringify(err)}`);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async waitCoreStop(timeoutMs: number): Promise<void> {
    const start: number = Date.now();
    while (Date.now() - start < timeoutMs) {
      try {
        if (testNapi.isRunning() === 0) {
          return;
        }
      } catch (_e) {
        return;
      }
      await this.sleep(100);
    }
  }
}
