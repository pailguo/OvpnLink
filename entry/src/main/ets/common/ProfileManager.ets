/**
 * ProfileManager.ets
 * 配置文件管理器 - 对应 Windows GUI 的 config_parser.c 和 openvpn_config.c
 *
 * 功能：
 * - 扫描配置目录
 * - 解析 .ovpn 文件
 * - 保存/删除配置
 * - 持久化存储
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';

const TAG = 'ProfileManager';
const DOMAIN = 0x0001;

// VPN 配置接口（与 Index.ets 保持一致）
export interface VpnProfile {
  id: string;
  name: string;
  configFile: string;
  remote: string;
  proto: string;
  state: number;
  autoConnect: boolean;
  lastConnected?: number;
  // OpenVPN 配置选项
  port?: number;
  dev?: string;
  cipher?: string;
  auth?: string;
  compress?: string;
  // 认证
  authUser?: string;
  authRetry?: string;
  // TLS
  ca?: string;
  cert?: string;
  key?: string;
  tlsCrypt?: string;
  // 其他
  verb?: number;
  mute?: number;
}

// .ovpn 文件解析结果
export interface OvpnConfig {
  remote: string[];        // 可能有多个 remote
  port: number;
  proto: string;
  dev: string;
  ca?: string;
  cert?: string;
  key?: string;
  tlsCrypt?: string;
  cipher?: string;
  auth?: string;
  compress?: string;
  verb?: number;
  extra: string[];          // 未单独建模的配置行
}

export class ProfileManager {
  private static instance: ProfileManager;
  private profiles: VpnProfile[] = [];
  private configDir: string = '/data/storage/el2/base/haps/entry/files/config';
  private preferencesStore: preferences.Preferences | null = null;

  private constructor() {
  }

  public static getInstance(): ProfileManager {
    if (!ProfileManager.instance) {
      ProfileManager.instance = new ProfileManager();
    }
    return ProfileManager.instance;
  }

  /**
   * 初始化管理器
   */
  public async init(context: Context): Promise<void> {
    try {
      // 创建配置目录
      await this.ensureConfigDir();

      // 初始化持久化存储
      this.preferencesStore = await preferences.getPreferences(context, 'openvpn_profiles');

      // 加载已保存的配置
      await this.loadProfiles();

      hilog.info(DOMAIN, TAG, `ProfileManager initialized, ${this.profiles.length} profiles loaded`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Init error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 确保配置目录存在
   */
  private async ensureConfigDir(): Promise<void> {
    try {
      const stat = await fs.stat(this.configDir);
      if (!stat.isDirectory()) {
        await fs.mkdir(this.configDir);
      }
    } catch (err) {
      // 目录不存在，创建
      await fs.mkdir(this.configDir);
    }
  }

  /**
   * 加载配置列表
   */
  private async loadProfiles(): Promise<void> {
    if (!this.preferencesStore) return;

    try {
      const profilesJson = await this.preferencesStore.get('profiles', '[]') as string;
      this.profiles = JSON.parse(profilesJson) as VpnProfile[];

      // 重置所有状态为断开
      this.profiles.forEach(p => p.state = 0); // ConnState.DISCONNECTED
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Load profiles error: ${JSON.stringify(err)}`);
      this.profiles = [];
    }
  }

  /**
   * 保存配置列表到持久化存储
   */
  private async saveProfiles(): Promise<void> {
    if (!this.preferencesStore) return;

    try {
      const profilesJson = JSON.stringify(this.profiles);
      await this.preferencesStore.put('profiles', profilesJson);
      await this.preferencesStore.flush();
      hilog.info(DOMAIN, TAG, `Profiles saved, count: ${this.profiles.length}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Save profiles error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 获取所有配置
   */
  public getProfiles(): VpnProfile[] {
    return this.profiles;
  }

  /**
   * 根据 ID 获取配置
   */
  public getProfileById(id: string): VpnProfile | undefined {
    return this.profiles.find(p => p.id === id);
  }

  /**
   * 添加配置
   */
  public async addProfile(profile: VpnProfile): Promise<void> {
    this.profiles.push(profile);
    await this.saveProfiles();
  }

  /**
   * 更新配置
   */
  public async updateProfile(id: string, updates: Partial<VpnProfile>): Promise<boolean> {
    const index = this.profiles.findIndex(p => p.id === id);
    if (index === -1) {
      return false;
    }

    const current: VpnProfile = this.profiles[index];
    this.profiles[index] = this.mergeVpnProfile(current, updates);
    await this.saveProfiles();
    return true;
  }

  private mergeVpnProfile(current: VpnProfile, updates: Partial<VpnProfile>): VpnProfile {
    const merged: VpnProfile = {
      id: updates.id !== undefined ? updates.id : current.id,
      name: updates.name !== undefined ? updates.name : current.name,
      configFile: updates.configFile !== undefined ? updates.configFile : current.configFile,
      remote: updates.remote !== undefined ? updates.remote : current.remote,
      proto: updates.proto !== undefined ? updates.proto : current.proto,
      state: updates.state !== undefined ? updates.state : current.state,
      autoConnect: updates.autoConnect !== undefined ? updates.autoConnect : current.autoConnect
    };
    const lastConnected: number | undefined =
      updates.lastConnected !== undefined ? updates.lastConnected : current.lastConnected;
    if (lastConnected !== undefined) {
      merged.lastConnected = lastConnected;
    }
    const port: number | undefined = updates.port !== undefined ? updates.port : current.port;
    if (port !== undefined) {
      merged.port = port;
    }
    const dev: string | undefined = updates.dev !== undefined ? updates.dev : current.dev;
    if (dev !== undefined) {
      merged.dev = dev;
    }
    const cipher: string | undefined = updates.cipher !== undefined ? updates.cipher : current.cipher;
    if (cipher !== undefined) {
      merged.cipher = cipher;
    }
    const auth: string | undefined = updates.auth !== undefined ? updates.auth : current.auth;
    if (auth !== undefined) {
      merged.auth = auth;
    }
    const compress: string | undefined = updates.compress !== undefined ? updates.compress : current.compress;
    if (compress !== undefined) {
      merged.compress = compress;
    }
    const authUser: string | undefined = updates.authUser !== undefined ? updates.authUser : current.authUser;
    if (authUser !== undefined) {
      merged.authUser = authUser;
    }
    const authRetry: string | undefined = updates.authRetry !== undefined ? updates.authRetry : current.authRetry;
    if (authRetry !== undefined) {
      merged.authRetry = authRetry;
    }
    const ca: string | undefined = updates.ca !== undefined ? updates.ca : current.ca;
    if (ca !== undefined) {
      merged.ca = ca;
    }
    const cert: string | undefined = updates.cert !== undefined ? updates.cert : current.cert;
    if (cert !== undefined) {
      merged.cert = cert;
    }
    const key: string | undefined = updates.key !== undefined ? updates.key : current.key;
    if (key !== undefined) {
      merged.key = key;
    }
    const tlsCrypt: string | undefined = updates.tlsCrypt !== undefined ? updates.tlsCrypt : current.tlsCrypt;
    if (tlsCrypt !== undefined) {
      merged.tlsCrypt = tlsCrypt;
    }
    const verb: number | undefined = updates.verb !== undefined ? updates.verb : current.verb;
    if (verb !== undefined) {
      merged.verb = verb;
    }
    const mute: number | undefined = updates.mute !== undefined ? updates.mute : current.mute;
    if (mute !== undefined) {
      merged.mute = mute;
    }
    return merged;
  }

  /**
   * 删除配置
   */
  public async deleteProfile(id: string): Promise<boolean> {
    const index = this.profiles.findIndex(p => p.id === id);
    if (index === -1) return false;

    // 删除配置文件
    const profile = this.profiles[index];
    try {
      await fs.unlink(profile.configFile);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `Delete config file error: ${JSON.stringify(err)}`);
    }

    this.profiles.splice(index, 1);
    await this.saveProfiles();
    return true;
  }

  /**
   * 导入 .ovpn 配置文件
   * @param sourceFile 源文件路径
   * @param profileName 配置名称（可选，默认使用文件名）
   */
  public async importOvpnFile(sourceFile: string, profileName?: string): Promise<VpnProfile | null> {
    try {
      // 读取文件内容
      const content = await this.readFile(sourceFile);

      // 解析配置
      const config = this.parseOvpnContent(content);

      // 生成配置对象
      const fileName = sourceFile.substring(sourceFile.lastIndexOf('/') + 1);
      const name = profileName || fileName.replace('.ovpn', '');
      const id = this.generateId();

      const profile: VpnProfile = {
        id: id,
        name: name,
        configFile: `${this.configDir}/${id}.ovpn`,
        remote: config.remote.length > 0 ? config.remote[0] : 'unknown',
        proto: config.proto || 'udp',
        port: config.port || 1194,
        dev: config.dev || 'tun',
        state: 0,
        autoConnect: false,
        ca: config.ca,
        cert: config.cert,
        key: config.key,
        tlsCrypt: config.tlsCrypt,
        cipher: config.cipher,
        auth: config.auth,
        compress: config.compress,
        verb: config.verb
      };

      // 拷贝配置文件到配置目录
      await this.copyFile(sourceFile, profile.configFile);

      // 添加到列表
      await this.addProfile(profile);

      hilog.info(DOMAIN, TAG, `Imported profile: ${profile.name}`);
      return profile;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Import ovpn file error: ${JSON.stringify(err)}`);
      return null;
    }
  }

  /**
   * 解析 .ovpn 文件内容
   */
  private parseOvpnContent(content: string): OvpnConfig {
    const lines = content.split('\n');
    const config: OvpnConfig = {
      remote: [],
      port: 1194,
      proto: 'udp',
      dev: 'tun',
      extra: []
    };

    for (let line of lines) {
      line = line.trim();

      // 跳过注释和空行
      if (line.startsWith('#') || line.startsWith(';') || line.length === 0) {
        continue;
      }

      // 解析配置项
      const parts = line.split(/\s+/);
      const directive = parts[0];

      switch (directive) {
        case 'remote':
          if (parts.length >= 2) {
            const host = parts[1];
            const port = parts.length >= 3 ? parts[2] : '1194';
            config.remote.push(`${host}:${port}`);
            config.port = parseInt(port);
          }
          break;

        case 'proto':
          if (parts.length >= 2) {
            config.proto = parts[1];
          }
          break;

        case 'port':
          if (parts.length >= 2) {
            config.port = parseInt(parts[1]);
          }
          break;

        case 'dev':
          if (parts.length >= 2) {
            config.dev = parts[1];
          }
          break;

        case 'ca':
          if (parts.length >= 2) {
            config.ca = parts[1];
          }
          break;

        case 'cert':
          if (parts.length >= 2) {
            config.cert = parts[1];
          }
          break;

        case 'key':
          if (parts.length >= 2) {
            config.key = parts[1];
          }
          break;

        case 'tls-crypt':
          if (parts.length >= 2) {
            config.tlsCrypt = parts[1];
          }
          break;

        case 'cipher':
          if (parts.length >= 2) {
            config.cipher = parts[1];
          }
          break;

        case 'auth':
          if (parts.length >= 2) {
            config.auth = parts[1];
          }
          break;

        case 'compress':
          if (parts.length >= 2) {
            config.compress = parts[1];
          }
          break;

        case 'verb':
          if (parts.length >= 2) {
            config.verb = parseInt(parts[1]);
          }
          break;

        default:
          config.extra.push(line);
          break;
      }
    }

    return config;
  }

  /**
   * 扫描配置目录，发现新配置
   */
  public async scanConfigDir(): Promise<VpnProfile[]> {
    const newProfiles: VpnProfile[] = [];

    try {
      const files = await fs.listFile(this.configDir);

      for (const file of files) {
        if (!file.endsWith('.ovpn')) continue;

        const fullPath = `${this.configDir}/${file}`;

        // 检查是否已存在
        const exists = this.profiles.some(p => p.configFile === fullPath);
        if (exists) continue;

        // 导入新配置
        const profile = await this.importOvpnFile(fullPath);
        if (profile) {
          newProfiles.push(profile);
        }
      }

      if (newProfiles.length > 0) {
        hilog.info(DOMAIN, TAG, `Scanned ${newProfiles.length} new profiles`);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Scan config dir error: ${JSON.stringify(err)}`);
    }

    return newProfiles;
  }

  /**
   * 生成唯一 ID
   */
  private generateId(): string {
    return `profile-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  }

  /**
   * 读取文件内容
   */
  private async readFile(filePath: string): Promise<string> {
    const file = await fs.open(filePath, fs.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(64 * 1024); // 64KB
    const readLen = await fs.read(file.fd, buffer);
    await fs.close(file.fd);

    const uint8Array: Uint8Array = new Uint8Array(buffer, 0, readLen);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(uint8Array);
  }

  /**
   * 拷贝文件
   */
  private async copyFile(source: string, dest: string): Promise<void> {
    const content = await this.readFile(source);
    const file = await fs.open(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    await fs.write(file.fd, content);
    await fs.close(file.fd);
  }
}
