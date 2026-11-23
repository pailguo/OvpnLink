/**
 * 从 Access Server 或 URL 下载 .ovpn，写入配置目录。
 * 对应原版 openvpn-gui as.c 的两个导入对话框。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import util from '@ohos.util';
import fs from '@ohos.file.fs';
import { SettingsStore, VpnSettings } from '../common/SettingsStore';
import { AppWindows, PROFILE_IMPORTED_EVENT } from '../common/AppWindows';
import { theme } from '../common/ThemeManager';

const DOMAIN: number = 0x0001;
const TAG: string = 'ImportProfile';
const FRIENDLY: string = '# OVPN_ACCESS_SERVER_FRIENDLY_NAME=';
const PROFILE: string = '# OVPN_ACCESS_SERVER_PROFILE=';

@Entry
@Component
struct ImportProfile {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageLink('importKind') importKind: string = 'url';
  @State urlText: string = '';
  @State username: string = '';
  @State password: string = '';
  @State autologin: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';

  private closePage(): void {
    AppWindows.closeImport();
  }

  private async onConfirm(): Promise<void> {
    if (this.busy) {
      return;
    }
    const urlInput: string = this.urlText.trim();
    const user: string = this.username.trim();
    if (urlInput.length === 0 || user.length === 0) {
      this.message = '请填写地址和用户名';
      return;
    }
    this.busy = true;
    this.message = '正在下载…';
    try {
      const requestUrl: string = this.importKind === 'as' ? this.buildAsUrl(urlInput) : this.normalizeUrl(urlInput);
      const body: string = await this.download(requestUrl, user, this.password);
      if (body.length === 0) {
        this.message = '服务器返回了空内容';
        this.busy = false;
        return;
      }
      const saved: string = await this.saveProfile(body, requestUrl);
      if (saved.length === 0) {
        this.busy = false;
        return;
      }
      AppStorage.setOrCreate('importedConfigName', saved);
      emitter.emit({ eventId: PROFILE_IMPORTED_EVENT });
      this.closePage();
    } catch (e) {
      const err: Error = e as Error;
      const text: string = err.message !== undefined && err.message.length > 0 ? err.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', text);
      if (text.indexOf('401') >= 0 || text.indexOf('403') >= 0) {
        this.message = '账号或密码不正确';
      } else if (text === '地址无效') {
        this.message = '地址无效';
      } else {
        this.message = '下载失败，请检查地址、账号和网络';
      }
      this.busy = false;
    }
  }

  private normalizeUrl(input: string): string {
    if (input.indexOf('://') >= 0) {
      return input;
    }
    return `https://${input}`;
  }

  /** 用户填的主机拼成 Access Server 的 REST 地址。 */
  private buildAsUrl(input: string): string {
    let raw: string = input.trim();
    let https: boolean = true;
    if (raw.indexOf('http://') === 0) {
      https = false;
      raw = raw.substring('http://'.length);
    } else if (raw.indexOf('https://') === 0) {
      raw = raw.substring('https://'.length);
    }
    const slash: number = raw.indexOf('/');
    const hostPort: string = slash >= 0 ? raw.substring(0, slash) : raw;
    let host: string = hostPort;
    let port: number = https ? 443 : 80;
    if (hostPort.startsWith('[')) {
      const end: number = hostPort.indexOf(']');
      if (end > 1) {
        host = hostPort.substring(0, end + 1);
        if (hostPort.length > end + 2 && hostPort.substring(end + 1, end + 2) === ':') {
          const parsed: number = parseInt(hostPort.substring(end + 2), 10);
          if (parsed > 0) {
            port = parsed;
          }
        }
      }
    } else {
      const colon: number = hostPort.lastIndexOf(':');
      if (colon > 0) {
        host = hostPort.substring(0, colon);
        const parsed: number = parseInt(hostPort.substring(colon + 1), 10);
        if (parsed > 0) {
          port = parsed;
        }
      }
    }
    if (host.length === 0) {
      throw new Error('地址无效');
    }
    const action: string = this.autologin ? 'GetAutologin' : 'GetUserlogin';
    const scheme: string = https ? 'https' : 'http';
    const defaultPort: boolean = (https && port === 443) || (!https && port === 80);
    const portText: string = defaultPort ? '' : `:${port}`;
    return `${scheme}://${host}${portText}/rest/${action}?tls-cryptv2=1&action=import`;
  }

  private basicToken(user: string, pass: string): string {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(`${user}:${pass}`);
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes, util.Type.BASIC);
  }

  private async download(url: string, user: string, pass: string): Promise<string> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Authorization': `Basic ${this.basicToken(user, pass)}`,
        'Accept': 'application/x-openvpn-profile'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 30000,
        readTimeout: 30000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };
      const response: http.HttpResponse = await client.request(url, options);
      if (response.responseCode !== 200) {
        throw new Error(`http ${response.responseCode}`);
      }
      const result: string | Object | ArrayBuffer = response.result as string | Object | ArrayBuffer;
      if (typeof result === 'string') {
        return result;
      }
      return '';
    } finally {
      client.destroy();
    }
  }

  private tagValue(body: string, token: string): string {
    const lines: string[] = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      let line: string = lines[i];
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.indexOf(token) === 0) {
        return line.substring(token.length).trim();
      }
    }
    return '';
  }

  private sanitize(name: string): string {
    let out: string = '';
    const bad: string = '<>:"/\\|?*;';
    for (let i = 0; i < name.length; i++) {
      const ch: string = name.substring(i, i + 1);
      const code: number = name.charCodeAt(i);
      if (code < 32 || bad.indexOf(ch) >= 0) {
        out += '_';
      } else {
        out += ch;
      }
    }
    return out.trim();
  }

  private hostFallback(url: string): string {
    let raw: string = url;
    const scheme: number = raw.indexOf('://');
    if (scheme >= 0) {
      raw = raw.substring(scheme + 3);
    }
    const slash: number = raw.indexOf('/');
    if (slash >= 0) {
      raw = raw.substring(0, slash);
    }
    const colon: number = raw.lastIndexOf(':');
    if (colon > 0 && raw.indexOf(']') < 0) {
      raw = raw.substring(0, colon);
    }
    if (raw.length === 0) {
      return 'imported';
    }
    return raw;
  }

  private profileBase(body: string, requestUrl: string): string {
    const friendly: string = this.tagValue(body, FRIENDLY);
    const profile: string = this.tagValue(body, PROFILE);
    let name: string = friendly.length > 0 ? friendly : profile;
    if (name.length === 0) {
      name = this.hostFallback(requestUrl);
    }
    name = this.sanitize(name);
    if (name.toLowerCase().endsWith('.ovpn')) {
      name = name.substring(0, name.length - '.ovpn'.length);
    }
    if (name.length === 0) {
      name = 'imported';
    }
    return name;
  }

  private fileExists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 写入配置目录。用户拒绝覆盖时返回空字符串。 */
  private async saveProfile(body: string, requestUrl: string): Promise<string> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await SettingsStore.getInstance().init(context);
    const settings: VpnSettings = await SettingsStore.getInstance().get();
    let ext: string = 'ovpn';
    if (settings.configExt.length > 0) {
      ext = settings.configExt.toLowerCase();
      if (ext.startsWith('.')) {
        ext = ext.substring(1);
      }
    }
    let dir: string = `${context.filesDir}/config`;
    if (settings.configDir.length > 0) {
      dir = settings.configDir;
    }
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 目录已存在
    }
    const base: string = this.profileBase(body, requestUrl);
    const dest: string = `${dir}/${base}.${ext}`;
    if (this.fileExists(dest)) {
      const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: 'OpenVPN GUI',
        message: `名为'${base}'的配置已存在。您想替换它吗？`,
        buttons: [
          { text: '是', color: theme.accentColor },
          { text: '否', color: theme.textColor }
        ]
      });
      if (choice.index !== 0) {
        this.message = '已取消';
        return '';
      }
    }
    const file: fs.File = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, body);
    fs.closeSync(file);
    hilog.info(DOMAIN, TAG, 'saved %{public}s', dest);
    return base;
  }

  build() {
    Column() {
      Row() {
        Row() {
          Text(this.importKind === 'as' ? '从 Access Server 导入' : '从 URL 导入')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(theme.textColor)
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(VerticalAlign.Center)
        .onMouse((event: MouseEvent) => {
          if (event.button === MouseButton.Left && event.action === MouseAction.Press) {
            AppWindows.startMoveImport();
          }
        })
        Row(){
          Image($r('app.media.Close_Btn'))
            .height(24)
            .width(24)
            .fillColor(theme.textColor)
            .onClick(() => {
              this.closePage();
            })
        }.height('100%')
      }
      .width('100%')
      .height(56)
      .padding({ left: 24, right: 24 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(theme.contentBgColor)

      Column({ space: 28 }) {
        Column({space:9}){
          Text(this.importKind === 'as' ? '服务地址' : '配置URL')
            .fontSize(16)
            .fontColor(theme.textColor)
            .width('100%')
          TextInput({ text: this.urlText, placeholder: this.importKind === 'as' ? 'vpn.example.com' : 'https://example.com/profile.ovpn' })
            .width('100%')
            .height(36)
            .fontColor(theme.textColor)
            .placeholderColor(theme.secondaryTextColor)
            .caretColor(theme.accentColor)
            .backgroundColor(theme.inputBgColor)
            .borderRadius(8)
            .onChange((value: string) => {
              this.urlText = value;
            })
        }

        Column({space:9}){
          Text('用户名')
            .fontSize(16)
            .fontColor(theme.textColor)
            .width('100%')
          TextInput({ text: this.username, placeholder: '用户名' })
            .width('100%')
            .height(36)
            .fontColor(theme.textColor)
            .placeholderColor(theme.secondaryTextColor)
            .caretColor(theme.accentColor)
            .backgroundColor(theme.inputBgColor)
            .borderRadius(8)
            .onChange((value: string) => {
              this.username = value;
            })
        }

        Column({space:9}){
          Text('密码')
            .fontSize(16)
            .fontColor(theme.textColor)
            .width('100%')
          TextInput({ text: this.password, placeholder: '密码' })
            .type(InputType.Password)
            .width('100%')
            .height(36)
            .fontColor(theme.textColor)
            .placeholderColor(theme.secondaryTextColor)
            .caretColor(theme.accentColor)
            .backgroundColor(theme.inputBgColor)
            .borderRadius(8)
            .onChange((value: string) => {
              this.password = value;
            })
        }

        if (this.importKind === 'as') {
          Row() {
            Checkbox()
              .select(this.autologin)
              .selectedColor(theme.accentColor)
              .onChange((value: boolean) => {
                this.autologin = value;
              })
            Text('自动登录')
              .fontSize(16)
              .fontColor(theme.textColor)
              .margin({ left: 8 })
          }
          .width('100%')
        }

        Text(this.message)
          .fontSize(12)
          .fontColor(theme.dangerColor)
          .width('100%')
          .maxLines(2)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
      .alignItems(HorizontalAlign.Start)

      Row({ space: 8 }) {
        Blank()
        Button('取消')
          .width(120)
          .height(40)
          .fontSize(16)
          .fontColor(theme.accentColor)
          .backgroundColor(theme.componentBgColor)
          .onClick(() => {
            this.closePage();
          })
          .borderRadius(8)
        Button('确定')
          .width(120)
          .height(40)
          .fontSize(16)
          .fontColor(theme.selectedTextColor)
          .backgroundColor(theme.accentColor)
          .borderRadius(8)
          .enabled(!this.busy)
          .onClick(() => {
            this.onConfirm();
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8, bottom: 16 })
    }
    .width('100%')
    .backgroundColor(this.isDark ? theme.contentBgColor : theme.contentBgColor)
  }
}
