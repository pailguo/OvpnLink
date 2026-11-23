/**
 * VpnServiceManager.ets
 * VPN 虚拟网卡管理器（单例）
 *
 * 必须在 VpnExtAbility 进程内、用 VpnExtensionContext 初始化。
 * UIAbility 不得调用 createVpnConnection / create（第三方应用会返回 202）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const TAG = 'VpnServiceManager';
const DOMAIN = 0x0001;
const LOG_PATH: string = '/data/storage/el2/base/cache/vpnext.log';

class Ipv6RouteSpec {
  public network: string = '';
  public prefixLength: number = 0;
}

function fileLog(msg: string): void {
  try {
    const file = fs.openSync(LOG_PATH, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, `${new Date().toISOString()} [VpnServiceManager] ${msg}\n`);
    fs.closeSync(file);
  } catch (e) {
    // 忽略
  }
}

export class VpnServiceManager {
  private static instance: VpnServiceManager | null = null;
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private currentFd: number = -1;
  /* 服务端 DNS 推送（FR-4.18-10）：core ovpn_emit_dns → onStatus "DNS:..." → setDnsAddresses
   * 缓存，setupTun 时写入 VpnConfig.dnsAddresses（DNS 推送早于 OPENTUN，时序正确） */
  private dnsAddresses: string[] = [];
  private ipv6Address: string = '';
  private ipv6PrefixLength: number = -1;
  private ipv6Routes: Ipv6RouteSpec[] = [];
  private tunMtu: number = 1500;
  /* PROTECTFD 早于 OPENTUN 到达（OpenVPN socket 创建在 TLS 前），此时 vpnConnection
   * 尚未创建。先缓存 fd，VpnConnection 创建成功后（setupTun）再统一 protect */
  private pendingProtectFds: number[] = [];

  /** 合并服务端推送的 DNS 地址列表（IPv4/IPv6 可能分多条 management 消息到达） */
  public setDnsAddresses(addrs: string[]): void {
    for (const address of addrs) {
      if (address.length > 0 && !this.dnsAddresses.includes(address)) {
        this.dnsAddresses.push(address);
      }
    }
    fileLog(`dnsAddresses set: ${this.dnsAddresses.join(',')}`);
  }

  /** 保存 OpenVPN IFCONFIG6 下发的 IPv6 地址和前缀，供创建 TUN 时启用双栈。 */
  public setIpv6Config(address: string, prefixLength: number): void {
    const normalized: string = this.normalizeIpv6(address);
    const valid: boolean = normalized.includes(':') && Number.isInteger(prefixLength) &&
      prefixLength >= 0 && prefixLength <= 128 && !this.isLinkLocalIpv6(normalized);
    if (!valid) {
      this.ipv6Address = '';
      this.ipv6PrefixLength = -1;
      fileLog(`invalid IPv6 config ignored: address=${address}, prefixLength=${prefixLength}`);
      return;
    }
    this.ipv6Address = normalized;
    this.ipv6PrefixLength = prefixLength;
    fileLog(`IPv6 config set: ${normalized}/${prefixLength}`);
  }

  /**
   * 解析 IFCONFIG6 文本："<addr>/<prefix> <mtu>"。
   * 空文本表示本次连接没有 IPv6 地址，关闭 isIPv6Accepted。
   */
  public applyIfconfig6(config: string): void {
    this.tunMtu = 1500;
    const trimmed: string = config.trim();
    if (trimmed.length === 0) {
      this.ipv6Address = '';
      this.ipv6PrefixLength = -1;
      fileLog('no IPv6 config read before TUN');
      return;
    }
    const parts: string[] = trimmed.split(' ');
    const addressPart: string = parts[0];
    const slash: number = addressPart.lastIndexOf('/');
    if (slash <= 0 || slash + 1 >= addressPart.length) {
      this.ipv6Address = '';
      this.ipv6PrefixLength = -1;
      fileLog(`invalid IFCONFIG6 push: ${trimmed}`);
      return;
    }
    const prefixText: string = addressPart.substring(slash + 1);
    const prefixLength: number = this.parsePrefix(prefixText);
    if (prefixLength < 0 || prefixLength > 128) {
      this.ipv6Address = '';
      this.ipv6PrefixLength = -1;
      fileLog(`invalid IFCONFIG6 push: ${trimmed}`);
      return;
    }
    if (parts.length > 1) {
      const mtu: number = this.parsePrefix(parts[1]);
      if (mtu >= 1280 && mtu <= 65535) {
        this.tunMtu = mtu;
      }
    }
    this.setIpv6Config(addressPart.substring(0, slash), prefixLength);
  }

  /** 用 native 缓存的 ROUTE6 列表整体替换（逗号分隔的 "<network>/<prefix>"）。 */
  public applyIpv6RouteList(list: string): void {
    this.ipv6Routes = [];
    const trimmed: string = list.trim();
    if (trimmed.length === 0) {
      fileLog('IPv6 routes set: (none)');
      return;
    }
    const items: string[] = trimmed.split(',');
    for (const item of items) {
      this.addIpv6RouteToken(item);
    }
    fileLog(`IPv6 routes set: ${this.formatIpv6Routes()}`);
  }

  /** 追加一条 ROUTE6。重复前缀忽略。 */
  public addIpv6RouteToken(token: string): void {
    const trimmed: string = token.trim();
    const slash: number = trimmed.lastIndexOf('/');
    if (slash <= 0 || slash + 1 >= trimmed.length) {
      return;
    }
    const network: string = this.normalizeIpv6(trimmed.substring(0, slash));
    const prefixLength: number = this.parsePrefix(trimmed.substring(slash + 1));
    if (!network.includes(':') || prefixLength < 0 || prefixLength > 128 || this.isLinkLocalIpv6(network)) {
      fileLog(`invalid IPv6 route ignored: ${trimmed}`);
      return;
    }
    for (const existing of this.ipv6Routes) {
      if (existing.network === network && existing.prefixLength === prefixLength) {
        return;
      }
    }
    const spec: Ipv6RouteSpec = new Ipv6RouteSpec();
    spec.network = network;
    spec.prefixLength = prefixLength;
    this.ipv6Routes.push(spec);
    fileLog(`IPv6 route add: ${network}/${prefixLength}`);
  }

  private normalizeIpv6(raw: string): string {
    let address: string = raw.trim();
    if (address.startsWith('[') && address.indexOf(']') > 1) {
      address = address.substring(1, address.indexOf(']'));
    }
    const zone: number = address.indexOf('%');
    if (zone >= 0) {
      address = address.substring(0, zone);
    }
    return address;
  }

  private isLinkLocalIpv6(address: string): boolean {
    return address.toLowerCase().startsWith('fe80:');
  }

  private parsePrefix(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return -1;
      }
    }
    const value: number = parseInt(text, 10);
    if (!Number.isInteger(value) || value < 0 || value > 65535) {
      return -1;
    }
    return value;
  }

  private formatIpv6Routes(): string {
    if (this.ipv6Routes.length === 0) {
      return '(none)';
    }
    const parts: string[] = [];
    for (const spec of this.ipv6Routes) {
      parts.push(`${spec.network}/${spec.prefixLength}`);
    }
    return parts.join(',');
  }

  private makeIpv6Route(network: string, prefixLength: number, isDefault: boolean): connection.RouteInfo {
    const destination: connection.LinkAddress = {
      address: { address: network, family: 2 },
      prefixLength: prefixLength,
    };
    const route: connection.RouteInfo = {
      interface: 'vpn-tun',
      destination: destination,
      gateway: { address: this.ipv6Address, family: 2 },
      hasGateway: false,
      isDefaultRoute: isDefault,
    };
    return route;
  }

  public static getInstance(): VpnServiceManager {
    if (VpnServiceManager.instance === null) {
      VpnServiceManager.instance = new VpnServiceManager();
    }
    return VpnServiceManager.instance;
  }

  /**
   * 由 VpnExtAbility.onCreate 调用，初始化 VpnConnection
   */
  public init(context: vpnExtension.VpnExtensionContext): void {
    hilog.info(DOMAIN, TAG, 'init called');
    fileLog(`init called, contextType=${typeof context}`);
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(context);
      hilog.info(DOMAIN, TAG, 'createVpnConnection ok');
      fileLog('createVpnConnection ok');
    } catch (err) {
      hilog.error(DOMAIN, TAG, `createVpnConnection error: ${JSON.stringify(err)}`);
      fileLog(`createVpnConnection error: ${JSON.stringify(err)}`);
    }
  }

  public isInitialized(): boolean {
    return this.vpnConnection !== null;
  }

  /**
   * 创建虚拟网卡并返回 tun fd（对应 OpenVPN 的 OPENTUN 请求）
   * @param ip 服务端分配的真实 IP（ASSIGN_IP/CONNECTED 状态解析，如 10.96.0.17）；
   *           未传时回退占位地址（本地联调场景 10.8.0.2）
   *
   * 路由设计（对齐 OpenVPN redirect-gateway 语义）：
   *   - 默认路由 0.0.0.0/0 → tun（全局代理；本地服务端未 push redirect 时也兼容）
   *   - 服务端下发 IFCONFIG6 时 isIPv6Accepted=true，addresses 增加 family=2 地址；
   *     ROUTE6 写入 routes，没有 IPv6 路由时补 ::/0，使 IPv6 流量进入隧道
   *   - 隧道对端 socket 排除由 protect(fd) 完成（OpenVPN PROTECTFD → VpnConnection.protect），
   *     避免 UDP/TCP 隧道包被默认路由引回 tun 自环
   */
  public async setupTun(ip?: string): Promise<number> {
    /* 复用已创建的 tun fd：VpnConnection.create 只能成功一次（第二次报 2203002），
     * OpenVPN 重连/多次 OPENTUN 时直接返回已有 fd */
    fileLog(`setupTun called, currentFd=${this.currentFd}, ip=${ip ?? ''}`);
    if (this.currentFd >= 0) {
      hilog.info(DOMAIN, TAG, `setupTun: reuse existing fd=${this.currentFd}`);
      fileLog(`setupTun: reuse existing fd=${this.currentFd}, ipv6=${this.ipv6Address}/${this.ipv6PrefixLength} routes=${this.formatIpv6Routes()}`);
      return this.currentFd;
    }

    const conn = this.vpnConnection;
    if (conn === null) {
      hilog.error(DOMAIN, TAG, 'vpnConnection is null');
      fileLog('setupTun: vpnConnection is null');
      return -1;
    }

    /* 动态地址：优先服务端分配的真实 IP，回退占位地址（本地联调 10.8.0.2）。
     * prefixLength 取 24：OpenVPN 分配网段通常为 /24（ProtonVPN 10.96.0.0/24、本地 10.8.0.0/24）。
     * ArkTS 严格模式：嵌套对象字面量须有显式目标类型（先声明再引用，避免 untyped obj literal）。 */
    const tunIp: string = (ip !== undefined && ip.length > 0) ? ip : '10.8.0.2';
    const vpnAddr: connection.LinkAddress = {
      address: { address: tunIp, family: 1 },
      prefixLength: 24,
    };
    const defaultRoute: connection.RouteInfo = {
      interface: 'vpn-tun',
      destination: {
        address: { address: '0.0.0.0', family: 1 },
        prefixLength: 0
      },
      gateway: { address: tunIp, family: 1 },
      hasGateway: false,
      isDefaultRoute: true,
    };
    const addresses: connection.LinkAddress[] = [vpnAddr];
    const routes: connection.RouteInfo[] = [defaultRoute];
    const ipv6Enabled: boolean = this.ipv6Address.length > 0 && this.ipv6PrefixLength >= 0;
    if (ipv6Enabled) {
      const vpnAddr6: connection.LinkAddress = {
        address: { address: this.ipv6Address, family: 2 },
        prefixLength: this.ipv6PrefixLength,
      };
      addresses.push(vpnAddr6);
      /* 有服务端 ROUTE6 时按推送安装（redirect-gateway ipv6 不是 ::/0）。
       * 没有路由时补 ::/0，否则仅有地址时部分系统不会把 IPv6 流量送进隧道。 */
      if (this.ipv6Routes.length === 0) {
        routes.push(this.makeIpv6Route('::', 0, true));
      } else {
        for (const spec of this.ipv6Routes) {
          routes.push(this.makeIpv6Route(spec.network, spec.prefixLength, spec.prefixLength === 0));
        }
      }
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      mtu: this.tunMtu,
      isIPv4Accepted: true,
      isIPv6Accepted: ipv6Enabled,
      /* 服务端 DNS 推送（FR-4.18-10）：core 收到 push dhcp-option DNS →
       * ovpn_emit_dns → onStatus "DNS:..." → setDnsAddresses 缓存，
       * setupTun 时写入 VpnConfig，系统 VPN 框架按推送 DNS 生效 */
      dnsAddresses: this.dnsAddresses.length > 0 ? this.dnsAddresses : []
    };

    try {
      const fd = await conn.create(config);
      this.currentFd = fd;
      hilog.info(DOMAIN, TAG, `setupTun ok, fd=${fd}`);
      const ipv6Log: string = ipv6Enabled ?
        `${this.ipv6Address}/${this.ipv6PrefixLength} routes=${this.ipv6Routes.length === 0 ? '::/0' : this.formatIpv6Routes()}` :
        'disabled';
      fileLog(`setupTun ok, fd=${fd}, mtu=${this.tunMtu}, ipv6=${ipv6Log}`);
      /* VpnConnection 已就绪，补 protect 之前缓存的 fd（PROTECTFD 早于 OPENTUN） */
      this.flushPendingProtects();
      return fd;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `setupTun error: ${JSON.stringify(err)}`);
      fileLog(`setupTun error: ${JSON.stringify(err)}`);
      return -1;
    }
  }

  /**
   * 保护 socket fd（OpenVPN PROTECTFD 请求）。使该 socket 流量绕过 VPN 隧道
   * （走物理网卡），防止默认路由下隧道包自环。
   * vpnConnection 未就绪时先缓存，setupTun 成功后补执行。
   */
  public async protectFd(fd: number): Promise<void> {
    const conn = this.vpnConnection;
    if (conn === null) {
      fileLog(`protectFd: vpnConnection not ready, cache fd=${fd}`);
      if (!this.pendingProtectFds.includes(fd)) {
        this.pendingProtectFds.push(fd);
      }
      return;
    }
    try {
      await conn.protect(fd);
      fileLog(`protectFd ok: fd=${fd}`);
    } catch (err) {
      fileLog(`protectFd error fd=${fd}: ${JSON.stringify(err)}`);
    }
  }

  private flushPendingProtects(): void {
    const pending: number[] = this.pendingProtectFds;
    this.pendingProtectFds = [];
    for (const fd of pending) {
      this.protectFd(fd);
    }
  }

  /**
   * 双隧道冒烟验证（多连接前置闸门）：
   * 创建两个独立 VpnConnection，各 generateVpnId() + create（不同 vpnId），
   * 观察系统是否允许两条隧道同时 active。
   * - 都成功 → 系统支持多 VPN → 值得投入连接池重构
   * - 第二个报 2203002（VPN exist already）→ 商用版未开 SUPPORT_SYSVPN → 放弃多连
   * 不触碰 this.vpnConnection（现有单连接不受影响），结果写 vpnext.log。
   */
  public async smokeTestDualTunnel(context: object): Promise<string> {
    try {
      fileLog('smoke: dual tunnel test START');
      /* 创建两个独立 VpnConnection 实例（同进程，各自 vpnId） */
      const connA: vpnExtension.VpnConnection =
        vpnExtension.createVpnConnection(context as vpnExtension.VpnExtensionContext);
      const connB: vpnExtension.VpnConnection =
        vpnExtension.createVpnConnection(context as vpnExtension.VpnExtensionContext);

      const vpnIdA: string = await connA.generateVpnId();
      const vpnIdB: string = await connB.generateVpnId();
      fileLog(`smoke: vpnIdA=${vpnIdA} vpnIdB=${vpnIdB}`);

      /* 隧道 A：10.99.0.0/24 */
      const addrA: connection.LinkAddress = {
        address: { address: '10.99.0.2', family: 1 }, prefixLength: 24
      };
      const routeA: connection.RouteInfo = {
        interface: 'vpn-tun',
        destination: { address: { address: '10.99.0.0', family: 1 }, prefixLength: 24 },
        gateway: { address: '10.99.0.2', family: 1 },
        hasGateway: false, isDefaultRoute: false
      };
      const cfgA: vpnExtension.VpnConfig = { addresses: [addrA], routes: [routeA], mtu: 1500, vpnId: vpnIdA };
      const fdA: number = await connA.create(cfgA);
      fileLog(`smoke: tunnel A created fd=${fdA}`);

      /* 隧道 B：10.98.0.0/24（关键：B 是否也被允许 active） */
      const addrB: connection.LinkAddress = {
        address: { address: '10.98.0.2', family: 1 }, prefixLength: 24
      };
      const routeB: connection.RouteInfo = {
        interface: 'vpn-tun',
        destination: { address: { address: '10.98.0.0', family: 1 }, prefixLength: 24 },
        gateway: { address: '10.98.0.2', family: 1 },
        hasGateway: false, isDefaultRoute: false
      };
      const cfgB: vpnExtension.VpnConfig = { addresses: [addrB], routes: [routeB], mtu: 1500, vpnId: vpnIdB };
      const fdB: number = await connB.create(cfgB);
      fileLog(`smoke: tunnel B created fd=${fdB}`);

      /* 双隧道同时 active 成功 → 清理（按 vpnId 精确销毁） */
      await connA.destroy(vpnIdA);
      await connB.destroy(vpnIdB);
      fileLog('smoke: DUAL TUNNEL SUPPORTED (both active, then destroyed)');
      return 'SUPPORTED';
    } catch (err) {
      fileLog(`smoke: FAILED -> ${JSON.stringify(err)}`);
      return `FAILED: ${JSON.stringify(err)}`;
    }
  }

  /**
   * 销毁虚拟网卡。可重复调用。
   */
  public async destroy(): Promise<void> {
    const conn = this.vpnConnection;
    this.vpnConnection = null;
    this.currentFd = -1;
    this.dnsAddresses = [];
    this.ipv6Address = '';
    this.ipv6PrefixLength = -1;
    this.ipv6Routes = [];
    this.tunMtu = 1500;
    this.pendingProtectFds = [];
    if (conn === null) {
      return;
    }
    try {
      await conn.destroy();
      hilog.info(DOMAIN, TAG, 'vpn destroyed');
      fileLog('vpn destroyed');
    } catch (err) {
      hilog.error(DOMAIN, TAG, `destroy error: ${JSON.stringify(err)}`);
      fileLog(`destroy error: ${JSON.stringify(err)}`);
    }
  }
}
