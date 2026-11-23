/**
 * VpnTray.ets
 * 鸿蒙 PC（2in1）右下角状态栏托盘。
 *
 * 使用 @kit.DeskTopExtensionKit 的 statusBarManager：
 * 图标常驻状态栏，右键弹出菜单，点击通过 rightMenuClick 的 menuCode 回到主界面。
 * 一级菜单总数不能超过 20。系统会自带「退出」，这里不再加一项。配置项最多放 18 个，其余是导入、选项。
 */

import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TrayKeepAlive } from './TrayKeepAlive';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnTray';
const MENU_SEP: string = '\u0001';
/** 一级菜单上限 20：配置最多 18 个，再加导入、选项。退出由系统菜单提供。 */
const MAX_CONFIG_ITEMS: number = 18;
const MENU_UPDATE_INTERVAL_MS: number = 250;
const MENU_UPDATE_ATTEMPTS: number = 3;

export type TrayAction = 'connect' | 'disconnect' | 'reconnect' | 'status' | 'log' | 'edit' |
  'clearpass' | 'import' | 'import-as' | 'import-url' | 'settings' | 'exit' | 'show';

/** 某一份配置在托盘一级菜单上的标记。同一时间只有当前会话那一份不是 idle。 */
export type TrayLinkState = 'connected' | 'connecting' | 'idle';

export interface TrayCommand {
  action: TrayAction;
  configName: string;
}

class TrayUpdateSuperseded extends Error {
  constructor() {
    super('Tray update superseded');
  }
}

export class VpnTray {
  private static pending: Promise<void> = Promise.resolve();
  private static listening: boolean = false;
  private static added: boolean = false;
  private static menuKey: string = '';
  private static iconName: string = '';
  private static hover: string = '';
  private static held: image.PixelMap[] = [];
  private static handler: ((cmd: TrayCommand) => void) | null = null;
  private static activeName: string = '';
  private static linkState: TrayLinkState = 'idle';
  /** 0 自动（超过 25 个按子目录分组），1 扁平，2 始终按子目录分组。 */
  private static menuView: number = 0;
  private static menuIcons: Map<string, statusBarManager.StatusBarItemIcon> = new Map();
  private static menuHeld: image.PixelMap[] = [];
  private static appliedMenuIcons: Map<string, statusBarManager.StatusBarItemIcon> = new Map();
  private static lastMenuUpdateAt: number = 0;
  private static requestVersion: number = 0;

  public static setHandler(handler: (cmd: TrayCommand) => void): void {
    VpnTray.handler = handler;
  }

