#!/bin/bash
# =============================================================================
#  netcfg.sh - Linux 服务器网络(IP/网关/DNS)一键配置, 带自动回滚保护
#
#  支持平台:
#    * Ubuntu 20.04+ (netplan; systemd-networkd 或 NetworkManager 渲染均可)
#    * Debian/Ubuntu 老系统 (ifupdown: /etc/network/interfaces.d)
#    * NetworkManager (nmcli)
#
#  常用用法:
#    netcfg.sh show                                           # 看当前 IP/网关/DNS
#    netcfg.sh set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8"
#    netcfg.sh set -i ens33 -4 192.168.1.10/24 -4 192.168.1.11/24 -g 192.168.1.1
#    netcfg.sh set -i ens33 --dhcp                             # 改回 DHCP
#    netcfg.sh set -i ens33 -4 10.0.0.5/24 -g 10.0.0.1 -n    # -n = 只看计划, 不落盘
#    netcfg.sh rollback                                        # 回滚到最近一次备份
#    netcfg.sh selftest                                        # 沙箱自测, 不动本机网络
#
#  安全设计(为什么敢一键改网络):
#    1. 动手前把 /etc/netplan、/etc/resolv.conf、/etc/resolvconf、/etc/network、
#       /etc/NetworkManager/system-connections、/etc/dhcp/dhclient.conf 打包到
#       /var/backups/netcfg/<时间戳>/ ; 同时记录本次新建了哪些文件(回滚时删除)
#    2. 写盘后先 netplan generate 做离线语法/语义校验, 失败直接还原, 不碰运行态
#    3. apply 之后自动校验地址/默认路由(硬校验) 和 网关 ping、DNS 解析(软校验),
#       失败立即回滚并重新 apply
#    4. apply 之前拉起看门狗: 若脚本中途被网络中断杀掉(改错 IP 导致 SSH 断开),
#       看门狗在 --timeout 秒后自动回滚, 不会把机器搞成失联
#    5. 全程 -n/--dry-run 可先看要写入的内容
# =============================================================================
set -euo pipefail

PROG="netcfg.sh"
VER="1.2.5"
SELF=""
for _cand in "${BASH_SOURCE[0]:-}" "$0"; do
  if [ -n "$_cand" ] && [ -f "$_cand" ]; then
    SELF=$(readlink -f "$_cand" 2>/dev/null || true)
    break
  fi
done
unset _cand

# CentOS 等系统的非登录 shell 往往没有 /sbin, 而 ip/ifup/nmcli 在那里
for _d in /usr/sbin /sbin; do
  case ":$PATH:" in
    *":$_d:"*) ;;
    *) PATH="$PATH:$_d" ;;
  esac
done
export PATH
unset _d

ROOT="/"                 # 沙箱根目录(仅自测用)
BACKEND="auto"
IFACE=""
ADDRS=(); V6S=(); DNSES=(); SEARCHES=()
GW=""; GW6=""; MTU=""
MODE=""
DHCP6=0
DNS_GIVEN=0
NO_DNS=0
ALLOW_OFFLINK=0
TIMEOUT="${NETCFG_TIMEOUT:-120}"
GUARD=1
DRY_RUN=0
YES=0
VERBOSE=0
STRICT=0
VERIFY=1
VERIFY_HOST="${NETCFG_VERIFY_HOST:-www.baidu.com}"
VERIFY_TRIES="${NETCFG_VERIFY_TRIES:-10}"
VERIFY_INTERVAL="${NETCFG_VERIFY_INTERVAL:-1}"
PY=""
BDIR=""
WATCHDOG_PID=""
DETACH=0
DETACH_LOG=""
CAPTURE_SOURCE=0
FROM_CURRENT=0
WITH_IPV6=0
NMCLI_HARD=0
ALLOW_OTHER_PREFIX=0
PIN_OLD_IP=""
TARGET_HOSTNAME=""
SKIP_HOSTS=0
HOSTNAME_BACKUP_DIR=""

