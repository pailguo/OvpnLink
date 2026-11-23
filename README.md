# OvpnLink · HarmonyOS OpenVPN 客户端

OvpnLink 是面向 HarmonyOS 平板与 PC / 二合一设备的 OpenVPN 客户端。界面使用 ArkTS / ArkUI，连接核心使用移植后的 OpenVPN 2.x，通过 N-API 与系统 VPN 扩展协作，实现配置导入、连接管理、认证交互、托盘操作和连接日志。

本项目参考 Windows OpenVPN GUI 的操作方式，但并非其全部功能的等价移植，也不是 OpenVPN 官方发布的 HarmonyOS 客户端。使用前需要自行准备有权访问的 VPN 服务端及客户端配置；项目不提供 VPN 账号或公共节点。

## 环境与版本

| 项目 | 当前工程配置 |
| --- | --- |
| 应用版本 | `1.0.0` |
| 目标设备 | `tablet`、`2in1`；托盘和多窗口体验主要面向 PC / 二合一设备 |
| 目标 / 最低兼容 SDK | HarmonyOS `6.1.1(24)` / API 24 |
| 工程与 Hvigor 模型 | `6.1.1` |
| Native ABI | `arm64-v8a` |
| OpenVPN 核心 | `2.7.6` |
| OpenSSL | 随仓库提供 ARM64 静态库及头文件；头文件版本标识为 `3.5.1` |
| 默认包名 | `com.practical.opensource.OvpnLink` |

配置依据：[应用配置](<AppScope/app.json5>)、[工程构建配置](<build-profile.json5>)、[模块构建配置](<entry/build-profile.json5>)、[模块声明](<entry/src/main/module.json5>)及 [Native 构建入口](<entry/src/main/cpp/CMakeLists.txt>)。切换分支后请以对应分支的实际配置为准。

> 工程使用 HarmonyOS API 24 的系统能力，不能仅凭“设备支持 HarmonyOS”就判断兼容。请使用满足 SDK、架构和系统能力要求的真机验证；ArkUI 预览不能代替 VPN、托盘及网络恢复验证。

## 主要功能

- **配置管理**：从系统文件选择器导入配置，支持从 URL 或 OpenVPN Access Server 下载；同名配置替换前确认。
- **连接管理**：UDP / TCP 连接、断开、重新连接、切换配置；显示连接状态、分配的隧道 IP、收发字节数和日志。
- **认证交互**：用户名 / 密码、可选 OTP 手动拼接提示、代理认证、认证失败重试、按配置记住用户名或保存密码。
- **托盘操作**：显示主窗口，按配置连接、断开、重连、查看日志、打开配置文件、清除已保存密码，以及进入导入和选项页面。
- **窗口与主题**：主窗口、独立设置 / 导入窗口、跟随系统的深浅色主题；关闭主窗口与退出应用分别处理。
- **网络集成**：由系统 VPN 扩展创建 TUN，保护到服务端的 socket，接收服务端 DNS 推送，并处理已接入的 IPv6 地址和路由信息。
- **代理与通知**：配置文件代理、系统 HTTP 代理、手动 HTTP / SOCKS 代理，以及可配置的连接通知。HTTP 代理仅适用于 TCP 隧道。

