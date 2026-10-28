# 代理 + 广告拦截（mihomo TUN 模式，带网页管理）

在一台 **OpenWrt 24.10 / aarch64** 路由器上，用 **mihomo（Clash.Meta）** 做透明代理，
同时用同一份规则做 DNS 级广告拦截，并自带一个**中文网页管理界面**（增删订阅、切换出口、改密钥）。

> 本目录是 [360t7-mesh](../README.md) 项目的第二阶段：Mesh 打通后，再加上「出国 + 去广告」。
> 全部脚本均已在 360T7（MT7981，128MB flash / 256MB RAM）实机验证。

---

## 1. 为什么不用 Nikki / OpenClash

| 方案 | 能否装 | 原因 |
|---|---|---|
| **Nikki**（mihomo + LuCI） | ❌ | 依赖 `firewall4`（nft 表 `inet fw4`）。本固件是**老 iptables firewall**，会报 `list table inet fw4: No such file or directory`；feed 里也没有 `firewall4`，强装等于替换防火墙后端 |
| OpenClash | ⚠️ | 依赖 bash/大量组件，overlay 吃紧的机器上风险高 |
| **本方案** | ✅ | **纯 TUN 模式**，不需要 fw4 / nft tproxy；一个二进制 + 几个脚本，总共约 60MB（UBIFS 压缩后约占 30MB） |

资源实测：`mihomo` 常驻内存约 30–50MB，overlay 安装后剩余约 10–15MB。

---

## 2. 架构

```
LAN 客户端
   │  DNS :53
   ▼
dnsmasq ──上游──► mihomo DNS 127.0.0.1:1053（redir-host）
   │                    │
   │                    └── DoH: 223.5.5.5 / doh.pub
   ▼
路由/转发 ──► TUN (mihomo0) ──► 规则分流
                                 ├─ RULE-SET,adblock → REJECT（拦广告）
                                 ├─ 内网网段 → DIRECT
                                 ├─ GEOIP,CN → DIRECT
                                 └─ 其余 → Proxy（地区组 / Auto / DIRECT）
```

- 出口切换走 `PUT /proxies/Proxy`，**即时生效、不重启**；
- `profile.store-selected: true`：手动选的节点/分组**重启后保留**。

---

## 3. 文件说明

| 文件 | 部署位置 | 作用 |
|---|---|---|
| `gen-config.sh` | `/etc/mihomo/gen-config.sh` | 由订阅列表生成 `config.yaml`（含分组/规则），生成前用 `mihomo -t` 校验 |
| `regions.conf` | `/etc/mihomo/regions.conf` | 地区分组定义，格式 `显示名|节点名正则` |
| `mihomo.init` | `/etc/init.d/mihomo` | procd 自启（respawn） |
| `adblock-update.sh` | `/usr/sbin/adblock-update` | 下载 anti-AD → 转纯域名 → 热重载 |
| `mihomo-backup.sh` | `/usr/sbin/mihomo-backup` | 备份/恢复/轮转（保留 5 份，内容去重） |
| `www/mihomo/index.html` | `/www/mihomo/index.html` | 中文管理页（订阅增删、停启、出口切换、密钥） |
| `www/cgi-bin/mihomo-sub` | `/www/cgi-bin/mihomo-sub` | 管理页后端（CGI） |
| `luci/controller/mihomo_ui.lua` | `/usr/lib/lua/luci/controller/` | 把管理页挂进 LuCI 菜单：服务 → 代理管理 |
| `luci/view/mihomo_ui.htm` | `/usr/lib/lua/luci/view/` | LuCI 内嵌 iframe 视图 |
| `install.sh` | （本地执行） | 一键部署以上全部内容 |

---

## 4. 安装内核

```sh
# 在电脑上下载（路由器直连 GitHub 经常被 reset，建议本机下载再传）
curl -L -o mihomo.gz \
  https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-arm64-<版本>.gz

# 传给路由器
scp mihomo.gz root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'gunzip -c /tmp/mihomo.gz > /usr/bin/mihomo && chmod 755 /usr/bin/mihomo && mihomo -v'
```

需要 `kmod-tun`，确认 `/dev/net/tun` 存在：

```sh
ls -l /dev/net/tun || opkg install kmod-tun
```

## 5. 一键部署

```sh
# 先把本目录拷到路由器
scp -r proxy root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'sh /tmp/proxy/install.sh --dry-run'   # 先看要做什么
ssh root@192.168.10.1 'sh /tmp/proxy/install.sh'
```

`install.sh` 会做这些事（可重复执行）：

1. 检查内核 / `/dev/net/tun` / overlay 余量；
2. 安装脚本、页面、LuCI 菜单；
3. 生成 secret（已存在则保留）；
4. 生成初始配置（此时无订阅，全部直连）；
5. `dnsmasq` 设 `noresolv=1` + `server=127.0.0.1#1053`（**注意是 `add_list`，见坑 2**）；
6. `mihomo0` 加入 LAN 防火区域；
7. 写 `/etc/sysupgrade.conf` 保留清单；
8. 启动服务；
9. 首次拉取广告规则；
10. 加两条 cron（4:00 备份、4:30 更新规则）。

---

## 6. 日常使用