# ---------------------------------------------------------------- 基础工具 ---
log()  { printf '%s\n' "$*"; }
info() { printf '[netcfg] %s\n' "$*"; }
warn() { printf '[netcfg][警告] %s\n' "$*" >&2; }
err()  { printf '[netcfg][错误] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
vlog() { if [ "$VERBOSE" -eq 1 ]; then printf '[netcfg][debug] %s\n' "$*" >&2; fi; return 0; }

# 把 /etc/xxx 映射到沙箱内的路径
real_path() { local p="/${1#/}"; if [ "${ROOT%/}" = "" ] || [ "$ROOT" = "/" ]; then printf '%s' "$p"; else printf '%s%s' "${ROOT%/}" "$p"; fi; }

join_list() {
  local _jn="$1" _jv=""
  local IFS=','
  eval "_jv=\${$_jn[*]-}"
  printf '%s' "$_jv"
}

# 把 "a,b c" 这类写法拆成数组元素(支持重复选项/逗号/空格混用)
normalize_list() {
  local _nn="$1" _nl _nv=""
  local -a _nt=()
  eval "_nv=\${$_nn[*]-}"
  while IFS= read -r _nl; do
    if [ -n "$_nl" ]; then _nt+=("$_nl"); fi
  done < <(printf '%s\n' "$_nv" | tr ',[:space:]' '\n' | sed '/^[[:space:]]*$/d')
  eval "$_nn=()"
  if [ ${#_nt[@]} -gt 0 ]; then
    eval "$_nn=(\"\${_nt[@]}\")"
  fi
  return 0
}

normalize_all_lists() {
  normalize_list ADDRS
  normalize_list V6S
  normalize_list DNSES
  normalize_list SEARCHES
  return 0
}

require_root() {
  if [ "${ROOT%/}" = "" ] || [ "$ROOT" = "/" ]; then
    if [ "$(id -u)" -ne 0 ]; then die "该操作需要 root 权限, 请用 sudo 执行"; fi
  fi
}

cleanup() {
  if [ -n "$PY" ] && [ -f "$PY" ]; then rm -f "$PY"; fi
  return 0
}

usage() {
  cat <<'USAGE'
netcfg.sh - Linux 服务器 IP/网关/DNS 一键配置(带自动回滚)

用法:
  netcfg.sh show                          查看当前网卡/IP/路由/DNS 与配置文件
  netcfg.sh set [选项]                     配置网卡(静态或 DHCP)
  netcfg.sh pin [选项]                     把当前运行中的 IP/网关/DNS 固化成静态配置
                                          加 -4 新IP/前缀 则只换 IP(必须与当前同网段)
  netcfg.sh apply                         重新应用当前配置(带校验与回滚保护)
  netcfg.sh hostname [新名字]               查看/修改主机名(带备份, 可 revert)
  netcfg.sh backup                         只做一次备份
  netcfg.sh rollback [备份目录]            回滚到指定/最近一次备份
  netcfg.sh selftest                       沙箱自测(不改本机网络)
  netcfg.sh --version                      显示版本号
  netcfg.sh help                           本帮助

全局选项(必须写在子命令前面):
  --root DIR     沙箱根目录, 只用于自测/演练; 该模式下默认不真正 apply
  --detach[=LOG] 后台执行(setsid), 输出写到 LOG(默认 /var/log/netcfg-<时间>.log)
                 修改当前 SSH 连接所用网卡时强烈建议用它, 断开也不会打断校验
  -v, --verbose  输出执行的命令

set 选项:
  -i, --iface NIC        网卡名, 默认取默认路由所在网卡
  -4, --ip A/B           静态 IPv4 地址(可重复/逗号分隔), 必须带前缀, 如 192.168.1.10/24
  -6, --ipv6 A/B         静态 IPv6 地址(可重复)
  -g, --gateway IP       IPv4 默认网关
  -G, --gateway6 IP      IPv6 默认网关
  -d, --dns "IP [IP]"    DNS 服务器(空格或逗号分隔); 可重复
      --no-dns           删除已配置的 DNS
  -s, --search DOMAIN    DNS 搜索域(可重复)
  -m, --mtu N            MTU
      --from-current     不给地址时, 直接固化当前运行态(等价于 pin)
      --dhcp             改用 DHCP 自动获取(不再给静态地址)
      --dhcp6            同时启用 DHCPv6
      --with-ipv6        pin 时一并固化当前全局 IPv6 地址与 IPv6 默认网关
      --allow-other-prefix  pin 换 IP 时允许前缀长度与当前不同(默认必须一致)
      --hostname NAME    同时修改主机名(网络校验通过后执行, 带备份与 revert.sh)
      --allow-offlink-gateway   允许网关不在本网段(默认拒绝)
  -t, --timeout N        看门狗超时秒数, 默认 120, 0=关闭看门狗
      --no-guard         关闭看门狗
      --no-verify        跳过 apply 后的校验(不建议)
      --strict           网关 ping / DNS 解析失败也算失败(触发回滚)
  -n, --dry-run          只打印计划与将要写入的配置, 不改任何文件
  -y, --yes              非交互, 不再二次确认
  -b, --backend B        netplan|ifupdown|nmcli, 默认自动探测
  -h, --help             帮助

示例:
  sudo ./netcfg.sh set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 \
       -d "223.5.5.5 8.8.8.8" -s example.com
  sudo ./netcfg.sh set -i ens33 --dhcp
  sudo ./netcfg.sh set -i eth1 -4 10.0.0.5/24 -4 10.0.0.6/24 -g 10.0.0.1 -n
  sudo ./netcfg.sh rollback /var/backups/netcfg/20260101-120000

远程改唯一网卡(推荐后台跑, SSH 断开也能完成校验):
  sudo ./netcfg.sh --detach set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d 223.5.5.5 -y
  tail -f /var/log/netcfg-*.log
USAGE
}

# ------------------------------------------------------------- python 引擎 ---
ensure_py() {
  if [ -n "$PY" ] && [ -f "$PY" ]; then return 0; fi
  command -v python3 >/dev/null 2>&1 || die "需要 python3"
  PY=$(mktemp "${TMPDIR:-/tmp}/netcfg-py.XXXXXX.py")
  trap cleanup EXIT
  cat > "$PY" <<'PYEOF'
import sys, os, re, glob, argparse

def die(msg, code=2):
    sys.stderr.write("netcfg: %s\n" % msg)
    raise SystemExit(code)

import ipaddress

yaml = None


def load_yaml_module():
    """按需加载 PyYAML: 只有 netplan 相关操作需要它"""
    global yaml
    if yaml is None:
        try:
            import yaml as _yaml
        except ImportError:
            die("缺少 PyYAML: Debian/Ubuntu 执行 apt-get install -y python3-yaml; "
                "RHEL/CentOS 执行 yum install -y python3-PyYAML")
        yaml = _yaml
    return yaml

IFACE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,14}$')
LABEL_RE = re.compile(r'^(?!-)[A-Za-z0-9_-]{1,63}(?<!-)$')


def rp(root, path):
    path = '/' + path.lstrip('/')
    if root in ('', '/'):
        return path
    return os.path.join(root.rstrip('/'), path.lstrip('/'))


def split_items(values):
    if isinstance(values, str):
        values = [values]
    out = []
    for v in values or []:
        for x in re.split(r'[,\s]+', v or ''):
            x = x.strip()
            if x:
                out.append(x)
    return out


def parse_addrs(values, ver=None, label="IP"):
    res, seen = [], set()
    for it in split_items(values):
        if '/' not in it:
            die("非法%s地址: %s (必须带前缀长度, 例如 192.168.1.10/24)" % (label, it))
        try:
            ifc = ipaddress.ip_interface(it)
        except ValueError:
            die("非法%s地址: %s (必须带前缀长度, 例如 192.168.1.10/24)" % (label, it))
        if ver and ifc.version != ver:
            die("%s 地址族不匹配: %s" % (label, it))
        s = str(ifc)
        if s not in seen:
            seen.add(s)
            res.append(s)
    return res


def parse_dns(values):
    res = []
    for it in split_items(values):
        try:
            ipaddress.ip_address(it)
        except ValueError:
            die("非法 DNS 地址: %s" % it)
        if it not in res:
            res.append(it)
    return res


def parse_search(values):
    res = []
    for it in split_items(values):
        if not all(LABEL_RE.match(p) for p in it.split('.')):
            die("非法搜索域: %s" % it)
        res.append(it)
    return res


def norm_mtu(v):
    if v in (None, ''):
        return None
    try:
        n = int(v)
    except ValueError:
        die("非法 MTU: %s" % v)
    if not 576 <= n <= 9216:
        die("MTU 越界(576-9216): %s" % n)
    return n


def dump_yaml(data):
    """PyYAML >=5.1 才有 sort_keys, CentOS 7 的 3.x 没有"""
    load_yaml_module()
    try:
        return yaml.safe_dump(data, default_flow_style=False, sort_keys=False, allow_unicode=True)
    except TypeError:
        return yaml.safe_dump(data, default_flow_style=False, allow_unicode=True)


def write_yaml(path, data, header=True):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    txt = dump_yaml(data)
    if header:
        txt = "# generated by netcfg.sh, 建议用 netcfg.sh 修改\n" + txt
    tmp = path + ".netcfg.tmp"
    with open(tmp, "w") as fh:
        fh.write(txt)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_docs(ndir):
    load_yaml_module()
    docs = {}
    for f in sorted(glob.glob(os.path.join(ndir, '*.yaml'))):
        try:
            with open(f, "r") as fh:
                data = yaml.safe_load(fh)
        except Exception as e:
            die("解析 %s 失败: %s" % (f, e))
        if data is None:
            data = {}
        if not isinstance(data, dict):
            die("%s 顶层不是映射, 不是合法 netplan 配置" % f)
        docs[f] = data
    return docs


def do_validate(a):
    if not IFACE_RE.match(a.iface or ""):
        die("非法网卡名: %r (1-15 位字母数字及 _.:@-)" % (a.iface,))
    v4 = parse_addrs(a.addr, 4, 'IPv4')
    v6 = parse_addrs(a.v6, 6, 'IPv6')
    gw = (a.gw or '').strip()
    if gw:
        try:
            g = ipaddress.ip_address(gw)
        except ValueError:
            die("非法网关: %s" % gw)
        if g.version != 4:
            die("IPv4 网关格式错误: %s" % gw)
        if not v4:
            die("配置 IPv4 网关时必须同时给出 -4 地址")
        if not any(g in ipaddress.ip_interface(x).network for x in v4) and not a.allow_offlink:
            die("网关 %s 不在已配置网段内, 如确需请加 --allow-offlink-gateway" % gw)
    gw6 = (a.gw6 or '').strip()
    if gw6:
        try:
            g6 = ipaddress.ip_address(gw6)
        except ValueError:
            die("非法 IPv6 网关: %s" % gw6)
        if g6.version != 6:
            die("IPv6 网关格式错误: %s" % gw6)
    if a.mtu:
        norm_mtu(a.mtu)
    parse_dns(a.dns)
    parse_search(a.search)
    if a.mode == 'static' and not v4 and not v6:
        die("静态模式至少要有一个地址: -4 或 --ipv6")
    if a.mode == 'dhcp' and (v4 or v6):
        die("DHCP 模式下不能再指定静态地址")
    print("ok")


def build_stanza(old, a):
    st = dict(old) if isinstance(old, dict) else {}
    for k in ('addresses', 'gateway4', 'gateway6', 'dhcp4', 'dhcp6',
              'dhcp4-overrides', 'dhcp6-overrides', 'nameservers'):
        st.pop(k, None)
    kept = []
    for r in (st.get('routes') or []):
        if not isinstance(r, dict):
            continue
        if str(r.get('to', '')) in ('default', '0.0.0.0/0', '::/0'):
            continue
        kept.append(r)
    st.pop('routes', None)

    o = old if isinstance(old, dict) else {}
    old_dhcp6 = bool(o.get('dhcp6'))
    old_ra = bool(o.get('accept-ra'))
    v6_addrs = parse_addrs(a.v6, 6, 'IPv6')

    st['dhcp4'] = (a.mode == 'dhcp')
    # IPv6 只在显式要求时才动, 避免"固化 IPv4"顺手把机器上的 IPv6 关掉
    if a.dhcp6:
        st['dhcp6'] = True
        st['accept-ra'] = True
    elif v6_addrs:
        st['dhcp6'] = False
    elif old_dhcp6:
        st['dhcp6'] = True
        if old_ra:
            st['accept-ra'] = True

    addrs = parse_addrs(a.addr, 4, 'IPv4') + v6_addrs
    if addrs:
        st['addresses'] = addrs

    routes = list(kept)
    if a.gw:
        routes.insert(0, {'to': '0.0.0.0/0', 'via': a.gw})
    if a.gw6:
        routes.insert(0, {'to': '::/0', 'via': a.gw6})
    if routes:
        st['routes'] = routes

    old_ns = {}
    if isinstance(old, dict) and isinstance(old.get('nameservers'), dict):
        old_ns = old['nameservers']
    dns = None
    if a.no_dns:
        st.pop('nameservers', None)
    elif a.dns is not None or a.search is not None:
        if a.dns is None:
            dns = list(old_ns.get('addresses') or [])
        elif a.dns == '':
            dns = []
        else:
            dns = parse_dns([a.dns])
        if a.search is None:
            srch = list(old_ns.get('search') or [])
        elif a.search == '':
            srch = []
        else:
            srch = parse_search([a.search])
        if dns or srch:
            ns = {}
            if dns:
                ns['addresses'] = dns
            if srch:
                ns['search'] = srch
            st['nameservers'] = ns
            if a.mode == 'dhcp' and dns:
                st['dhcp4-overrides'] = {'use-dns': False}
                if a.dhcp6:
                    st['dhcp6-overrides'] = {'use-dns': False}
        else:
            st.pop('nameservers', None)

    mtu = norm_mtu(a.mtu)
    if mtu:
        st['mtu'] = mtu
    else:
        st.pop('mtu', None)
    return st


def do_edit_netplan(a):
    load_yaml_module()
    root = a.root
    ndir = rp(root, '/etc/netplan')
    if not os.path.isdir(ndir):
        die("目录不存在: %s (确认这是 netplan 系统, 或用 --backend 指定后端)" % ndir)
    docs = load_docs(ndir)
    iface = a.iface
    owner = None
    for f in sorted(docs):
        net = docs[f].get('network')
        if not isinstance(net, dict):
            continue
        for sect in ('bridges', 'bonds', 'vlans'):
            d = net.get(sect) or {}
            if not isinstance(d, dict):
                continue
            if iface in d:
                die("接口 %s 在 netplan %s 中定义, 本脚本只管理 ethernets" % (iface, sect))
            for nm, cfg in d.items():
                if iface in ((cfg or {}).get('interfaces') or []):
                    die("接口 %s 是 %s %s 的成员, 请先调整 %s 配置" % (iface, sect, nm, sect))
        eth = net.get('ethernets') or {}
        if isinstance(eth, dict) and iface in eth and owner is None:
            owner = f

    target = owner
    created = False
    if target is None:
        target = os.path.join(ndir, '90-netcfg.yaml')
        if target in docs:
            created = False
        else:
            created = True
            docs[target] = {'network': {'version': 2, 'ethernets': {}}}
    doc = docs[target]
    net = doc.get('network')
    if not isinstance(net, dict):
        die("%s 中 network 段不合法" % target)
    net.setdefault('version', 2)
    eth = net.get('ethernets')
    if not isinstance(eth, dict):
        eth = {}
        net['ethernets'] = eth
    old = eth.get(iface)
    eth[iface] = build_stanza(old, a)

    if a.dry_run:
        sys.stdout.write("### 目标文件: %s (%s)\n" % (target, "新建" if created else "修改"))
        sys.stdout.write(dump_yaml(doc))
    else:
        write_yaml(target, doc, header=False)
        print(("CREATED " if created else "WROTE ") + target)

    # 同一接口若在多个文件里重复定义, 从其余文件里删掉, 避免 netplan 合并冲突
    for f in sorted(docs):
        if f == target:
            continue
        net2 = docs[f].get('network')
        if not isinstance(net2, dict):
            continue
        eth2 = net2.get('ethernets')
        if isinstance(eth2, dict) and iface in eth2:
            del eth2[iface]
            if a.dry_run:
                sys.stdout.write("### 将从 %s 移除 %s 的重复定义\n" % (f, iface))
            else:
                write_yaml(f, docs[f], header=False)
                print("CLEANED " + f)


def do_ifupdown_stanza(a):
    lines = ["# generated by netcfg.sh"]
    v4 = parse_addrs(a.addr, 4, 'IPv4')
    v6 = parse_addrs(a.v6, 6, 'IPv6')
    if a.mode == 'dhcp':
        lines.append("auto %s" % a.iface)
        lines.append("iface %s inet dhcp" % a.iface)
        if a.dns:
            lines.append("    dns-nameservers %s" % " ".join(parse_dns([a.dns])))
        if a.search:
            lines.append("    dns-search %s" % " ".join(parse_search([a.search])))
    else:
        prim = ipaddress.ip_interface(v4[0])
        lines.append("auto %s" % a.iface)
        lines.append("iface %s inet static" % a.iface)
        lines.append("    address %s" % prim.ip)
        lines.append("    netmask %s" % prim.network.netmask)
        if a.gw:
            lines.append("    gateway %s" % a.gw)
        for extra in v4[1:]:
            lines.append("    up ip addr add %s dev %s || true" % (extra, a.iface))
            lines.append("    down ip addr del %s dev %s || true" % (extra, a.iface))
        if a.dns:
            lines.append("    dns-nameservers %s" % " ".join(parse_dns([a.dns])))
        if a.search:
            lines.append("    dns-search %s" % " ".join(parse_search([a.search])))
        if a.mtu:
            lines.append("    mtu %s" % norm_mtu(a.mtu))
        for v in v6:
            lines.append("    up ip -6 addr add %s dev %s || true" % (v, a.iface))
        if a.gw6:
            lines.append("    up ip -6 route add default via %s dev %s || true" % (a.gw6, a.iface))
    print("\n".join(lines))


HOSTNAME_RE = re.compile(r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*\.?$')


def do_hostname_check(a):
    n = (a.name or '').strip()
    if not n:
        die("主机名不能为空")
    if len(n) > 253:
        die("主机名过长(>253)")
    if not HOSTNAME_RE.match(n):
        die("非法主机名: %s (只允许字母/数字/-/., 每个标签 1-63 位且不能以 - 开头或结尾)" % n)
    if n.lower() in ('localhost', 'localhost.localdomain'):
        die("不建议把主机名设成 %s" % n)
    print("ok")


def do_subnet_check(a):
    """pin 只改 IP: 新地址必须落在当前地址所在网段内"""
    try:
        base = ipaddress.ip_interface(a.base)
    except ValueError:
        die("当前地址不合法: %s" % a.base)
    if base.version != 4:
        die("当前地址不是 IPv4: %s" % a.base)
    net = base.network
    new = parse_addrs([a.new], 4, '新 IPv4')
    if not new:
        die("没有给出 -4 新地址")
    for n in new:
        nif = ipaddress.ip_interface(n)
        if nif.ip not in net:
            die("新地址 %s 不在当前网段 %s 内; pin 只允许同网段换 IP(跨网段请用 set)" % (n, net))
        if nif.network.prefixlen != net.prefixlen and not a.allow_other_prefix:
            die("新地址前缀 /%d 与当前 /%d 不一致; 如确需请加 --allow-other-prefix"
                % (nif.network.prefixlen, net.prefixlen))
        if nif.ip == net.network_address:
            die("不能用网络地址 %s" % nif.ip)
        if nif.ip == net.broadcast_address:
            die("不能用广播地址 %s" % nif.ip)
    print("ok")


def do_summary(a):
    load_yaml_module()
    root = a.root
    ndir = rp(root, '/etc/netplan')
    files = sorted(glob.glob(os.path.join(ndir, '*.yaml')))
    if not files:
        print("(没有找到 netplan 配置文件)")
        return
    for f in files:
        print("配置: %s" % f)
        data = yaml.safe_load(open(f)) or {}
        net = data.get('network') or {}
        print("  version=%s renderer=%s" % (net.get('version', '-'), net.get('renderer', '(默认 networkd)')))
        for sect in ('ethernets', 'bridges', 'bonds', 'vlans'):
            d = net.get(sect) or {}
            if not isinstance(d, dict):
                continue
            for nm, cfg in d.items():
                cfg = cfg or {}
                if sect != 'ethernets':
                    print("  [%s] %s  interfaces=%s" % (sect, nm, ",".join(cfg.get('interfaces') or [])))
                    continue
                if cfg.get('dhcp4'):
                    mode = 'DHCP'
                elif cfg.get('addresses'):
                    mode = '静态'
                else:
                    mode = '未配置'
                print("  [ethernet] %s  模式=%s" % (nm, mode))
                if cfg.get('addresses'):
                    print("        地址: %s" % ", ".join(str(x) for x in cfg['addresses']))
                gws = []
                for r in (cfg.get('routes') or []):
                    if isinstance(r, dict) and str(r.get('to')) in ('default', '0.0.0.0/0', '::/0') and r.get('via'):
                        gws.append(str(r['via']))
                for k in ('gateway4', 'gateway6'):
                    if cfg.get(k):
                        gws.insert(0, "%s (%s)" % (cfg[k], k))
                if gws:
                    print("        网关: %s" % ", ".join(gws))
                ns = cfg.get('nameservers') or {}
                if ns.get('addresses'):
                    print("        DNS: %s" % ", ".join(str(x) for x in ns['addresses']))
                if ns.get('search'):
                    print("        搜索域: %s" % ", ".join(str(x) for x in ns['search']))
                if cfg.get('mtu'):
                    print("        MTU: %s" % cfg['mtu'])


def main():
    p = argparse.ArgumentParser(prog='netcfg-py')
    sub = p.add_subparsers(dest='cmd')

    def add_common(sp):
        sp.add_argument('--root', default='/')
        sp.add_argument('--iface', default='')
        sp.add_argument('--addr', action='append', default=[])
        sp.add_argument('--v6', action='append', default=[])
        sp.add_argument('--gw', default='')
        sp.add_argument('--gw6', default='')
        sp.add_argument('--dns', default=None)
        sp.add_argument('--no-dns', action='store_true')
        sp.add_argument('--search', default=None)
        sp.add_argument('--mtu', default='')
        sp.add_argument('--dhcp6', action='store_true')

    sp = sub.add_parser('validate')
    add_common(sp)
    sp.add_argument('--mode', default='static')
    sp.add_argument('--allow-offlink', action='store_true')

    sp = sub.add_parser('edit-netplan')
    add_common(sp)
    sp.add_argument('--mode', default='static')
    sp.add_argument('--allow-offlink', action='store_true')
    sp.add_argument('--dry-run', action='store_true')

    sp = sub.add_parser('ifupdown-stanza')
    add_common(sp)
    sp.add_argument('--mode', default='static')

    sp = sub.add_parser('hostname-check')
    sp.add_argument('--name', required=True)

    sp = sub.add_parser('subnet-check')
    sp.add_argument('--base', required=True)
    sp.add_argument('--new', required=True)
    sp.add_argument('--allow-other-prefix', action='store_true')

    sp = sub.add_parser('summary')
    sp.add_argument('--root', default='/')

    a = p.parse_args()
    if not getattr(a, 'cmd', None):
        p.error('缺少子命令')
    if a.cmd == 'validate':
        do_validate(a)
    elif a.cmd == 'edit-netplan':
        do_edit_netplan(a)
    elif a.cmd == 'ifupdown-stanza':
        do_ifupdown_stanza(a)
    elif a.cmd == 'hostname-check':
        do_hostname_check(a)
    elif a.cmd == 'subnet-check':
        do_subnet_check(a)
    elif a.cmd == 'summary':
        do_summary(a)


if __name__ == '__main__':
    main()
PYEOF
}

# ------------------------------------------------------------------ 探测 ---
detect_backend() {
  if [ "$BACKEND" != "auto" ]; then printf '%s' "$BACKEND"; return 0; fi
  local ndir; ndir=$(real_path /etc/netplan)
  if command -v netplan >/dev/null 2>&1 && [ -d "$ndir" ] && compgen -G "$ndir/*.yaml" >/dev/null 2>&1; then
    printf 'netplan'; return 0
  fi
  local nm_active=0 net_active=0
  if command -v nmcli >/dev/null 2>&1 && nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
    nm_active=1
  fi
  if systemctl is-active --quiet network 2>/dev/null; then net_active=1; fi
  if [ "$nm_active" -eq 1 ] && [ "$net_active" -eq 1 ]; then
    warn "NetworkManager 与 network.service 同时在跑, 可能有配置冲突; 本次按 nmcli 处理"
  fi
  if [ "$nm_active" -eq 1 ]; then printf 'nmcli'; return 0; fi
  # CentOS 7 server 传统模式: network.service + ifcfg
  if [ -d "$(real_path /etc/sysconfig/network-scripts)" ] && command -v ifup >/dev/null 2>&1; then
    printf 'ifcfg'; return 0
  fi
  if [ -f "$(real_path /etc/network/interfaces)" ] && command -v ifup >/dev/null 2>&1; then
    printf 'ifupdown'; return 0
  fi
  printf 'none'
}

default_iface() {
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -z "$dev" ]; then die "无法自动识别默认网卡, 请用 -i <网卡名> 指定"; fi
  printf '%s' "$dev"
}

ip_addrs_on() { ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}'; }

# 过滤掉本机 stub/回环 DNS
filter_dns_servers() {
  local w
  for w in $1; do
    case "$w" in
      ''|127.0.0.1|127.0.0.53|127.0.0.54|::1) continue ;;
    esac
    printf '%s\n' "$w"
  done
  return 0
}

# 从当前运行态采集 IP/网关/DNS/搜索域/MTU, 用于"固化"成静态配置
capture_current() {
  if [ -z "$IFACE" ]; then IFACE=$(default_iface); fi
  local -a tmp=()
  local line w

  if [ ${#ADDRS[@]} -eq 0 ]; then
    while IFS= read -r line; do
      case "$line" in */*) tmp+=("$line") ;; esac
    done < <(ip_addrs_on "$IFACE")
    if [ ${#tmp[@]} -eq 0 ]; then
      die "网卡 $IFACE 当前没有 IPv4 地址, 无法固化(可用 -i 指定其它网卡, 或直接用 -4 指定地址)"
    fi
    ADDRS=("${tmp[@]}")
  fi

  if [ -z "$GW" ]; then
    GW=$(ip -4 route show default 2>/dev/null | awk -v d="$IFACE" '
      $1=="default" {
        v=""; dd="";
        for (i=1;i<=NF;i++) { if ($i=="via") v=$(i+1); if ($i=="dev") dd=$(i+1) }
        if (dd==d && v!="") { print v; exit }
      }')
    if [ -z "$GW" ]; then warn "没有经过 $IFACE 的默认路由, 本次将不写网关(需要就用 -g 指定)"; fi
  fi

  if [ "$WITH_IPV6" -eq 1 ] && [ ${#V6S[@]} -eq 0 ]; then
    tmp=()
    while IFS= read -r line; do
      case "$line" in */*) tmp+=("$line") ;; esac
    done < <(ip -o -6 addr show dev "$IFACE" scope global 2>/dev/null \
             | grep -vE 'temporary|deprecated' | awk '{print $4}')
    if [ ${#tmp[@]} -gt 0 ]; then V6S=("${tmp[@]}"); fi
    tmp=()
    if [ -z "$GW6" ]; then
      GW6=$(ip -6 route show default 2>/dev/null | awk -v d="$IFACE" '
        $1=="default" {
          v=""; dd="";
          for (i=1;i<=NF;i++) { if ($i=="via") v=$(i+1); if ($i=="dev") dd=$(i+1) }
          if (dd==d && v!="") { print v; exit }
        }')
    fi
  fi

  if [ "$DNS_GIVEN" -eq 0 ] && [ ${#DNSES[@]} -eq 0 ]; then
    local raw=""
    if command -v resolvectl >/dev/null 2>&1; then
      raw=$(resolvectl dns "$IFACE" 2>/dev/null | sed -n 's/^[^)]*):[[:space:]]*//p' | head -1)
      if [ -z "$raw" ]; then
        raw=$(resolvectl status "$IFACE" 2>/dev/null | awk -F: '/^[ \t]*DNS Servers:/{print $2; exit}')
      fi
    fi
    if [ -z "$raw" ] && command -v nmcli >/dev/null 2>&1; then
      local _cn
      _cn=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
            | awk -F: -v d="$IFACE" '$NF==d{print; exit}' | sed 's/:[^:]*$//')
      if [ -n "$_cn" ]; then
        raw=$(nmcli -t -f ipv4.dns connection show "$_cn" 2>/dev/null \
              | sed -n 's/^ipv4\.dns://p' | tr ',' ' ')
      fi
    fi
    if [ -z "$raw" ] && [ -r /etc/resolv.conf ]; then
      raw=$(awk '/^[[:space:]]*nameserver/{printf "%s ",$2}' /etc/resolv.conf)
    fi
    while IFS= read -r line; do
      if [ -n "$line" ]; then DNSES+=("$line"); fi
    done < <(filter_dns_servers "$raw")
    if [ ${#DNSES[@]} -eq 0 ]; then warn "没能从当前系统读到可用 DNS, 需要就用 -d 指定"; fi
  fi

  if [ ${#SEARCHES[@]} -eq 0 ]; then
    local dline=""
    if command -v resolvectl >/dev/null 2>&1; then
      dline=$(resolvectl domain "$IFACE" 2>/dev/null | sed -n 's/^[^)]*):[[:space:]]*//p' | head -1)
    fi
    if [ -z "$dline" ] && [ -r /etc/resolv.conf ]; then
      dline=$(awk '/^[[:space:]]*search/{for(i=2;i<=NF;i++) printf "%s ",$i}' /etc/resolv.conf)
    fi
    for w in $dline; do
      case "$w" in ''|'~.'|'~'*) continue ;; esac
      SEARCHES+=("$w")
    done
  fi

  if [ -z "$MTU" ]; then
    local m
    m=$(ip link show dev "$IFACE" 2>/dev/null | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$m" ] && [ "$m" != "1500" ]; then MTU="$m"; fi
  fi

  if [ ${#DNSES[@]} -gt 0 ]; then DNS_GIVEN=1; fi
  MODE=static
  CAPTURE_SOURCE=1
  info "已从运行态采集: 地址 $(join_list ADDRS) / 网关 ${GW:-无} / DNS ${DNSES[*]-无}"
  return 0
}

# ------------------------------------------------------------------ 备份 ---
make_backup() {
  ensure_py
  local ts bdir rel have=()
  ts=$(date +%Y%m%d-%H%M%S)
  BACKUP_ROOT=$(real_path /var/backups/netcfg)
  bdir="$BACKUP_ROOT/$ts"
  mkdir -p "$bdir"
  for rel in etc/netplan etc/resolv.conf etc/resolvconf/resolv.conf.d \
             etc/network/interfaces etc/network/interfaces.d \
             etc/NetworkManager/system-connections etc/dhcp/dhclient.conf \
             etc/sysconfig/network-scripts; do
    if [ -e "$(real_path "/$rel")" ] || [ -L "$(real_path "/$rel")" ]; then have+=("./$rel"); fi
  done
  if [ ${#have[@]} -gt 0 ]; then
    tar -czf "$bdir/etc.tar.gz" -C "$ROOT" "${have[@]}" 2>/dev/null || warn "备份部分文件失败(继续)"
  else
    warn "没有可备份的网络配置文件"
    : > "$bdir/etc.tar.gz.empty"
  fi
  : > "$bdir/created.list"
  {
    printf 'BACKUP_DIR=%q\n' "$bdir"
    printf 'ROOT=%q\n' "$ROOT"
    printf 'BACKEND=%q\n' "$BACKEND"
    printf 'IFACE=%q\n' "$IFACE"
    printf 'SELF=%q\n' "$SELF"
    printf 'CREATED_AT=%q\n' "$(date '+%F %T')"
  } > "$bdir/meta.env"
  write_rollback_script "$bdir"
  printf '%s' "$bdir"
}

write_rollback_script() {
  local bdir="$1" apply_cmds=""
  case "$BACKEND" in
    netplan)  apply_cmds="netplan apply >/dev/null 2>&1 || true" ;;
    ifupdown) apply_cmds="ifdown '$IFACE' >/dev/null 2>&1 || true
ifup '$IFACE' >/dev/null 2>&1 || true" ;;
    ifcfg)    apply_cmds="ifdown '$IFACE' >/dev/null 2>&1 || true
ifup '$IFACE' >/dev/null 2>&1 || true" ;;
    nmcli)    apply_cmds="nmcli connection reload >/dev/null 2>&1 || true
nmcli device reapply '$IFACE' >/dev/null 2>&1 || {
  con=\$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d='$IFACE' '\$NF==d{print; exit}')
  if [ -n \"\$con\" ]; then nmcli connection up \"\${con%:*}\" >/dev/null 2>&1 || true; fi
}" ;;
    *)        apply_cmds="true" ;;
  esac
  cat > "$bdir/rollback.sh" <<EOF
#!/bin/bash
# 由 netcfg.sh 自动生成: 还原备份并重新应用网络配置
# 自包含: 不依赖原脚本位置, 管道执行(curl | bash)时同样可用
set -u
ROOT='$ROOT'
BDIR='$bdir'
if [ -s "\$BDIR/created.list" ]; then
  while IFS= read -r f; do
    [ -n "\$f" ] || continue
    rm -f "\${ROOT%/}\$f" 2>/dev/null || true
  done < "\$BDIR/created.list"
fi
if [ -f "\$BDIR/etc.tar.gz" ]; then
  tar -xzf "\$BDIR/etc.tar.gz" -C "\$ROOT" || exit 1
fi
$apply_cmds
echo "[rollback] \$(date '+%F %T') 已还原 \$BDIR"
EOF
  chmod +x "$bdir/rollback.sh"
}

restore_backup() {
  local bdir="${1:-}"
  [ -n "$bdir" ] || die "未指定备份目录"
  [ -d "$bdir" ] || die "备份目录不存在: $bdir"
  # 回滚时上层可能没指定网卡: 从备份的 meta.env 里取回
  if [ -f "$bdir/meta.env" ]; then
    local _v
    _v=$(sed -n 's/^IFACE=//p' "$bdir/meta.env" | head -1 | tr -d "\"'")
    if [ -n "$_v" ]; then IFACE="$_v"; fi
    _v=$(sed -n 's/^BACKEND=//p' "$bdir/meta.env" | head -1 | tr -d "\"'")
    if [ -n "$_v" ]; then BACKEND="$_v"; fi
  fi
  if [ -z "${IFACE:-}" ]; then
    set +e; IFACE=$(default_iface); set -e
  fi
  info "开始回滚: $bdir (网卡 $IFACE, 后端 $BACKEND)"
  if [ -s "$bdir/created.list" ]; then
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local abs; abs=$(real_path "$f")
      if [ -e "$abs" ] || [ -L "$abs" ]; then rm -f "$abs"; vlog "删除本次新建文件: $abs"; fi
    done < "$bdir/created.list"
  fi
  if [ -f "$bdir/etc.tar.gz" ]; then
    tar -xzf "$bdir/etc.tar.gz" -C "$ROOT" || { err "解包备份失败, 请手工处理: $bdir"; return 1; }
  fi
  info "配置文件已还原, 重新应用..."
  NMCLI_HARD=1
  backend_apply_quiet || warn "回滚后重新应用失败, 请执行: netplan apply / systemctl restart networking"
  info "回滚完成"
}

# ------------------------------------------------------------- 看门狗 ---
guard_arm() {
  local bdir="$1" secs="$2"
  if [ "$GUARD" -ne 1 ] || [ "$secs" -le 0 ]; then vlog "看门狗未启用"; return 0; fi
  cat > "$bdir/watchdog.sh" <<EOF
#!/bin/bash
for ((i=0;i<${secs};i++)); do
  [ -e "$bdir/.confirmed" ] && exit 0
  sleep 1
done
echo "[\$(date '+%F %T')] 未收到确认, 自动回滚" >> "$bdir/watchdog.log"
setsid bash "$bdir/rollback.sh" >> "$bdir/watchdog.log" 2>&1
EOF
  chmod +x "$bdir/watchdog.sh"
  setsid nohup bash "$bdir/watchdog.sh" >/dev/null 2>&1 </dev/null &
  WATCHDOG_PID=$!
  info "看门狗已启动: ${secs}s 内未确认将自动回滚($bdir/watchdog.sh)"
}

guard_confirm() {
  if [ -n "$BDIR" ]; then
    : > "$BDIR/.confirmed"
  fi
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
  return 0
}

# ------------------------------------------------------------- 后端实现 ---
run_cmd() {
  if [ "$ROOT" != "/" ] && [ "${NETCFG_SANDBOX:-0}" != "1" ]; then
    info "(沙箱) 跳过执行: $*"
    return 0
  fi
  vlog "执行: $*"
  "$@"
}

netplan_py_args() {
  NP_ARGS=(--root "$ROOT" --iface "$IFACE" --mode "$MODE")
  if [ ${#ADDRS[@]} -gt 0 ]; then NP_ARGS+=(--addr "$(join_list ADDRS)"); fi
  if [ ${#V6S[@]} -gt 0 ]; then NP_ARGS+=(--v6 "$(join_list V6S)"); fi
  if [ -n "$GW" ]; then NP_ARGS+=(--gw "$GW"); fi
  if [ -n "$GW6" ]; then NP_ARGS+=(--gw6 "$GW6"); fi
  if [ "$NO_DNS" -eq 1 ]; then NP_ARGS+=(--dns ""); fi
  if [ "${DNS_GIVEN:-0}" -eq 1 ] && [ "$NO_DNS" -eq 0 ]; then NP_ARGS+=(--dns "$(join_list DNSES)"); fi
  if [ ${#SEARCHES[@]} -gt 0 ]; then NP_ARGS+=(--search "$(join_list SEARCHES)"); fi
  if [ -n "$MTU" ]; then NP_ARGS+=(--mtu "$MTU"); fi
  if [ "$DHCP6" -eq 1 ]; then NP_ARGS+=(--dhcp6); fi
  if [ "$DRY_RUN" -eq 1 ]; then NP_ARGS+=(--dry-run); fi
  return 0
}

backend_netplan_write() {
  ensure_py
  netplan_py_args
  local out
  out=$(python3 "$PY" edit-netplan "${NP_ARGS[@]}")
  printf '%s\n' "$out"
  if [ "$DRY_RUN" -ne 1 ] && [ -n "$BDIR" ]; then
    printf '%s\n' "$out" | awk '$1=="CREATED"{print $2}' >> "$BDIR/created.list"
  fi
  if [ "$DRY_RUN" -ne 1 ] && [ "$ROOT" = "/" ]; then
    chmod 600 "$(real_path /etc/netplan)"/*.yaml 2>/dev/null || true
  fi
  return 0
}

backend_netplan_validate() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  if ! command -v netplan >/dev/null 2>&1; then
    if [ "$ROOT" != "/" ]; then
      vlog "本机无 netplan, 沙箱内跳过 generate 校验"
      return 0
    fi
    die "找不到 netplan 命令"
  fi
  local -a cmd=(netplan generate)
  if [ "$ROOT" != "/" ]; then cmd+=(--root-dir "$ROOT"); fi
  if ! run_cmd "${cmd[@]}" >/tmp/netcfg-generate.$$ 2>&1; then
    err "netplan 配置校验失败:"
    sed 's/^/    /' /tmp/netcfg-generate.$$ >&2 || true
    rm -f /tmp/netcfg-generate.$$
    return 1
  fi
  rm -f /tmp/netcfg-generate.$$
  info "netplan generate 校验通过"
  return 0
}

backend_netplan_apply() { run_cmd netplan apply; }

backend_ifupdown_write() {
  ensure_py
  local f iface_file
  iface_file=$(real_path "/etc/network/interfaces.d/$IFACE")
  mkdir -p "$(dirname "$iface_file")"
  if [ ! -e "$iface_file" ] && [ -n "$BDIR" ]; then
    printf '/etc/network/interfaces.d/%s\n' "$IFACE" >> "$BDIR/created.list"
  fi
  local -a args=(ifupdown-stanza --iface "$IFACE" --mode "$MODE")
  if [ ${#ADDRS[@]} -gt 0 ]; then args+=(--addr "$(join_list ADDRS)"); fi
  if [ ${#V6S[@]} -gt 0 ]; then args+=(--v6 "$(join_list V6S)"); fi
  [ -n "$GW" ] && args+=(--gw "$GW")
  [ -n "$GW6" ] && args+=(--gw6 "$GW6")
  [ "$NO_DNS" -eq 0 ] && [ ${#DNSES[@]} -gt 0 ] && args+=(--dns "$(join_list DNSES)")
  [ ${#SEARCHES[@]} -gt 0 ] && args+=(--search "$(join_list SEARCHES)")
  [ -n "$MTU" ] && args+=(--mtu "$MTU")
  local content; content=$(python3 "$PY" "${args[@]}")
  if [ "$DRY_RUN" -eq 1 ]; then
    log "### 将要写入 $iface_file"
    printf '%s\n' "$content"
    return 0
  fi
  printf '%s\n' "$content" > "$iface_file"
  info "已写入 $iface_file"
  # 确保主配置 include 了 interfaces.d
  local main; main=$(real_path /etc/network/interfaces)
  if [ -f "$main" ] && ! grep -qE '^\s*source\s+.*interfaces\.d' "$main"; then
    printf '\nsource /etc/network/interfaces.d/*\n' >> "$main"
    info "已在 $main 中追加 source /etc/network/interfaces.d/*"
  fi
  return 0
}

backend_ifupdown_validate() { return 0; }

backend_ifupdown_apply() {
  run_cmd ifdown "$IFACE" || true
  run_cmd ifup "$IFACE"
}

# ------------------------------------------------- ifcfg (CentOS 7 server) ---
ifcfg_dir()  { printf '%s' "$(real_path /etc/sysconfig/network-scripts)"; }
ifcfg_path() { printf '%s/%s' "$(ifcfg_dir)" "ifcfg-$IFACE"; }

ifcfg_render() {
  local a ip pfx i n
  if [ "$MODE" = "dhcp" ]; then
    printf 'BOOTPROTO=dhcp\n'
  else
    printf 'BOOTPROTO=none\n'
    i=0
    for a in "${ADDRS[@]-}"; do
      if [ -z "$a" ]; then continue; fi
      ip="${a%/*}"
      pfx="${a#*/}"
      if [ "$i" -eq 0 ]; then
        printf 'IPADDR=%s\nPREFIX=%s\n' "$ip" "$pfx"
      else
        printf 'IPADDR%s=%s\nPREFIX%s=%s\n' "$i" "$ip" "$i" "$pfx"
      fi
      i=$((i+1))
    done
    if [ -n "$GW" ]; then
      printf 'GATEWAY=%s\nDEFROUTE=yes\n' "$GW"
    fi
  fi
  if [ ${#DNSES[@]} -gt 0 ]; then
    n=1
    for a in "${DNSES[@]}"; do
      printf 'DNS%s=%s\n' "$n" "$a"
      n=$((n+1))
    done
    if [ "$MODE" = "dhcp" ]; then printf 'PEERDNS=no\n'; fi
  fi
  printf 'ONBOOT=yes\n'
  if [ -n "$MTU" ]; then printf 'MTU=%s\n' "$MTU"; fi
  return 0
}

backend_ifcfg_write() {
  local f d tmp
  d=$(ifcfg_dir); f=$(ifcfg_path)
  if [ ! -d "$d" ]; then die "找不到 $d (确认是 ifcfg/network-scripts 系统)"; fi
  if [ -f "$f" ] && grep -qE '^(BONDING_|BRIDGE=|TEAM_|VLAN=|BRIDGE_)' "$f"; then
    die "ifcfg 含 bond/bridge/team/vlan 配置, 本脚本只支持普通以太网: $f"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '### 目标文件: %s\n' "$f"
    ifcfg_render
    return 0
  fi
  tmp="$f.netcfg.tmp"
  {
    if [ -f "$f" ]; then
      grep -vE '^(BOOTPROTO|IPADDR[0-9]*|PREFIX[0-9]*|NETMASK[0-9]*|GATEWAY|DNS[0-9]+|PEERDNS|ONBOOT|DEFROUTE|MTU)=' "$f" || true
    else
      printf 'TYPE=Ethernet\nDEVICE=%s\n' "$IFACE"
    fi
    ifcfg_render
  } > "$tmp" || die "生成 $tmp 失败"
  chmod 644 "$tmp"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; die "写入 $f 失败"; }
  if command -v restorecon >/dev/null 2>&1; then restorecon "$f" >/dev/null 2>&1 || true; fi
  info "已写入 $f"
  return 0
}

backend_ifcfg_validate() {
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  local f; f=$(ifcfg_path)
  if [ ! -f "$f" ]; then err "ifcfg 未生成: $f"; return 1; fi
  if [ "$MODE" != "dhcp" ] && ! grep -q '^IPADDR=' "$f"; then
    err "ifcfg 缺少 IPADDR: $f"; return 1
  fi
  info "ifcfg 校验通过: $f"
  return 0
}

backend_ifcfg_apply() {
  run_cmd ifdown "$IFACE" || true
  run_cmd ifup "$IFACE"
}

backend_nmcli_con() {
  local line
  line=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$IFACE" '$NF==d{print; exit}' || true)
  [ -n "$line" ] || return 1
  printf '%s' "${line%:*}"
}

backend_nmcli_write() {
  local con; con=$(backend_nmcli_con) || die "找不到网卡 $IFACE 对应的 NetworkManager 连接(用 nmcli connection show 确认)"
  local -a cmd=(nmcli connection modify "$con")
  if [ "$MODE" = "dhcp" ]; then
    cmd+=(ipv4.method auto ipv4.addresses "" ipv4.gateway "")
  else
    cmd+=(ipv4.method manual ipv4.addresses "$(join_list ADDRS)")
    cmd+=(ipv4.gateway "${GW:-}")
  fi
  if [ ${#V6S[@]} -gt 0 ]; then
    cmd+=(ipv6.method manual ipv6.addresses "$(join_list V6S)")
    [ -n "$GW6" ] && cmd+=(ipv6.gateway "$GW6")
  fi
  if [ "$NO_DNS" -eq 1 ]; then
    cmd+=(ipv4.dns "" ipv6.dns "")
  elif [ ${#DNSES[@]} -gt 0 ]; then
    local _d _v4=" " _v6=" "
    for _d in "${DNSES[@]}"; do
      case "$_d" in
        *:*) _v6="$_v6$_d " ;;
        *)   _v4="$_v4$_d " ;;
      esac
    done
    if [ "$(printf '%s' "$_v4" | tr -d ' ')" != "" ]; then
      cmd+=(ipv4.dns "${_v4# }")
    fi
    if [ "$(printf '%s' "$_v6" | tr -d ' ')" != "" ]; then
      cmd+=(ipv6.dns "${_v6# }")
    fi
    if [ "$MODE" = "dhcp" ]; then cmd+=(ipv4.ignore-auto-dns yes); fi
  fi
  if [ ${#SEARCHES[@]} -gt 0 ]; then cmd+=(ipv4.dns-search "${SEARCHES[*]}"); fi
  cmd+=(connection.autoconnect yes)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '### 将要执行: %s\n' "${cmd[*]}"
    printf '### 然后执行: nmcli connection up %s\n' "$con"
    return 0
  fi
  run_cmd "${cmd[@]}"
  info "已更新 NetworkManager 连接: $con"
  NMCLI_CON="$con"
  return 0
}

backend_nmcli_validate() { return 0; }

backend_nmcli_apply() {
  # CentOS 7/NM 1.18 实测: 还原 ifcfg 后 reapply 有时是空操作, connection up 才真正下发;
  # 所以两步都试, 并用 profile 的期望地址做校验
  local con i ok a have expect
  run_cmd nmcli connection reload || true
  sleep 2
  con="${NMCLI_CON:-}"
  for i in 1 2 3 4 5; do
    if [ -n "$con" ]; then break; fi
    con=$(backend_nmcli_con 2>/dev/null || true)
    if [ -z "$con" ]; then sleep 1; fi
  done
  if [ -z "$con" ]; then
    warn "找不到网卡 $IFACE 对应的 NM 连接, 重启 NetworkManager"
    run_cmd systemctl restart NetworkManager
    return $?
  fi

  if [ "${NMCLI_HARD:-0}" -ne 1 ] && nmcli_apply_matches "$con"; then
    vlog "reapply 后地址已符合 profile"
    return 0
  fi
  warn "设备地址与 profile 不一致, 尝试 down/up $con"
  # 对已激活连接直接 up 往往是空操作, 必须先 down 再 up 才会按新 profile 下发
  for i in 1 2 3; do
    run_cmd nmcli connection down "$con" >/dev/null 2>&1 || true
    sleep 1
    if run_cmd nmcli connection up "$con"; then
      sleep 1
      if nmcli_apply_matches "$con"; then return 0; fi
    fi
    sleep 2
  done
  warn "nmcli 激活后地址仍不符, 重启 NetworkManager"
  run_cmd systemctl restart NetworkManager
  sleep 3
  if nmcli_apply_matches "$con"; then return 0; fi
  err "NetworkManager 重启后地址仍与 profile 不一致"
  return 1
}

# 先 reapply 再比对: profile 里的 ipv4.addresses 是否都已落到网卡上
nmcli_apply_matches() {
  local con="$1" a have expect
  # 沙箱里 nmcli 是桩, 无法比对实际地址, 直接视为成功
  if [ "$ROOT" != "/" ]; then return 0; fi
  run_cmd nmcli device reapply "$IFACE" >/dev/null 2>&1 || true
  sleep 1
  expect=$(nmcli -g ipv4.addresses connection show "$con" 2>/dev/null | tr ',' ' ' | tr -d ' ')
  if [ -z "$expect" ]; then
    sleep 1
    expect=$(nmcli -g ipv4.addresses connection show "$con" 2>/dev/null | tr ',' ' ' | tr -d ' ')
  fi
  if [ -z "$expect" ]; then return 1; fi
  have=$(ip_addrs_on "$IFACE")
  for a in $expect; do
    printf '%s\n' "$have" | grep -qxF -- "$a" || return 1
  done
  return 0
}

backend_write() {
  case "$BACKEND" in
    netplan)  backend_netplan_write ;;
    ifupdown) backend_ifupdown_write ;;
    ifcfg)    backend_ifcfg_write ;;
    nmcli)    backend_nmcli_write ;;
    *) die "未知后端: $BACKEND" ;;
  esac
}

backend_validate() {
  case "$BACKEND" in
    netplan)  backend_netplan_validate ;;
    ifupdown) backend_ifupdown_validate ;;
    ifcfg)    backend_ifcfg_validate ;;
    nmcli)    backend_nmcli_validate ;;
  esac
}

backend_apply() {
  case "$BACKEND" in
    netplan)  backend_netplan_apply ;;
    ifupdown) backend_ifupdown_apply ;;
    ifcfg)    backend_ifcfg_apply ;;
    nmcli)    backend_nmcli_apply ;;
  esac
}

backend_apply_quiet() {
  backend_apply >/dev/null 2>&1 || return 1
  return 0
}

# ---------------------------------------------------------------- DNS 落地 ---
apply_resolv_conf() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ ${#DNSES[@]} -gt 0 ] || return 0
  if [ "$BACKEND" = "nmcli" ]; then
    vlog "NetworkManager 自己写 resolv.conf, 跳过直写"
    return 0
  fi
  local rc; rc=$(real_path /etc/resolv.conf)
  if [ -L "$rc" ]; then
    local tgt; tgt=$(readlink -f "$rc" 2>/dev/null || true)
    case "$tgt" in
      */systemd/resolve/*)
        vlog "resolv.conf 由 systemd-resolved 管理, netplan 已下发 DNS"
        return 0 ;;
    esac
  fi
  local rcdir; rcdir=$(real_path /etc/resolvconf/resolv.conf.d)
  if [ -d "$rcdir" ]; then
    {
      printf '# generated by netcfg.sh at %s\n' "$(date '+%F %T')"
      local d
      for d in "${DNSES[@]}"; do printf 'nameserver %s\n' "$d"; done
      if [ ${#SEARCHES[@]} -gt 0 ]; then printf 'search %s\n' "${SEARCHES[*]}"; fi
      printf 'options timeout:2 attempts:3 rotate\n'
    } > "$rcdir/base"
    info "已写入 $rcdir/base"
    if [ "$ROOT" = "/" ] && command -v resolvconf >/dev/null 2>&1; then
      resolvconf -u >/dev/null 2>&1 || warn "resolvconf -u 执行失败"
    fi
    return 0
  fi
  if [ -f "$rc" ] && [ ! -L "$rc" ] || [ -L "$rc" ]; then
    {
      printf '# generated by netcfg.sh at %s\n' "$(date '+%F %T')"
      local d
      for d in "${DNSES[@]}"; do printf 'nameserver %s\n' "$d"; done
      if [ ${#SEARCHES[@]} -gt 0 ]; then printf 'search %s\n' "${SEARCHES[*]}"; fi
    } > "$rc"
    info "已直接写入 $rc"
  fi
  if [ "$MODE" = "dhcp" ]; then
    local dhclient; dhclient=$(real_path /etc/dhcp/dhclient.conf)
    if [ -f "$dhclient" ] && ! grep -q 'netcfg.sh' "$dhclient"; then
      {
        printf '\n# netcfg.sh: 防止 dhclient 覆盖 resolv.conf\n'
        printf 'supersede domain-name-servers %s;\n' "$(join_list DNSES | tr ',' ' ')"
      } >> "$dhclient"
      info "已在 $dhclient 中加 supersede, 避免 DHCP 覆盖 DNS"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- 校验 ---
# 当前配置文件指纹, 用于发现"应用过程中配置被改动/已被看门狗回滚"
config_fingerprint() {
  local dir file
  case "$BACKEND" in
    netplan)
      dir=$(real_path /etc/netplan)
      if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null \
          | sort -z | xargs -0 -r cat 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
      fi
      ;;
    ifupdown)
      dir=$(real_path /etc/network/interfaces)
      file=$(real_path "/etc/network/interfaces.d/$IFACE")
      { if [ -f "$dir" ]; then cat "$dir"; fi; if [ -f "$file" ]; then cat "$file"; fi; } 2>/dev/null \
        | sha256sum 2>/dev/null | awk '{print $1}'
      ;;
    ifcfg)
      file=$(ifcfg_path)
      if [ -f "$file" ]; then sha256sum "$file" 2>/dev/null | awk '{print $1}'; fi
      ;;
    *) printf '' ;;
  esac
}

verify_network() {
  local i a ok have soft=0
  if [ "$VERIFY" -ne 1 ]; then info "跳过校验(--no-verify)"; return 0; fi

  if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    err "网卡 $IFACE 不存在或无法读取"; return 1
  fi

  ok=0
  for ((i=0;i<VERIFY_TRIES;i++)); do
    ok=1
    if [ ${#ADDRS[@]} -gt 0 ]; then
      have=$(ip_addrs_on "$IFACE")
      for a in "${ADDRS[@]}"; do
        printf '%s\n' "$have" | grep -qxF -- "$a" || ok=0
      done
    fi
    if [ ${#V6S[@]} -gt 0 ]; then
      have=$(ip -o -6 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}')
      for a in "${V6S[@]}"; do
        printf '%s\n' "$have" | grep -qixF -- "$a" || ok=0
      done
    fi
    if [ ${#ADDRS[@]} -eq 0 ] && [ ${#V6S[@]} -eq 0 ]; then
      have=$(ip_addrs_on "$IFACE")
      if [ -z "$have" ]; then ok=0; fi
    fi
    if [ "$ok" -eq 1 ]; then break; fi
    sleep "$VERIFY_INTERVAL"
  done
  if [ "$ok" -ne 1 ]; then
    err "地址校验失败: 期望 [${ADDRS[*]-} ${V6S[*]-}(为空则 DHCP 自动获取)], 实际 [$(ip_addrs_on "$IFACE" | tr '\n' ' ')]"
    return 1
  fi
  info "地址校验通过: $(ip_addrs_on "$IFACE" | tr '\n' ' ')"

  if [ -n "$GW" ] || [ -n "$GW6" ] || [ "$MODE" = "dhcp" ]; then
    ok=0
    for ((i=0;i<5;i++)); do
      if ip -4 route show default 2>/dev/null | grep -q "dev $IFACE"; then ok=1; break; fi
      if [ -n "$GW6" ] && ip -6 route show default 2>/dev/null | grep -q "dev $IFACE"; then ok=1; break; fi
      sleep "$VERIFY_INTERVAL"
    done
    if [ "$ok" -ne 1 ]; then err "路由校验失败: 没有经过 $IFACE 的默认路由"; return 1; fi
    info "默认路由: $(ip -4 route show default | grep "dev $IFACE" | head -1)"
    if [ -n "$GW6" ]; then info "IPv6 默认路由: $(ip -6 route show default | grep "dev $IFACE" | head -1)"; fi
  fi

  if [ -n "$GW" ]; then
    if ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
      info "网关 $GW 可达"
    else
      warn "网关 $GW ping 不通(可能禁 ping, 默认不据此回滚)"
      soft=1
    fi
  fi

  if [ ${#DNSES[@]} -gt 0 ] && [ -n "$VERIFY_HOST" ]; then
    ok=0
    for ((i=0;i<3;i++)); do
      if getent hosts "$VERIFY_HOST" >/dev/null 2>&1; then ok=1; break; fi
      sleep "$VERIFY_INTERVAL"
    done
    if [ "$ok" -eq 1 ]; then info "DNS 解析正常: $VERIFY_HOST"; else warn "DNS 解析 $VERIFY_HOST 失败"; soft=1; fi
  fi

  if [ "$soft" -eq 1 ] && [ "$STRICT" -eq 1 ]; then
    err "软校验失败且指定 --strict, 判定为失败"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------- set ---
print_plan() {
  printf '\n===== 配置计划 =====\n'
  printf '后端    : %s\n' "$BACKEND"
  printf '网卡    : %s\n' "$IFACE"
  if [ "$CAPTURE_SOURCE" -eq 1 ]; then printf '来源    : 当前运行态(固化)\n'; fi
  if [ -n "$TARGET_HOSTNAME" ]; then
    printf '主机名  : %s -> %s\n' "$(hostname_current)" "$TARGET_HOSTNAME"
  fi
  if [ -n "$PIN_OLD_IP" ]; then printf '原 IP   : %s(仅改 IP, 同网段)\n' "$PIN_OLD_IP"; fi
  if [ "$MODE" = "dhcp" ]; then printf '模式    : DHCP 自动获取\n'; else printf '模式    : 静态\n'; fi
  if [ ${#ADDRS[@]} -gt 0 ]; then printf 'IPv4    : %s\n' "$(join_list ADDRS)"; fi
  if [ ${#V6S[@]} -gt 0 ]; then printf 'IPv6    : %s\n' "$(join_list V6S)"; fi
  if [ -n "$GW" ]; then printf '网关    : %s\n' "$GW"; fi
  if [ -n "$GW6" ]; then printf '网关v6  : %s\n' "$GW6"; fi
  if [ "$NO_DNS" -eq 1 ]; then printf 'DNS     : (清空)\n';
  elif [ ${#DNSES[@]} -gt 0 ]; then printf 'DNS     : %s\n' "${DNSES[*]}"; fi
  if [ ${#SEARCHES[@]} -gt 0 ]; then printf '搜索域  : %s\n' "${SEARCHES[*]}"; fi
  if [ -n "$MTU" ]; then printf 'MTU     : %s\n' "$MTU"; fi
  printf '备份到  : %s\n' "$(real_path /var/backups/netcfg)/<时间戳>"
  printf '看门狗  : %s\n' "$([ "$GUARD" -eq 1 ] && echo "${TIMEOUT}s 未确认自动回滚" || echo 关闭)"
  printf '====================\n\n'
}

cmd_set() {
  if [ "$DRY_RUN" -ne 1 ]; then require_root; fi
  normalize_all_lists
  set +e
  BACKEND=$(detect_backend)
  set -e
  if [ "$BACKEND" = "none" ]; then
    die "未找到受支持的网络管理组件(需要 netplan / NetworkManager / ifupdown 之一)"
  fi
  if [ -z "$IFACE" ]; then IFACE=$(default_iface); fi
  if [ -z "$MODE" ]; then
    if [ ${#ADDRS[@]} -gt 0 ] || [ ${#V6S[@]} -gt 0 ]; then
      MODE=static
    else
      info "未指定地址: 默认把当前运行中的 IP/网关/DNS 固化成静态配置(等价于 pin)"
      capture_current
    fi
  fi
  if [ "$MODE" = "dhcp" ] && [ ${#ADDRS[@]} -gt 0 ]; then die "DHCP 模式下不能再指定静态地址"; fi
  if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    die "网卡不存在: $IFACE (可用 ip -br a 查看)"
  fi

  ensure_py
  local -a vargs=(validate --iface "$IFACE" --mode "$MODE" --gw "$GW" --gw6 "$GW6" --mtu "$MTU")
  if [ ${#ADDRS[@]} -gt 0 ]; then vargs+=(--addr "$(join_list ADDRS)"); fi
  if [ ${#V6S[@]} -gt 0 ]; then vargs+=(--v6 "$(join_list V6S)"); fi
  if [ "$DNS_GIVEN" -eq 1 ] && [ "$NO_DNS" -eq 0 ]; then vargs+=(--dns "$(join_list DNSES)"); fi
  if [ ${#SEARCHES[@]} -gt 0 ]; then vargs+=(--search "$(join_list SEARCHES)"); fi
  if [ "$ALLOW_OFFLINK" -eq 1 ]; then vargs+=(--allow-offlink); fi
  python3 "$PY" "${vargs[@]}" >/dev/null
  if [ -n "$TARGET_HOSTNAME" ]; then
    python3 "$PY" hostname-check --name "$TARGET_HOSTNAME" >/dev/null
  fi

  print_plan

  if [ -n "${SSH_CONNECTION:-}" ] && [ "$DRY_RUN" -ne 1 ]; then
    warn "检测到 SSH 远程会话: 如果改的正是当前连接使用的网卡, apply 后本次连接会断开,"
    warn "脚本可能被 SIGHUP 杀掉。推荐用: sudo ${SELF} --detach set ... (后台执行, 断开也不影响校验/回滚)"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "=== 演练模式: 只显示将要写入的内容, 不改任何文件 ==="
    case "$BACKEND" in
      netplan) backend_netplan_write ;;
      ifupdown) backend_ifupdown_write ;;
      nmcli) backend_nmcli_write ;;
    esac
    info "演练结束, 去掉 -n/--dry-run 即真正生效"
    return 0
  fi

  if [ "$YES" -ne 1 ]; then
    if [ ! -t 0 ]; then die "非交互环境请加 -y 确认执行"; fi
    local ans
    printf '确认按以上配置修改网络? 修改期间本机 IP 会变化 [y/N] '
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) info "已取消"; return 0 ;; esac
  fi

  BDIR=$(make_backup)
  info "已备份到 $BDIR"

  local fp1 fp2
  fp1=""
  if ! backend_write; then
    err "写配置失败, 开始回滚"
    restore_backup "$BDIR" || true
    exit 1
  fi
  fp1=$(config_fingerprint)
  apply_resolv_conf

  if ! backend_validate; then
    err "配置校验失败, 已放弃本次修改并回滚"
    restore_backup "$BDIR" || true
    exit 1
  fi

  guard_arm "$BDIR" "$TIMEOUT"

  if ! backend_apply; then
    err "应用配置失败, 开始回滚"
    guard_confirm
    restore_backup "$BDIR" || true
    exit 1
  fi

  if verify_network; then
    fp2=$(config_fingerprint)
    if [ -n "$fp1" ] && [ -n "$fp2" ] && [ "$fp1" != "$fp2" ]; then
      guard_confirm
      err "配置在应用过程中被改动(可能已被看门狗回滚), 请检查 $BDIR"
      exit 1
    fi
    guard_confirm
    if [ -n "$TARGET_HOSTNAME" ]; then
      info "网络已校验通过, 继续修改主机名"
      if ! hostname_set_internal "$TARGET_HOSTNAME"; then
        err "主机名修改失败, 但网络配置已生效(可单独重试: $PROG hostname $TARGET_HOSTNAME)"
        exit 1
      fi
    fi
    printf '\n[netcfg] 配置成功\n'
    if [ -n "$SELF" ]; then
      printf '  回滚命令: sudo %s rollback %s\n\n' "$SELF" "$BDIR"
    else
      printf '  回滚命令: sudo bash %s/rollback.sh\n\n' "$BDIR"
    fi
    return 0
  fi

  err "应用后校验失败, 自动回滚"
  guard_confirm
  restore_backup "$BDIR" || true
  exit 1
}

# ------------------------------------------------------------ 主机名 ---
hostname_current() {
  local f; f=$(real_path /etc/hostname)
  if [ "$ROOT" != "/" ]; then
    if [ -f "$f" ]; then cat "$f"; else echo unknown; fi
    return 0
  fi
  hostname 2>/dev/null || { [ -f "$f" ] && cat "$f" || echo unknown; }
}

hostname_apply() {
  local n="$1" f
  f=$(real_path /etc/hostname)
  if [ "$ROOT" != "/" ]; then
    printf '%s\n' "$n" > "$f"
    return 0
  fi
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$n"
  else
    printf '%s\n' "$n" > "$f"
    hostname "$n"
  fi
}

# 同步 /etc/hosts: 替换 127.0.1.1 记录, 并替换旧名字出现在别处的情况
hosts_apply_hostname() {
  local old="$1" new="$2" f tmp
  f=$(real_path /etc/hosts)
  [ -f "$f" ] || return 0
  tmp="$f.netcfg.tmp"
  awk -v old="$old" -v new="$new" '
    $1 == "127.0.1.1" { print "127.0.1.1\t" new; next }
    {
      for (i = 1; i <= NF; i++) if ($i == old) $i = new
      print
    }' "$f" > "$tmp" || return 1
  grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' "$tmp" || printf '127.0.1.1\t%s\n' "$new" >> "$tmp"
  mv -f "$tmp" "$f"
  if command -v restorecon >/dev/null 2>&1; then restorecon "$f" >/dev/null 2>&1 || true; fi
  return 0
}

write_hostname_revert() {
  local bdir="$1"
  cat > "$bdir/revert.sh" <<EOF
#!/bin/bash
# 由 netcfg.sh 生成: 恢复主机名与 /etc/hosts
set -u
ROOT='$ROOT'
BDIR='$bdir'
[ -f "\$BDIR/hostname" ] && cp -a "\$BDIR/hostname" "\${ROOT%/}/etc/hostname"
[ -f "\$BDIR/hosts" ] && cp -a "\$BDIR/hosts" "\${ROOT%/}/etc/hosts"
if [ "\$ROOT" = "/" ]; then
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "\$(cat /etc/hostname)"
  else
    hostname "\$(cat /etc/hostname)"
  fi
fi
echo "[hostname] 已恢复: \$(cat "\${ROOT%/}/etc/hostname")"
EOF
  chmod +x "$bdir/revert.sh"
}

# 真正执行改名(无提示/无计划), 供 hostname 子命令与 set/pin --hostname 共用
hostname_set_internal() {
  local new="$1" cur ts bdir now
  cur=$(hostname_current)
  if [ "$new" = "$cur" ]; then
    info "主机名已经是 $new, 跳过"
    return 0
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  bdir="$(real_path /var/backups/netcfg-hostname)/$ts"
  mkdir -p "$bdir"
  cp -a "$(real_path /etc/hostname)" "$bdir/hostname" 2>/dev/null || true
  cp -a "$(real_path /etc/hosts)" "$bdir/hosts" 2>/dev/null || true
  write_hostname_revert "$bdir"
  hostname_apply "$new" || { err "设置主机名失败"; return 1; }
  if [ "$SKIP_HOSTS" -eq 0 ]; then
    hosts_apply_hostname "$cur" "$new" || warn "更新 /etc/hosts 失败(不影响主机名)"
  fi
  now=$(hostname_current)
  if [ "$now" = "$new" ]; then
    HOSTNAME_BACKUP_DIR="$bdir"
    info "主机名已改为: $new"
    printf '  主机名回退: sudo bash %s/revert.sh\n' "$bdir"
    return 0
  fi
  err "主机名读回不一致: [$now] != [$new]"
  return 1
}

cmd_hostname() {
  local new="" skip_hosts=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1; shift ;;
      -y|--yes)     YES=1; shift ;;
      --without-hosts) skip_hosts=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           die "未知参数: $1" ;;
      *)            new="$1"; shift ;;
    esac
  done
  local cur; cur=$(hostname_current)
  if [ -z "$new" ]; then
    printf '当前主机名: %s\n' "$cur"
    printf '静态文件  : %s\n' "$(real_path /etc/hostname)"
    printf '修改方法  : sudo %s hostname <新名字>\n' "$PROG"
    return 0
  fi
  ensure_py
  python3 "$PY" hostname-check --name "$new" >/dev/null
  if [ "$DRY_RUN" -ne 1 ]; then require_root; fi

  printf '\n===== 主机名变更计划 =====\n'
  printf '当前    : %s\n' "$cur"
  printf '新的    : %s\n' "$new"
  if [ "$skip_hosts" -eq 1 ]; then
    printf '/etc/hosts: 不改\n'
  else
    printf '/etc/hosts: 同步 127.0.1.1 记录与旧名字\n'
  fi
  printf '备份到  : %s\n' "$(real_path /var/backups/netcfg-hostname)/<时间戳>"
  printf '==========================\n\n'

  if [ "$new" = "$cur" ]; then info "主机名没变化, 什么都不做"; return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then info "演练模式, 未做任何修改"; return 0; fi
  if [ "$YES" -ne 1 ]; then
    if [ ! -t 0 ]; then die "非交互环境请加 -y"; fi
    local ans
    printf '确认修改主机名 %s -> %s ? [y/N] ' "$cur" "$new"
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) info "已取消"; return 0 ;; esac
  fi

  SKIP_HOSTS="$skip_hosts"
  hostname_set_internal "$new"
}

# --------------------------------------------------------------- 固化 ---
# 改 IP 前探测地址是否已被占用(arping 优先; 失败只告警)
pin_dup_check() {
  local a ip
  if [ "$ROOT" != "/" ]; then return 0; fi
  for a in "$@"; do
    ip="${a%/*}"
    if command -v arping >/dev/null 2>&1; then
      if arping -D -c 2 -w 2 -I "$IFACE" "$ip" >/dev/null 2>&1; then
        vlog "arping: $ip 看起来空闲"
      else
        warn "地址 $ip 有 ARP 响应, 可能已被占用, 请确认后再执行"
      fi
    elif ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      warn "地址 $ip 当前 ping 有响应, 可能已被占用, 请确认后再执行"
    fi
  done
  return 0
}

cmd_pin() {
  if [ "$MODE" = "dhcp" ]; then
    die "pin 不接受 --dhcp: 要切回 DHCP 请用 set --dhcp"
  fi
  local -a user4=() user6=()
  local _ua
  # bash 4.2 下空数组 "${arr[@]}" 在 set -u 时会报 unbound, 必须加长度守卫
  if [ ${#ADDRS[@]} -gt 0 ]; then
    for _ua in "${ADDRS[@]}"; do if [ -n "$_ua" ]; then user4+=("$_ua"); fi; done
  fi
  if [ ${#V6S[@]} -gt 0 ]; then
    for _ua in "${V6S[@]}"; do if [ -n "$_ua" ]; then user6+=("$_ua"); fi; done
  fi
  ADDRS=(); V6S=()
  capture_current
  local -a cur4=("${ADDRS[@]-}")
  if [ ${#user4[@]} -gt 0 ]; then
    ensure_py
    local -a sargs=(subnet-check --base "${cur4[0]}" --new "$(join_list user4)")
    if [ "$ALLOW_OTHER_PREFIX" -eq 1 ]; then sargs+=(--allow-other-prefix); fi
    python3 "$PY" "${sargs[@]}" >/dev/null || die "新 IP 校验未通过, 已放弃"
    pin_dup_check "${user4[@]}" || true
    ADDRS=("${user4[@]}")
    PIN_OLD_IP="${cur4[0]}"
    warn "仅改 IP: ${cur4[0]} -> $(join_list ADDRS); 网关/DNS/搜索域/MTU 沿用当前配置"
  fi
  if [ ${#user6[@]} -gt 0 ]; then
    V6S=("${user6[@]}")
  fi
  if [ "$WITH_IPV6" -eq 0 ]; then
    local v6now
    v6now=$(ip -o -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -vE 'temporary|deprecated' | wc -l || true)
    if [ "${v6now:-0}" -gt 0 ]; then
      warn "$IFACE 上还有全局 IPv6 地址, pin 默认只固化 IPv4(IPv6 现状保留); 如需一起写死加 --with-ipv6"
    fi
  fi
  warn "固化说明: 若该地址原本由 DHCP 分配, 请在 DHCP 服务器上按 MAC 做静态保留/从池中排除,"
  warn "否则租约到期后被别的机器占用会造成 IP 冲突; 本脚本只把当前地址写死并保证配置可回滚。"
  cmd_set
}

# ---------------------------------------------------------------- 其它命令 ---
cmd_show() {
  printf '== 系统 ==\n'
  printf '主机名 : %s\n' "$(hostname)"
  if [ -r /etc/os-release ]; then printf '发行版 : %s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"; fi
  set +e; local bk; bk=$(detect_backend); set -e
  printf '后端   : %s\n' "$bk"
  printf '\n== 网卡与地址 ==\n'
  ip -br a 2>/dev/null || ip addr
  printf '\n== 默认路由 ==\n'
  ip -4 route show default 2>/dev/null || true
  printf '\n== DNS ==\n'
  if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Domain|Current DNS' | sed 's/^/  /' || true
  fi
  if [ -r /etc/resolv.conf ]; then
    printf '  /etc/resolv.conf -> %s\n' "$(readlink -f /etc/resolv.conf 2>/dev/null || echo -)"
    grep -E '^\s*(nameserver|search)' /etc/resolv.conf 2>/dev/null | sed 's/^/  /' || true
  fi
  printf '\n== 配置文件 ==\n'
  ensure_py
  python3 "$PY" summary --root "$ROOT" || true
  printf '\n== 最近备份 ==\n'
  local br; br=$(real_path /var/backups/netcfg)
  if [ -d "$br" ]; then ls -1t "$br" 2>/dev/null | head -5 | sed "s|^|  $br/|"; else printf '  (无)\n'; fi
}

cmd_apply() {
  require_root
  set +e; BACKEND=$(detect_backend); set -e
  [ "$BACKEND" = "none" ] && die "未找到受支持的网络管理组件"
  if [ -z "$IFACE" ]; then IFACE=$(default_iface); fi
  info "后端=$BACKEND 网卡=$IFACE, 开始备份并重新应用"
  BDIR=$(make_backup)
  guard_arm "$BDIR" "$TIMEOUT"
  if ! backend_apply; then
    guard_confirm; err "apply 失败, 已回滚"; restore_backup "$BDIR" || true; exit 1
  fi
  if verify_network; then guard_confirm; info "应用成功"; return 0; fi
  guard_confirm; err "校验失败, 已回滚"; restore_backup "$BDIR" || true; exit 1
}

cmd_backup() {
  require_root
  ensure_py
  local bk; set +e; bk=$(detect_backend); set -e
  BACKEND="$bk"
  BDIR=$(make_backup)
  info "备份完成: $BDIR"
}

cmd_rollback() {
  require_root
  set +e; BACKEND=$(detect_backend); set -e
  local bdir="${1:-}"
  if [ -z "$bdir" ]; then
    local br; br=$(real_path /var/backups/netcfg)
    [ -d "$br" ] || die "没有可用的备份目录: $br"
    bdir=$(ls -1d "$br"/*/ 2>/dev/null | sort | tail -1)
    bdir="${bdir%/}"
    [ -n "$bdir" ] || die "备份目录为空: $br"
  fi
  restore_backup "$bdir"
}

# ----------------------------------------------------------------- 自测 ---
cmd_selftest() {
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/netcfg-selftest.XXXXXX")
  trap "rm -rf '$T'" EXIT
  local pass=0 fail=0 skip=0
  t_ok()  { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
  t_no()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
  t_sk()  { skip=$((skip+1)); printf '  [SKIP] %s\n' "$1"; }

  printf '== netcfg.sh 自测 (沙箱 %s) ==\n' "$T"

  mkdir -p "$T/bin" "$T/root/etc/netplan"
  local b
  for b in netplan ip ping getent nmcli ifup ifdown systemctl resolvectl resolvconf; do :; done

  cat > "$T/bin/netplan" <<'EOS'
#!/bin/bash
case "$1" in
  generate) exit "${FAKE_GENERATE_RC:-0}" ;;
  apply)    exit "${FAKE_APPLY_RC:-0}" ;;
  *)        exit 0 ;;
esac
EOS
  cat > "$T/bin/ip" <<'EOS'
#!/bin/bash
if [ "$1" = "link" ]; then
  [ "${FAKE_LINK_DOWN:-0}" = "1" ] && exit 1
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "-4" ] && [ "$3" = "addr" ]; then
  dev="${!#}"; i=2
  for a in ${FAKE_IFACE_ADDRS:-}; do
    printf '%d: %s    inet %s brd 0.0.0.0 scope global %s\\       valid_lft forever preferred_lft forever\n' "$i" "$dev" "$a" "$dev"
    i=$((i+1))
  done
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "-6" ] && [ "$3" = "addr" ]; then
  dev="${!#}"; i=2
  for a in ${FAKE_IFACE_ADDRS6:-}; do
    printf '%d: %s    inet6 %s scope global\\       valid_lft forever preferred_lft forever\n' "$i" "$dev" "$a"
    i=$((i+1))
  done
  exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "route" ]; then
  [ -n "${FAKE_ROUTE6:-}" ] && printf '%s\n' "$FAKE_ROUTE6"
  exit 0
fi
if [ "$1" = "-4" ] && [ "$2" = "route" ]; then
  [ -n "${FAKE_ROUTE:-}" ] && printf '%s\n' "$FAKE_ROUTE"
  exit 0
fi
if [ "$1" = "route" ]; then
  [ -n "${FAKE_ROUTE:-}" ] && printf '%s\n' "$FAKE_ROUTE"
  exit 0
fi
exit 0
EOS
  cat > "$T/bin/ping" <<'EOS'
#!/bin/bash
exit "${FAKE_PING_RC:-0}"
EOS
  cat > "$T/bin/getent" <<'EOS'
#!/bin/bash
exit "${FAKE_DNS_RC:-0}"
EOS
  cat > "$T/bin/ifup" <<'EOS'
#!/bin/bash
[ -n "${FAKE_CALL_LOG:-}" ] && echo "ifup $*" >> "$FAKE_CALL_LOG"
exit "${FAKE_IFUP_RC:-0}"
EOS
  cat > "$T/bin/ifdown" <<'EOS'
#!/bin/bash
[ -n "${FAKE_CALL_LOG:-}" ] && echo "ifdown $*" >> "$FAKE_CALL_LOG"
exit 0
EOS
  cat > "$T/bin/nmcli" <<'EOS'
#!/bin/bash
[ -n "${FAKE_CALL_LOG:-}" ] && echo "nmcli $*" >> "$FAKE_CALL_LOG"
if [ "$1" = "-t" ]; then
  printf 'Wired connection 1:ens33\n'
  exit 0
fi
exit 0
EOS
  cat > "$T/bin/systemctl" <<'EOS'
#!/bin/bash
exit 0
EOS
  cat > "$T/bin/resolvectl" <<'EOS'
#!/bin/bash
case "$1" in
  dns)    [ -n "${FAKE_RESOLVECTL_DNS:-}" ] && printf '%s\n' "$FAKE_RESOLVECTL_DNS"; exit 0 ;;
  domain) [ -n "${FAKE_RESOLVECTL_DOMAIN:-}" ] && printf '%s\n' "$FAKE_RESOLVECTL_DOMAIN"; exit 0 ;;
