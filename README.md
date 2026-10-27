# 两台 360T7 组 802.11s Mesh + 同 SSID 无缝漫游（跨房间无线回程）

> 实战记录：用两台 360 T7 路由器（MediaTek Filogic MT7981，OpenWrt 24.10 / bleachwrt mini），
> 通过 **802.11s mesh 无线回程**打通客厅与卧室，全屋同一副 SSID，手机拿在手里无缝漫游。
> 本文不含真实 SSID / 密码 / MAC，示例一律用占位名。

- 作者：zseagate
- 日期：2026-10-27
- 设备：360 T7 × 2
- 固件：bleachwrt mini `R26.10.26`（OpenWrt 24.10.5，内核 6.12.112，`mediatek/filogic`）

---

## 0. TL;DR（一句话版）

用 **5G 单独一张 radio 建 802.11s mesh 回程**，两台的 `mesh_id`、SAE 密码、信道必须完全一致；
客厅作为主路由（DHCP），卧室做成**哑 AP**（关 DHCP/DNS、LAN 改同网段 IP）；
两个 **802.11r/k/v**（漫游）必须同步打。
而真正把人坑了一下午的，是 `/lib/netifd/wireless/mac80211.sh` 里一个
**`frequency=5745.0` 浮点值导致 wpa_supplicant 拒认配置**的 bug——**不是 SAE 的问题**，
也不是 encryption 用 `psk2` 的问题，别被表象骗了。

---

## 1. 拓扑

```
        客户端 (手机/电脑)                        客户端 (手机/笔记本)
            │  同一套 SSID，同一密码                   │
            ▼                                        ▼
 ┌──────────────────────────┐        802.11s mesh  ┌──────────────────────────┐
 │  客厅路由  192.168.10.1   │ ◄═══════5G ch149════►│  卧室路由  192.168.10.2   │
 │  (主路由 PPPoE, DHCP 开)   │        HE80/SAE     │  (哑 AP, DHCP/DNS 关)     │
 └──────────────────────────┘        mesh 回程      └──────────────────────────┘
            ▏2.4G(ch6 HE20) 客户端AP     ▏2.4G(ch1 HE20) 客户端AP
              │  客户端漫游时自动切到                    │
              ▼  信号更好的那一台                       ▼
              └── 同一局域网 192.168.10.0/24 ──────────┘
```

- **两台之间只有 mesh 无线这一条路径**，没有网线直连。
- `lan1/lan2/lan3` 全部桥在 `br-lan` 上，**STP 未开**（详见 §6 环路风险）。
- 回程实测 1200.9 Mbps（HE-MCS11 80MHz 2SS），单向最大 522 Mbps，ping 跨 mesh ~1.0 ms。

---

## 2. 频道规划表（必须两台完全对齐的部分加粗）

| 项 | 客厅（主） | 卧室（哑 AP） | 备注 |
|---|---|---|---|
| LAN IP | **192.168.10.1** | **192.168.10.2** | 卧室默认 192.168.1.1 必须改 |
| 2.4G 信道 | **ch6 / HE20** | **ch1 / HE20** | 错开频道，别叠加 |
| 5G 信道 | **ch149 / HE80 + noscan=1** | **ch149 / HE80 + noscan=1** | mesh 必须同频 |
| 5G 发射功率 | 29 dBm | **23 dBm**（调低，降同频干扰） | 同频 AP 功率高反而坏事 |
| SSID（2.4G） | `MainWiFi-2G` | 同名同密码 | |
| SSID（5G） | `MainWiFi-5G` | 同名同密码 | |
| encryption | `psk-mixed` | 同 | |
| 802.11r | `ieee80211r=1, mobility_domain=4f57, ft_over_ds=1, ft_psk_generate_local=1` | **同，一字不差** | |
| 802.11k | `ieee80211k=1` | 同 | |
| 802.11v | `bss_transition=1, wnm_sleep_mode=1` | 同 | ⚠️ 注意键名不是 `ieee80211v`，见坑2 |
| mesh | `mode=mesh, mesh_id=MeshBackhaul, network=lan, mesh_fwding=1` | 同 | 绑 5G radio |
| mesh encryption | `sae`（或 `psk2`，效果一样，见坑1） | 同 | |
| DHCP | 开（唯一 DHCP） | **关**：`dhcp.lan.ignore=1`，并 `disable` dnsmasq/odhcpd | |
| 其他 | hostname `livingroom` | hostname `bedroom` | 便于 mDNS 识别 |

