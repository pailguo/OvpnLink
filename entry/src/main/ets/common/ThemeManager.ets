import { ConfigurationConstant } from '@kit.AbilityKit';

/**
 * 深浅色主题。
 * EntryAbility 把系统 colorMode 写入 AppStorage('isDark')，界面用 @StorageLink 跟着刷新。
 */
export class ThemeManager {
  private static instance: ThemeManager | null = null;
  private _isDark: boolean = false;

  private constructor() {}

  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  /** 在 EntryAbility.onCreate 里、写入 colorMode 之后调用。 */
  init(): void {
    const colorMode: number | undefined = AppStorage.get('colorMode');
    this._isDark = this.colorModeToIsDark(colorMode);
    AppStorage.setOrCreate('isDark', this._isDark);
  }

  /** 在 EntryAbility.onConfigurationUpdate 里调用。 */
  applyColorMode(colorMode: number | undefined): void {
    this._isDark = this.colorModeToIsDark(colorMode);
    AppStorage.setOrCreate('isDark', this._isDark);
  }

  get isDark(): boolean {
    return this._isDark;
  }

  private colorModeToIsDark(colorMode: number | undefined): boolean {
    if (colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return true;
    }
    return false;
  }

  /** 设置页、编辑页这类灰底。 */
  get pageBgColor(): string {
    return this._isDark ? '#1A1A1A' : '#F1F3F5';
  }

  /** 卡片、对话框、主窗口。 */
  get contentBgColor(): string {
    return this._isDark ? '#1E1E1E' : '#FFFFFF';
  }

  /** 白底输入框。深色下略抬起，和卡片分开。 */
  get inputBgColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.08)' : '#FFFFFF';
  }

  /** 主文本。 */
  get textColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.9)' : 'rgba(0, 0, 0, 0.9)';
  }

  /** 说明、占位。 */
  get secondaryTextColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.6)' : 'rgba(0, 0, 0, 0.6)';
  }

  /** 禁用文字。 */
  get mutedTextColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.4)' : 'rgba(0, 0, 0, 0.4)';
  }

  /** 输入框描边。 */
  get borderColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.15)' : '#E5E5E5';
  }

  /** 浅分割线。 */
  get hairlineColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.05)';
  }

  /** 次级按钮、认证框输入底。 */
  get componentBgColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.05)';
  }

  /** 强调蓝。 */
  get accentColor(): string {
    return this._isDark ? '#317AF7' : '#0A59F7';
  }

  /** 日志区浅底。 */
  get accentSoftBgColor(): string {
    return this._isDark ? 'rgba(49, 122, 247, 0.16)' : 'rgba(10, 89, 247, 0.05)';
  }

  /** 关于页图标底。 */
  get accentBadgeBgColor(): string {
    return this._isDark ? 'rgba(49, 122, 247, 0.22)' : '#E8F3FF';
  }

  /** 蓝底按钮上的字，深浅都用白。 */
  get selectedTextColor(): string {
    return '#FFFFFF';
  }

  /** 错误、重试提示。 */
  get dangerColor(): string {
    return this._isDark ? '#F54A3A' : '#E84026';
  }

  /** 对话框遮罩。 */
  get overlayColor(): string {
    return this._isDark ? 'rgba(0, 0, 0, 0.72)' : '#00000060';
  }

  /** 手动代理未启用时盖住表单。 */
  get disabledFillColor(): string {
    return this._isDark ? 'rgba(255, 255, 255, 0.04)' : '#0D000000';
  }

  get logErrorColor(): string {
    return this._isDark ? '#FF6B6B' : '#D1242F';
  }

  get logWarnColor(): string {
    return this._isDark ? '#E6A23C' : '#C67B00';
  }

  get shadowColor(): string {
    return this._isDark ? '#80000000' : '#33000000';
  }
}

export const theme = ThemeManager.getInstance();