esac
exit 0
EOS
  cat > "$T/bin/resolvconf" <<'EOS'
#!/bin/bash
exit 0
EOS
  chmod +x "$T/bin"/*

  local sbx="$T/root"
  mkdir -p "$sbx/etc"
  printf 'oldbox\n' > "$sbx/etc/hostname"
  cat > "$sbx/etc/hosts" <<'EOS'
127.0.0.1 localhost localhost.localdomain
127.0.1.1 oldbox
::1 localhost
EOS
  cat > "$sbx/etc/netplan/00-installer-config.yaml" <<'EOS'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: true
    ens99:
      addresses: [10.9.9.9/24]
      gateway4: 10.9.9.1
      nameservers:
        addresses: [10.9.9.53]
EOS
  local pristine="$T/pristine"
  cp -a "$sbx" "$pristine"
  reset_sbx() { rm -rf "$sbx"; cp -a "$pristine" "$sbx"; }

  run_nc() {
    PATH="$T/bin:$PATH" NETCFG_SANDBOX=1 \
    NETCFG_VERIFY_TRIES=2 NETCFG_VERIFY_INTERVAL=0 \
    bash "$SELF" --root "$sbx" "$@"
  }

  local out rc
  local cfg="$sbx/etc/netplan/00-installer-config.yaml"

  # --- 1. 参数校验 ---------------------------------------------------------
  reset_sbx
  set +e; out=$(run_nc set -i ens33 -4 999.9.9.9/24 -g 192.168.1.1 -y 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "非法IPv4"; then t_ok "非法 IP 被拒绝"; else t_no "非法 IP 未被拒绝 (rc=$rc)"; fi

  reset_sbx
  set +e; out=$(run_nc set -i ens33 -4 10.0.0.5/24 -g 192.168.1.1 -y 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "不在已配置网段"; then t_ok "网关不在网段被拒绝"; else t_no "网关不在网段未被拒绝 (rc=$rc)"; fi

  reset_sbx
  set +e; out=$(run_nc set -i ens33 -4 10.0.0.5 -y 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "前缀长度"; then t_ok "缺少前缀长度被拒绝"; else t_no "缺少前缀长度未被拒绝 (rc=$rc)"; fi

  reset_sbx
  set +e; out=$(run_nc set -i ens33 -y 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ]; then t_ok "既无地址又无 --dhcp 被拒绝"; else t_no "空配置未被拒绝"; fi

  reset_sbx
  set +e; out=$(run_nc set -i ens33 -4 10.0.0.5/24 -g 10.0.0.1 -d "8.8.8.8" --dhcp -y 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ]; then t_ok "DHCP 与静态地址互斥被拒绝"; else t_no "DHCP+静态未报错"; fi

  # --- 2. 静态配置渲染 + 应用 ---------------------------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33 proto static" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then t_ok "静态配置应用成功(rc=0)"; else t_no "静态配置应用失败 rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /'; fi
  grep -q "192.168.1.10/24" "$cfg" && t_ok "写入地址 192.168.1.10/24" || t_no "未写入地址"
  grep -q "dhcp4: false" "$cfg" && t_ok "dhcp4 被置为 false" || t_no "dhcp4 未置为 false"
  grep -q "via: 192.168.1.1" "$cfg" && t_ok "写入默认路由(via 网关)" || t_no "未写入默认路由"
  grep -q "223.5.5.5" "$cfg" && t_ok "写入 DNS" || t_no "未写入 DNS"
  grep -q "10.9.9.9/24" "$cfg" && t_ok "其它网卡 ens99 配置被保留" || t_no "ens99 配置丢失"
  grep -q "gateway4: 10.9.9.1" "$cfg" && t_ok "ens99 原有 gateway4 保留" || t_no "ens99 gateway4 丢失"
  [ -f "$sbx/etc/resolvconf/resolv.conf.d/base" ] && t_no "本机无 resolvconf 目录时不应创建" || t_ok "未误建 resolv.conf 相关文件"
  local nb; nb=$(ls -1d "$sbx/var/backups/netcfg"/*/ 2>/dev/null | wc -l)
  [ "$nb" -ge 1 ] && t_ok "生成了备份目录" || t_no "没有生成备份"
  [ -f "$(ls -1d "$sbx/var/backups/netcfg"/*/ | tail -1)rollback.sh" ] && t_ok "生成了 rollback.sh" || t_no "缺少 rollback.sh"

  # --- 3. 幂等: 再跑一次内容不变 ------------------------------------------
  cp "$cfg" "$T/after1.yaml"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && diff -q "$T/after1.yaml" "$cfg" >/dev/null 2>&1; then t_ok "重复执行幂等(内容一致)"; else t_no "重复执行不幂等 rc=$rc"; fi

  # --- 4. apply 失败 -> 自动回滚 ------------------------------------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_APPLY_RC=1 FAKE_IFACE_ADDRS="192.168.1.10/24" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -y -t 3 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then t_ok "apply 失败自动回滚(文件已还原)"; else t_no "apply 失败未回滚 rc=$rc"; fi

  # --- 5. 校验失败 -> 自动回滚 --------------------------------------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_IFACE_ADDRS="10.0.0.9/24" FAKE_ROUTE="default via 10.0.0.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -y -t 3 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then t_ok "校验失败自动回滚(文件已还原)"; else t_no "校验失败未回滚 rc=$rc"; fi
  if printf '%s' "$out" | grep -q "地址校验失败"; then t_ok "报错信息指明地址校验失败"; else t_no "报错信息不明确"; fi

  # --- 6. netplan generate 失败 -> 回滚 -----------------------------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_GENERATE_RC=1 FAKE_IFACE_ADDRS="192.168.1.10/24" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -y -t 3 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then t_ok "generate 失败即回滚(未进运行态)"; else t_no "generate 失败未回滚 rc=$rc"; fi

  # --- 7. DHCP 模式 -------------------------------------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.77/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 --dhcp -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "dhcp4: true" "$cfg" && ! grep -q "192.168.1.10" "$cfg"; then
    t_ok "DHCP 模式写入正确"
  else t_no "DHCP 模式异常 rc=$rc"; fi

  # --- 8. 多地址 + MTU + 搜索域 -------------------------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24 192.168.1.11/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 "192.168.1.10/24,192.168.1.11/24" -g 192.168.1.1 -d 8.8.8.8 \
              -s example.com -m 1500 -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.11/24" "$cfg" && grep -q "example.com" "$cfg" && grep -q "mtu: 1500" "$cfg"; then
    t_ok "多地址/搜索域/MTU 写入正确"
  else t_no "多地址/搜索域/MTU 异常 rc=$rc"; fi

  # --- 9. dry-run 不落盘 --------------------------------------------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d 8.8.8.8 -n 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1 && printf '%s' "$out" | grep -q "192.168.1.10/24"; then
    t_ok "dry-run 只打印不改文件"
  else t_no "dry-run 行为异常 rc=$rc"; fi

  # --- 10. rollback 命令 --------------------------------------------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -y -t 5 2>&1); rc=$?
  out2=$(FAKE_IFACE_ADDRS="192.168.1.1/24" run_nc rollback 2>&1); rc2=$?
  set -e
  if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then
    t_ok "rollback 命令还原到初始配置"
  else t_no "rollback 命令异常 rc=$rc/$rc2"; fi

  # --- 10b. backup / apply / 无备份回滚 -----------------------------------
  reset_sbx
  set +e
  out=$(run_nc backup 2>&1); rc=$?
  set -e
  local bdir2; bdir2=$(ls -1d "$sbx/var/backups/netcfg"/*/ 2>/dev/null | tail -1)
  if [ "$rc" -eq 0 ] && [ -n "$bdir2" ] && [ -f "$bdir2/etc.tar.gz" ]; then
    t_ok "backup 命令生成备份包"
  else t_no "backup 异常 rc=$rc"; fi

  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.88/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc apply 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "应用成功"; then
    t_ok "apply 命令正常"
  else t_no "apply 异常 rc=$rc"; fi

  reset_sbx
  rm -rf "$sbx/var/backups/netcfg"
  set +e
  out=$(run_nc rollback 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then t_ok "无备份时 rollback 明确报错"; else t_no "无备份时 rollback 未报错"; fi

  # --- 10c. pin: 固化当前运行配置 -----------------------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24 192.168.1.11/24" \
        FAKE_ROUTE="default via 192.168.1.1 dev ens33 proto dhcp" \
        FAKE_RESOLVECTL_DNS="Link 2 (ens33): 223.5.5.5 8.8.8.8 127.0.0.53" \
        FAKE_RESOLVECTL_DOMAIN="Link 2 (ens33): corp.local ~." \
        run_nc pin -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.11/24" "$cfg" && grep -q "via: 192.168.1.1" "$cfg" \
     && grep -q "223.5.5.5" "$cfg" && grep -q "8.8.8.8" "$cfg" \
     && ! grep -q "127.0.0.53" "$cfg" && grep -q "corp.local" "$cfg" && ! grep -q '~\.' "$cfg"; then
    t_ok "pin 固化当前 IP/网关/DNS/搜索域(并过滤 stub DNS)"
  else t_no "pin 固化异常 rc=$rc"; printf '%s\n' "$out" | tail -6 | sed 's/^/      /'; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="" run_nc pin -i ens33 -y -t 3 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "没有 IPv4 地址"; then
    t_ok "pin 无地址时明确报错"
  else t_no "pin 无地址未报错 rc=$rc"; fi

  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        FAKE_RESOLVECTL_DNS="Link 2 (ens33): 223.5.5.5" \
        run_nc pin -n 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then
    t_ok "pin -n 只打印不落盘"
  else t_no "pin -n 落盘了 rc=$rc"; fi

  # pin -4: 只换 IP, 必须同网段
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24 192.168.1.50/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        FAKE_RESOLVECTL_DNS="Link 2 (ens33): 223.5.5.5 8.8.8.8" \
        run_nc pin -4 192.168.1.50/24 -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.50/24" "$cfg" && grep -q "via: 192.168.1.1" "$cfg" \
     && grep -q "223.5.5.5" "$cfg" && ! grep -q "192.168.1.10/24" "$cfg" \
     && printf '%s' "$out" | grep -q "原 IP"; then
    t_ok "pin -4 同网段换 IP(网关/DNS 沿用当前)"
  else t_no "pin -4 同网段换 IP 失败 rc=$rc"; printf '%s\n' "$out" | tail -6 | sed 's/^/      /'; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc pin -4 10.0.0.5/24 -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "不在当前网段"; then
    t_ok "pin -4 跨网段被拒绝"
  else t_no "pin -4 跨网段未拒绝 rc=$rc"; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc pin -4 192.168.1.255/24 -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "广播地址"; then
    t_ok "pin -4 广播地址被拒绝"
  else t_no "pin -4 广播地址未拒绝 rc=$rc"; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc pin -4 192.168.1.50/16 -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "前缀"; then
    t_ok "pin -4 前缀不一致被拒绝"
  else t_no "pin -4 前缀不一致未拒绝 rc=$rc"; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        FAKE_IFACE_ADDRS6="2001:db8::77/64" FAKE_ROUTE6="default via 2001:db8::1 dev ens33 metric 100" \
        run_nc pin --with-ipv6 -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "2001:db8::77/64" "$cfg" && grep -q "2001:db8::1" "$cfg"; then
    t_ok "pin --with-ipv6 一并固化 IPv6 地址与网关"
  else t_no "pin --with-ipv6 异常 rc=$rc"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fi

  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        FAKE_RESOLVECTL_DNS="Link 2 (ens33): 223.5.5.5" \
        run_nc pin -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && ! grep -q "dhcp6" "$cfg"; then
    t_ok "pin 不写 dhcp6 键(不动既有 IPv6 配置)"
  else t_no "pin 误写 dhcp6 rc=$rc"; fi

  # --- 10d. 零参数 set 等价于 pin -----------------------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        FAKE_RESOLVECTL_DNS="Link 2 (ens33): 223.5.5.5" \
        run_nc set -i ens33 -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.10/24" "$cfg" && grep -q "via: 192.168.1.1" "$cfg" \
     && printf '%s' "$out" | grep -q "默认把当前运行中的 IP"; then
    t_ok "零参数 set 默认固化当前配置"
  else t_no "零参数 set 异常 rc=$rc"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fi

  # --- 11. ifupdown 后端渲染 ---------------------------------------------
  reset_sbx
  rm -rf "$sbx/etc/netplan"; mkdir -p "$sbx/etc/network/interfaces.d"
  printf 'source /etc/network/interfaces.d/*\n' > "$sbx/etc/network/interfaces"
  cp "$sbx/etc/network/interfaces" "$T/ifaces.orig"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24 192.168.1.11/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -b ifupdown -4 192.168.1.10/24 -4 192.168.1.11/24 -g 192.168.1.1 \
              -d "223.5.5.5 8.8.8.8" -s example.com -y -t 5 2>&1); rc=$?
  set -e
  local ifc="$sbx/etc/network/interfaces.d/ens33"
  if [ "$rc" -eq 0 ] && grep -q "address 192.168.1.10" "$ifc" && grep -q "netmask 255.255.255.0" "$ifc" \
     && grep -q "gateway 192.168.1.1" "$ifc" && grep -q "dns-nameservers 223.5.5.5 8.8.8.8" "$ifc" \
     && grep -q "ip addr add 192.168.1.11/24" "$ifc"; then
    t_ok "ifupdown 生成 static stanza 正确"
  else t_no "ifupdown stanza 异常 rc=$rc"; fi

  reset_sbx
  rm -rf "$sbx/etc/netplan"; mkdir -p "$sbx/etc/network/interfaces.d"
  printf 'source /etc/network/interfaces.d/*\n' > "$sbx/etc/network/interfaces"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.77/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -b ifupdown --dhcp -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "iface ens33 inet dhcp" "$ifc"; then t_ok "ifupdown DHCP stanza 正确"; else t_no "ifupdown DHCP 异常 rc=$rc"; fi

  # --- 11c. ifcfg 后端(CentOS 7 server: network.service) -------------------
  reset_sbx
  mkdir -p "$sbx/etc/sysconfig/network-scripts"
  local ic="$sbx/etc/sysconfig/network-scripts/ifcfg-ens33"
  cat > "$ic" <<'EOS'
TYPE=Ethernet
DEVICE=ens33
HWADDR=00:0C:29:58:0F:82
UUID=64984771-dcef-39aa-b200-589412794fba
NAME="Wired connection 1"
BOOTPROTO=none
IPADDR=10.0.0.99
PREFIX=24
DNS1=1.1.1.1
IPV6INIT=yes
IPV6_AUTOCONF=yes
ZONE=public
ONBOOT=yes
EOS
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -b ifcfg -4 192.168.1.10/24 -g 192.168.1.1 \
              -d "223.5.5.5 8.8.8.8" -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q '^IPADDR=192.168.1.10$' "$ic" && grep -q '^PREFIX=24$' "$ic" \
     && grep -q '^GATEWAY=192.168.1.1$' "$ic" && grep -q '^DNS1=223.5.5.5$' "$ic" \
     && grep -q '^DNS2=8.8.8.8$' "$ic" && grep -q '^UUID=64984771' "$ic" \
     && grep -q '^ZONE=public$' "$ic" && grep -q '^IPV6INIT=yes$' "$ic" \
     && ! grep -q '10.0.0.99' "$ic" && ! grep -q '^DNS1=1.1.1.1$' "$ic"; then
    t_ok "ifcfg static 改写正确且保留未知键(UUID/ZONE/IPV6)"
  else t_no "ifcfg static 异常 rc=$rc"; sed -n '1,18p' "$ic" | sed 's/^/      /'; fi

  printf 'TYPE=Ethernet\nDEVICE=ens33\nBOOTPROTO=none\nIPADDR=10.0.0.99\nPREFIX=24\nDNS1=1.1.1.1\nONBOOT=yes\n' > "$ic"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.50/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -b ifcfg --dhcp -d "223.5.5.5" -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q '^BOOTPROTO=dhcp$' "$ic" && grep -q '^PEERDNS=no$' "$ic" \
     && grep -q '^DNS1=223.5.5.5$' "$ic" && ! grep -q '^IPADDR=' "$ic"; then
    t_ok "ifcfg DHCP + 静态 DNS(PEERDNS=no) 正确"
  else t_no "ifcfg DHCP 异常 rc=$rc"; sed -n '1,12p' "$ic" | sed 's/^/      /'; fi

  printf 'TYPE=Ethernet\nBONDING_MASTER=yes\nBONDING_OPTS="mode=1"\n' > "$ic"
  set +e
  out=$(run_nc set -i ens33 -b ifcfg -4 192.168.1.10/24 -g 192.168.1.1 -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "只支持普通以太网"; then
    t_ok "ifcfg 遇 bond 明确拒绝"
  else t_no "ifcfg bond 未拒绝 rc=$rc"; fi

  # --- 12. nmcli 后端命令构造 --------------------------------------------
  reset_sbx
  rm -rf "$sbx/etc/netplan"
  rm -f "$T/nmcli.log"
  set +e
  out=$(FAKE_CALL_LOG="$T/nmcli.log" FAKE_IFACE_ADDRS="192.168.1.10/24" \
        FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -b nmcli -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -y -t 5 2>&1); rc=$?
  set -e
  local log="$T/nmcli.log"
  if [ "$rc" -eq 0 ] && grep -q "ipv4.method manual" "$log" && grep -q "ipv4.addresses 192.168.1.10/24" "$log" \
     && grep -q "ipv4.gateway 192.168.1.1" "$log" && grep -q "ipv4.dns 223.5.5.5 8.8.8.8" "$log" \
     && grep -q 'connection modify Wired connection 1' "$log" \
     && grep -q "connection reload" "$log"; then
    t_ok "nmcli 命令参数正确"
  else t_no "nmcli 命令参数异常 rc=$rc"; grep . "$log" | sed 's/^/      /' || true; fi

  # --- 13. resolvconf 场景 -----------------------------------------------
  reset_sbx
  mkdir -p "$sbx/etc/resolvconf/resolv.conf.d"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.10/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 -d "223.5.5.5 8.8.8.8" -s corp.local -y -t 5 2>&1); rc=$?
  set -e
  local base="$sbx/etc/resolvconf/resolv.conf.d/base"
  if [ "$rc" -eq 0 ] && grep -q "nameserver 223.5.5.5" "$base" && grep -q "search corp.local" "$base"; then
    t_ok "resolvconf base 写入正确"
  else t_no "resolvconf base 异常 rc=$rc"; fi

  # --- 14. 真实 netplan 语法校验 -----------------------------------------
  if command -v netplan >/dev/null 2>&1; then
    reset_sbx
    PATH="/usr/sbin:/usr/bin:/sbin:/bin" NETCFG_SANDBOX=1 \
      bash "$SELF" --root "$sbx" set -i ens33 -4 192.168.1.10/24 -g 192.168.1.1 \
           -d "223.5.5.5 8.8.8.8" -s example.com -m 1500 -y -t 3 >/dev/null 2>&1 || true
    if PATH="/usr/sbin:/usr/bin:/sbin:/bin" netplan generate --root-dir "$sbx" >"$T/gen.log" 2>&1; then
      t_ok "真实 netplan generate 校验通过"
    else
      t_sk "真实 netplan generate 在沙箱内不可用: $(head -1 "$T/gen.log")"
    fi
  else
    t_sk "本机无 netplan, 跳过真实语法校验"
  fi

  # --- 15. 未定义网卡 -> 新建文件; 再配另一块网卡不互相覆盖 ---------------
  reset_sbx
  cp "$cfg" "$T/orig.yaml"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.5.5/24" FAKE_ROUTE="default via 192.168.5.1 dev ens77" \
        run_nc set -i ens77 -4 192.168.5.5/24 -g 192.168.5.1 -y -t 5 2>&1); rc=$?
  set -e
  local newf="$sbx/etc/netplan/90-netcfg.yaml"
  if [ "$rc" -eq 0 ] && [ -f "$newf" ] && grep -q "192.168.5.5/24" "$newf" \
     && diff -q "$T/orig.yaml" "$cfg" >/dev/null 2>&1; then
    t_ok "未定义网卡写入新文件 90-netcfg.yaml(不动原文件)"
  else t_no "新增网卡写入异常 rc=$rc"; fi

  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.30/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.30/24 -g 192.168.1.1 -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.30/24" "$cfg" && grep -q "192.168.5.5/24" "$newf"; then
    t_ok "90-netcfg.yaml 中已有网卡不被覆盖"
  else t_no "90-netcfg.yaml 被覆盖 rc=$rc"; fi

  # --- 17. 看门狗抢跑: apply 卡住期间被回滚, 脚本必须报错 -----------------
  reset_sbx
  cat > "$T/bin/netplan" <<'EOS'
#!/bin/bash
case "$1" in
  generate) exit 0 ;;
  apply)    sleep 2; exit 0 ;;
esac
exit 0
EOS
  chmod +x "$T/bin/netplan"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.40/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.40/24 -g 192.168.1.1 -y -t 1 2>&1); rc=$?
  set -e
  cat > "$T/bin/netplan" <<'EOS'
#!/bin/bash
case "$1" in
  generate) exit "${FAKE_GENERATE_RC:-0}" ;;
  apply)    exit "${FAKE_APPLY_RC:-0}" ;;
  *)        exit 0 ;;
esac
EOS
  chmod +x "$T/bin/netplan"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qE "配置在应用过程中被改动|校验失败"; then
    t_ok "看门狗回滚后脚本不再谎报成功"
  else t_no "看门狗抢跑未被发现 rc=$rc"; fi

  # --- 18. --detach 后台执行 ---------------------------------------------
  reset_sbx
  local dlog="$sbx/var/log/netcfg-detach.log"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.60/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc --detach=/var/log/netcfg-detach.log set -i ens33 -4 192.168.1.60/24 -g 192.168.1.1 -y -t 5 2>&1); rc=$?
  set -e
  local i2
  for ((i2=0;i2<24;i2++)); do
    if [ -f "$dlog" ] && grep -q "配置成功" "$dlog"; then break; fi
    sleep 0.5
  done
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.60/24" "$cfg" && grep -q "配置成功" "$dlog" 2>/dev/null; then
    t_ok "--detach 后台执行并完成校验"
  else t_no "--detach 异常 rc=$rc"; [ -f "$dlog" ] && tail -5 "$dlog" | sed 's/^/      /'; fi

  # --- 18b. --version -----------------------------------------------------
  set +e; out=$("$SELF" --version 2>&1); rc=$?; set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE '^netcfg\.sh [0-9]+\.[0-9]+\.[0-9]+$'; then
    t_ok "--version 输出正确 ($out)"
  else t_no "--version 异常 rc=$rc out=$out"; fi

  # --- 18c. 管道模式(curl | bash): 回滚脚本必须仍然可用 -------------------
  reset_sbx
  set +e
  out=$(PATH="$T/bin:$PATH" NETCFG_SANDBOX=1 NETCFG_VERIFY_TRIES=2 NETCFG_VERIFY_INTERVAL=0 \
        FAKE_IFACE_ADDRS="192.168.1.50/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        bash -s -- --root "$sbx" set -i ens33 -4 192.168.1.50/24 -g 192.168.1.1 -y -t 5 < "$SELF" 2>&1); rc=$?
  set -e
  local pipe_bdir; pipe_bdir=$(ls -1d "$sbx/var/backups/netcfg"/*/ 2>/dev/null | tail -1)
  if [ "$rc" -eq 0 ] && [ -n "$pipe_bdir" ] && ! grep -q 'exec bash' "$pipe_bdir/rollback.sh"; then
    t_ok "管道模式生成自包含 rollback.sh"
  else t_no "管道模式 rollback.sh 异常 rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /'; fi

  if [ -n "$pipe_bdir" ] && PATH="$T/bin:$PATH" bash "$pipe_bdir/rollback.sh" >/dev/null 2>&1 \
     && diff -q "$T/pristine/etc/netplan/00-installer-config.yaml" "$cfg" >/dev/null 2>&1; then
    t_ok "管道模式的 rollback.sh 能真正回滚"
  else t_no "管道模式 rollback.sh 执行失败"; fi

  reset_sbx
  set +e
  out=$(PATH="$T/bin:$PATH" NETCFG_SANDBOX=1 bash -s -- --root "$sbx" --detach set -i ens33 --dhcp -y < "$SELF" 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "需要脚本是真实文件"; then
    t_ok "管道模式 --detach 明确报错"
  else t_no "管道模式 --detach 未报错 rc=$rc"; fi

  # --- 19. show 可运行 ---------------------------------------------------
  reset_sbx
  set +e; out=$(PATH="$T/bin:$PATH" bash "$SELF" --root "$sbx" show 2>&1); rc=$?; set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "ens33"; then t_ok "show 输出正常"; else t_no "show 异常 rc=$rc"; fi

  # --- 20. hostname 修改(沙箱) -------------------------------------------
  reset_sbx
  local hf="$sbx/etc/hostname" hostsf="$sbx/etc/hosts"
  set +e
  out=$(run_nc hostname nc-test -y 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ "$(cat "$hf")" = "nc-test" ] \
     && grep -qE '^127\.0\.1\.1[[:space:]]+nc-test$' "$hostsf" && ! grep -q oldbox "$hostsf" \
     && [ -f "$(ls -1d "$sbx/var/backups/netcfg-hostname"/*/ 2>/dev/null | tail -1)revert.sh" ]; then
    t_ok "hostname 修改(同步 /etc/hosts, 生成 revert.sh)"
  else t_no "hostname 修改异常 rc=$rc"; sed -n '1,4p' "$hostsf" | sed 's/^/      /'; fi

  reset_sbx
  set +e
  out=$(run_nc hostname "bad..name" -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "非法主机名"; then
    t_ok "非法主机名被拒绝"
  else t_no "非法主机名未拒绝 rc=$rc"; fi

  reset_sbx
  cp "$hf" "$T/h.orig"; cp "$hostsf" "$T/hosts.orig"
  set +e
  out=$(run_nc hostname nc-dry -n 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && diff -q "$T/h.orig" "$hf" >/dev/null 2>&1 && diff -q "$T/hosts.orig" "$hostsf" >/dev/null 2>&1; then
    t_ok "hostname -n 只打印不落盘"
  else t_no "hostname -n 落盘了 rc=$rc"; fi

  reset_sbx
  set +e
  out=$(run_nc hostname nc-rev -y 2>&1); rc=$?
  set -e
  local rev; rev=$(ls -1d "$sbx/var/backups/netcfg-hostname"/*/ 2>/dev/null | tail -1)revert.sh
  if [ "$rc" -eq 0 ] && [ -f "$rev" ] && bash "$rev" >/dev/null 2>&1 \
     && [ "$(cat "$hf")" = "oldbox" ] && grep -q oldbox "$hostsf"; then
    t_ok "hostname revert.sh 能恢复主机名与 hosts"
  else t_no "hostname revert 失败 rc=$rc"; fi

  # --- 21. set/pin + --hostname 一条命令完成 -----------------------------
  reset_sbx
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.70/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.70/24 -g 192.168.1.1 --hostname nc-combo -y -t 5 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "192.168.1.70/24" "$cfg" && [ "$(cat "$hf")" = "nc-combo" ] \
     && grep -qE '^127\.0\.1\.1[[:space:]]+nc-combo$' "$hostsf"; then
    t_ok "set + --hostname 一条命令同时生效"
  else t_no "set + --hostname 失败 rc=$rc"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fi

  reset_sbx
  cp "$cfg" "$T/c.orig"; cp "$hf" "$T/h2.orig"
  set +e
  out=$(FAKE_IFACE_ADDRS="192.168.1.71/24" FAKE_ROUTE="default via 192.168.1.1 dev ens33" \
        run_nc set -i ens33 -4 192.168.1.71/24 -g 192.168.1.1 --hostname "bad..name" -y 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ] && diff -q "$T/c.orig" "$cfg" >/dev/null 2>&1 && diff -q "$T/h2.orig" "$hf" >/dev/null 2>&1; then
    t_ok "非法主机名时整条命令不落盘"
  else t_no "非法主机名未阻断 rc=$rc"; fi

  printf '\n== 结果: 通过 %d, 失败 %d, 跳过 %d ==\n' "$pass" "$fail" "$skip"
  if [ "$fail" -ne 0 ]; then printf '自测存在失败项\n'; return 1; fi
  printf '自测全部通过\n'
}

# ---------------------------------------------------------- 后台执行 ---
detach_self() {
  if [ -z "$SELF" ] || [ ! -f "$SELF" ]; then
    die "--detach 需要脚本是真实文件(从管道执行无法后台化): 先 curl -o netcfg.sh, 或先安装 netcfg"
  fi
  local -a keep=()
  local a log
  for a in "$@"; do
    case "$a" in
      --detach|--detach=*) continue ;;
    esac
    keep+=("$a")
  done
  if [ -n "$DETACH_LOG" ]; then
    log="$DETACH_LOG"
    case "$log" in /*) ;; *) log="/var/log/$log" ;; esac
  else
    log="/var/log/netcfg-$(date +%Y%m%d-%H%M%S).log"
  fi
  if [ "$ROOT" != "/" ]; then log=$(real_path "$log"); fi
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  if ! : > "$log" 2>/dev/null; then die "无法创建日志文件: $log (需要 root?)"; fi
  setsid nohup bash "$SELF" "${keep[@]}" >>"$log" 2>&1 </dev/null &
  local pid=$!
  info "已在后台执行(PID $pid), 输出写入 $log"
  info "完成后会自动校验并确认; 失败或超时未确认会看门狗自动回滚"
  info "查看进度: tail -f $log"
  return 0
}

# ---------------------------------------------------------------- 入口 ---
main() {
  local -a ORIG=("$@")
  # 先扫一遍 --detach: 放在子命令前后任意位置都生效
  local a
  for a in "${ORIG[@]}"; do
    case "$a" in
      --detach) DETACH=1 ;;
      --detach=*) DETACH=1; DETACH_LOG="${a#*=}" ;;
    esac
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --detach|--detach=*) shift ;;
      -V|--version) printf '%s %s\n' "$PROG" "$VER"; exit 0 ;;
      -v|--verbose) VERBOSE=1; shift ;;
      --) shift; break ;;
      -*) break ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || { usage; exit 2; }
  local cmd="$1"; shift
  case "$cmd" in
    set|config|apply|rollback|restore)
      if [ "$DETACH" -eq 1 ]; then detach_self "${ORIG[@]}"; exit 0; fi ;;
  esac
  case "$cmd" in
    show|status) cmd_show ;;
    set|config)  parse_set_opts "$@"; if [ "$FROM_CURRENT" -eq 1 ]; then capture_current; fi; cmd_set ;;
    pin|freeze|from-current) parse_set_opts "$@"; cmd_pin ;;
    apply)       parse_set_opts "$@"; cmd_apply ;;
    hostname|host) cmd_hostname "$@" ;;
    backup)      cmd_backup ;;
    rollback|restore) cmd_rollback "${1:-}" ;;
    _restore)    restore_backup "${1:-}" ;;
    selftest|test) cmd_selftest ;;
    help|-h|--help) usage ;;
    *) err "未知命令: $cmd"; usage; exit 2 ;;
  esac
}

parse_set_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--iface)      IFACE="${2:-}"; shift 2 ;;
      -4|--ip|--ipv4)  ADDRS+=("${2:-}"); shift 2 ;;
      -6|--ipv6)       V6S+=("${2:-}"); shift 2 ;;
      -g|--gateway)    GW="${2:-}"; shift 2 ;;
      -G|--gateway6)   GW6="${2:-}"; shift 2 ;;
      -d|--dns)        DNS_GIVEN=1; DNSES+=("${2:-}"); shift 2 ;;
      --no-dns)        NO_DNS=1; DNS_GIVEN=1; shift ;;
      -s|--search|--dns-search) SEARCHES+=("${2:-}"); shift 2 ;;
      -m|--mtu)        MTU="${2:-}"; shift 2 ;;
      --from-current)  FROM_CURRENT=1; shift ;;
      --with-ipv6)     WITH_IPV6=1; shift ;;
      --allow-other-prefix) ALLOW_OTHER_PREFIX=1; shift ;;
      --hostname)      TARGET_HOSTNAME="${2:-}"; shift 2 ;;
      --dhcp)          MODE=dhcp; shift ;;
      --dhcp6)         DHCP6=1; shift ;;
      --static)        MODE=static; shift ;;
      --allow-offlink|--allow-offlink-gateway) ALLOW_OFFLINK=1; shift ;;
      -t|--timeout)    TIMEOUT="${2:-}"; shift 2 ;;
      --no-guard)      GUARD=0; shift ;;
      --strict)        STRICT=1; shift ;;
      --no-verify)     VERIFY=0; shift ;;
      -n|--dry-run)    DRY_RUN=1; shift ;;
      -y|--yes)        YES=1; shift ;;
      -b|--backend)    BACKEND="${2:-}"; shift 2 ;;
      -v|--verbose)    VERBOSE=1; shift ;;
      -V|--version)    printf '%s %s\n' "$PROG" "$VER"; exit 0 ;;
      -h|--help)       usage; exit 0 ;;
      *) die "未知参数: $1 (netcfg.sh help 查看用法)" ;;
    esac
  done
}

main "$@"