> ⚠️ 同 SSID 必须保证 **密码、加密方式、mobility_domain、802.11r/k/v 全部一致**，任何一个不一致都会导致漫游握手失败。

---

## 3. 客厅侧配置（只加一个 mesh 接口）

```sh
# 1) 主信道钉死,禁止 hostapd 启动时自动换 primary
uci set wireless.radio1.noscan='1'

# 2) 漫游参数（三把 r/k/v）
for r in default_radio0 default_radio1; do
  uci set wireless.$r.ieee80211r='1'
  uci set wireless.$r.mobility_domain='4f57'
  uci set wireless.$r.ft_over_ds='1'
  uci set wireless.$r.ft_psk_generate_local='1'
  uci set wireless.$r.ieee80211k='1'
  # 注意:这里写的是 bss_transition 而不是 ieee80211v!见坑2
  uci set wireless.$r.bss_transition='1'
  uci set wireless.$r.wnm_sleep_mode='1'
done

# 3) 802.11s mesh 回程
uci set wireless.mesh5g=wifi-iface
uci set wireless.mesh5g.device='radio1'
uci set wireless.mesh5g.mode='mesh'
uci set wireless.mesh5g.mesh_id='MeshBackhaul'
uci set wireless.mesh5g.mesh_fwding='1'
uci set wireless.mesh5g.network='lan'
uci set wireless.mesh5g.encryption='sae'
uci set wireless.mesh5g.key='<你的mesh密码>'
uci commit wireless

# 4) 应用 —— 注意用 down/up 而不是 reload
wifi down radio1 && sleep 3 && wifi up radio1
```

## 4. 卧室侧配置（做哑 AP）

```sh
# 0) 备份
BK=/root/config-backup-$(date +%Y%m%d-%H%M)
cp -a /etc/config "$BK"

# 1) LAN 换网段 + 变成哑 AP
uci set network.lan.ipaddr='192.168.10.2'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.10.1'
uci set network.lan.dns='192.168.10.1'
uci commit network

uci set dhcp.lan.ignore='1'
uci commit dhcp
/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable
/etc/init.d/odhcpd stop && /etc/init.d/odhcpd disable

uci set system.@system[0].hostname='bedroom'
uci commit system

# 2) 频道（与客厅对齐的部分,**必须一样**）
uci set wireless.radio0.channel='1'      # 2.4G 与主路由错开
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.noscan='1'
uci set wireless.radio1.txpower='23'

# 3) SSID/密码/漫游 —— 与客厅一字不差
uci set wireless.default_radio0.ssid='MainWiFi-2G'
uci set wireless.default_radio0.encryption='psk-mixed'
uci set wireless.default_radio0.key='<WiFi密码>'
uci set wireless.default_radio1.ssid='MainWiFi-5G'
uci set wireless.default_radio1.encryption='psk-mixed'
uci set wireless.default_radio1.key='<WiFi密码>'
for r in default_radio0 default_radio1; do
  uci set wireless.$r.ieee80211r='1'
  uci set wireless.$r.mobility_domain='4f57'
  uci set wireless.$r.ft_over_ds='1'
  uci set wireless.$r.ft_psk_generate_local='1'
  uci set wireless.$r.ieee80211k='1'
  uci set wireless.$r.bss_transition='1'
  uci set wireless.$r.wnm_sleep_mode='1'
done

# 4) mesh —— 与客厅参数完全一致
uci set wireless.mesh5g=wifi-iface
uci set wireless.mesh5g.device='radio1'
uci set wireless.mesh5g.mode='mesh'
uci set wireless.mesh5g.mesh_id='MeshBackhaul'
uci set wireless.mesh5g.mesh_fwding='1'
uci set wireless.mesh5g.network='lan'
uci set wireless.mesh5g.encryption='sae'
uci set wireless.mesh5g.key='<同一个mesh密码>'
uci commit wireless
wifi down radio1 && sleep 3 && wifi up radio1
```

