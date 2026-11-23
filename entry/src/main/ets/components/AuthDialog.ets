/**
 * AuthDialog.ets
 * 认证对话框 - 对应 Windows GUI 的 passphrase.c 和 proxy.c
 *
 * 功能：
 * - 用户名/密码输入
 * - 私钥口令输入
 * - 保存密码选项
 */

import { theme } from '../common/ThemeManager';

// 认证类型
export enum AuthType {
  USERNAME_PASSWORD,  // 用户名/密码
  PRIVATE_KEY,        // 私钥口令
  CHALLENGE_RESPONSE  // 挑战响应
}

// 认证结果
export interface AuthResult {
  username?: string;
  password?: string;
  passphrase?: string;
  savePassword: boolean;
}

@CustomDialog
export struct AuthDialog {
  @StorageLink('isDark') isDark: boolean = false;
  controller: CustomDialogController;
  authType: AuthType = AuthType.USERNAME_PASSWORD;
  title: string = '身份验证';
  prompt: string = '请输入您的凭据';
  onConfirm?: (result: AuthResult) => void;
  onCancel?: () => void;

  @State username: string = '';
  @State password: string = '';
  @State passphrase: string = '';
  @State savePassword: boolean = false;
  @State showPassword: boolean = false;

  build() {
    Column({ space: 20 }) {
      // 标题
      Row() {
        Image($r('app.media.Logo_Foreground'))
          .width(32)
          .height(32)
          .margin({ right: 12 })

        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(theme.textColor)
      }
      .width('100%')

      // 提示信息
      if (this.prompt) {
        Text(this.prompt)
          .fontSize(14)
          .fontColor(theme.secondaryTextColor)
          .width('100%')
      }

      // 输入区域
      if (this.authType === AuthType.USERNAME_PASSWORD) {
        this.UsernamePasswordInput()
      } else if (this.authType === AuthType.PRIVATE_KEY) {
        this.PrivateKeyInput()
      }

      // 保存密码选项
      Row() {
        Checkbox({ name: 'save-password', group: 'auth' })
          .select(this.savePassword)
          .onChange((value: boolean) => {
            this.savePassword = value;
          })

        Text('保存密码')
          .fontSize(14)
          .fontColor(theme.textColor)
          .margin({ left: 8 })
      }
      .width('100%')

      // 按钮
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor(theme.componentBgColor)
          .fontColor(theme.textColor)
          .onClick(() => {
            if (this.onCancel) {
              this.onCancel();
            }
            this.controller.close();
          })

        Button('确定')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor(theme.accentColor)
          .fontColor(theme.selectedTextColor)
          .onClick(() => {
            const result: AuthResult = {
              username: this.username,
              password: this.password,
              passphrase: this.passphrase,
              savePassword: this.savePassword
            };

            if (this.onConfirm) {
              this.onConfirm(result);
            }
            this.controller.close();
          })
      }
      .width('100%')
    }
    .padding(24)
    .backgroundColor(this.isDark ? theme.contentBgColor : theme.contentBgColor)
    .borderRadius(12)
  }

  @Builder
  UsernamePasswordInput() {
    Column({ space: 12 }) {
      // 用户名
      Column({ space: 6 }) {
        Text('用户名')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.textColor)
          .width('100%')

        TextInput({ placeholder: '请输入用户名', text: this.username })
          .width('100%')
          .height(40)
          .fontSize(14)
          .onChange((value: string) => {
            this.username = value;
          })
      }
      .alignItems(HorizontalAlign.Start)

      // 密码
      Column({ space: 6 }) {
        Text('密码')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.textColor)
          .width('100%')

        Row() {
          TextInput({
            placeholder: '请输入密码',
            text: this.password
          })
            .width('100%')
            .height(40)
            .fontSize(14)
            .type(this.showPassword ? InputType.Normal : InputType.Password)
            .onChange((value: string) => {
              this.password = value;
            })

          Button(this.showPassword ? '👁' : '👁‍🗨')
            .width(40)
            .height(40)
            .fontSize(18)
            .backgroundColor(theme.componentBgColor)
            .position({ x: '100%', y: 0 })
            .translate({ x: -40 })
            .onClick(() => {
              this.showPassword = !this.showPassword;
            })
        }
        .width('100%')
        .position({ x: 0, y: 0 })
      }
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  PrivateKeyInput() {
    Column({ space: 6 }) {
      Text('私钥口令')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.textColor)
        .width('100%')

      TextInput({
        placeholder: '请输入私钥口令',
        text: this.passphrase
      })
        .width('100%')
        .height(40)
        .fontSize(14)
        .type(this.showPassword ? InputType.Normal : InputType.Password)
        .onChange((value: string) => {
          this.passphrase = value;
        })
    }
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 显示认证对话框的辅助函数
 */
export function showAuthDialog(
  authType: AuthType,
  title: string,
  prompt: string,
  onConfirm: (result: AuthResult) => void,
  onCancel?: () => void
): void {
  const dialogController: CustomDialogController = new CustomDialogController({
    builder: AuthDialog({
      authType: authType,
      title: title,
      prompt: prompt,
      onConfirm: onConfirm,
      onCancel: onCancel
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  dialogController.open();
}