“多份配置”表示可以保存和选择多份配置，**不表示可以同时运行多个 VPN 连接**。具体边界见[已知限制](#已知限制)。

## 开发与构建

### 1. 准备工具

- 安装支持当前工程模型的 DevEco Studio。
- 在 SDK 管理器中准备 HarmonyOS API 24，以及匹配的 Native 编译工具链；工程配置使用 BiSheng。
- 使用 DevEco Studio 配套的 OHPM、Hvigor 和 Node.js，避免混用不匹配的全局工具版本。
- 准备符合设备要求的应用签名配置和可调试的 ARM64 真机。

在 DevEco Studio 中打开**本 README 所在目录**，而不是外层工作区。该目录同时包含 [Hvigor 入口](<hvigorfile.ts>)和 [OHPM 配置](<oh-package.json5>)。

### 2. 同步依赖

通过 DevEco Studio 同步工程。若使用已配置好 OHPM 的终端，在工程根目录执行：

```shell
ohpm install
```

[模块依赖配置](<entry/oh-package.json5>)通过本地类型声明引用 `libentry.so`；该库由 CMake 构建，不是需要单独从 OHPM 下载的 OpenVPN 二进制包。

Native 构建所需的以下内容已随仓库提供：

```text
entry/src/main/cpp/core/                       OpenVPN 移植源码
entry/src/main/cpp/core/build-ohos/config.h    平台配置宏
entry/src/main/cpp/core/build-ohos/config-version.h
entry/src/main/cpp/libs/include/               OpenSSL 头文件
entry/src/main/cpp/libs/arm64-v8a/libcrypto.a
entry/src/main/cpp/libs/arm64-v8a/libssl.a
```

只需构建本鸿蒙工程，不要求额外构建外层工作区中的 Windows OpenVPN。若调整核心版本、ABI 或 OpenSSL，请同时核对源码、平台配置、头文件与静态库，不能只修改界面版本字符串。

### 3. 配置签名

在 DevEco Studio 的签名设置中配置自己的证书和 Profile，并更新 [工程构建配置](<build-profile.json5>)中的签名引用。不要直接复用其他开发者的本机路径、签名私钥或签名密码。

如需更换包名或制作并存安装包，不能只改 [应用配置](<AppScope/app.json5>)：还需检查 [VPN IPC](<entry/src/main/ets/common/VpnIpc.ets>)、[托盘保活](<entry/src/main/ets/tray/TrayKeepAlive.ets>)、[后台 Ability](<entry/src/main/ets/backgroundability/BackGroundAbility.ets>)中的包名及事件作用域，并同步修改调试命令。

### 4. 构建与安装

选择 `default` product、`entry` 模块和 `default` target，通过 DevEco Studio 执行 HAP 构建；按需要选择 `debug` 或 `release`。对应 Hvigor 构建任务为 `assembleHap`。

默认构建输出目录：

```text
entry/build/default/outputs/default/
```

签名配置成功时可生成签名 HAP。使用 DevEco Studio 部署到已选择的真机；若通过 HDC 安装，请先确认设备序列号，避免多设备环境中安装到错误设备。

首次运行和连接时，按系统提示处理 VPN 授权、通知授权等请求。仅完成安装不代表已经建立 VPN 隧道。

## 使用说明

### 导入配置

1. 从 VPN 管理员获取客户端配置，通常为 `.ovpn` 文件。不要把服务端配置当作客户端配置导入。
2. 打开托盘菜单中的 **导入 → 导入配置文件…**，选择文件；当前文件选择器一次导入一份。
3. 若已有同名配置，确认是否替换。文件名中的 `.udp`、`.tcp` 会保留，因此 `office.udp.ovpn` 和 `office.tcp.ovpn` 是不同配置。
4. 导入后重新扫描配置列表。新增配置不会主动断开正在使用的连接；需要切换时再选择另一份配置连接。

建议使用包含所需证书和密钥的**单文件配置**，例如按服务端要求内嵌 `<ca>`、`<cert>`、`<key>`、`<tls-crypt>`。文件导入只复制选中的配置文件，不会自动复制它引用的外部证书、私钥或认证文件；Windows 绝对路径也不能直接用于鸿蒙沙箱。

默认配置目录为应用私有目录下的 `files/config`，当前默认沙箱路径为：

```text
/data/storage/el2/base/haps/entry/files/config
```

以应用实际显示的配置目录为准。普通系统文件管理器不一定能访问应用私有目录，日常使用建议走文件选择器。没有配置时，点击提示框的“确定”只收起主窗口，仍可从托盘导入配置。

**URL / Access Server 导入注意事项：**

- 当前实现要求填写地址和非空用户名，使用 HTTP Basic 认证下载，不是通用匿名下载器。
- Access Server 使用 `GetUserlogin` / `GetAutologin` REST 接口；不代表兼容所有部署方式，也未实现完整的 SSO / 多步 MFA 登录流程。
- 请仅使用可信的 **HTTPS** 地址。实现仍接受显式 HTTP 地址，但 HTTP Basic 的 Base64 编码不是加密，不要通过明文 HTTP 提交账号密码。
- 下载成功并不等于配置有效；连接时仍需通过 OpenVPN 的参数解析、证书检查和服务端认证。

### 连接与认证

从托盘选择配置并点击“连接”，或在主窗口对当前配置发起连接。需要账号密码时显示认证框；纯证书配置不一定要求用户名和密码。

- 可按配置保存密码或仅记住用户名；已保存密码的认证框支持倒计时自动提交。
- OTP 选项仅提示用户将动态口令手动追加到密码后，不生成动态口令，也不提供通用多步 MFA 流程。
- 认证失败后可重新输入；取消认证会停止本次连接。
- 认证框显示期间请求系统隐私窗口保护，结束后恢复正常窗口隐私设置。
- 连接另一份配置时先停止当前会话，再启动新会话。

确认状态为“已连接”后，还应访问隧道内目标地址或业务服务验证数据通路。证书握手成功并不保证服务端转发、NAT、DNS 和业务防火墙已经配置正确。

### 隐藏、退出与窗口模式

| 操作 | 行为 |
| --- | --- |
| 主窗口右上角关闭 / “隐藏” | 收起主窗口，保留进程和托盘，不主动断开 VPN |
| 无配置提示的“确定” | 收起主窗口，再次打开且仍无配置时继续显示提示 |
| 托盘显示主窗口 | 唤起窗口；最小化时恢复，不强制退出最大化 / 全屏 / 分屏 |
| 弹出认证框 | 在主界面内展示，不强制恢复为初始窗口大小 |
| 托盘或 Dock 退出 | 有活动连接时先确认；确认后停止 VPN 并结束应用 |

### UDP、TCP 与断网重连

UDP 和 TCP 是到 VPN 服务端的外层传输方式，并不限制隧道内只能运行同类业务。一般优先使用 UDP；UDP 受限或需要 HTTP 代理时可使用 TCP。两份独立配置不会因为其中一份失败就自动互相切换。

断网后，业务流量可能先停止，而界面短时间仍显示“已连接”。客户端主要按 OpenVPN 核心状态更新界面，检测超时或底层连接错误后通常进入“重新连接中…”或“连接中…”。

例如服务端采用 `keepalive 10 60` 且客户端接受其推送时，客户端通常在约 60 秒收不到对端有效包后触发重连；这不是所有配置的固定超时。网络恢复后的重连速度还取决于重试退避、服务器可达性和认证结果。

“活动连接自动重新启动”是应用启动后的恢复逻辑，不是系统开机自启；“持久连接：自动”还会在符合条件的非主动退出后尝试重新启动连接。用户主动点击“断开连接”不应按网络故障自动重连。

## 开发调试命令

应用通过 `EntryAbility` 的 Want 参数接收命令，不是直接在设备上运行桌面版 `openvpn.exe`。先正常启动应用、完成所需授权并导入配置，再进行命令调试。

以下为 PowerShell 示例；仅供开发者手动执行：

## 架构与代码导航

```text
ArkUI 主界面 / 托盘
        │ 连接命令、状态、日志、流量统计
        ▼
VpnIpc：应用内公共事件 + 沙箱文件兜底
        ▼
VpnExtAbility：系统独立 VPN 扩展进程
        ├─ VpnServiceManager → 系统 VpnConnection / TUN / socket protect
        └─ N-API → OpenVPN bridge → OpenVPN 2.x + OpenSSL
                           ↕
                    Unix management socket
```

OpenVPN 核心、TUN 文件描述符及 socket 保护在 VPN 扩展进程中协作，不能依靠 UI 进程中的 ArkTS 单例或 N-API 回调直接跨进程共享。

| 入口 | 职责 |
| --- | --- |
| [Index](<entry/src/main/ets/pages/Index.ets>) | 主界面、配置选择、认证、连接状态、日志与 CLI 命令处理 |
| [Settings](<entry/src/main/ets/pages/Settings.ets>) / [SettingsStore](<entry/src/main/ets/common/SettingsStore.ets>) | 设置界面、Preferences、按配置保存凭据 |
| [ImportProfile](<entry/src/main/ets/pages/ImportProfile.ets>) | URL / Access Server 配置下载 |
| [EntryAbility](<entry/src/main/ets/entryability/EntryAbility.ets>) / [AppWindows](<entry/src/main/ets/common/AppWindows.ets>) | 应用生命周期、窗口关闭拦截、窗口显示与位置管理 |
| [VpnTray](<entry/src/main/ets/tray/VpnTray.ets>) / [TrayKeepAlive](<entry/src/main/ets/tray/TrayKeepAlive.ets>) | 托盘菜单、图标更新、后台保活和退出协调 |
| [VpnExtAbility](<entry/src/main/ets/vpnextension/VpnExtAbility.ets>) | 扩展进程内启动、停止核心并转发事件 |
| [VpnIpc](<entry/src/main/ets/common/VpnIpc.ets>) | UI 与 VPN 扩展的跨进程命令和状态传输 |
| [VpnServiceManager](<entry/src/main/ets/common/VpnServiceManager.ets>) | 系统虚拟网卡、路由、DNS、socket 保护 |
| [napi_init.cpp](<entry/src/main/cpp/napi_init.cpp>) | ArkTS 与 Native 的接口和回调桥接 |
| [openvpn_bridge.c](<entry/src/main/cpp/openvpn_bridge.c>) / [management_client.c](<entry/src/main/cpp/management_client.c>) | 核心线程、参数处理、management 协议、认证与 TUN 交接 |
| [CMakeLists.txt](<entry/src/main/cpp/CMakeLists.txt>) | Native 源码选择、平台头文件和静态库链接 |

## 已知限制

- **单活动连接**：切换配置会停止旧会话，不支持用户同时连接多个配置。
- **路由不是完整的桌面版映射**：当前 TUN 使用固定的 IPv4 `/24` 前缀，并安装 `0.0.0.0/0` 默认路由，即使服务端未推送 `redirect-gateway` 也如此。不要将其视为已经完整支持任意 IPv4 分流配置；服务端未配置转发 / NAT 时，连接后可能无法访问互联网。
- **IPv6 依赖服务端配置**：接收到 IPv6 地址后才启用对应隧道配置；采用已解析的 IPv6 路由，没有对应路由时补 `::/0`。不要据此假定所有 IPv6、DNS 分流和防泄漏策略均已覆盖。
- **断网不等于自动直连**：重连期间虚拟网卡和路由可能保留，不能保证普通流量立即回到物理网络，也不能把这种行为当作经过验证的完整 Kill Switch。
- **托盘配置数量限制**：当前菜单最多展示扫描结果中的 18 份配置，其余配置不会出现在托盘配置菜单中。
- **Native 能力限制**：当前平台配置未启用 DCO、LZO、LZ4 和 PKCS#11。CLI `version` 的能力描述含硬编码文本，不应据此判断实际编译能力；以 [平台配置](<entry/src/main/cpp/core/build-ohos/config.h>)和 [CMake 配置](<entry/src/main/cpp/CMakeLists.txt>)为准。
- **不是全部 Windows GUI 功能的移植**：设置模型保留了开机启动、预登录、脚本窗口等字段，但没有对应的完整系统实现；Windows 专属服务、驱动和脚本不能直接用于鸿蒙。
- **桌面交互需真机确认**：系统托盘、后台保活、隐私窗口和多窗口模式受到设备及系统能力约束。

## 日志与排查

主窗口显示当前连接日志；托盘的“查看日志”和“编辑配置”通过系统文本应用打开文件，设备需有能够处理相应文件类型的应用。

当前连接日志由 [ProfileLog](<entry/src/main/ets/common/ProfileLog.ets>)与 Native 层共同约定，实际位置在应用沙箱的缓存目录：

```text
/data/storage/el2/base/cache/<配置名>.log
/data/storage/el2/base/cache/vpnext.log
```

配置名中的路径分隔符和部分特殊字符会替换为下划线。不要仅根据设置模型中的 `logDir` 字段推断当前实际日志位置。

| 现象 | 优先检查 |
| --- | --- |
| 没有找到配置 | 是否已导入、配置目录是否正确、文件后缀与扫描设置是否一致 |
| TLS / 证书错误 | CA、客户端证书和私钥是否匹配，系统时间是否正确，服务端身份校验是否匹配 |
| 一直连接中 | 服务端地址、协议与端口是否一致，防火墙和代理是否允许访问 |
| 已连接但业务不通 | 隧道内地址可达性、服务端转发 / NAT、DNS 和业务防火墙 |
| 断网后暂时仍显示已连接 | 核心尚未检测到超时；结合收发数据、日志与保活配置判断 |
| 改包名后扩展或托盘异常 | IPC、后台 Ability、事件订阅和调试命令是否同步修改 |
| 构建或安装失败 | SDK / 工具链版本、ARM64 静态库、签名配置和目标设备兼容性 |

反馈问题时提供设备型号、系统版本、分支 / 提交、操作步骤、预期结果和脱敏日志。配置内容只保留必要参数，不要上传私钥、密码、认证令牌、签名文件或完整沙箱备份。

## 验证建议

现有 [本地测试](<entry/src/test/LocalUnit.test.ets>)和 [设备测试](<entry/src/ohosTest/ets/test/Ability.test.ets>)主要还是模板用例，不能作为 VPN 功能已验证的依据。构建通过、握手成功和业务流量通过也应分别确认。

发布或修改连接逻辑后，建议在授权测试环境中手动覆盖：

- UDP / TCP 首次连接、主动断开、重新连接和切换配置。
- 正确 / 错误凭据、取消认证、保存与清除密码、代理认证。
- 关闭网络、恢复网络、切换网络及服务端重启后的状态和流量恢复。
- 最大化 / 全屏后弹认证框、最小化后唤起、隐藏后从托盘恢复和真正退出。
- 本地文件 / URL 导入、同名替换、无配置提示，以及配置数量超过托盘显示上限。
- 隧道内访问、DNS、服务端转发，以及服务器具备 IPv6 配置时的 IPv6 数据通路。

## 安全与第三方许可

- 仅导入可信来源的配置。配置可能包含私钥和敏感网络信息，不应提交到公开仓库。
- 当前保存密码使用应用沙箱中的 Preferences 字符串，未接入专用密钥库加密方案；跨进程认证命令也会序列化到沙箱缓存，因此“不保存密码”不等于凭据完全不落盘。请勿将应用缓存、备份或原始日志作为公开附件。
- 认证框的隐私窗口保护不能代替凭据存储保护，也不能代替日志脱敏。
- 发布前请清理或替换开发签名引用，妥善保管签名证书、私钥、Profile 和密码。

本项目集成第三方源码及库：

- OpenVPN 核心源文件声明使用 GNU GPL v2，参见 [OpenVPN 源文件声明](<entry/src/main/cpp/core/openvpn/openvpn.c>)；具体文件及依赖应分别核对其许可条款。
- OpenSSL 3.x 使用 Apache License 2.0，参见随仓库提供的 [OpenSSL 头文件声明](<entry/src/main/cpp/libs/include/openssl/opensslv.h>)。

当前仓库未提供统一的顶层许可证文件。修改或分发前，应核对项目自身和所有第三方组件的许可、通知及源码提供义务，不能仅根据本 README 推定整个工程采用某一种许可证。
