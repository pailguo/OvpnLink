/**
 * ConnectionManager.ets
 * 连接管理器 - 对应 Windows GUI 的 openvpn.c 和 manage.c
 *
 * 功能：
 * - 管理 OpenVPN 连接生命周期
 * - 处理 Management 接口通信
 * - 状态监控和事件分发
 * - 流量统计
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { VpnProfile } from './ProfileManager';

const TAG = 'ConnectionManager';
const DOMAIN = 0x0001;

// 连接状态枚举
export enum ConnState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  RECONNECTING = 2,
  CONNECTED = 3,
  DISCONNECTING = 4,
  SUSPENDED = 5
}

// 连接统计
export interface ConnectionStats {
  duration: number;
  bytesIn: number;
  bytesOut: number;
  virtualIP: string;
  realIP: string;
  connectedAt: number;
}

// 事件类型
export enum ConnectionEvent {
  STATE_CHANGED,
  LOG_MESSAGE,
  AUTH_REQUIRED,
  TUN_REQUIRED,
  STATS_UPDATE,
  ERROR
}

// 事件回调数据：日志/错误为 string，状态为 ConnState，统计为 ConnectionStats
export type ConnectionEventData = string | ConnState | ConnectionStats;

// 事件回调
export type ConnectionEventCallback = (event: ConnectionEvent, data?: ConnectionEventData) => void;

export class ConnectionManager {
  private static instance: ConnectionManager;
  private currentProfile: VpnProfile | null = null;
  private currentState: ConnState = ConnState.DISCONNECTED;
  private stats: ConnectionStats = this.createEmptyStats();
  private eventCallbacks: ConnectionEventCallback[] = [];
  private statsTimer: number = -1;

  private constructor() {
    this.setupNapiCallbacks();
  }

  public static getInstance(): ConnectionManager {
    if (!ConnectionManager.instance) {
      ConnectionManager.instance = new ConnectionManager();
    }
    return ConnectionManager.instance;
  }

  /**
   * 设置 NAPI 回调
   */
  private setupNapiCallbacks(): void {
    // 状态回调
    testNapi.onStatus((msg: string) => {
      hilog.info(DOMAIN, TAG, `Status: ${msg}`);
      this.handleStatusMessage(msg);
      this.emitEvent(ConnectionEvent.LOG_MESSAGE, `[状态] ${msg}`);
    });

    // 日志回调
    testNapi.onLog((line: string) => {
      this.emitEvent(ConnectionEvent.LOG_MESSAGE, line);
    });

    // Tun fd 请求
    testNapi.onTunRequest(() => {
      hilog.info(DOMAIN, TAG, 'Tun fd requested');
      this.emitEvent(ConnectionEvent.TUN_REQUIRED);
    });

    // 认证请求
    testNapi.onAuthRequest((info: string) => {
      hilog.info(DOMAIN, TAG, `Auth requested: ${info}`);
      this.emitEvent(ConnectionEvent.AUTH_REQUIRED, info);
    });
  }

  /**
   * 注册事件监听器
   */
  public addEventListener(callback: ConnectionEventCallback): void {
    this.eventCallbacks.push(callback);
  }

  /**
   * 移除事件监听器
   */
  public removeEventListener(callback: ConnectionEventCallback): void {
    const index = this.eventCallbacks.indexOf(callback);
    if (index >= 0) {
      this.eventCallbacks.splice(index, 1);
    }
  }

  /**
   * 触发事件
   */
  private emitEvent(event: ConnectionEvent, data?: ConnectionEventData): void {
    this.eventCallbacks.forEach(cb => {
      try {
        cb(event, data);
      } catch (err) {
        hilog.error(DOMAIN, TAG, `Event callback error: ${JSON.stringify(err)}`);
      }
    });
  }

  /**
   * 连接 VPN
   */
  public async connect(profile: VpnProfile): Promise<boolean> {
    if (this.currentState !== ConnState.DISCONNECTED) {
      hilog.warn(DOMAIN, TAG, 'Already connecting or connected');
      return false;
    }

    this.currentProfile = profile;
    this.setState(ConnState.CONNECTING);
    this.resetStats();

    try {
      // 构建配置 JSON
      const configJson = JSON.stringify({
        name: profile.name,
        configFile: profile.configFile,
        remote: profile.remote,
        proto: profile.proto,
        port: profile.port || 1194,
        dev: profile.dev || 'tun'
      });

      // 启动 OpenVPN core
      const ret = testNapi.start(configJson);
      if (ret !== 0) {
        hilog.error(DOMAIN, TAG, `Start failed with code: ${ret}`);
        this.setState(ConnState.DISCONNECTED);
        this.emitEvent(ConnectionEvent.ERROR, `启动失败: ${ret}`);
        return false;
      }

      hilog.info(DOMAIN, TAG, `Connection started for profile: ${profile.name}`);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Connect error: ${JSON.stringify(err)}`);
      this.setState(ConnState.DISCONNECTED);
      this.emitEvent(ConnectionEvent.ERROR, JSON.stringify(err));
      return false;
    }
  }

  /**
   * 断开 VPN
   */
  public async disconnect(): Promise<boolean> {
    if (this.currentState === ConnState.DISCONNECTED) {
      return true;
    }

    this.setState(ConnState.DISCONNECTING);

    try {
      testNapi.stop();
      this.stopStatsTimer();
      this.setState(ConnState.DISCONNECTED);
      this.currentProfile = null;
      this.resetStats();

      hilog.info(DOMAIN, TAG, 'Disconnected');
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Disconnect error: ${JSON.stringify(err)}`);
      this.emitEvent(ConnectionEvent.ERROR, JSON.stringify(err));
      return false;
    }
  }

  /**
   * 设置 Tun fd
   */
  public setTunFd(fd: number): void {
    try {
      testNapi.setTunFd(fd);
      hilog.info(DOMAIN, TAG, `Tun fd set: ${fd}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Set tun fd error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 设置认证凭据
   */
  public setCredentials(username: string, password: string): void {
    try {
      const credJson = JSON.stringify({ username, password });
      testNapi.setCredentials(credJson);
      hilog.info(DOMAIN, TAG, 'Credentials set');
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Set credentials error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 获取当前状态
   */
  public getState(): ConnState {
    return this.currentState;
  }

  /**
   * 获取当前配置
   */
  public getCurrentProfile(): VpnProfile | null {
    return this.currentProfile;
  }

  /**
   * 获取统计信息
   */
  public getStats(): ConnectionStats {
    const copy: ConnectionStats = {
      duration: this.stats.duration,
      bytesIn: this.stats.bytesIn,
      bytesOut: this.stats.bytesOut,
      virtualIP: this.stats.virtualIP,
      realIP: this.stats.realIP,
      connectedAt: this.stats.connectedAt
    };
    return copy;
  }

  /**
   * 处理状态消息
   */
  private handleStatusMessage(msg: string): void {
    if (msg.includes('CONNECTED')) {
      this.setState(ConnState.CONNECTED);
      this.stats.connectedAt = Date.now();
      this.startStatsTimer();

      // 解析 IP 地址
      const match = msg.match(/(\d+\.\d+\.\d+\.\d+)/);
      if (match) {
        this.stats.virtualIP = match[1];
      }
    } else if (msg.includes('CONNECTING')) {
      this.setState(ConnState.CONNECTING);
    } else if (msg.includes('RECONNECTING')) {
      this.setState(ConnState.RECONNECTING);
    } else if (msg.includes('EXITED') || msg.includes('DISCONNECTED')) {
      this.setState(ConnState.DISCONNECTED);
      this.stopStatsTimer();
    }
  }

  /**
   * 设置状态
   */
  private setState(newState: ConnState): void {
    if (this.currentState !== newState) {
      const oldState = this.currentState;
      this.currentState = newState;
      hilog.info(DOMAIN, TAG, `State changed: ${oldState} -> ${newState}`);
      this.emitEvent(ConnectionEvent.STATE_CHANGED, newState);
    }
  }

  /**
   * 启动统计定时器
   */
  private startStatsTimer(): void {
    this.stopStatsTimer();

    this.statsTimer = setInterval(() => {
      if (this.currentState === ConnState.CONNECTED) {
        this.updateStats();
      }
    }, 1000);
  }

  /**
   * 停止统计定时器
   */
  private stopStatsTimer(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  /**
   * 更新统计信息
   */
  private updateStats(): void {
    if (!this.currentProfile) return;

    // 计算连接时长
    if (this.stats.connectedAt > 0) {
      this.stats.duration = Math.floor((Date.now() - this.stats.connectedAt) / 1000);
    }

    // TODO: 从 core 获取实际的字节统计
    // 目前使用模拟数据
    this.stats.bytesIn += Math.floor(Math.random() * 1024);
    this.stats.bytesOut += Math.floor(Math.random() * 512);

    this.emitEvent(ConnectionEvent.STATS_UPDATE, this.stats);
  }

  /**
   * 重置统计
   */
  private resetStats(): void {
    this.stats = this.createEmptyStats();
  }

  /**
   * 创建空统计对象
   */
  private createEmptyStats(): ConnectionStats {
    return {
      duration: 0,
      bytesIn: 0,
      bytesOut: 0,
      virtualIP: '--',
      realIP: '--',
      connectedAt: 0
    };
  }

  /**
   * 是否正在运行
   */
  public isRunning(): boolean {
    try {
      return testNapi.isRunning() !== 0;
    } catch (err) {
      return false;
    }
  }

  /**
   * 获取版本信息
   */
  public getVersion(): string {
    try {
      return testNapi.getVersion();
    } catch (err) {
      return 'Unknown';
    }
  }
}
