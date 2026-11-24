# netcfg — Linux 服务器 IP / 网关 / DNS 一键配置

改网卡配置最大的风险是"改完连不上，只能去机房"。`netcfg.sh` 用一条命令改完，
**改错自动退回去**。

支持 `netplan`（Ubuntu 20.04+）、`ifupdown`（老 Debian/Ubuntu）、`NetworkManager`（nmcli）。

> 文中的 IP 均为示意，请替换成你自己的。

## 安装（免费、无依赖）

```sh
curl -fsSL https://fastly.jsdelivr.net/gh/scenep/netcfg@main/install.sh | sudo bash
```

装到 `/usr/local/bin/netcfg`，然后：

```sh
sudo netcfg show
```

不要安装、直接用：

```sh
curl -fsSLO https://fastly.jsdelivr.net/gh/scenep/netcfg@v1.1.0/netcfg.sh
sudo bash netcfg.sh show
```

国内如果 CDN 也不通，可用镜像：

```sh
curl -fsSLO https://ghproxy.net/https://raw.githubusercontent.com/scenep/netcfg/main/netcfg.sh
```

> 为什么主推 jsDelivr：`raw.githubusercontent.com` 在部分国内网络不可达。

## 30 秒上手

```sh
sudo netcfg show                      # 现状：IP/路由/DNS/配置文件（只读）

sudo netcfg pin -n                    # 演练：把当前 DHCP 拿到的 IP/网关/DNS 固化成静态
sudo netcfg pin                       # 确认后生效

sudo netcfg set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -n
sudo netcfg set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8"

sudo netcfg set -i ens33 --dhcp        # 改回 DHCP
sudo netcfg rollback                  # 回滚到最近一次备份
netcfg selftest                       # 沙箱自测(45 项, 不改本机网络)
```

改的正是当前 SSH 那根网卡时，用后台模式（连接断了也不影响校验和确认）：

```sh
sudo netcfg --detach set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -y
tail -f /var/log/netcfg-*.log
```

## 为什么敢一键改

1. **先备份**：`/etc/netplan`、`/etc/resolv.conf`、`/etc/resolvconf`、`/etc/network`、
   `/etc/NetworkManager/system-connections`、`/etc/dhcp/dhclient.conf` 打包到
   `/var/backups/netcfg/<时间戳>/`，并记录新建了哪些文件（回滚时删除），目录里带
   `rollback.sh`；
2. **写盘后先离线校验**：`netplan generate` 只生成后端配置、不动运行态；报错立即还原；
3. **看门狗**：`apply` 前用 `setsid` 拉起脱离 SSH 会话的看门狗，脚本被 SIGHUP 杀掉、
   卡死或超时未确认（默认 120s），自动回滚并重新 apply；
4. **应用后校验**：地址是否落到网卡、默认路由是否经过该网卡（硬校验，失败即回滚）；
   网关 ping、DNS 解析（软校验，`--strict` 时也回滚）；
5. **指纹兜底**：校验通过后再比一次配置指纹，防止被看门狗/他人改动后谎报成功。

只改指定网卡，其它网卡与其它 netplan 键（`macaddress`/`optional`/非默认静态路由等）
原样保留；同一网卡被多个 yaml 重复定义会自动去重。

## 固化当前配置（DHCP → 静态）

`pin` 直接从运行态采集，不猜：

| 项 | 来源 |
|---|---|
| 网卡 | 默认路由所在网卡（`-i` 可指定） |
| IPv4 | `ip -o -4 addr show` 的全部 global 地址 |
| 网关 | `ip route show default` 中经过该网卡的条目 |
| DNS | `resolvectl dns`，剔除 `127.0.0.53/127.0.0.1/::1` 等本机 stub；无 resolved 时用 `/etc/resolv.conf` |
| 搜索域 | `resolvectl domain`，剔除 `~.` 这类 routing-only 域 |
| MTU | `ip link` 实际值（1500 不写） |
| IPv6 | 默认原样保留，不采集；`--with-ipv6` 才一并固化 |

> 固化后记得在 DHCP 服务器上按 MAC 做静态保留或把地址从池里排除，否则会 IP 冲突。

## 参数

```
-i, --iface NIC        网卡名，默认取默认路由所在网卡
-4, --ip A/B           静态 IPv4（可重复或逗号分隔），必须带前缀
-6, --ipv6 A/B         静态 IPv6
-g, --gateway IP       IPv4 网关（必须在本网段，否则拒绝；--allow-offlink-gateway 可放行）
-G, --gateway6 IP      IPv6 网关
-d, --dns "IP [IP]"    DNS（空格/逗号分隔，可重复）
    --no-dns           清空 DNS
-s, --search DOMAIN    DNS 搜索域（可重复）
-m, --mtu N            MTU
    --from-current     不给地址时固化当前运行态（等价于 pin）
    --with-ipv6        pin 时一并固化 IPv6
    --dhcp / --dhcp6   使用 DHCP / 启用 DHCPv6
-t, --timeout N        看门狗超时，默认 120s，0=关闭
    --no-guard         关闭看门狗
    --no-verify        跳过应用后校验（不建议）
    --strict           ping 网关 / DNS 解析失败也算失败
-n, --dry-run          只打印，不改文件
-y, --yes              非交互
-b, --backend B        netplan|ifupdown|nmcli
    --detach[=LOG]     后台执行（改唯一网卡时推荐）
-V, --version          版本号
```

退出码：`0` 成功；非 0 失败（此时配置已自动回滚，可看 `/var/backups/netcfg/*/watchdog.log`）。

## DNS 落地

| 系统情况 | 处理 |
|---|---|
| `/etc/resolv.conf` 指向 systemd-resolved stub | 不动，netplan 的 `nameservers` 由 resolved 接管 |
| 有 `/etc/resolvconf/resolv.conf.d/` | 写 `base` 后 `resolvconf -u` |
| 普通 `/etc/resolv.conf` | 直接覆盖写 |
| DHCP + 指定 DNS | netplan 写 `dhcp4-overrides.use-dns: false`；ifupdown 场景给 dhclient 加 `supersede` |

## 自测

```sh
netcfg selftest        # 45 项，约 20s，沙箱 + 桩程序，不动本机网络
```

覆盖参数校验、静态/DHCP/双栈渲染、多地址、其它网卡保留、幂等、dry-run 不落盘、
apply/generate/校验三种失败回滚、看门狗抢跑、`--detach`、`pin` 固化、backup/apply/
rollback、ifupdown/nmcli 命令构造、resolvconf 写入，以及用真实 netplan 对生成的 YAML
做 `netplan generate --root-dir` 校验。

CI：GitHub Actions 在 ubuntu-22.04 / 24.04 上跑同一套自测。

## 许可

MIT
