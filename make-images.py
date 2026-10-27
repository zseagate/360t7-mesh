#!/usr/bin/env python3
# 生成公众号头条封面 (900×383 实际显示, 做 1200×510 高清) + 拓扑图
from PIL import Image, ImageDraw, ImageFont
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets")
os.makedirs(OUT, exist_ok=True)
FONT_DIR = "/usr/share/fonts/opentype/noto"
BOLD = os.path.join(FONT_DIR, "NotoSansCJK-Bold.ttc")
BLK = os.path.join(FONT_DIR, "NotoSansCJK-Black.ttc")
REG = os.path.join(FONT_DIR, "NotoSansCJK-Regular.ttc")
DEMILIGHT = os.path.join(FONT_DIR, "NotoSansCJK-DemiLight.ttc")

# ---------- 公众号头条封面 1200x510 ----------
W, H = 1200, 510
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
# 垂直渐变 深蓝→青
top = (13, 27, 42); bot = (22, 55, 83)
for y in range(H):
    t = y / (H - 1)
    d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)))
# 装饰:右上斜光带
for i in range(90):
    x0 = W - 200 + i
    d.line([(x0, 0), (x0 + 260, H)], fill=(46, 134, 193, ), width=1)
# 装饰:网状连线
for i in range(14):
    x = 720 + i * 34
    d.ellipse([x, 120 + (i % 3) * 40, x + 3, 123 + (i % 3) * 40], fill=(120, 200, 255))

def rrect(box, r, fill, outline=None, w=2):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=w)

def text(x, y, s, font, fill, anchor="la"):
    d.text((x, y), s, font=font, fill=fill, anchor=anchor)

f_title = ImageFont.truetype(BLK, 92)
f_sub = ImageFont.truetype(BOLD, 46)
f_tag = ImageFont.truetype(REG, 28)
f_small = ImageFont.truetype(DEMILIGHT, 24)

ACC = (255, 196, 12)
CY = (86, 204, 242)
WHT = (245, 246, 250)

# 左上的标签
rrect((60, 64, 348, 112), 24, (0, 0, 0, 0), ACC, 2)
text(90, 74, "OPENWRT 实战", f_tag, ACC)

# 大标题
text(60, 150, "两台 360T7 组 Mesh", f_title, WHT)
text(60, 268, "踩坑全记录", f_title, ACC)

# 副标题
text(62, 400, "802.11s 回程 · 5G ch149 · 同 SSID 漫游", f_sub, CY)

# 右侧: 两台路由器图标 + mesh 链路
rx1, rx2, ry = 850, 1060, 290
for x in (rx1, rx2):
    rrect((x, ry, x + 70, ry + 42), 12, (30, 50, 70), CY, 2)
    for k in range(3):
        rrect((x + 8 + k * 20, ry + 10, x + 20 + k * 20, ry + 32), 4, CY)
        d.arc([x + 6 + k * 20, ry - 6, x + 22 + k * 20, ry + 14], 180, 360, fill=(160, 210, 255), width=2)
# mesh 链路(虚线)
for s in range(0, rx2 - rx1 - 80, 26):
    d.line([rx1 + 72 + s, ry + 21, rx1 + 72 + s + 14, ry + 21], fill=ACC, width=4)
text((rx1 + rx2 + 35) / 2, ry - 16, "mesh 5G", f_small, ACC, anchor="ms")
# 回程速率徽标
rrect((rx1 - 10, ry + 80, rx2 + 90, ry + 130), 12, (255,196,12), None)
text((rx1 - 10 + rx2 + 90) / 2, ry + 105, "1200 Mbps", f_small, (13, 27, 42), anchor="mm")

img.save(os.path.join(OUT, "cover-wechat.png"), "PNG")
print("cover saved", img.size)

# ---------- 拓扑图 1400x760 ----------
JW, JH = 1400, 760
timg = Image.new("RGB", (JW, JH), (250, 250, 250))
td = ImageDraw.Draw(timg)
F_N = ImageFont.truetype(BOLD, 34)
F_M = ImageFont.truetype(REG, 26)
F_S = ImageFont.truetype(DEMILIGHT, 22)
F_T = ImageFont.truetype(BLK, 40)
NAVY = (23, 42, 60); BLUE = (41, 128, 185); GRY = (90, 100, 110)
INK = (40, 44, 50); ACC = (230, 126, 34); GRN = (39, 174, 96)

td.text((JW // 2, 52), "360T7 × 2 组 Mesh · 同 SSID 无缝漫游", font=F_T, fill=NAVY, anchor="ma")

def router(x, y, label, ip, tags):
    bw, bh = 470, 210
    td.rounded_rectangle([x, y, x + bw, y + bh], radius=18, fill=(255, 255, 255), outline=BLUE, width=3)
    td.text((x + bw / 2, y + 34), label, font=F_N, fill=NAVY, anchor="ma")
    td.text((x + bw / 2, y + 78), ip, font=F_M, fill=BLUE, anchor="ma")
    for i, tg in enumerate(tags):
        td.text((x + 30, y + 118 + i * 28), tg, font=F_S, fill=INK)
    return x, y, bw, bh

l1 = router(130, 260, "客厅路由（主）", "192.168.10.1 · PPPoE / DHCP",
            ["2.4G  ch6    HE20", "5G    ch149  HE80  29dBm", "mesh  wlan1  SAE"])
l2 = router(130 + 750, 260, "卧室路由（哑AP）", "192.168.10.2 · DHCP/DNS OFF",
            ["2.4G  ch1    HE20", "5G    ch149  HE80  23dBm", "mesh  wlan1  SAE"])

# mesh 链路
mx1, mx2 = l1[0] + l1[2], l2[0]
my = l1[1] + l1[3] / 2
td.line([mx1 + 8, my, mx2 - 8, my], fill=ACC, width=5)
td.polygon([(mx2 - 8, my - 10), (mx2 - 8, my + 10), (mx2 + 8, my)], fill=ACC)
td.polygon([(mx1 + 8, my - 10), (mx1 + 8, my + 10), (mx1 - 8, my)], fill=ACC)
td.text(((mx1 + mx2) / 2, my - 46), "802.11s mesh", font=F_N, fill=ACC, anchor="mb")
td.text(((mx1 + mx2) / 2, my - 18), "(5G ch149)", font=F_S, fill=INK, anchor="mb")
td.text(((mx1 + mx2) / 2, my + 16), "同 ID · 同密码", font=F_S, fill=INK, anchor="mt")

# 客户端漫游(顶部大弧, 说明文字放弧线下方避免压标题)
td.arc([l1[0] + 100, 105, l2[0] + l2[2] - 100, 470], 190, 350, fill=GRN, width=4)
td.polygon([(l2[0] + 400, 260), (l2[0] + 380, 250), (l2[0] + 386, 274)], fill=GRN)
td.text((JW // 2, 212), "客户端拿在手里走，自动切到信号更好的那台", font=F_M, fill=GRN, anchor="mb")

# 下部要点
pts = [
    "① 两台之间只有无线 mesh，不要再用网线串 LAN（无 STP 会广播风暴）",
    "② mesh_id / SAE 密码 / ch149 / HE80 完全一致，缺一个就叫不上",
    "③ 只有 5G 做 mesh，2.4G 留给普通客户端，信道错开，别让回程抢带宽",
]
for i, p in enumerate(pts):
    td.text((130, 540 + i * 62), p, font=F_M, fill=INK)

timg.save(os.path.join(OUT, "topology.png"), "PNG")
print("topology saved", timg.size)
