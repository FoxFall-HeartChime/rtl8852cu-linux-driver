# rtl8852cu-linux-driver

Realtek RTL8852CU（AX3000、Wi-Fi 6 USB 网卡）Linux 驱动。基于厂商 v1.1 版本，把内核接口适配到 7.3，让这张网卡在新内核上还能编译、能加载。

- 芯片：RTL8852CU / RTL8832CU（USB 接口，模块名 `8852cu`）
- 内核：5.15 – 6.14 沿用厂商实现，6.15 – 7.3 由本仓库适配
- 发行版：Alpine、Debian、Ubuntu、CentOS（及 RHEL/Rocky/AlmaLinux/Fedora）
- 验证：[build.yml](.github/workflows/build.yml) 对每个版本边界内核真实编译；[packages.yml](.github/workflows/packages.yml) 在各发行版容器里产出预编译包

## 一键安装

```sh
curl -fsSLO https://raw.githubusercontent.com/FoxFall-HeartChime/rtl8852cu-linux-driver/main/install.sh
sudo sh install.sh
```

脚本会先按 `uname -r` 找对应的预编译包（`8852cu_<内核版本>_<架构>.tar.gz`），直接装上；找不到就自动装依赖、用本机内核头文件编译。装完自动 `depmod`、处理内核自带 `rtw89` 的冲突、`modprobe` 并打印网卡接口。

```sh
sudo sh install.sh --prebuilt     # 只接受预编译包，找不到就退出
sudo sh install.sh --build        # 强制本地编译
sudo sh install.sh --dkms         # 本地编译并注册 DKMS，换内核后自动重编
sudo sh install.sh --uninstall    # 卸载
```

预编译包不匹配时脚本会检查模块的 `vermagic`，对不上就拒绝安装，不会把编错内核的模块塞进系统。

## 预编译包

推 `v*` 标签会触发 [packages.yml](.github/workflows/packages.yml)，在下列发行版容器中编译并上传到 Release：

| 发行版 | 镜像 |
| --- | --- |
| Debian 12 / 13 | `debian:12` / `debian:13` |
| Ubuntu 22.04 / 24.04 | `ubuntu:22.04` / `ubuntu:24.04` |
| CentOS Stream 9 | `quay.io/centos/centos:stream9` |
| AlmaLinux 9 | `almalinux:9` |
| Alpine 3.20 / 最新版 | `alpine:3.20` / `alpine:latest` |

每个任务产出 `8852cu_<内核版本>_<架构>.tar.gz`，Debian 系额外产出 `.deb`。预编译包绑定具体内核版本，`uname -r` 对不上的机器会自动回退到源码编译，所以这只影响"能不能省一次编译"，不影响能不能用。

本机也可以直接生成：

```sh
sudo sh packaging/build-prebuilt.sh ./out
```

## 适配的内核接口变更

| 内核 | 变更 | 处理 |
| --- | --- | --- |
| 6.15 | `del_timer*` 改名 `timer_delete*`；kbuild 移除 `EXTRA_CFLAGS` | 按版本切换；6.15+ 把 `EXTRA_CFLAGS` 镜像到 `ccflags-y` |
| 6.16 | `from_timer()` 换成 `timer_container_of()` | 按版本切换 |
| 6.17 | cfg80211 增加 `radio_idx` 参数 | 补参数 |
| 6.18 | 内核 crypto 新增同名 `hmac_sha256()` | 驱动内改为 `rtl_hmac_sha256()` |
| 7.1 | cfg80211 回调改用 `wireless_dev`；扫描被拒时不能同步回调 | 回调入口转换 `wdev_to_ndev()`；被拒扫描返回 `-EBUSY` |
| 7.2 | 内核移除 `strncpy()` | 改用 `strscpy()` / `strscpy_pad()`，平台层保留原语义的本地实现 |
| 7.3 | cookie 改为按值传递；`probe_client` 改名 `probe_peer` | 补兼容分支 |
| 7.x | Makefile 版本判断 `major>=6 && minor>=N` 在 7.0 上失效 | 增加 `KER_MAJOR_7` 旁路 |

另外修正了监听模式下帧不属于本接口时 `adapter_link` 为空导致的空指针 panic。

## 手动编译

需要 `gcc`、`make`、`bc` 和当前内核的头文件或源码树。

```sh
make -j$(nproc)                                  # 用 /lib/modules/$(uname -r)/build
make -j$(nproc) KSRC=/path/to/linux-7.3          # 指定内核源码
sudo make install
sudo modprobe 8852cu
```

## 注意

- `CONFIG_BR_EXT` 默认关闭：`core/rtw_br_ext.c` 在 7.1+ 上无法编译，桥接 NAT2.5 相关功能随之停用。
- 6.19 起主线内核的 `rtw89` 已包含 8852cu 支持，能用内核自带驱动时优先用它；本驱动主要用于厂商特性、监听模式或较旧内核。安装脚本会在检测到内核 `rtw89` 驱动时写入 blacklist，避免两者抢设备。
- Secure Boot 开启时未签名模块不会加载，需要自己签名或关闭 Secure Boot。
- 仓库里 `LICENSE` 为 MIT，仅覆盖安装脚本与打包脚本；驱动源码沿用各文件头部的 GPL-2.0 声明与 Realtek 版权。
