# luci-app-virtualhere

OpenWrt / ImmortalWrt 的 VirtualHere USB Server 控制插件，使用 LuCI JavaScript 页面、JSON 菜单及 ACL、UCI 配置和 ucode RPC 后端，无需 Lua。

## 功能与需求

- 插件只负责服务控制和配置编辑，不包含、下载、更新或编译 VirtualHere 二进制。
- 基本设置 Tab：开机启动、自定义 vhusbd 可执行文件路径、VirtualHere 配置文件路径、运行状态、程序检查结果及启动 / 停止 / 重启。
- 配置文件 Tab：读取和编辑所指定配置文件的原始内容，支持重新读取、保存、保存并应用。
- 路径允许自定义目录和文件名；服务以 `vhusbd -c <配置文件路径>` 前台运行，由 procd 跟踪、停止及自动恢复。
- 基本设置“保存”持久化设置并同步开机启动，不重启服务；“保存并应用”只重启已启动的服务，停止的服务保持停止。
- 配置文件“保存”只写文件，要求服务已停止；“保存并应用”在服务已启动时先停止、写入并恢复运行，停止的服务保持停止。
- 文件不存在时可编辑并保存创建；写入采用同目录临时文件和原子替换。读写失败保留输入，检测自读取后的外部修改，避免直接覆盖。
- 修改配置文件路径后，应先保存基本设置，再重新读取新文件。编辑器不自动把旧文件内容复制到新路径。
- 提供主包 `luci-app-virtualhere` 和独立简体中文语言包 `luci-i18n-virtualhere-zh-cn`。

## 下载和安装服务端程序

请自行到 [VirtualHere 官方 Linux USB Server 下载页面](https://www.virtualhere.com/usb_server_software) 选择与路由器 CPU 架构匹配的二进制，例如 ARM64、ARM、x86_64、MIPS 或 MIPSEL。版本和授权信息以官网为准。

将下载的程序上传到路由器，例如 `/usr/bin/vhusbd` 或 `/mnt/sda1/virtualhere/vhusbdarm64`，并赋予执行权限：

```sh
chmod 0755 /mnt/sda1/virtualhere/vhusbdarm64
```

安装插件和中文包后，打开 **服务 → VirtualHere → 基本设置**，填写实际程序路径及配置文件路径。程序所在文件系统必须允许执行，二进制必须匹配设备架构；插件的路径检查不能替代实际启动检查。

默认程序路径为 `/usr/bin/vhusbd`，默认配置文件为 `/etc/vhusbd.conf`，开机启动默认关闭。插件提供初始空配置文件，供 VirtualHere 使用默认设置并回写。自定义配置文件的父目录请提前创建，并确保可读写。外置存储必须在服务启动前挂载完成。

可先点击“启动”让 VirtualHere 使用默认配置，再到“配置文件”Tab 重新读取；也可以在服务停止时直接创建配置文件。配置项含义见 [VirtualHere Server Configuration FAQ](https://www.virtualhere.com/configuration_faq)。

**VirtualHere 会在运行和退出时回写配置文件，官网要求编辑前完全停止服务。** 因此编辑文件时，运行中的服务请使用“保存并应用”；普通“保存”会提示先停止服务。退出时文件若发生变化，插件会提示重新读取，不覆盖新内容。

编辑器用于文本配置，单个文件最大 16 KiB。重新读取或离开页面前会提醒未保存的修改。“配置文件”Tab 内的按钮保存文件内容，页面底部的“保存 / 保存并应用”只保存基本设置。配置文件可能包含授权信息，请使用具备管理权限的 LuCI 账户。

日志可在 LuCI 系统日志中查看，或执行：

```sh
logread | grep -i -E 'virtualhere|vhusbd'
/etc/init.d/vhusbd check
```

## 配置与升级

管理设置保存在 `/etc/config/virtualhere`：

```uci
config virtualhere 'main'
    option autostart '0'
    option binary_path '/usr/bin/vhusbd'
    option config_path '/etc/vhusbd.conf'
```

插件升级保留 `/etc/config/virtualhere` 和 `/etc/vhusbd.conf`。自定义路径的配置文件及二进制由用户自行备份；需要 sysupgrade 保留时，将实际路径加入 `/etc/sysupgrade.conf`，外置存储中的文件按其自身存储方式维护。

## 构建和发布

需要支持 JavaScript 视图和 rpcd ucode 插件的 OpenWrt / ImmortalWrt，并准备标准 `luci` 和依赖 feed。在源码或 SDK 根目录加入本仓库：

```sh
echo 'src-git virtualhere https://github.com/altman08/luci-app-virtualhere.git' >> feeds.conf.default
./scripts/feeds update virtualhere
./scripts/feeds install -f -p virtualhere luci-app-virtualhere
```

在 `.config` 中选择：

```text
CONFIG_PACKAGE_luci-app-virtualhere=m
CONFIG_PACKAGE_luci-i18n-virtualhere-zh-cn=m
```

然后执行：

```sh
make defconfig
make package/luci-app-virtualhere/compile V=s
```

中文包是主包的翻译子包，不需要独立源码编译目标。产物位于 `bin/packages/<arch>/virtualhere/`，格式随 SDK 为 `.ipk` 或 `.apk`。

GitHub Actions 的 `Release OpenWrt packages` 工作流仅通过 `workflow_dispatch` 手动运行，填写预期发布的 tag 和 prerelease 选项即可，无需提前创建 tag。先对各 SDK / 架构编译主包和中文包，并校验两者存在、上传 artifact；只有全部编译任务成功后，发布任务才会以本次运行的提交创建 tag 和 Release，并上传安装包。编译失败不会执行发布任务。Release 文件名带 SDK 和架构后缀，附带 SHA256 校验和；不会产出 VirtualHere 二进制。检出仓库和构建步骤设置总时限，GitHub CLI 操作设置超时和有限重试。

## 验收清单

以下为待执行的编译及设备验收项；当前按要求暂不运行测试。

- [ ] SDK 编译成功并生成主包和简体中文包。
- [ ] 页面及 RPC 后端不依赖 Lua，中文切换有效。
- [ ] 自定义路径 / 文件名可启动，错误路径及无执行权限有提示。
- [ ] 启停、重启、状态刷新和开机启动同步正常。
- [ ] 文件不存在可创建，重新读取会提醒未保存内容。
- [ ] 保存不启动已停止服务，保存并应用恢复原有运行状态。
- [ ] 运行中的配置文件不会被直接改写，外部修改会提示冲突。
- [ ] 写入失败保留编辑内容，包内不含 vhusbd 二进制。