| 用途 | 入口 |
|---|---|
| 订阅管理（增删/停启/切出口） | `http://<路由器IP>/mihomo/`，或 LuCI **服务 → 代理管理** |
| 节点面板（切具体节点、看延迟） | `http://<路由器IP>:9090/ui/`，密钥见 `cat /etc/mihomo/.secret` || 广告规则状态 | `adblock-update --status` |
| 备份 / 恢复 | `mihomo-backup` / `mihomo-backup restore <文件>` |

### 可选：安装节点面板（metacubexd）

`install.sh` 不包含面板静态文件（约 8MB），需要的话单独装：

```sh
cd /tmp && \
curl -L -o mcd.tgz https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz && \
mkdir -p /etc/mihomo/ui && tar xzf mcd.tgz -C /etc/mihomo/ui && \
/etc/init.d/mihomo restart
```

`config.yaml` 里的 `external-ui: ui` 已指向该目录，重启后访问 `http://<路由器IP>:9090/ui/`，
首次进入填「后端地址 `http://<路由器IP>:9090`」+「密钥（secret）」即可，浏览器会记住。

### 出口策略：为什么不默认「自动最快」

`Auto` 是**跨地区**测速，出口 IP 会在香港/美国/日本之间来回跳——这是银行、支付、流媒体风控最敏感的特征。
所以默认锁定**单一地区组**（如「香港」），只在该地区内换节点，**出口国家不变**：

```
Proxy（默认 = 第一个可用地区组）
├─ 香港 / 台湾 / 日本 / 新加坡 / 美国 / 韩国 / 英国 / 德国 / 马来西亚 / 荷兰
├─ Auto      （跨地区最快，仅备选）
├─ DIRECT    （全部直连 = 临时关停代理）
└─ sub-<订阅名>
```

地区组 = `url-test` + `filter` 正则 + `use` 全部 provider，`tolerance: 80` 避免无谓切换。
想只走某个节点，直接在面板里点它（会持久化）。

地区表可改 `regions.conf`，格式 `显示名|节点名正则`，改完：

```sh
/etc/mihomo/gen-config.sh && /etc/init.d/mihomo restart
```

订阅缓存里没有该地区节点时，会自动跳过、不生成空分组。

---

## 7. 广告拦截

- 规则源：**anti-AD**（约 9.9 万条），多个源自动降级：
  `cdn.jsdelivr.net` → `anti-ad.net` → `ghfast.top` 反代；
- 转换：easylist 的 `||domain^` → 纯域名，配合 `behavior: domain` + `format: text`；
- 安全阀：少于 5 万条视为下载不完整，**保留旧规则**；内容一致则跳过不写盘；
- 生效方式：`PUT /configs?force=true` 热重载，失败才回退 `restart`。

⚠️ **REJECT 是连接级拦截，不是 DNS 拦截**：域名照样能解析出 IP，但连接被瞬间拒绝。
所以别用 `nslookup` 判断是否生效（会误判），用 `curl` 看 `code=000` 或直接开浏览器。

---

## 8. 备份与持久化

`mihomo-backup` 默认只备份“配置类”内容（约 0.9MB）：

```sh
mihomo-backup              # 备份到 /root/mihomo-backup-YYYYmmdd-HHMMSS.tgz
mihomo-backup --full       # 额外含面板静态文件 + GeoSite.dat
mihomo-backup --with-core  # 额外含内核（+20MB，空间紧张别用）
mihomo-backup list|restore|clean
```

- 保留最近 5 份，**内容一致自动跳过**（省 flash）；
- 恢复前会自动把现场另存为 `pre-restore-*.tgz`；
- 所有关键文件已写入 `/etc/sysupgrade.conf`，**升级固件不会丢**。

真正的异地备份仍需拉到电脑：`scp root@<IP>:/root/mihomo-backup-*.tgz ./`

---

## 9. 排坑记录（都是实机踩过的）

1. **Nikki 装不上**：`firewall4` 缺失 + feed 无包 → 别改防火墙后端，直接用 TUN 模式。
2. **`dnsmasq` 的 `server` 是 list**：`uci set dhcp.@dnsmasq[0].server=...` **不生效**，
   必须 `uci add_list` + `noresolv=1`，否则 DNS 全拒（`REFUSED`）。
3. **TUN 必须进防火区**：`uci add_list firewall.@zone[0].device=mihomo0`，否则 LAN→tun 被丢。
4. **offload 冲突**：开 `turboacc` 的 flow offloading 时，TUN 流量可能绕过规则，建议关闭。
5. **空间红线**：AGH(32MB) 与 mihomo(57MB) 无法共存（实测只剩 464KB）；二选一。
6. **下载不稳**：GitHub 直链常被 reset，用镜像 `https://ghfast.top/https://github.com/...`。
7. **订阅写入竞态**：早期版本每次请求都重写 `subs.list`，并发提交会丢条目；
   现在改为「读全量 → 写临时文件 → `mv` 原子替换」，并保留 5 份带时间戳快照。
8. **`grep` 不支持 `(?i)`**：mihomo 的 filter 支持，但生成器里做预判时要去掉，改用 `grep -i`。
9. **地区误匹配**：判断某个地区有没有节点时，只匹配 `name:` 行，否则 URL 里的 `de`/`uk` 会造成误判。

---

## 10. 安全提醒

- 订阅链接里带 token，**不要提交到仓库**；本目录所有文件均不含真实订阅与密钥；
- `secret` 保存在 `/etc/mihomo/.secret`（600），面板与管理页都需要它；
- 管理页无登录鉴权（仅监听 LAN），如需暴露到公网请自行加 Basic Auth / 反向代理。