## 5. 验收清单

```sh
# Ⅰ 5G 上是否有 mesh 接口 + 它是不是真的在 802.11s
iw dev | grep -E "Interface|type"          # 应看到一个 type: mesh point
iw dev wlan1 info                           # 应是 ch149/80MHz

# Ⅱ mesh plink 状态(两台都看)
iw dev wlan1 station dump | grep -E "^Station|plink|bitrate|signal"
#    → mesh plink: ESTAB
#    → tx bitrate: 1200.9 MBit/s 80MHz HE-MCS 11

# Ⅲ mpath 表
iw dev wlan1 mpath dump                     # 应有一条到对端的路

# Ⅳ 跨 mesh 端到端(在哑 AP 上 ping 主路由)
ping -c 5 192.168.10.1                      # 0% 丢包
ping -c 5 -s 1400 192.168.10.1              # 大包也 0%

# Ⅴ 环路检测:同一 MAC 不应被学在多个端口
brctl showmacs br-lan | awk 'NR>2 && $2=="no"{mac=$1;c[mac]++}END{for(m in c) if(c[m]>1)print "DUP:",m}'

# Ⅵ 802.11r/k/v 是否真的在 hostapd 里生效(不是 uci 里"看起来开了")
grep -E "bss_transition|wnm_sleep|rrm_neighbor|mobility_domain|ft_" /var/run/hostapd-phy0.conf
```

---

## 6. ⚠️ 实战排坑记录（真坑都在这）

### 坑 1：mesh 一直 `IFUP_ERROR`,根因根本不在 SAE

**表象**（多人遇到都以为是 SAE 不行）：
```
netifd: radio1 (7500): Cannot find device "wlan1"
netifd: radio1 (7500): Interface 1 setup failed: IFUP_ERROR / WPA_SUPPLICANT_FAILED
wpa_supplicant: Failed to read or parse configuration '/var/run/wpa_supplicant-wlan1.conf'
```
换 `psk2`、换 key、换驱动、重启路由器都**不解决**。

**真正日志里的一行：**
```
wpa_supplicant: Line 11: invalid number "5745.0"
wpa_supplicant: Line 11: failed to parse frequency '5745.0'.
wpa_supplicant: Line 17: failed to parse network block.
```

**根因**：新版 `iw`（6.17）`iw phy info` 输出频率为 **`5745.0 MHz`（浮点）**，
而 `netifd` 的 `get_freq()` 直接 `awk '{print $2}'` 截取，结果就是 `frequency=5745.0`。
wpa_supplicant 不接受小数 → 整个 network 块解析失败 → mesh 压根没启动。

**一锤子修复**（两台都要打；overlay 可写层、重启保留；**sysupgrade 会丢失**）：

```sh
# /lib/netifd/wireless/mac80211.sh 第 1065 行
- print $2
+ print int($2)
```
做成正则替换（脚本已放在本仓库 [patches/fix-mesh-frequency.sh](patches/fix-mesh-frequency.sh)）：

```sh
sed -i 's/^	print \$2$/	print int($2)/' /lib/netifd/wireless/mac80211.sh
```

**容易踩的延伸坑 ×3：**

1. **mesh 模式下 hostapd.sh 强制走 SAE**（1346/1380 行把 `wpa_key_mgmt=SAE` 写死），
   所以 uci 里 `encryption=` 填 `sae` 还是 `psk2` **效果一样**，别再期待改它就能翻盘。