  /** 按当前配置列表、提示文字、图标和连接标记刷新托盘。重复调用会排队，避免接口调用过频。 */
  public static sync(context: common.UIAbilityContext, configs: string[], hoverTips: string,
    iconName: string, activeName: string, linkState: TrayLinkState, menuView: number = 0): void {
    VpnTray.activeName = activeName;
    VpnTray.linkState = linkState;
    const requestVersion: number = ++VpnTray.requestVersion;
    const snapshot: string[] = configs.slice();
    VpnTray.pending = VpnTray.pending.then(async (): Promise<void> => {
      if (requestVersion !== VpnTray.requestVersion) {
        return;
      }
      await VpnTray.apply(context, snapshot, hoverTips, iconName, menuView, requestVersion);
    }).catch((error: Object): void => {
      if (error instanceof TrayUpdateSuperseded) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'tray sync failed: %{public}s', VpnTray.errorText(error));
    });
  }

  private static errorText(error: Object): string {
    const failure: BusinessError = error as BusinessError;
    return `code=${failure.code ?? 'unknown'}, message=${failure.message ?? JSON.stringify(error)}`;
  }

  private static wait(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, milliseconds);
    });
  }

  private static async updateTray(requestVersion: number, operation: () => Promise<void>): Promise<void> {
    for (let attempt: number = 0; attempt < MENU_UPDATE_ATTEMPTS; attempt++) {
      if (requestVersion !== VpnTray.requestVersion) {
        throw new TrayUpdateSuperseded();
      }
      const delay: number = MENU_UPDATE_INTERVAL_MS - (Date.now() - VpnTray.lastMenuUpdateAt);
      if (delay > 0) {
        await VpnTray.wait(delay);
      }
      if (requestVersion !== VpnTray.requestVersion) {
        throw new TrayUpdateSuperseded();
      }
      VpnTray.lastMenuUpdateAt = Date.now();
      try {
        await operation();
        return;
      } catch (error) {
        const failure: BusinessError = error as BusinessError;
        if (failure.code !== 1010710003 || attempt + 1 === MENU_UPDATE_ATTEMPTS) {
          throw error as Error;
        }
        hilog.warn(DOMAIN, TAG, 'tray menu rate limited, retry=%{public}d: %{public}s',
          attempt + 1, VpnTray.errorText(error));
        await VpnTray.wait(1000 * (attempt + 1));
      }
    }
  }

  private static onIconClick(_event: emitter.EventData): void {
    VpnTray.emit('show', '');
  }

  private static menuCodeOf(event: emitter.EventData): string {
    if (event.data === undefined) {
      return '';
    }
    const raw: Object = event.data['menuCode'] as Object;
    if (typeof raw !== 'string' || raw.length === 0) {
      return '';
    }
    return raw;
  }

  private static onMenuClick(event: emitter.EventData): void {
    const code: string = VpnTray.menuCodeOf(event);
    if (code.length === 0) {
      return;
    }
    if (code === 'import-file') {
      VpnTray.emit('import', '');
      return;
    }
    if (code === 'import-as') {
      VpnTray.emit('import-as', '');
      return;
    }
    if (code === 'import-url') {
      VpnTray.emit('import-url', '');
      return;
    }
    if (code === 'settings') {
      VpnTray.emit('settings', '');
      return;
    }
    if (code === 'exit') {
      VpnTray.emit('exit', '');
      return;
    }
    const sep: number = code.indexOf(MENU_SEP);
    if (sep <= 0) {
      return;
    }
    const action: string = code.substring(0, sep);
    const name: string = code.substring(sep + MENU_SEP.length);
    if (action === 'connect' || action === 'disconnect' || action === 'reconnect' ||
      action === 'status' || action === 'log' || action === 'edit' || action === 'clearpass') {
      const cmd: TrayAction = action as TrayAction;
      if (!VpnTray.allow(cmd, name)) {
        hilog.info(DOMAIN, TAG, 'tray item disabled: %{public}s %{public}s', action, name);
        return;
      }
      VpnTray.emit(cmd, name);
    }
  }

  /** 二级菜单里当前状态下不可点的项。界面上仍保留，点击不执行。 */
  private static allow(action: TrayAction, name: string): boolean {
    const state: TrayLinkState = name === VpnTray.activeName ? VpnTray.linkState : 'idle';
    if (state === 'connected') {
      return action !== 'connect';
    }
    if (state === 'connecting') {
      return action !== 'connect' && action !== 'clearpass';
    }
    return action !== 'disconnect' && action !== 'reconnect' && action !== 'status';
  }

  private static emit(action: TrayAction, configName: string): void {
    if (VpnTray.handler === null) {
      hilog.warn(DOMAIN, TAG, 'tray click ignored, handler missing: %{public}s', action);
      return;
    }
    const cmd: TrayCommand = { action: action, configName: configName };
    VpnTray.handler(cmd);
  }

  private static ensureListening(): void {
    if (VpnTray.listening) {
      return;
    }
    statusBarManager.on('statusBarIconClick', VpnTray.onIconClick);
    statusBarManager.on('rightMenuClick', VpnTray.onMenuClick);
    VpnTray.listening = true;
  }

  private static actionOf(): statusBarManager.StatusBarMenuAction {
    const action: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      notifyOnly: true
    };
    return action;
  }

  private static code(action: string, name: string): string {
    return `${action}${MENU_SEP}${name}`;
  }

  private static subItem(title: string, code: string, iconName: string,
    withIcons: boolean): statusBarManager.StatusBarSubMenuItem {
    const item: statusBarManager.StatusBarSubMenuItem = {
      subTitle: title,
      menuCode: code,
      menuAction: VpnTray.actionOf()
    };
    const icon: statusBarManager.StatusBarItemIcon | null = withIcons ? VpnTray.menuIcon(iconName) : null;
    if (icon !== null) {
      const options: statusBarManager.StatusBarMenuItemOptions = { icon: icon };
      item.options = options;
    }
    return item;
  }

  private static leaf(title: string, code: string, iconName: string,
    withIcons: boolean): statusBarManager.StatusBarMenuItem {
    const item: statusBarManager.StatusBarMenuItem = {
      title: title,
      menuCode: code,
      menuAction: VpnTray.actionOf()
    };
    VpnTray.applyIcon(item, iconName, withIcons);
    return item;
  }

  private static menuIcon(name: string): statusBarManager.StatusBarItemIcon | null {
    const icon: statusBarManager.StatusBarItemIcon | undefined = VpnTray.menuIcons.get(name);
    if (icon === undefined) {
      return null;
    }
    return icon;
  }

  private static applyIcon(item: statusBarManager.StatusBarMenuItem, iconName: string, withIcons: boolean): void {
    const icon: statusBarManager.StatusBarItemIcon | null = withIcons ? VpnTray.menuIcon(iconName) : null;
    if (icon === null) {
      return;
    }
    const options: statusBarManager.StatusBarMenuItemOptions = { icon: icon };
    item.options = options;
  }

  private static stateOf(name: string): TrayLinkState {
    if (name === VpnTray.activeName && VpnTray.linkState !== 'idle') {
      return VpnTray.linkState;
    }
    return 'idle';
  }

  /** 当前会话那一份用蓝色链接，其余用灰色链接。 */
  private static profileIcon(name: string): string {
    return VpnTray.stateOf(name) === 'idle' ? 'NO_Link' : 'Link';
  }

  private static configItem(name: string, withIcons: boolean): statusBarManager.StatusBarMenuItem {
    const subs: statusBarManager.StatusBarSubMenuItem[] = [
      VpnTray.subItem('连接', VpnTray.code('connect', name), 'Link', withIcons),
      VpnTray.subItem('断开连接', VpnTray.code('disconnect', name), 'Link_Down', withIcons),
      VpnTray.subItem('重新连接', VpnTray.code('reconnect', name), 'Reconnect', withIcons),
      VpnTray.subItem('显示状态', VpnTray.code('status', name), 'Show_Main', withIcons),
      VpnTray.subItem('显示日志', VpnTray.code('log', name), 'Show_Log', withIcons),
      VpnTray.subItem('编辑配置文件', VpnTray.code('edit', name), 'Edit_Ovpn', withIcons),
      VpnTray.subItem('清除已保存的密码', VpnTray.code('clearpass', name), 'Delete_Password', withIcons)
    ];
    const item: statusBarManager.StatusBarMenuItem = {
      title: name,
      menuCode: VpnTray.code('profile', name),
      subMenu: subs
    };
    VpnTray.applyIcon(item, VpnTray.profileIcon(name), withIcons);
    return item;
  }

  private static folderOf(name: string): string {
    const slash: number = name.indexOf('/');
    return slash > 0 ? name.substring(0, slash) : '';
  }

  private static buildGroups(configs: string[], withIcons: boolean): statusBarManager.StatusBarGroupMenu[] {
    const shown: string[] = configs.length > MAX_CONFIG_ITEMS ? configs.slice(0, MAX_CONFIG_ITEMS) : configs;
    const grouped: boolean = VpnTray.menuView === 2 || (VpnTray.menuView === 0 && shown.length > 25);
    const profiles: statusBarManager.StatusBarMenuItem[] = [];
    const folderGroups: statusBarManager.StatusBarGroupMenu[] = [];
    if (!grouped) {
      for (const name of shown) {
        profiles.push(VpnTray.configItem(name, withIcons));
      }
    } else {
      const folders: string[] = [];
      const buckets: string[][] = [];
      for (const name of shown) {
        const folder: string = VpnTray.folderOf(name);
        let idx: number = folders.indexOf(folder);
        if (idx < 0) {
          const row: string[] = [];
          folders.push(folder);
          buckets.push(row);
          idx = folders.length - 1;
        }
        buckets[idx].push(name);
      }
      for (const bucket of buckets) {
        const items: statusBarManager.StatusBarMenuItem[] = [];
        for (const name of bucket) {
          items.push(VpnTray.configItem(name, withIcons));
        }
        folderGroups.push(items);
      }
    }
    const importItem: statusBarManager.StatusBarMenuItem = {
      title: '导入',
      menuCode: 'import-menu',
      subMenu: [
        VpnTray.subItem('导入配置文件...', 'import-file', 'Import_Doc', withIcons),
        VpnTray.subItem('从Access Server导入...', 'import-as', 'Import_Acc', withIcons),
        VpnTray.subItem('从URL导入...', 'import-url', 'Import_Url', withIcons)
      ]
    };
    VpnTray.applyIcon(importItem, 'import', withIcons);
    const tail: statusBarManager.StatusBarMenuItem[] = [
      importItem,
      VpnTray.leaf('选项...', 'settings', 'Setting', withIcons)
    ];
    const groups: statusBarManager.StatusBarGroupMenu[] = [];
    if (folderGroups.length > 0) {
      for (const folder of folderGroups) {
        groups.push(folder);
      }
    } else if (profiles.length > 0) {
      groups.push(profiles);
    }
    groups.push(tail);
    return groups;
  }

  private static menuSignature(configs: string[]): string {
    const shown: string[] = configs.length > MAX_CONFIG_ITEMS ? configs.slice(0, MAX_CONFIG_ITEMS) : configs;
    return `v9\n${VpnTray.menuView}\n${shown.join('\n')}`;
  }

  private static async updateMenuIcons(context: common.UIAbilityContext,
    groups: statusBarManager.StatusBarGroupMenu[], requestVersion: number): Promise<void> {
    let updated: number = 0;
    for (const group of groups) {
      for (const item of group) {
        if (requestVersion !== VpnTray.requestVersion) {
          return;
        }
        const code: string = item.menuCode ?? '';
        const icon: statusBarManager.StatusBarItemIcon | undefined = item.options?.icon;
        if (icon === undefined || VpnTray.appliedMenuIcons.get(code) === icon) {
          continue;
        }
        try {
          await VpnTray.updateTray(requestVersion, (): Promise<void> => {
            return statusBarManager.updateStatusBarMenuItem(context, item);
          });
        } catch (error) {
          if (error instanceof TrayUpdateSuperseded) {
            throw error as Error;
          }
          hilog.error(DOMAIN, TAG, 'tray menu item failed: %{public}s, %{public}s',
            item.title, VpnTray.errorText(error));
          throw error as Error;
        }
        VpnTray.appliedMenuIcons.set(code, icon);
        updated++;
      }
    }
    if (updated > 0) {
      hilog.info(DOMAIN, TAG, 'tray menu icons ready, items=%{public}d, updated=%{public}d',
        VpnTray.appliedMenuIcons.size, updated);
    }
  }

  private static clipTip(tip: string): string {
    const text: string = tip.length > 0 ? tip : 'OpenVPN';
    return text.length > 128 ? text.substring(0, 128) : text;
  }

  private static async loadIcon(context: common.UIAbilityContext, mediaName: string,
    side: number = 48): Promise<image.PixelMap> {
    const bytes: Uint8Array = await context.resourceManager.getMediaByName(mediaName);
    const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const source: image.ImageSource = image.createImageSource(buffer);
    try {
      return await source.createPixelMap({ desiredSize: { width: side, height: side } });
    } finally {
      await source.release();
    }
  }

  /** 深色壁纸用浅色图标。未连接那张资源名沿用文件名 Diaconnected_Dark。 */
  private static darkMediaName(mediaName: string): string {
    if (mediaName === 'connected') {
      return 'Connected_Dark';
    }
    if (mediaName === 'connecting') {
      return 'Connecting_Dark';
    }
    if (mediaName === 'disconnected') {
      return 'Diaconnected_Dark';
    }
    return mediaName;
  }

  /** white 画在深色壁纸上，black 画在浅色壁纸上。 */
  private static async loadPair(context: common.UIAbilityContext,
    mediaName: string): Promise<statusBarManager.StatusBarIcon> {
    const white: image.PixelMap = await VpnTray.loadIcon(context, VpnTray.darkMediaName(mediaName));
    const black: image.PixelMap = await VpnTray.loadIcon(context, mediaName);
    const icon: statusBarManager.StatusBarIcon = { white: white, black: black };
    return icon;
  }

  /** 新图标交给系统后再释放上一套，避免托盘图标被提前回收。 */
  private static keepIcons(icon: statusBarManager.StatusBarIcon): void {
    const previous: image.PixelMap[] = VpnTray.held;
    VpnTray.held = [icon.white, icon.black];
    for (const old of previous) {
      try {
        old.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'release icon skipped');
      }
    }
  }

  /** 深色壁纸用的菜单图标。已连接的 Link 是蓝色，没有单独的深色图。 */
  private static menuDarkName(name: string): string {
    if (name === 'import') {
      return 'Import_Dark';
    }
    if (name === 'Link') {
      return 'Link';
    }
    return `${name}_Dark`;
  }

  /** 菜单图标只加载一次。浅色、深色各一份，避免和状态栏图标一起被释放。 */
  private static async ensureMenuIcons(context: common.UIAbilityContext): Promise<void> {
    const names: string[] = [
      'Link', 'NO_Link', 'Link_Down', 'import', 'Setting',
      'Import_Doc', 'Import_Acc', 'Import_Url',
      'Reconnect', 'Show_Main', 'Show_Log', 'Edit_Ovpn', 'Delete_Password'
    ];
    for (const name of names) {
      if (VpnTray.menuIcons.has(name)) {
        continue;
      }
      const white: image.PixelMap = await VpnTray.loadIcon(context, VpnTray.menuDarkName(name), 24);
      const black: image.PixelMap = await VpnTray.loadIcon(context, name, 24);
      const icon: statusBarManager.StatusBarItemIcon = { white: white, black: black };
      VpnTray.menuIcons.set(name, icon);
      VpnTray.menuHeld.push(white);
      VpnTray.menuHeld.push(black);
    }
  }

  private static async apply(context: common.UIAbilityContext, configs: string[], hoverTips: string,
    iconName: string, menuView: number, requestVersion: number): Promise<void> {
    VpnTray.ensureListening();
    VpnTray.menuView = menuView;
    const tip: string = VpnTray.clipTip(hoverTips);
    const menuKey: string = VpnTray.menuSignature(configs);
    if (!VpnTray.added) {
      const icons: statusBarManager.StatusBarIcon = await VpnTray.loadPair(context, iconName);
      const item: statusBarManager.StatusBarItem = {
        icons: icons,
        quickOperation: {
          title: 'OpenVPN',
          height: 1,
          abilityName: ''
        },
        statusBarGroupMenu: VpnTray.buildGroups(configs, false),
        hoverTips: tip
      };
      try {
        await VpnTray.updateTray(requestVersion, (): Promise<void> => {
          return new Promise<void>((resolve, reject) => {
            statusBarManager.addToStatusBar(context, item, (error: BusinessError): void => {
              if (error) {
                reject(error);
              } else {
                resolve();
              }
            });
          });
        });
      } catch (error) {
        await icons.white.release();
        await icons.black.release();
        throw error as Error;
      }
      VpnTray.keepIcons(icons);
      VpnTray.added = true;
      VpnTray.menuKey = menuKey;
      VpnTray.appliedMenuIcons.clear();
      VpnTray.iconName = iconName;
      VpnTray.hover = tip;
      hilog.info(DOMAIN, TAG, 'tray added, configs=%{public}d, icons=pending', configs.length);
      TrayKeepAlive.hold(context);
    } else if (VpnTray.menuKey !== menuKey) {
      const groups: statusBarManager.StatusBarGroupMenu[] = VpnTray.buildGroups(configs, false);
      await VpnTray.updateTray(requestVersion, (): Promise<void> => {
        return new Promise<void>((resolve, reject) => {
          statusBarManager.updateStatusBarMenu(context, groups, (error: BusinessError): void => {
            if (error) {
              reject(error);
            } else {
              resolve();
            }
          });
        });
      });
      VpnTray.menuKey = menuKey;
      VpnTray.appliedMenuIcons.clear();
      hilog.info(DOMAIN, TAG, 'tray menu structure updated, configs=%{public}d, icons=pending', configs.length);
    }
    let updateError: Object | null = null;
    try {
      if (VpnTray.iconName !== iconName) {
        const icons: statusBarManager.StatusBarIcon = await VpnTray.loadPair(context, iconName);
        try {
          await VpnTray.updateTray(requestVersion, (): Promise<void> => {
            return new Promise<void>((resolve, reject) => {
              statusBarManager.updateStatusBarIcon(context, icons, (error: BusinessError): void => {
                if (error) {
                  reject(error);
                } else {
                  resolve();
                }
              });
            });
          });
        } catch (error) {
          await icons.white.release();
          await icons.black.release();
          throw error as Error;
        }
        VpnTray.keepIcons(icons);
        VpnTray.iconName = iconName;
      }
    } catch (error) {
      if (error instanceof TrayUpdateSuperseded) {
        throw error as Error;
      }
      updateError = error;
      hilog.error(DOMAIN, TAG, 'tray icon update failed: %{public}s', VpnTray.errorText(error));
    }
    try {
      if (VpnTray.hover !== tip) {
        await VpnTray.updateTray(requestVersion, (): Promise<void> => {
          return statusBarManager.updateStatusBarHoverTips(context, tip);
        });
        VpnTray.hover = tip;
      }
    } catch (error) {
      if (error instanceof TrayUpdateSuperseded) {
        throw error as Error;
      }
      updateError = error;
      hilog.error(DOMAIN, TAG, 'tray hover update failed: %{public}s', VpnTray.errorText(error));
    }
    if (requestVersion !== VpnTray.requestVersion) {
      return;
    }
    await VpnTray.ensureMenuIcons(context);
    await VpnTray.updateMenuIcons(context, VpnTray.buildGroups(configs, true), requestVersion);
    if (updateError !== null) {
      throw updateError as Error;
    }
  }
}

