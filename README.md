# luci-app-virtualhere

OpenWrt / ImmortalWrt 的 VirtualHere USB Server 控制插件，使用 LuCI JavaScript 页面、JSON 菜单及 ACL、UCI 配置和 ucode RPC 后端，无需 Lua。

## 功能与需求

- 插件负责服务控制、配置编辑和日志查看，不包含、下载、更新或编译 VirtualHere 二进制。
- 状态与操作 Tab：启用开关、运行状态、PID、程序检查结果及启动 / 停止 / 重启。
- 基本设置 Tab：自定义 vhusbd 可执行文件路径、VirtualHere 配置文件路径。
- 配置文件 Tab：读取和编辑所指定配置文件的原始内容，支持重新读取、保存、保存并应用。
- 运行日志 Tab：查看程序和插件控制日志，显示最近 200 行，支持自动刷新和手动刷新。
- 路径允许自定义目录和文件名；服务以 `vhusbd -c <配置文件路径>` 前台运行，由 procd 跟踪、停止及自动恢复。
- 页面底部“保存”持久化启用开关和路径，不改变当前服务运行状态；“保存并应用”根据启用开关启动 / 重启或停止服务。
- 配置文件“保存文件”只写文件，要求服务已停止；“保存文件并应用”先停止服务再写入，成功后根据已保存的启用开关决定是否启动。
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

在“状态与操作”中勾选“启用”，再点页面底部“保存并应用”，即可启动服务并允许下次开机启动；取消勾选后应用则停止服务。“启动 / 停止 / 重启”使用已保存的路径，执行临时服务操作，不修改启用开关。未启用时也可以手动启动；手动停止后，如果仍保持启用，再次保存并应用或下次开机会重新启动。

| 已保存的启用开关 | 实际运行状态 | 页面显示 |
| --- | --- | --- |
| 关闭 | 停止 | 未启用，服务当前未运行 |
| 开启 | 停止 | 已停止 |
| 开启 | 运行 | 运行中，并显示 PID |
| 关闭 | 运行 | 运行中（未启用），并显示 PID |

页面空闲时每 5 秒自动刷新状态，操作期间暂停轮询，完成后局部刷新，保留未保存的表单及文件编辑内容。服务停止时可点击“启动”，运行时可点击“停止 / 重启”；操作期间、状态读取失败或账号只有只读权限时，服务按钮禁用。读取文件、保存和服务操作在页面内互斥，操作期间文件编辑器暂时只读，避免较晚返回的读取结果覆盖新输入。

