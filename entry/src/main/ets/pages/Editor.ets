/**
 * Editor.ets
 * 配置编辑器 - 对齐原版托盘菜单 "Edit Config"（调记事本编辑 .ovpn）
 *
 * 功能：
 * - TextArea 等宽字体编辑 .ovpn 内容
 * - 保存前自动备份 .bak（防误改）
 * - 保存后返回主界面（连接中的配置，OpenVPN 重连时读新文件）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import fs from '@ohos.file.fs';
import { promptAction } from '@kit.ArkUI';
import { theme } from '../common/ThemeManager';

const DOMAIN = 0x0001;
const TAG = 'OpenVpnEditor';


@Entry
@Component
struct Editor {
  @StorageLink('isDark') isDark: boolean = false;
  @State content: string = '';
  @State filePath: string = '';
  @State fileName: string = '';
  @State fontSize: number = 14;
  @State dirty: boolean = false;

  aboutToAppear(): void {
    try {
      const params = router.getParams() as Record<string, Object>;
      this.filePath = (params['path'] as string) ?? '';
      this.fileName = (params['name'] as string) ?? 'unknown.ovpn';
      if (this.filePath.length > 0) {
        const file = fs.openSync(this.filePath, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        fs.closeSync(file);
        this.content = String.fromCharCode(...new Uint8Array(buf));
      }
      hilog.info(DOMAIN, TAG, `editor opened: ${this.fileName}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load error: %{public}s', JSON.stringify(e));
    }
  }

  private saveFile(): void {
    try {
      /* 保存前自动备份（对齐原版"编辑配置"安全习惯：.bak 防误改） */
      const bakPath: string = `${this.filePath}.bak`;
      try {
        if (fs.accessSync(bakPath)) {
          fs.unlinkSync(bakPath);
        }
        fs.copyFileSync(this.filePath, bakPath);
      } catch (bakErr) {
        hilog.warn(DOMAIN, TAG, 'backup skip: %{public}s', JSON.stringify(bakErr));
      }

      /* 写回新内容 */
      const file = fs.openSync(this.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.content);
      fs.closeSync(file);
      this.dirty = false;
      hilog.info(DOMAIN, TAG, `saved: ${this.fileName}`);
      promptAction.showToast({ message: `已保存 ${this.fileName}（备份 .bak）`, duration: 2000 });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save error: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: `保存失败: ${JSON.stringify(e)}`, duration: 3000 });
    }
  }

  private backPage(): void {
    if (this.dirty) {
      /* 未保存退出提示（对齐原版：关闭记事本未保存会询问） */
      promptAction.showDialog({
        title: '未保存的更改',
        message: '内容已修改但未保存，是否保存？',
        buttons: [
          { text: '放弃', color: theme.dangerColor },
          { text: '保存', color: '#64BB5C' }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index === 1) {
          this.saveFile();
        }
        router.back();
      }).catch(() => {
        router.back();
      });
    } else {
      router.back();
    }
  }

  build() {
    Column() {
      // ============ 顶部工具栏 ============
      Row({ space: 8 }) {
        Button('← 返回')
          .height(32)
          .fontSize(13)
          .backgroundColor(theme.componentBgColor)
          .fontColor(theme.textColor)
          .onClick(() => {
            this.backPage();
          })

        Text(this.fileName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.textColor)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.dirty ? '*' : '')
          .fontSize(16)
          .fontColor(theme.dangerColor)

        Button('A-')
          .width(60)
          .height(32)
          .fontSize(12)
          .backgroundColor(theme.componentBgColor)
          .fontColor(theme.textColor)
          .onClick(() => {
            this.fontSize = Math.max(10, this.fontSize - 2);
          })

        Button('A+')
          .width(60)
          .height(32)
          .fontSize(12)
          .backgroundColor(theme.componentBgColor)
          .fontColor(theme.textColor)
          .onClick(() => {
            this.fontSize = Math.min(20, this.fontSize + 2);
          })

        Button('保存')
          .height(32)
          .fontSize(13)
          .fontColor(theme.selectedTextColor)
          .backgroundColor(theme.accentColor)
          .onClick(() => {
            this.saveFile();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(theme.contentBgColor)
      .border({ width: { bottom: 1 }, color: theme.borderColor })

      // ============ 编辑区（等宽字体可滚动） ============
      TextArea({ text: this.content, placeholder: '配置文件内容...' })
        .layoutWeight(1)
        .width('100%')
        .fontSize(this.fontSize)
        .fontFamily('monospace')
        .fontColor(theme.textColor)
        .placeholderColor(theme.secondaryTextColor)
        .caretColor(theme.accentColor)
        .backgroundColor(theme.contentBgColor)
        .onChange((value: string) => {
          this.content = value;
          this.dirty = true;
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? theme.pageBgColor : theme.pageBgColor)
  }
}