2. **单次 `wifi reload` 不一定重建 mesh 接口**，要用：
   ```
   wifi down radio1 && sleep 3 && wifi up radio1
   ```
3. **在同一张 radio 上同时建 AP + mesh 有一个 ifname 争用**：
   AP 先抢 `wlan1`，mesh 就拿不到了 → `Cannot find device "wlan1"`。
   **可靠做法是"两阶段起无线"**：
   ```
   # 阶段一:先把 AP 关掉,让 mesh 拿到 wlan1
   uci set wireless.default_radio1.disabled='1'; uci commit wireless
   wifi reload radio1; sleep 8
   # 阶段二:把 AP 加回来,自动落到 wlan1-1
   uci set wireless.default_radio1.disabled='0'; uci commit wireless
   wifi reload radio1; sleep 10
   ```
   且建议**断电前把上面的启动路径固化**（用 `/etc/rc.local` 或热插拔脚本），
   否则重启一次踩一次。

### 坑 2：LuCI/uci 里 `ieee80211v='1'` 看似开了，实际是死的

`hostapd.sh` **根本不读取** `ieee80211v` 这个键，只读 `bss_transition`：

```sh
# /lib/netifd/hostapd.sh
857: json_get_vars ... wnm_sleep_mode ... bss_transition mbo
858: set_default bss_transition 0          # ← 默认还是 0
869: [ "$bss_transition" -eq "1" ] && append bss_conf "bss_transition=1" "$N"
```

**正确写法：**
```sh
uci set wireless.default_radioX.bss_transition='1'
uci set wireless.default_radioX.wnm_sleep_mode='1'
```

**验证不是"看起来"而是"真的在"**：
```sh
grep -E "bss_transition|wnm_sleep|rrm_neighbor|mobility_domain|ft_" /var/run/hostapd-phy0.conf
```
（我们两台最初 `grep bss_transition` 都是空的——LuCI 界面欺骗性 pretty 强。）

### 坑 3：绿（mesh enkrypted）在客户端侧一直"看不到对端"

表现为两边 `iw dev wlan1 station dump` 都是**空**，`mpath dump` 也空。
排查顺序要牢记：

```sh
1. 两台 mesh_id 一致       → uci get wireless.mesh5g.mesh_id
2. 两台 SAE 密码一致        → 用同一个变量/文件，别手动改两处
3. 两台 5G 主信道一致       → iw dev wlan1 info                         ← 最常见"一强一弱"
4. 双方 radio 都 up        → ubus call network.wireless status
5. 是否真有 mesh 接口       → iw dev | grep "type: mesh point"
```

如果第 5 步发现接口都存在但 `NO-CARRIER`，**第一优先回头检查日志里有没有
`invalid number "5745.0"`（坑1）**——这是这次最耗时的一段。

### 坑 4：卧室改 LAN IP 会留下"绑死在旧 IP"的服务

把 LAN 从 `192.168.1.1` 改到 `192.168.10.2` 后，netifd 里的 `ifup lan` 只是换地址，
**已经用旧地址 bind 的进程不会自动 rebind**：

| 服务 | 现象 | 修法 |
|---|---|---|
| `ttyd`（LuCI 的"终端"） | `netstat -lnt` 仍看到它监听 `192.168.1.1:7681`，新地址端口**拒绝连接** | `/etc/init.d/ttyd restart` |

排查命令：
```sh
netstat -lnt | grep "192.168.1.1"     # 一切"绑死在旧网段"的服务
```

### 坑 5：环路隐患（务必读这段）

两台的 `br-lan` **STP 都是关的**，而 mesh 和有线网口都桥在 `br-lan` 上。
确认没有环路 JIT 之前,下面的组合就是"广播风暴现场":