可先点击“启动”让 VirtualHere 使用默认配置，再到“配置文件”Tab 重新读取；也可以在服务停止时直接创建配置文件。配置项含义见 [VirtualHere Server Configuration FAQ](https://www.virtualhere.com/configuration_faq)。

**VirtualHere 会在运行和退出时回写配置文件，官网要求编辑前完全停止服务。** 因此编辑文件时，运行中的服务请使用“保存并应用”；普通“保存”会提示先停止服务。退出时文件若发生变化，插件会提示重新读取，不覆盖新内容。

RPC 使用同一把锁协调保存和服务控制。写文件前会确认旧进程已退出且 procd 中没有残留实例，并在停机后、原子替换前检查文件内容和实际目标路径。写入失败后尝试恢复之前的服务；如果恢复也失败，页面同时报告原始错误和恢复错误。

点击“停止”后，页面会显示“正在停止 VirtualHere，等待进程退出…”。停止操作要等程序完成退出和配置回写后才报告成功，因此可能需要几秒钟。

编辑器用于文本配置，单个文件最大 16 KiB。重新读取或离开页面前会提醒未保存的修改。“配置文件”Tab 内的按钮保存文件内容，页面底部的“保存 / 保存并应用”只保存基本设置。配置文件可能包含授权信息，请使用具备管理权限的 LuCI 账户。

“运行日志”Tab 从系统日志读取包含 `vhusbd` 或 `virtualhere` 的记录，包含程序运行日志、插件控制错误及相关 procd 消息。打开时立即读取，保持打开且页面可见时每 5 秒刷新，也可点击“刷新”手动读取。服务停止后仍可查看退出记录；读取失败会显示提示并保留上次内容。浏览旧日志时保留滚动位置，停留底部时跟随新记录；刷新不影响尚未保存的设置或文件编辑。

日志接口为只读权限，每次最多返回最近 200 行及 256 KiB 的内容，不依赖服务是否正在运行。使用现有 syslog 输出，不添加 `-r` 或创建独立日志文件；历史记录的保留范围由系统日志缓冲区和系统日志配置决定。

日志筛选由后端读取后完成，再截取最近记录。OpenWrt 的 `logread -e` 使用基本正则，不能直接将 `vhusbd|virtualhere` 当作“或”表达式；命令行查看时可使用下方的 `grep -E`。

也可在 LuCI 系统日志中查看，或执行：

```sh
logread | grep -i -E 'virtualhere|vhusbd'
/etc/init.d/vhusbd check
```

命令行临时服务控制使用 `/etc/init.d/vhusbd start_now`、`stop_now`、`restart_now`，均不修改启用开关。普通 `start`、`restart` 和 `reload` 遵循已保存的 `enabled`。通过命令行修改 UCI 后，应提交配置并显式执行 `reload`；页面通过 RPC 在锁内直接应用设置，没有注册自动配置重载触发器。

## 配置与升级

管理设置保存在 `/etc/config/virtualhere`：

```uci
config virtualhere 'main'
    option enabled '0'
    option binary_path '/usr/bin/vhusbd'
    option config_path '/etc/vhusbd.conf'
```

升级时会将旧版 `autostart` 迁移到 `enabled`，保留原有开关值并删除旧字段。系统 init 启动入口保持启用，由 UCI 的 `enabled` 决定开机是否运行进程。

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

可在仓库根目录运行本地回归测试，需要 Node.js 18 或更新版本、Python 3，以及带 `fs` 模块的 ucode：

```sh
node --test tests/view.test.js
python3 tests/init.test.py
ucode tests/rpc.test.uc
```

前端测试覆盖异步请求、操作互斥、编辑内容保留，以及日志刷新、滚动位置和失败恢复。init 测试使用延迟退出的测试进程和仅支持整秒的 sleep，验证等待退出和超时边界。RPC 测试使用真实临时文件、文件锁和日志读取子进程，模拟 UCI / procd，覆盖启停、保存应用、实例延迟清理、停机回写冲突、目标路径变化、失败恢复和日志读取边界，不操作实际服务。

发布前应完成以下编译及设备验收：

- [ ] SDK 编译成功并生成主包和简体中文包。
- [ ] 页面及 RPC 后端不依赖 Lua，中文切换有效。
- [ ] 自定义路径 / 文件名可启动，错误路径及无执行权限有提示。
- [ ] 四种启用 / 运行状态显示正确，服务按钮样式及可用条件一致。
- [ ] 未启用时可临时启动，手动启停 / 重启不修改启用开关。
- [ ] 启用后保存并应用会启动 / 重启，取消启用后应用会停止；开机遵循启用配置。
- [ ] 状态轮询及操作后刷新保留编辑内容，操作期间不会重复提交。
- [ ] 运行日志包含程序和控制错误，打开时及每 5 秒刷新，切换其他 Tab 后暂停日志轮询。
- [ ] 服务停止后仍能查看日志；无记录和读取失败的提示不同，失败时保留旧日志。
- [ ] 只读账号可查看和刷新日志，浏览旧日志不会被自动滚到底部。
- [ ] 文件不存在可创建，重新读取会提醒未保存内容。
- [ ] 页面底部保存只提交启用开关和路径；文件保存独立执行。
- [ ] 保存文件并应用成功后遵循已保存的启用开关，失败时尝试恢复原服务。
- [ ] 运行中的配置文件不会被直接改写，外部修改会提示冲突。
- [ ] 写入失败保留编辑内容，包内不含 vhusbd 二进制。
