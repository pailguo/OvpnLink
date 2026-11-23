/**
 * Settings.ets
 * 设置页面。字段对齐原版 OpenVPN GUI（settings.c），版式四页：
 *   - 常规：偏好设置 / 显示通知 / 持久连接 / 自动重启与 OTP
 *   - 代理：代理模式 + 手动代理配置
 *   - 高级：配置文件 / 管理界面与菜单视图 / 消息展示
 *   - 关于：三张介绍卡片，下面是隐私与权限
 *
 * 手动代理里第二项稿面写成「手动」，实际仍是 SOCKS，避免和「手动设置」搞混。
 * 密码框稿面标签误写成「用户名」，这里用「密码」（占位和眼睛图标都是密码）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, Want } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import {
  SettingsStore,
  ProxyMode,
  ProxySubType,
  ShowNotifyMode,
  PersistentConn,
  MenuView,
  MsgDisplay,
  VpnSettings,
  defaultSettings
} from '../common/SettingsStore';
import { AppWindows, SETTINGS_SAVED_EVENT } from '../common/AppWindows';
import { theme } from '../common/ThemeManager';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnSettings';
/** 应用市场托管的本应用隐私政策 */
const PRIVACY_URL: string =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2060860288864934592';

/** 单选组选项 */
interface RadioOption {
  value: number;
  label: string;
}

@Entry
@Component
struct Settings {
  @StorageLink('isDark') isDark: boolean = false;
  @State settings: VpnSettings = defaultSettings();
  @State currentTab: number = 0;
  @State loaded: boolean = false;