- ❌ 两台之间再拉一根 `LAN↔LAN` 网线 + mesh 同时存在 = **二层环路**
- ❌ 两台都插同一个交换机的 LAN + 无 STP = **二层环路**

**正确姿势：**
- 只用 mesh → **谁也别用网线把两台 LAN 串起来**
- 真要用有线回程 → **先把 mesh 禁了**（`uci set wireless.mesh5g.disabled='1'; uci commit wireless`）
- 或者把 `br-lan` 的 STP 打开，然后任选

**环路自检一行**（我们现场实际跑过，干净）：
```sh
brctl showmacs br-lan | awk 'NR>2 && $2=="no"{c[$1]++}END{for(m in c)if(c[m]>1)print "DUP:",m,c[m]}'
```

---

## 7. 性能数据（本次实测）

| 指标 | 值 |
|---|---|
| mesh 链路速率 | 1200.9 Mbit/s（HE-MCS11 80MHz 2SS） |
| 回程信号 | 客厅↔卧室 -37~-53 dBm（推荐 ≥ -65dBm，越好回程越稳） |
| 单向实际吞吐 | **最高 522 Mbps**（测试中落在 RAM 的文件可跑出该值；文件落在 flash 会跑不上去） |
| 延迟 | 跨 mesh ping 主路由 ~1.0 ms（无网络风暴时） |
| iPhone 5G RSSI | 从 -77 dBm 提高到 **-52 dBm**（摆位带来的提升 >25dB，比改任何 radio 参数都管用） |

> 💡 摆位是 mesh 组网**回报最高**的投入：回程我看到 -45 dBm 时一切都顺；
> 弱到 -70 dBm 时哪怕配置全对，你的体验也只会是"卡、断、漫游抖"。

---

## 8. 常见坑速查

| 症状 | 大概率原因 | 快速验证 |
|---|---|---|
| 两台无法互学对方 / `station dump` 为空 | `frequency=5745.0` 解析失败（坑1） | `dmesg` / `logread | grep -iE "frequency|IFUP"` |
| mesh 接口一直 `NO-CARRIER` | 上面坑1，或两台主信道不一致 | 两边各 `iw dev wlan1 info` 对比 |
| 新增 mesh 报 `Cannot find device "wlan1"` | AP 抢了 `wlan1` 名（坑1延伸3） | `brctl show br-lan` 看端口映射 |
| uci 里看 11v 开了，但客户端不漫游 | 写的是 `ieee80211v` 而非 `bss_transition`（坑2） | `grep bss_transition /var/run/hostapd-phy0.conf` |
| mesh SSID 出现在手机 WiFi 列表里 | 802.11s 规范要求 beacon 里必带 mesh_id，**无法隐藏** | 属正常，不要去连 |
| 管理机改 IP 后 LuCI/SSH 某个端口拒绝 | 服务绑死在旧 IP（坑4） | `netstat -lnt | grep 旧IP` |
| 全网突然掉线、广播包暴涨 | 二层环路（坑5） | `brctl showmacs` 看 MAC 是否漂移 |

---

## 9. 仓库结构

```
360t7-mesh/
├── README.md                        ← 本篇
├── LICENSE                          ← MIT
├── patches/
│   ├── fix-mesh-frequency.sh        ← 根治 mesh "frequency=5745.0" bug
│   └── apply-mesh-config.example.sh ← 两台的 uci 配置成稿（已脱敏）
└── scripts/
    └── verify-mesh.sh               ← 一键验收脚本
```

## 10. 一键验收脚本

```sh
./verify-mesh.sh            # 本地跑,输出 ✅/⚠️ 清单
```

---

## 11. 安全与脱敏

- 本文所有 SSID 均为示例占位（`MainWiFi-*` / `MeshBackhaul`）；
- 所有密码统一用 `<你的WiFi密码>` / `<你的mesh密码>`；
- MAC 全部截断；
- 实际部署时**不要**把密码写进任何会被 push 到 Git 的文件。

## 12. License

MIT