  async aboutToAppear(): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.getInstance().init(context);
      this.settings = await SettingsStore.getInstance().get();
      this.loaded = true;
      hilog.info(DOMAIN, TAG, 'settings loaded');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load error: %{public}s', JSON.stringify(e));
    }
  }

  /** 把当前输入框写回 HTTP 或 SOCKS 那一套，再让 proxyServer 指向正在用的那套。 */
  private flushProxyFields(): void {
    if (this.settings.proxySubType === ProxySubType.SOCKS) {
      this.settings.proxySocksServer = this.settings.proxyServer;
      this.settings.proxySocksPort = this.settings.proxyPort;
    } else {
      this.settings.proxyHttpServer = this.settings.proxyServer;
      this.settings.proxyHttpPort = this.settings.proxyPort;
    }
  }

  /** 切换 HTTP / SOCKS 时换出各自保存的地址和端口。 */
  private selectProxySub(next: number): void {
    this.flushProxyFields();
    this.settings.proxySubType = next;
    if (next === ProxySubType.SOCKS) {
      this.settings.proxyServer = this.settings.proxySocksServer;
      this.settings.proxyPort = this.settings.proxySocksPort > 0 ? this.settings.proxySocksPort : 1080;
    } else {
      this.settings.proxyServer = this.settings.proxyHttpServer;
      this.settings.proxyPort = this.settings.proxyHttpPort > 0 ? this.settings.proxyHttpPort : 8080;
    }
  }

  /** 保存并返回（对齐原版设置对话框 OK 行为） */
  private async saveSettings(): Promise<void> {
    try {
      this.flushProxyFields();
      await SettingsStore.getInstance().save(this.settings);
      hilog.info(DOMAIN, TAG, 'settings saved by user');
      emitter.emit({ eventId: SETTINGS_SAVED_EVENT });
      AppWindows.closeSettings();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save error: %{public}s', JSON.stringify(e));
    }
  }

  private closePage(): void {
    AppWindows.closeSettings();
  }

  /** 用系统浏览器打开给定网址 */
  private openInBrowser(url: string): void {
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx === undefined || hostCtx === null) {
      return;
    }
    const context: common.UIAbilityContext = hostCtx as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'openInBrowser failed: %{public}s', JSON.stringify(e));
    });
  }

  /** 清除全部已保存凭据（确认后执行，防止误操作） */
  private clearSavedCredentials(): void {
    this.getUIContext().showAlertDialog({
      title: '清除保存的凭据',
      message: '将删除所有已保存的用户名/密码，下次连接需重新输入。确定继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '确定清除',
        fontColor: theme.dangerColor,
        action: () => {
          this.doClearCredentials();
        }
      }
    });
  }

  private async doClearCredentials(): Promise<void> {
    try {
      const count: number = await SettingsStore.getInstance().clearAllCredentials();
      this.getUIContext().showAlertDialog({
        title: '清除完成',
        message: count > 0 ? `已清除 ${count} 条已保存凭据。` : '没有找到已保存的凭据。',
        confirm: {
          value: '好的',
          action: () => {
          }
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clear credentials error: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
        TabContent() { this.GeneralTab() }
          .tabBar(this.TabBarBuilder('常规', 0))

        TabContent() { this.ProxyTab() }
          .tabBar(this.TabBarBuilder('代理', 1))

        TabContent() { this.AdvancedTab() }
          .tabBar(this.TabBarBuilder('高级', 2))

        TabContent() { this.AboutTab() }
          .tabBar(this.TabBarBuilder('关于', 3))
      }
      .width('100%')
      .layoutWeight(1)
      .barMode(BarMode.Fixed)
      .barHeight(48)
      .barBackgroundColor(theme.contentBgColor)
      .backgroundColor(theme.pageBgColor)
      .onChange((index: number) => {
        this.currentTab = index;
      })

      Row({ space: 12 }) {
        Blank()

        Button('取消')
          .width(96)
          .height(40)
          .fontSize(16)
          .fontColor(theme.accentColor)
          .backgroundColor(theme.contentBgColor)
          .borderRadius(8)
          .onClick(() => {
            this.closePage();
          })

        Button('确定')
          .width(96)
          .height(40)
          .fontSize(16)
          .fontColor(theme.selectedTextColor)
          .backgroundColor(theme.accentColor)
          .borderRadius(8)
          .onClick(() => {
            this.saveSettings();
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8, bottom: 20 })
      .backgroundColor(theme.pageBgColor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? theme.pageBgColor : theme.pageBgColor)
  }

  @Builder
  GeneralTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.GBPreferences()
        this.GBShowNotif()
        this.GBPersistentConn()
        this.GBRestartOtp()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .backgroundColor(theme.pageBgColor)
  }

  @Builder
  GBPreferences() {
    Column({ space: 8 }) {
      Text('偏好设置')
        .fontSize(20)
        .fontColor(theme.textColor)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ bottom: 4 })
      this.CheckRow('追加日志文件', this.settings.appendLog, (v: boolean) => {
        this.settings.appendLog = v;
      })
      Row() {
        Row() {
          Checkbox({ name: '静默连接', group: '静默连接' })
            .select(this.settings.silentConn)
            .width(20)
            .height(20)
            .onChange((value: boolean) => {
              this.settings.silentConn = value;
            })
          Text('静默连接')
            .fontSize(16)
            .fontColor(theme.textColor)
            .margin({ left: 8 })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Button('清除保存的数据')
          .height(32)
          .fontSize(16)
          .fontColor(theme.dangerColor)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(theme.pageBgColor)
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.clearSavedCredentials();
          })
      }
      .width('100%')
      .height(36)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GBShowNotif() {
    Column({ space: 12 }) {
      Text('显示通知')
        .fontSize(20)
        .fontColor(theme.textColor)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      this.RadioSpread('showNotif', this.settings.showNotification, [
        { value: ShowNotifyMode.ON_CONNECT, label: '连接时' },
        { value: ShowNotifyMode.ON_CONNECT_RECONNECT, label: '连接时、重新连接时' },
        { value: ShowNotifyMode.NEVER, label: '从不' }
      ], (v: number) => { this.settings.showNotification = v; })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  /** 自动：隧道自己断开后重连当前配置。手动：断开后保留选择。禁用：断开后清空选择。 */
  @Builder
  GBPersistentConn() {
    Column({ space: 12 }) {
      Text('持久连接')
        .fontSize(20)
        .fontColor(theme.textColor)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      this.RadioSpread('persist', this.settings.persistentConn, [
        { value: PersistentConn.AUTO, label: '自动' },
        { value: PersistentConn.MANUAL, label: '手动' },
        { value: PersistentConn.DISABLED, label: '禁用' }
      ], (v: number) => { this.settings.persistentConn = v; })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GBRestartOtp() {
    Row() {
      Column() {
        this.CheckRow('启用活动连接的自动重新启动', this.settings.autoRestart, (v: boolean) => {
          this.settings.autoRestart = v;
        })
      }
      .layoutWeight(1)

      Column()
        .width(1)
        .height(20)
        .backgroundColor(theme.borderColor)

      Column() {
        this.CheckRow('提示输入 OTP 并与密码结合', this.settings.otpCombine, (v: boolean) => {
          this.settings.otpCombine = v;
        })
      }
      .layoutWeight(1)
      .padding({ left: 16 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ProxyTab() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          Text('代理模式')
            .fontSize(20)
            .fontColor(theme.textColor)
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .margin({ bottom: 4 })
          this.RadioRow('proxyMode', 'proxyMode_cfg', ProxyMode.FROM_CONFIG, this.settings.proxyMode, '使用配置文件中的设置', (v: number) => {
            this.settings.proxyMode = v;
          })
          this.RadioRow('proxyMode', 'proxyMode_sys', ProxyMode.SYSTEM, this.settings.proxyMode, '使用系统代理设置', (v: number) => {
            this.settings.proxyMode = v;
          })
          this.RadioRow('proxyMode', 'proxyMode_man', ProxyMode.MANUAL, this.settings.proxyMode, '手动设置', (v: number) => {
            this.settings.proxyMode = v;
          })
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          Text('手动代理配置')
            .fontSize(20)
            .fontColor(theme.textColor)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Column({ space: 16 }) {
            if (this.settings.proxyMode === ProxyMode.MANUAL) {
              Row() {
                Row() {
                  this.RadioRow('proxySub', 'proxySub_http', ProxySubType.HTTP, this.settings.proxySubType, 'HTTP代理', (v: number) => {
                    this.selectProxySub(v);
                  })
                }.layoutWeight(1)

                Row() {
                  this.RadioRow('proxySub', 'proxySub_socks', ProxySubType.SOCKS, this.settings.proxySubType, 'SOCKS代理', (v: number) => {
                    this.selectProxySub(v);
                  })
                }.layoutWeight(1)
              }
              .width('100%')
              .key('proxySubOn')
            } else {
              Row() {
                Row() {
                  this.RadioRow('proxySubOff', 'proxySubOff_http', ProxySubType.HTTP, this.settings.proxySubType, 'HTTP代理', (v: number) => {
                  }, false)
                }.layoutWeight(1)

                Row() {
                  this.RadioRow('proxySubOff', 'proxySubOff_socks', ProxySubType.SOCKS, this.settings.proxySubType, 'SOCKS代理', (v: number) => {
                  }, false)
                }.layoutWeight(1)
              }
              .width('100%')
              .hitTestBehavior(HitTestMode.None)
              .key('proxySubOff')
            }

            Row({ space: 12 }) {
              Text('地址')
                .fontSize(16)
                .fontColor(theme.textColor)
                .width(64)
              TextInput({ text: this.settings.proxyServer, placeholder: '请输入代理服务器地址' })
                .layoutWeight(1)
                .height(40)
                .fontSize(16)
                .placeholderColor(theme.secondaryTextColor)
                .enabled(this.settings.proxyMode === ProxyMode.MANUAL)
                .backgroundColor(theme.contentBgColor)
                .borderRadius(8)
                .border({ width: 1, color: theme.borderColor })
                .fontColor(theme.textColor)
                .caretColor(theme.accentColor)
                .backgroundColor(theme.inputBgColor)
                .onChange((v: string) => {
                  this.settings.proxyServer = v;
                })
              Text('端口')
                .fontSize(16)
                .fontColor(theme.textColor)
                .margin({ left: 8 })
              TextInput({ text: this.settings.proxyPort.toString() })
                .width(140)
                .height(40)
                .fontSize(16)
                .type(InputType.Number)
                .enabled(this.settings.proxyMode === ProxyMode.MANUAL)
                .backgroundColor(theme.contentBgColor)
                .borderRadius(8)
                .border({ width: 1, color: theme.borderColor })
                .fontColor(theme.textColor)
                .caretColor(theme.accentColor)
                .backgroundColor(theme.inputBgColor)
                .onChange((v: string) => {
                  const n: number = parseInt(v, 10);
                  if (!Number.isNaN(n)) {
                    this.settings.proxyPort = n;
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 12 }) {
              Text('用户名')
                .fontSize(16)
                .fontColor(theme.textColor)
                .width(64)
              TextInput({ text: this.settings.proxyUsername, placeholder: '请输入用户名' })
                .layoutWeight(1)
                .height(40)
                .fontSize(16)
                .placeholderColor(theme.secondaryTextColor)
                .enabled(this.settings.proxyMode === ProxyMode.MANUAL)
                .backgroundColor(theme.contentBgColor)
                .borderRadius(8)
                .border({ width: 1, color: theme.borderColor })
                .fontColor(theme.textColor)
                .caretColor(theme.accentColor)
                .backgroundColor(theme.inputBgColor)
                .onChange((v: string) => {
                  this.settings.proxyUsername = v;
                })
              Text('密码')
                .fontSize(16)
                .fontColor(theme.textColor)
                .margin({ left: 8 })
              TextInput({ text: this.settings.proxyPassword, placeholder: '请输入密码' })
                .layoutWeight(1)
                .height(40)
                .fontSize(16)
                .placeholderColor(theme.secondaryTextColor)
                .type(InputType.Password)
                .showPasswordIcon(true)
                .enabled(this.settings.proxyMode === ProxyMode.MANUAL)
                .backgroundColor(theme.contentBgColor)
                .borderRadius(8)
                .border({ width: 1, color: theme.borderColor })
                .fontColor(theme.textColor)
                .caretColor(theme.accentColor)
                .backgroundColor(theme.inputBgColor)
                .onChange((v: string) => {
                  this.settings.proxyPassword = v;
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor(this.settings.proxyMode === ProxyMode.MANUAL ? Color.Transparent : theme.disabledFillColor)
          .alignItems(HorizontalAlign.Start)
          .enabled(this.settings.proxyMode === ProxyMode.MANUAL)
          .opacity(this.settings.proxyMode === ProxyMode.MANUAL ? 1 : 0.45)
          .hitTestBehavior(this.settings.proxyMode === ProxyMode.MANUAL ? HitTestMode.Default : HitTestMode.Block)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .backgroundColor(theme.pageBgColor)
  }

  @Builder
  AdvancedTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.GBConfigDir()
        this.GBManageAndMenu()
        this.GBMsgDisplay()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .backgroundColor(theme.pageBgColor)
  }

  @Builder
  GBConfigDir() {
    Column({ space: 16 }) {
      Text('配置文件')
        .fontSize(20)
        .fontColor(theme.textColor)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      this.FolderLine('文件夹', this.settings.configDir)
      Row({ space: 12 }) {
        Text('扩展名')
          .fontSize(16)
          .fontColor(theme.textColor)
          .width(64)
        TextInput({ text: this.settings.configExt })
          .layoutWeight(1)
          .height(40)
          .fontSize(16)
          .backgroundColor(theme.contentBgColor)
          .borderRadius(8)
          .border({ width: 1, color: theme.borderColor })
          .fontColor(theme.textColor)
          .caretColor(theme.accentColor)
          .backgroundColor(theme.inputBgColor)
          .onChange((v: string) => {
            this.settings.configExt = v;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  /** 管理界面与配置菜单视图并排。扁平化只扫根目录，嵌套化按子目录分组。 */
  @Builder
  GBManageAndMenu() {
    Row() {
      Column({ space: 16 }) {
        Text('管理界面')
          .fontSize(20)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Bold)
          .width('100%')
        Row({ space: 12 }) {
          Text('端口偏移')
            .fontSize(16)
            .fontColor(theme.textColor)
          TextInput({ text: this.settings.mgmtPortOffset.toString() })
            .width(120)
            .height(40)
            .fontSize(16)
            .type(InputType.Number)
            .backgroundColor(theme.contentBgColor)
            .borderRadius(8)
            .border({ width: 1, color: theme.borderColor })
            .fontColor(theme.textColor)
            .caretColor(theme.accentColor)
            .backgroundColor(theme.inputBgColor)
            .onChange((v: string) => {
              const n: number = parseInt(v, 10);
              if (!Number.isNaN(n)) {
                this.settings.mgmtPortOffset = n;
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 16 }) {
        Text('配置菜单视图')
          .fontSize(20)
          .fontColor(theme.textColor)
          .fontWeight(FontWeight.Bold)
          .width('100%')
        this.RadioSpread('menuView', this.settings.menuView, [
          { value: MenuView.AUTO, label: '自动' },
          { value: MenuView.FLAT, label: '扁平化' },
          { value: MenuView.NESTED, label: '嵌套化' }
        ], (v: number) => { this.settings.menuView = v; })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(VerticalAlign.Top)
  }

  /** 自动弹出 echo 并发状态通知。永不两者都不发。静音小时抑制重复。 */
  @Builder
  GBMsgDisplay() {
    Column({ space: 16 }) {
      Text('消息展示')
        .fontSize(20)
        .fontColor(theme.textColor)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      this.RadioSpread('msgDisplay', this.settings.messageDisplay, [
        { value: MsgDisplay.AUTO, label: '自动' },
        { value: MsgDisplay.NEVER, label: '永不' }
      ], (v: number) => { this.settings.messageDisplay = v; })

      Row({ space: 12 }) {
        Text('重要的消息会被静音：')
          .fontSize(16)
          .fontColor(theme.textColor)
        TextInput({ text: this.settings.repeatMsgMuteHours.toString() })
          .width(88)
          .height(40)
          .fontSize(16)
          .type(InputType.Number)
          .backgroundColor(theme.contentBgColor)
          .borderRadius(8)
          .border({ width: 1, color: theme.borderColor })
          .fontColor(theme.textColor)
          .caretColor(theme.accentColor)
          .backgroundColor(theme.inputBgColor)
          .onChange((v: string) => {
            const n: number = parseInt(v, 10);
            if (!Number.isNaN(n)) {
              this.settings.repeatMsgMuteHours = n;
            }
          })
        Text('小时')
          .fontSize(16)
          .fontColor(theme.textColor)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(theme.contentBgColor)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AboutTab() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 16 }) {
          Stack() {
            Image($r('app.media.Logo_Foreground'))
              .width(89)
              .height(89)
              .objectFit(ImageFit.Contain)
          }
          .width(100)
          .height(100)
          .borderRadius(21)
          .backgroundColor(this.isDark ? 'rgba(49, 122, 247, 0.1)' : 'rgba(231, 237, 253, 1)')

          Column({ space: 4 }) {
            Text('OvpnLink — 基于 OpenVPN 的鸿蒙客户端')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(theme.textColor)
              .width('100%')
            Text('版权所有（C）2004-2005 Mathias Sundman <info@openvpn.se>')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('版权所有（C）2008-2014 Heiko Hund <heikoh@users.sf.net>')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('版权所有（C）2012-2026 OpenVPN GUI 贡献者')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('https://github.com/pailguo/OvpnLink')
              .fontSize(14)
              .fontColor(theme.accentColor)
              .width('100%')
              .margin({ top: 2 })
              .onClick(() => {
                this.openInBrowser('https://github.com/pailguo/OvpnLink');
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(VerticalAlign.Top)

        Row({ space: 16 }) {
          this.AboutSideImage('about')

          Column({ space: 4 }) {
            Text('OpenVPN v2.7.6')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(theme.textColor)
              .width('100%')
            Text('是一套可以安全地通过单一 TCP/UDP 端口在 IP 网络建立隧道的应用程序。它支持 SSL/TLS 为基础的连接验证与密钥交换、封包加密、封包验证、以及封包压缩。')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('版权所有（C）2002-2026 OpenVPN Technologies, Inc <info@openvpn.net>')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
              .margin({ top: 2 })
            Text('https://openvpn.net/')
              .fontSize(14)
              .fontColor(theme.accentColor)
              .width('100%')
              .onClick(() => {
                this.openInBrowser('https://openvpn.net/');
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(VerticalAlign.Top)

        Row({ space: 16 }) {
          this.AboutSideImage('pc')

          Column({ space: 4 }) {
            Text('OpenVPN for HarmonyOS')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(theme.textColor)
              .width('100%')
            Text('鸿蒙 PC（arm64-v8a）客户端')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('核心：OpenVPN 2.7.6 / OpenSSL 3.5.1')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(VerticalAlign.Center)

        Row({ space: 16 }) {
          this.AboutSideImage('privacy')

          Column({ space: 4 }) {
            Text('隐私与权限')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(theme.textColor)
              .width('100%')
            Text('本应用声明了网络访问、退出前准备，以及隐私窗口（认证时避免该窗口被截屏或录屏）。用户名和密码只在你选择保存时写在本机。')
              .fontSize(14)
              .fontColor(theme.secondaryTextColor)
              .width('100%')
            Text('隐私政策')
              .fontSize(14)
              .fontColor(theme.accentColor)
              .width('100%')
              .onClick(() => {
                this.openInBrowser(PRIVACY_URL);
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(theme.contentBgColor)
        .borderRadius(16)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .backgroundColor(theme.pageBgColor)
  }

  /** 关于页卡片左侧图。浅色和深色各一张，尺寸与圆角已经画在图里。 */
  @Builder
  AboutSideImage(kind: string) {
    if (kind === 'about') {
      Image(this.isDark ? $r('app.media.About_Dark') : $r('app.media.About'))
        .width(100)
        .height(100)
        .objectFit(ImageFit.Contain)
    } else if (kind === 'pc') {
      Image(this.isDark ? $r('app.media.PC_Dark') : $r('app.media.PC'))
        .width(100)
        .height(100)
        .objectFit(ImageFit.Contain)
    } else {
      Image(this.isDark ? $r('app.media.Privacy_Dark') : $r('app.media.Privacy'))
        .width(100)
        .height(100)
        .objectFit(ImageFit.Contain)
    }
  }

  // ============================================================
  // 复用构件
  // ============================================================

  /** 等分标签。选中项蓝色加粗，下方短下划线。 */
  @Builder
  TabBarBuilder(title: string, index: number) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontColor(this.currentTab === index ? theme.accentColor : theme.secondaryTextColor)
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Medium)
      Column()
        .width(40)
        .height(2)
        .margin({ top: 8 })
        .borderRadius(1)
        .backgroundColor(this.currentTab === index ? theme.accentColor : Color.Transparent)
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
  }

  /** 复选框 + 文字（每个独立 group，互不影响）
   *  enabled=false 时灰显禁用（用于鸿蒙无法实现的 Windows 专属选项） */
  @Builder
  CheckRow(title: string, checked: boolean, onChange: (v: boolean) => void, enabled?: boolean) {
    Row() {
      Checkbox({ name: title, group: title })
        .select(checked)
        .selectedColor(theme.accentColor)
        .enabled(enabled !== false)
        .width(20)
        .height(20)
        .onChange((value: boolean) => {
          onChange(value);
        })
      Text(title)
        .fontSize(16)
        .fontColor(enabled !== false ? theme.textColor : theme.mutedTextColor)
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .height(32)
    .opacity(enabled !== false ? 1 : 0.7)
  }

  /** 单选均匀铺开，和稿里的三列/两列一致。 */
  @Builder
  RadioSpread(groupHint: string, selected: number, items: RadioOption[], onChange: (v: number) => void) {
    Row() {
      ForEach(items, (item: RadioOption) => {
        Row() {
          Radio({ value: `${groupHint}_${item.value}`, group: groupHint })
            .checked(selected === item.value)
            .onChange((checked: boolean) => {
              if (checked) {
                onChange(item.value);
              }
            })
          Text(item.label)
            .fontSize(16)
            .fontColor(theme.textColor)
            .margin({ left: 8 })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }, (item: RadioOption) => `${groupHint}_${item.value}`)
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
  }

  /** 单行单选（独占一行的 Radio + 文字） */
  @Builder
  RadioRow(groupHint: string, value: string, myValue: number, selected: number, label: string,
    onChange: (v: number) => void, enabled?: boolean) {
    Row() {
      Radio({ value: value, group: groupHint })
        .checked(selected === myValue)
        .enabled(enabled !== false)
        .onChange((checked: boolean) => {
          if (checked && enabled !== false) {
            onChange(myValue);
          }
        })
      Text(label)
        .fontSize(16)
        .fontColor(enabled !== false ? theme.textColor : theme.mutedTextColor)
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .onClick(() => {
      if (enabled !== false) {
        onChange(myValue);
      }
    })
  }

  /** 只读路径。配置目录由沙箱固定，不提供浏览。 */
  @Builder
  FolderLine(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(16)
        .fontColor(theme.textColor)
        .width(64)
      Row() {
        Text(value)
          .width('100%')
          .fontSize(16)
          .fontColor(theme.textColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height(40)
      .padding({ left: 12, right: 12 })
      .backgroundColor(theme.contentBgColor)
      .border({ width: 1, color: theme.borderColor })
      .borderRadius(8)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
