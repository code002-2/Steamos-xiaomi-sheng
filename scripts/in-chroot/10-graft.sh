#!/usr/bin/env bash
# 10-graft.sh —— 在（已铺好 Frame userspace 的）镜像 chroot 内注入 sheng 设备层
# 由 workflow 通过 chroot 调用：chroot <mount> /root/graft/10-graft.sh
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

PARTLABEL="${PARTLABEL:-linux}"
KVER_BOOT="${KVER_BOOT:-}"
export DEBIAN_FRONTEND=noninteractive

# 1) /sbin/init 必须在（内核会 exec 它；缺了会 panic: No working init found）
for c in /sbin/init /usr/sbin/init /usr/lib/systemd/systemd; do [[ -x "$c" ]] && break; done
[[ -x "${c:-}" ]] || die "找不到 init（缺 systemd-sysvcompat？）"
log "init: $c"

# 2) 撤掉 Frame 的内核生成钩子 + preset，**必须在任何 pacman 事务之前**：
#    ① 移除 Frame 自带内核（下面 pacman -Rdd）时 `60-mkinitcpio-remove.hook` 就会触发；
#    ② 装我们的内核时 `90-mkinitcpio-install.hook` 触发。
#    它会给已被换掉的 `linux-618-deckard` 生成 initramfs，于是报
#      ==> ERROR: specified kernel image does not exist: '/boot/vmlinuz-linux-618-deckard'
#      error: command failed to execute correctly
#    （事务本身成功，纯粹是噪声；第一版放在装包之后 → 无效，第二版放在移除内核之后 → 仍剩一半）。
#    我们这套镜像**不用 initramfs**（内核 EXT4_FS=y / UFS_QCOM=y / DEVTMPFS_MOUNT=y 直接挂根）。
rm -f /etc/mkinitcpio.d/*.preset 2>/dev/null || true
for h in /usr/share/libalpm/hooks/*mkinitcpio*.hook; do
  [[ -e "$h" ]] && mv -f "$h" "$h.disabled" && log "已停用 Frame 的 mkinitcpio 钩子: $(basename "$h")"
done

# 3) 卸掉 Frame 的内核（我们用 sheng 的），再装我们的包
mapfile -t kp < <(pacman -Qq 2>/dev/null | grep -E '^linux(-[a-z0-9]+)?$' || true)
if [[ "${#kp[@]}" -gt 0 ]]; then
  warn "移除 Frame 自带内核: ${kp[*]}"
  pacman -Rdd --noconfirm --color never "${kp[@]}" || warn "移除内核失败（继续）"
fi
# Frame 固件包也换掉（我们替换 linux-firmware 语义）
# 放宽到所有固件包：Frame 可能叫 steamos-firmware / linux-firmware-* / 其它
mapfile -t fp < <(pacman -Qq 2>/dev/null | grep -Ei '(^linux-firmware|firmware)' || true)
[[ "${#fp[@]}" -gt 0 ]] && pacman -Rdd --noconfirm --color never "${fp[@]}" || true

# 0.5) 我们的包是 makepkg 产物（未签名），Frame 的 pacman.conf 若强制校验本地包签名，
#      pacman -U 会以 "signature is unknown trust" 失败 —— 先放开本地包签名要求。
if [[ -f /etc/pacman.conf ]]; then
  sed -i 's/^[[:space:]]*LocalFileSigLevel.*/LocalFileSigLevel = Optional/' /etc/pacman.conf
  grep -q '^LocalFileSigLevel' /etc/pacman.conf || sed -i '/^\[options\]/a LocalFileSigLevel = Optional' /etc/pacman.conf
  log "已确保 LocalFileSigLevel = Optional（本地包不校验签名）"
fi

shopt -s nullglob
pkgs=(/tmp/pkgs/*.pkg.tar.*)
[[ "${#pkgs[@]}" -gt 0 ]] || die "/tmp/pkgs 下没有设备包"
log "安装 sheng 设备包（${#pkgs[@]} 个）"
# 先做一次依赖体检：pacman -T 只列出"没被满足的依赖"，是排查跨发行版底包最直接的依据
log "依赖检查（pacman -T，列出未满足项）："
pacman -T "${pkgs[@]}" 2>&1 | sed 's/^/    /' || true

if ! pacman -U --noconfirm --color never "${pkgs[@]}"; then
  warn "首次安装失败，刷新数据库补依赖后重试"
  pacman -Sy --noconfirm --color never || warn "pacman -Sy 失败（Frame 的仓库可能是内部通道，无法补包）"
  if ! pacman -U --noconfirm --color never "${pkgs[@]}"; then
    # 兜底：**真正**跳过全部依赖检查。
    # ⚠️ 必须写 `-dd`（或 --nodeps 两次）。这里踩过一次实打实的坑：
    #   pacman 的 `--nodeps`（= `-d`）只跳过**版本**检查，包名依旧要能解析，
    #   所以只要底包缺一个运行期依赖就会失败。实测缺的是 `fprintd`（SteamOS 底包
    #   压根不带指纹栈）→ "unable to satisfy dependency 'fprintd' required by
    #   xiaomi-sheng-fingerprint" → 连兜底都装不上 → 整个镜像构建在这里挂掉。
    #   `-dd` 才是「文件照装、依赖只记录不强制」；缺哪些由下面的 pacman -Dk 报出来。
    warn "改用 -dd --overwrite '*' 强装（缺的运行期依赖会在 pacman -Dk 体检里列出）"
    pacman -U --noconfirm --color never -dd --overwrite '*' "${pkgs[@]}" \
      || die "设备包安装失败（连 -dd --overwrite 都装不上）"
  fi
fi

# 3) 内核模块索引（无 initramfs 启动的前提）
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
[[ -n "$KVER" ]] || die "装完内核包却看不到 /usr/lib/modules/*"
log "depmod -a $KVER"
depmod -a "$KVER" || warn "depmod 失败"
[[ -f "/usr/lib/modules/$KVER/modules.dep" ]] || die "modules.dep 未生成"

# 4) sheng 的挂载布局（替换 Frame 的 A/B 槽）
#    根分区用 PARTLABEL：与上游 boot.img 的 cmdline（root=PARTLABEL=userdata）保持一致。
#    ⚠️ 曾经改成 UUID=ee8d3593-…，结果镜像起不来 —— 已回退，别再无谓地动这里。
log "写 /etc/fstab: PARTLABEL=$PARTLABEL"
# 分区布局：SteamOS PC/掌机那一套是「root + home 两块」（参考 MaSieS4Fun/SteamOS-ARM-SM8550，
# 同一份 Frame 底包，他们的布局是 p1 BOOT / p2 root / p3 home）。我们的 root 在 $PARTLABEL 上，
# 另外给 /home 留一个 PARTLABEL=home 的分区：
#   * 有 home 分区 → 挂上去，重刷 rootfs 不再丢用户数据
#   * 没有 home 分区 → nofail 保证启动照常，/home 就留在 root 里
#     （**同一条 fstab 两种布局都能开机**，所以不强制用户立刻重分区）
# x-systemd.growfs 让文件系统首启扩到分区大小；分区本身（growpart）由 sheng-expand-home.service 做。
cat > /etc/fstab <<EOF
# steamos-sheng：sheng 分区布局（root 首启由 growfs 扩到分区实际大小）
PARTLABEL=$PARTLABEL /      ext4  defaults,x-systemd.growfs  0 1
# 可选的独立 home：分区不存在时 nofail 保证不影响启动；存在则由 sheng-expand-home 首启扩容
PARTLABEL=home       /home  ext4  defaults,noatime,nofail,x-systemd.growfs  0 2
EOF

# 5) 基本系统配置
: > /etc/machine-id
hostname > /etc/hostname 2>/dev/null || echo "${HOSTNAME_OVERRIDE:-xiaomi-sheng}" > /etc/hostname
ln -sf /usr/share/zoneinfo/UTC /etc/localtime 2>/dev/null || true

# 5.5) /var 骨架：Frame 的 /var 可能在独立子卷/分区（3.var-A.img）里，若没并进来就是空的。
#      systemd 首启虽会用 tmpfiles 补一部分，但 pacman 数据库、DBus、日志目录得先在，
#      否则重装/升级包时直接报错。
for d in var/lib/pacman var/lib/dbus var/lib/systemd var/lib/systemd/coredump \
         var/lib/NetworkManager var/lib/iwd var/log var/log/journal var/tmp \
         var/cache var/cache/pacman/pkg home root srv mnt opt proc sys dev run tmp; do
  mkdir -p "/$d"
done
chmod 1777 /tmp /var/tmp 2>/dev/null || true
chmod 0700 /root 2>/dev/null || true
log "/var 骨架已补齐（pacman/dbus/systemd/log 目录）"

# 5.9) 停掉「按 Frame 分区表挂载」的单元 + GPT 自动挂载生成器
#      症状（实机）：屏幕亮了但一直卡在等待 home 分区 —— systemd 在等
#      dev-disk-by-partlabel-home.device，那分区在 sheng 上根本不存在。
#      原因：Frame 的 userspace 带着指向 PARTLABEL=home / var-A / esp / efi-A 的挂载单元；
#            我们把 var/home/usr/opt 的内容并进了根分区（见 01-lay-rootfs.sh），
#            设备上只有 linux/userdata，于是这些单元永远等不到设备。
#      做法：① 把这些单元在 /etc/systemd/system 下软链到 /dev/null（屏蔽，systemd 官方用法）
#            ② 去掉指向它们的 .wants 启动依赖
#            ③ 停用 systemd-gpt-auto-generator（它会按 GPT 类型 GUID 自动生成 /home /var 挂载）
mkdir -p /etc/systemd/system
# 诊断：把底包里所有挂载相关单元的清单打全（上一轮只按内容 grep by-partlabel/xxx，
# 漏了 systemd 的转义写法 by\x2dpartlabel 与运行时生成的单元，所以扫出个空）
log "所有 mount/automount 单元文件："
ls -1 /usr/lib/systemd/system/*.mount /usr/lib/systemd/system/*.automount \
      /etc/systemd/system/*.mount /etc/systemd/system/*.automount 2>/dev/null | sed 's/^/    /' || true
# 打印每个 mount 单元实际挂什么（软链要跟到真实文件；实机卡住时这几行就是答案）
for f in /usr/lib/systemd/system/*.mount /etc/systemd/system/*.mount; do
  [[ -e "$f" || -L "$f" ]] || continue
  real="$f"; [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
  log "  ${f##*/}: $(grep -hE '^[[:space:]]*(What|Where|Options)[[:space:]]*=' "$real" 2>/dev/null | tr '\n' ' ' || true)"
done
log "wants 目录里的挂载相关软链："
for d in /usr/lib/systemd/system/*.wants /etc/systemd/system/*.wants; do
  [[ -d "$d" ]] || continue
  ls -1 "$d" 2>/dev/null | grep -E '\.(mount|automount|device|swap)$' | sed "s|^|    $d/|" || true
done
log "任何提到 partlabel / home / by-partlabel 的单元（含转义写法）："
grep -rlEi 'partlabel|by\\x2dpartlabel|/home\b|home\.mount' /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
  | sed 's/^/    /' || true
# 生成器与「已启用单元」清单：.mount 文件为空说明运行时生成的单元只能出自生成器，
# 而 on-screen 的 "start job is running for …" 对应的是某个 enabled 单元的依赖 → 必须看清楚
log "systemd 生成器清单："
ls -1 /usr/lib/systemd/system-generators/ 2>/dev/null | sed 's/^/    /' || true
log "已启用的单元（前 60 条）："
systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | head -60 | sed 's/^/    /' || true
log "包含 home/var/steam/part 字样的单元文件："
ls -1 /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
  | grep -Ei 'home|var|steam|part|esp|efi' | sort -u | sed 's/^/    /' || true

# 屏蔽：按「What= 是否指向设备」的通用规则屏蔽，而不是只按名字。
#   实测底包里 home.mount / esp.mount / efi.mount 都是**软链**（grep -r 不跟随软链，所以
#   之前按内容 grep by-partlabel 扫出个空），它们的 What= 指向 Frame 的分区 →
#   sheng 上没有这些分区 → systemd 干等（屏幕上就是「一直在等待一个 home 分区」）。
#   我们的镜像把 var/home/usr/opt 的内容并进了根分区（见 01-lay-rootfs.sh），
#   根由内核按 cmdline `root=PARTLABEL=linux` 直接挂载，因此这些设备型 mount 单元一个都不需要。
masked=0
for f in /usr/lib/systemd/system/*.mount /etc/systemd/system/*.mount \
         /usr/lib/systemd/system/*.automount /etc/systemd/system/*.automount; do
  [[ -e "$f" || -L "$f" ]] || continue
  u="${f##*/}"
  # 软链要跟到真实文件再读内容
  real="$f"; [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
  what="$(grep -hE '^[[:space:]]*What[[:space:]]*=' "$real" 2>/dev/null | head -n1 || true)"
  if [[ "$what" =~ /dev/|UUID=|PARTUUID=|by-partlabel|by-partuuid|by-label ]]; then
    log "屏蔽 $u（$what）"
    ln -sf /dev/null "/etc/systemd/system/$u" && masked=$((masked + 1))
  fi
done
# 兜底：这些名字即使文件不存在也屏蔽（防 cmdline/fstab/生成器运行时生成）
for u in home.mount home.automount var.mount var.automount boot.mount boot.automount \
         esp.mount efi.mount systemd-growfs@home.service systemd-growfs@var.service; do
  ln -sf /dev/null "/etc/systemd/system/$u" && masked=$((masked + 1))
done
log "已屏蔽 $masked 个设备型挂载单元（home/var/boot/esp/efi 等）"

# 5.9b) Valve 的 partset 机制 + adbd gadget —— 实机屏幕转录给出的确切依赖：
#   [TIME] Timed out waiting for device /dev/disk/by-partset/shared/home.
#   [DEPEND] Dependency failed for /home.
#   [DEPEND] Dependency failed for Steamos Offload - /var/tmp.
#   [DEPEND] Dependency failed for File System Check on /dev/disk/by-partset/shared/home.
#   [ *** ] A start job is running for Android Debug Bridge USB gadget enabler (6min 13s / no limit)
#   SteamOS 用 /dev/disk/by-partset/<组>/<名>（Valve 私有 udev 规则生成）指代分区，
#   sheng 的分区表里没有 shared/home、shared/offload → 设备永远不出现。
#   最后那条 adbd（Android USB gadget）在 sheng 上同样无人应答，会以 no limit 卡住启动。
log "引用 by-partset 的文件（诊断）："
grep -rl 'by-partset' /usr/lib/systemd /etc/systemd /usr/lib/udev 2>/dev/null | head -20 | sed 's/^/    /' || true
for u in 'systemd-fsck@dev-disk-by\x2dpartset-shared-home.service' \
         'systemd-fsck@dev-disk-by\x2dpartset-shared-offload.service' \
         'systemd-fsck@dev-disk-by\x2dpartset-shared-var.service' \
         'steamos-offload.target' 'dev-disk-by\x2dpartset-shared-home.device'; do
  ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（partset 派生）"
done
# adbd / USB gadget：Android Debug Bridge 的 gadget 链在 sheng 上无人应答。
#   ⚠️ 实机屏幕那条 no limit 的 job 叫 "Android Debug Bridge USB gadget enabler"，
#   **名字不以 adbd 开头**，所以只按 adbd* 匹配会漏掉它 → 这里按关键字（名字或内容）找。
log "与 adb/gadget/ffs 相关的单元（诊断）："
ls -1 /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
  | grep -Ei 'adb|gadget|ffs|android' | sort -u | sed 's/^/    /' || true
grep -rlEi 'gadget|ffs\.|functionfs' /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
  | sed 's/^/    内容提到 gadget/ffs: /' || true
for f in /usr/lib/systemd/system/*.service /usr/lib/systemd/system/*.socket /usr/lib/systemd/system/*.path \
         /etc/systemd/system/*.service /etc/systemd/system/*.socket /etc/systemd/system/*.path; do
  [[ -e "$f" || -L "$f" ]] || continue
  u="${f##*/}"
  real="$f"; [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
  if [[ "$u" =~ [Aa]db|[Gg]adget|[Ff]fs|[Aa]ndroid ]] || grep -qEi 'gadget|functionfs|ffs\.' "$real" 2>/dev/null; then
    ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（adb/gadget 链，sheng 无对应接口，会以 no limit 卡住启动）"
  fi
done
for d in /etc/systemd/system/*.wants /usr/lib/systemd/system/*.wants; do
  [[ -d "$d" ]] || continue
  while IFS= read -r l; do
    b="${l##*/}"
    case "$b" in
      home.*|var.*|var-A.*|esp.*|efi*|dev-disk-by*partlabel*) rm -f "$l" && log "已移除启动依赖: $l" ;;
    esac
  done < <(find "$d" -maxdepth 1 -type l 2>/dev/null || true)
done
GEN=/etc/systemd/system-generators/systemd-gpt-auto-generator
if [[ -e /usr/lib/systemd/system-generators/systemd-gpt-auto-generator && ! -e "$GEN" ]]; then
  mkdir -p "$(dirname "$GEN")"
  ln -sf /dev/null "$GEN" && log "已停用 systemd-gpt-auto-generator（按 GPT 类型自动挂挂载）"
fi
[[ "$masked" -eq 0 ]] && log "（没有发现需要屏蔽的挂载单元）"

# 5.97) Deckard(Steam Frame) 专有硬件服务 + repart + v4l2loopback
#   实机屏幕转录到的三条失败：
#     Failed to start repartition root disk
#     Failed to start … v4l2loopback module is not loaded
#     Failed to start fpga configuration service
#   这些都是 Valve 只在 Frame 上才有的硬件/机制，在 sheng(小米) 上必然失败。
#   ⚠️ 其中 repart **必须**屏蔽：systemd-repart 会按 Valve 的分区表去改磁盘，
#      在手机这种 Android 分区表上跑它风险很高（可能动别人的分区）。
for f in /usr/lib/systemd/system/deckard*.service /etc/systemd/system/deckard*.service \
         /usr/lib/systemd/system/deckard*.timer   /etc/systemd/system/deckard*.timer \
         /usr/lib/systemd/system/steamvr*.service /etc/systemd/system/steamvr*.service \
         /usr/lib/systemd/system/*boot-images*.service /etc/systemd/system/*boot-images*.service \
         /usr/lib/systemd/system/systemd-repart.service /etc/systemd/system/systemd-repart.service \
         /usr/lib/systemd/system/systemd-repart*.service  /etc/systemd/system/systemd-repart*.service \
         /usr/lib/systemd/system/steamos-repartition*.service /etc/systemd/system/steamos-repartition*.service; do
  [[ -e "$f" || -L "$f" ]] || continue
  u="${f##*/}"
  ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（Frame 专有硬件/分区/VR 机制）"
done
# v4l2loopback（虚拟摄像头）：sheng 内核没有这个模块
for f in /usr/lib/systemd/system/*.service /etc/systemd/system/*.service \
         /usr/lib/systemd/system/*.socket  /etc/systemd/system/*.socket; do
  [[ -e "$f" || -L "$f" ]] || continue
  u="${f##*/}"
  real="$f"; [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
  if grep -qEi 'v4l2loopback' "$real" 2>/dev/null; then
    ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（v4l2loopback，sheng 内核无此模块）"
  fi
done
# repart.d 配置也挪走：万一有别的路径触发 systemd-repart，配置没了它就无从下手
if [[ -d /usr/lib/repart.d ]]; then
  mkdir -p /root/graft/repart.d.bak
  mv -f /usr/lib/repart.d/* /root/graft/repart.d.bak/ 2>/dev/null || true
  log "已移走 /usr/lib/repart.d 配置（防 systemd-repart 按 Valve 分区表改盘）"
fi

# 5.98) D-Bus 的 messagebus 用户/组 —— 实机取证：
#   dbus-broker.service: ExecStart=/usr/bin/dbus-broker-launch --scope system --audit
#                        → exit=1/FAILURE，Duration: 5ms（瞬间退出）
#   dbus.socket:         failed (Result: service-start-limit-hit)
#   → 没有系统总线 → SDDM 及一切图形会话都起不来 → 屏幕黑掉
#   （显示栈本身是好的：/dev/dri 有 card0/renderD128，面板 connected）
#   dbus-broker-launch 缺 messagebus 用户/组时会立刻退出，这里按需补上。
if ! getent group messagebus >/dev/null 2>&1; then
  groupadd -r messagebus 2>/dev/null && log "已创建 messagebus 组（dbus-broker 需要）" \
    || warn "创建 messagebus 组失败"
fi
if ! getent passwd messagebus >/dev/null 2>&1; then
  useradd -r -g messagebus -d / -s /usr/bin/nologin -c "System Message Bus" messagebus 2>/dev/null \
    && log "已创建 messagebus 用户（dbus-broker 需要）" || warn "创建 messagebus 用户失败"
fi
log "messagebus: $(getent passwd messagebus || echo '仍不存在 ✗')"

# 6) 服务：网络与桌面会话
#    先看清底包带的是哪些会话，缺 sddm 就尝试补装（SteamOS 桌面模式 = SDDM + Plasma Wayland；
#    Frame 自带的 gamescope-session / steamos-session-select 也在，补不上就用它原生的）
log "底包已有的 wayland 会话："
ls -1 /usr/share/wayland-sessions 2>/dev/null | sed 's/^/    /' || warn "  （没有 wayland-sessions 目录）"
# 进桌面这一步的关键信息：有没有可登录用户、显示管理器指向谁、会话选择器怎么配
log "用户列表（/etc/passwd 的登录用户）："
awk -F: '$3>=1000 && $3<65534 {print "    "$1" uid="$3" home="$6" shell="$7}' /etc/passwd 2>/dev/null || true
log "/home 内容（补家目录之前）："; ls -A /home 2>/dev/null | sed 's/^/    /' || true
# 5.95) 登录用户的家目录：底包把 /home 放在 Valve 的 shared/home 分区上（我们屏蔽了该挂载单元，
#       /home 落在根分区），而底包 /home 子卷是空的 → 家目录不存在 → SDDM/PAM 登录会失败。
#       底包里有 steamos-create-homedir.service 负责首启创建，我们这里先建好，双保险。
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1":"$3":"$4":"$6}' /etc/passwd 2>/dev/null); do
  un="${u%%:*}"; rest="${u#*:}"; uid_="${rest%%:*}"; rest="${rest#*:}"; gid_="${rest%%:*}"; home_="${rest#*:}"
  [[ -n "$home_" && "$home_" != "/" ]] || continue
  if [[ ! -d "$home_" ]]; then
    mkdir -p "$home_" && chown "$uid_:$gid_" "$home_" && chmod 0755 "$home_" \
      && log "已创建家目录 $home_（属主 $un）"
  else
    log "家目录已存在: $home_"
  fi
done
log "display-manager.service → $(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo '（未设置）')"
if ! command -v sddm >/dev/null 2>&1; then
  warn "底包里没有 sddm，尝试从仓库补装（失败不致命，会回退到 Frame 原生会话）"
  pacman -S --noconfirm --needed sddm 2>&1 | tail -3 | sed 's/^/    /' \
    || warn "补装 sddm 失败（保持 Frame 原生会话）"
fi
command -v sddm >/dev/null 2>&1 && { systemctl enable sddm.service || warn "启用 sddm 失败"; }
systemctl set-default graphical.target 2>/dev/null || warn "设置 graphical.target 失败"
# NetworkManager.service 的启用放在第 7 节（网络统一交给它，与 WiFi keyfile 一起处理）
# 说明：这里曾有「tty2 免密 root 控制台」的调试安全网（以及 DEBUG_CONSOLE=1 屏蔽图形会话
# 停到文本控制台、把诊断报告打到屏幕上的整套排查手段）。桌面链路已经稳定，全部移除 ——
# 镜像里不再有任何免密 root 入口；需要进系统走 sshd（root 密码 / 公钥）。

# 7) 无人值守配置：WiFi 凭据 / root 密码 / sshd / D-Bus 去 --audit
#    目的：**设备侧零输入** —— 刷完开机自动连 WiFi、能 SSH 进去，后续调试全在电脑上做。
#
#    ⚠️ 无线只交给 NetworkManager **一套**管。
#    曾经的做法是写 /etc/wpa_supplicant/wpa_supplicant-<if>.conf 并启用
#    wpa_supplicant@<if> + dhcpcd@<if>，而底包的 NetworkManager 同时也在跑 ——
#    两套管理器抢同一个接口：NM 发现 supplicant 不是自己拉起来的、还有另一个 DHCP
#    客户端在抢地址，就把设备标成 unavailable 并拒绝扫描。实机表现就是
#    「用着用着突然断网、之后恢复不了，nmcli 里网卡在但显示不可用、扫不到网络」。
#    现在改成：凭据写成 NM 的 keyfile，由 NM 自己连。顺带一个好处 ——
#    不用再猜接口名（以前写死/探测 wlan0 那套，systemd 可预测命名下很容易猜错）。
WIFI_SSID="${WIFI_SSID:-}"; WIFI_PSK="${WIFI_PSK:-}"; ROOT_PW="${ROOT_PW:-}"
if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  install -d -m 755 /etc/NetworkManager/system-connections
  NM_FILE="/etc/NetworkManager/system-connections/sheng-wifi.nmconnection"
  NM_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "sheng-wifi-uuid")"
  cat > "$NM_FILE" <<EOF
[connection]
id=$WIFI_SSID
uuid=$NM_UUID
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  # NM 会拒收权限过宽的 profile（世界可读的 PSK 等于把密码写进镜像里给人看）
  chmod 600 "$NM_FILE"; chown 0:0 "$NM_FILE"
  log "已写入 NetworkManager 连接 $NM_FILE（SSID=$WIFI_SSID，autoconnect=true）"
else
  log "未提供 WiFi 凭据，跳过预配（开机后用 nmcli 连）"
fi

# 无论有没有 WiFi 凭据，都确保：只有 NetworkManager 一套管理器
systemctl enable NetworkManager.service 2>/dev/null && log "已启用 NetworkManager.service" \
  || warn "启用 NetworkManager 失败"
# 屏蔽「第二套管理器」的模板单元 —— 之前版本的镜像可能已经把 wpa_supplicant@<if> /
# dhcpcd@<if> enable 过，这里既停用也屏蔽，避免它们在 NM 之外再抢接口。
# 注意只动**模板/按接口**单元，不碰 wpa_supplicant.service / dhcpcd.service
# （那是 NM 自己要用的路径，屏蔽了会反过来把 NM 的无线打坏）。
for u in wpa_supplicant@.service dhcpcd@.service; do
  [[ -e "/usr/lib/systemd/system/$u" ]] || continue
  systemctl disable "$u" >/dev/null 2>&1 || true
  ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（网络统一交给 NetworkManager）"
done
# systemd-networkd 如果被 enable 过也关掉（同样是为了只留一套）；不屏蔽，只停用
if systemctl is-enabled systemd-networkd.service >/dev/null 2>&1; then
  systemctl disable systemd-networkd.service >/dev/null 2>&1 \
    && log "已停用 systemd-networkd（网络统一交给 NetworkManager）" || true
fi
# DNS：底包用 systemd-resolved 时 /etc/resolv.conf 是软链，交给 NM/resolved 管；
# 只有它是普通文件时才写静态 DNS（否则会把构建机/Azure 的 DNS 带进镜像）
if [[ -L /etc/resolv.conf ]]; then
  log "/etc/resolv.conf 是软链（systemd-resolved），DNS 交给 NetworkManager"
else
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  log "已写入静态 DNS（1.1.1.1 / 8.8.8.8）"
fi
if [[ -n "$ROOT_PW" ]]; then
  echo "root:$ROOT_PW" | chpasswd 2>/dev/null && log "已设置 root 密码（SSH 用）" || warn "设置 root 密码失败"
fi
if command -v sshd >/dev/null 2>&1; then
  mkdir -p /run/sshd
  # 缺主机密钥时 sshd 会"接受连接后立刻关闭且不发 banner"（实机就是这个现象）→ 补齐
  ssh-keygen -A 2>/dev/null || true
  # ⚠️ sshd_config 是**先出现的指令生效**，所以不能只在末尾追加 yes：
  #    底包若有 `PermitRootLogin no` / `PasswordAuthentication no`，追加的那行会被忽略。
  #    做法：先把冲突项注释掉，再追加我们自己的（并写 drop-in 兜底）。
  sed -i -E 's/^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication)/# \1/I' \
    /etc/ssh/sshd_config 2>/dev/null || true
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' >> /etc/ssh/sshd_config
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-sheng.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
  if sshd -t 2>/dev/null; then log "sshd 配置语法检查通过 ✓"; else warn "sshd -t 报错，配置可能有问题"; fi
  systemctl enable sshd.service 2>/dev/null && log "已启用 sshd（root 可登录）" || warn "启用 sshd 失败"
  # 把最终生效值打进日志，避免"以为设了其实没生效"
  log "root 账户状态: $(passwd -S root 2>&1)"
  log "生效的 SSH 关键项: $(sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication)' | tr '\n' ' ')"
else
  warn "底包没有 sshd，SSH 不可用"
fi
# D-Bus：实机 dbus-broker-launch 5ms 退出。怀疑内核裁掉 CONFIG_AUDIT 时带 --audit 会失败，
# 加 drop-in 去掉该参数（audit 集成是可选的，去掉不影响正常使用）。
if [[ -e /usr/bin/dbus-broker-launch ]]; then
  mkdir -p /etc/systemd/system/dbus-broker.service.d
  cat > /etc/systemd/system/dbus-broker.service.d/no-audit.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dbus-broker-launch --scope system
EOF
  log "已给 dbus-broker 加 drop-in：去掉 --audit"
fi

# 8) 关键系统修复（每一条都是设备上实测出来的）
#  ① D-Bus：dbus-broker 在这套底包上起不来（实测报 "No medium found" /
#     "Transport endpoint is not connected" / "No listener socket inherited"），
#     而传统 dbus-daemon 可用 → 换成 dbus-daemon。
#     ⚠️ 更重要的连锁：logind 如果没在总线上注册，pam_systemd 就建不了会话 →
#     gamescope 会话脚本里所有 `systemctl --user` 全失败 → 会话秒退 → SDDM 死循环 → 黑屏。
#     换 dbus-daemon 后，开机时 logind 会在总线之后启动并正常注册。
if [[ -e /usr/bin/dbus-daemon ]]; then
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/dbus.service <<'EOF'
[Unit]
Description=System Message Bus (sheng: dbus-daemon)
Documentation=man:dbus-daemon(1)
DefaultDependencies=no
After=local-fs.target
# 必须早于 logind：logind 只有「在总线之后启动」才能占到 org.freedesktop.login1；
# 占不到名字 → pam_systemd 建会话失败 → SSH 登录被拒 + gamescope 会话里 systemctl --user 全挂（实机实测）
Before=basic.target systemd-logind.service
Sockets=dbus.socket
[Service]
Type=notify
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile
ExecReload=/bin/kill -HUP $MAINPID
[Install]
WantedBy=sysinit.target
EOF
  systemctl mask dbus-broker.service 2>/dev/null || true
  # socket 与 service 都启用，这样才没有竞态：
  #   · socket active     → 满足别人的 After=dbus.socket / Requires=dbus.socket
  #   · service 由 sysinit.target 明确拉起 → 早于 logind，不等 PAM 按需激活（避免抢时序）
  #   背景：底包的服务激活文件是 dbus-broker 专属写法（Exec=/bin/false + SystemdService=…），
  #        换 dbus-daemon 后那条路直接是 false ✗，所以必须让 logind 自己占名字。
  systemctl enable dbus.socket 2>/dev/null && log "已启用 dbus.socket" || warn "启用 dbus.socket 失败"
  systemctl enable dbus.service 2>/dev/null && log "dbus.service 已挂到 sysinit.target（早于 logind）" \
    || warn "启用 dbus.service 失败"
fi
#  ② machine-id：空文件会让 journald 不落盘 —— 这就是我们在设备上一直「看不到任何日志」的原因
if [[ ! -s /etc/machine-id ]]; then
  systemd-machine-id-setup >/dev/null 2>&1 || true
  if [[ ! -s /etc/machine-id ]]; then
    tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > /etc/machine-id
  fi
  log "已生成 machine-id（否则 journald 不落盘，故障时看不到日志）"
fi
#  ③ hostname：不能用构建机的（chroot 里 hostname 返回 runner 名字，实测设备被叫成 runnervmoyp6c）
echo "xiaomi-sheng" > /etc/hostname
grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null || echo "127.0.1.1 xiaomi-sheng" >> /etc/hosts
log "hostname 已固定为 xiaomi-sheng"
#  ④ root 密码：直接用 sha512 哈希落盘，不依赖 chpasswd（实测 chpasswd 那条路在设备上没生效）
if [[ -n "$ROOT_PW" ]] && command -v openssl >/dev/null 2>&1; then
  H="$(openssl passwd -6 "$ROOT_PW" 2>/dev/null || true)"
  if [[ -n "$H" ]]; then
    sed -i "s|^root:[^:]*:|root:$H:|" /etc/shadow && log "root 密码已写入 /etc/shadow（sha512 哈希）"
  else
    warn "生成密码哈希失败"
  fi
fi
#  ⑤ SSH 公钥：公钥登录不经过 PAM 密码链，是设备上最稳的入口
if [[ -n "${SSH_PUBKEY:-}" ]]; then
  mkdir -p /root/.ssh
  printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys
  chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; chown -R 0:0 /root/.ssh
  log "SSH 公钥已写入 /root/.ssh/authorized_keys"
fi

#  ⑥ PAM：关掉 pam_systemd_home 依赖。实测它的 account 阶段
#     （"Failed to query user record: Launch helper exited..."）一失败，
#     **所有认证方式（公钥+密码）都会被拒**，SSH 直接进不去。
#     homed 我们不用，注释掉没有任何副作用。
if [[ -d /etc/pam.d ]]; then
  pamn=0
  for f in /etc/pam.d/*; do
    [[ -f "$f" ]] || continue
    if grep -q 'pam_systemd_home' "$f" 2>/dev/null; then
      sed -i 's/^\([^#].*pam_systemd_home.*\)/#\1/' "$f" && pamn=$((pamn + 1))
    fi
  done
  log "已注释 $pamn 个 pam 文件里的 pam_systemd_home 依赖"
fi
#  ⑦ 不设静态 IP：交给路由器 DHCP —— 静态 IP 会和局域网里已有设备撞（.240 实测撞过），
#     扫描时用「ICMP 存活 + 逐个试公钥」就能定位设备，不需要固定地址。

# 9) 图形会话（整条链最后也最关键的一环，全部实机验证过）
#    背景：Steam Frame 是 VR 头显，底包的**会话默认都经过 gamescope 的 openvr 后端** ✗ ——
#    实测 gamescope 选对了连接器 DSI-1 与 3048x2032@144，但往平板 LCD 合成的是 VR 黑帧 ✗。
#    改成 SDDM **直连 Plasma**（与本机跑通的 Ubuntu 镜像同一条路 ✓）后桌面正常 ✓✓。
if [[ -x /usr/bin/startplasma-wayland ]]; then
  install -d /usr/share/wayland-sessions
  cat > /usr/share/wayland-sessions/plasma-sheng.desktop <<'EOF'
[Desktop Entry]
Name=Plasma (Wayland, sheng)
Comment=Start Plasma Wayland directly (no gamescope; the Frame gamescope session targets a VR headset)
Exec=/usr/lib/steamos/sheng-startplasma
TryExec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF
  install -d /etc/sddm.conf.d
  cat > /etc/sddm.conf.d/zz-sheng.conf <<'EOF'
[Autologin]
Session=plasma-sheng.desktop
User=steamos
EOF
  log "已创建 Plasma 直连会话，并让 SDDM 自动登录它（实测这是出桌面的关键）"
else
  warn "没有 startplasma-wayland，保持底包默认会话（很可能是 gamescope/VR，平板上会黑）"
fi
# steamos-manager（系统侧）必须先于会话就位：用户侧 daemon 要 ping 它，
# 否则用户会话启动超时 → 图形会话根本起不来（实测 "start operation timed out"）
systemctl enable steamos-manager.service 2>/dev/null \
  && log "已启用 steamos-manager.service（系统侧）" || warn "启用 steamos-manager.service 失败"
install -d /etc/systemd/system/sddm.service.d
cat > /etc/systemd/system/sddm.service.d/after-steamos-manager.conf <<'EOF'
[Unit]
Wants=steamos-manager.service
After=steamos-manager.service
EOF
# gamescope 那条路（游戏模式）也改成往平板屏输出，而不是 VR
if [[ -f /usr/lib/steamos/gamescope-session ]]; then
  sed -i 's/--backend openvr/--backend drm/' /usr/lib/steamos/gamescope-session \
    && log "gamescope 后端已从 openvr 改为 drm（平板屏）"
fi
# 噪声：无头显时 SteamVR 的日志采集会无限重启刷屏
install -d /etc/systemd/user
ln -sf /dev/null /etc/systemd/user/steamvr-logs.service 2>/dev/null || true

# 10) 设备包收尾：内核模块 + 启用服务 + 自检
#     由来：Arch 的惯例是「打包不 enable 服务，由 workflow 在 chroot 里 enable」
#     （见 archlinux-sheng 的 scripts/in-chroot/30-device-packages.sh 第 5 节），
#     而 steamos-sheng 之前一条都没 enable —— 包装上了，服务却从没启动过。
#
#     下面每一行都按各包 payload 里真实的单元定义逐个核对过，**不是照抄**：
#
#     ① uinput：内核 config 是 CONFIG_INPUT_UINPUT=m，而 uinput 是 misc 设备、
#        没有总线 modalias 可以自动加载 → 不写 modules-load.d 就根本没有 /dev/uinput，
#        触屏 daemon 建不出 input 设备（实机确认：modprobe 后 /dev/uinput 才出现）。
install -d /etc/modules-load.d
echo uinput > /etc/modules-load.d/uinput.conf
log "已写入 /etc/modules-load.d/uinput.conf（触屏 daemon 需要 /dev/uinput）"

#     ② 需要显式 enable 的（有 [Install] 且没有别的东西会拉起它）
enable_unit() {
  local u="$1" why="$2"
  if [[ -f "/usr/lib/systemd/system/$u" ]]; then
    systemctl enable "$u" >/dev/null 2>&1 && log "已启用 $u（$why）" || warn "启用 $u 失败（$why）"
  else
    warn "缺 $u（$why）—— 对应的设备包没装上？"
  fi
}
#  触屏：NT36532E 内核驱动只暴露 /proc/nvt_thp_* 原始帧流、不注册 input 设备，
#  多点触控与 Focus Pen 全靠这个用户态 daemon 经 uinput 造设备
enable_unit xiaomi-sheng-thp.service        "触屏（NT36532E THP 用户态 daemon）"
enable_unit sheng-devauth.service           "sheng 设备认证"
enable_unit adsprpcd-sensorspd.service      "sensorspd aDSP RPC（iio-sensor-proxy 的后端）"
#     xiaomi-charger-mode.service 故意不 enable：它带
#     ConditionKernelCommandLine=androidboot.mode=charger，我们的 cmdline 没有该参数，
#     它本来就该跳过（只在关机充电模式下用），enable 了也不会跑。
#     xiaomi-mipps-auth.service 也不 enable：它没有 [Install]，
#     靠 90-xiaomi-mipps-auth.rules 的 SYSTEMD_WANTS 在 USB-C partner 出现时拉起。

#     ③ 靠 udev 的 SYSTEMD_WANTS 拉起、**不该** enable 的（写在这里是为了下次别乱加）：
#       iio-sensor-proxy.service           ← 80-iio-sensor-proxy.rules（传感器出现时）
#       xiaomi-mipps-auth.service          ← 90-xiaomi-mipps-auth.rules
#       qteesupplicant.service             ← 99-qcomtee-fpc.rules（/dev/tee0 出现时）
#       sfsconfig.service                  ← qteesupplicant.service 的 Requires=
#       xiaomi-sheng-keyboard-helper-angle.service ← 90-xiaomi-sheng-keyboard-helper.rules
#       xiaomi-sheng-keyboard-helper-micmute.service（user 单元，SYSTEMD_USER_WANTS）
#       xiaomi-pen-status                  ← etc/xdg/autostart 桌面自启动
#     iio-sensor-proxy.service 自己是 Type=dbus 且没有 [Install]：上游那套
#     dbus-broker 风格的激活文件（Exec=/bin/false + SystemdService=）在经典
#     dbus-daemon 上不生效，所以只能靠 udev 规则拉 —— 这是正路，别去手写激活文件。
#     adsprpcd-sensorspd 的 [Install] 是 WantedBy=iio-sensor-proxy.service：
#     enable 后软链落在 iio-sensor-proxy.service.wants/ 里，iio 被 udev 拉起时一起带上。

#     ④ 安装结果自检：关键二进制/单元少一个就告警（这些正是「刷完发现功能没有」的根源）
missing=0
for f in /usr/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp \
         /usr/lib/systemd/system/xiaomi-sheng-thp.service \
         /usr/bin/adsprpcd /usr/bin/xiaomi_devauth /usr/libexec/iio-sensor-proxy \
         /usr/bin/xiaomi-pen-status /usr/libexec/xiaomi-sheng-keyboard-helper \
         /usr/libexec/qteesupplicant /usr/bin/fastfetch; do
  if [[ -e "$f" ]]; then
    log "  ✓ $f"
  else
    warn "  ✗ 缺 $f"
    missing=$((missing + 1))
  fi
done
[[ "$missing" -eq 0 ]] || warn "有 $missing 个关键文件缺失 —— 设备包里少装了东西，回看上面的 pacman 输出"

#     ⑤ 依赖体检：Frame 底包缺哪些运行期依赖，在这里一次说清楚（不致命，只报告）
log "依赖体检（pacman -Dk，下面每行都是「某个包缺某个依赖」）："
pacman -Dk 2>&1 | grep -v '^checking' | sed 's/^/    /' || true

# 11) SteamOS-on-SM8550 通用修复（移植自 MaSieS4Fun/SteamOS-ARM-SM8550）
#     那个项目跟我们是**同一份底包**（Valve Steam Frame / Deckard userspace），目标设备是
#     AYN Odin 2 / Thor 那批 SM8550 掌机。下面的每一条都是他们在实机上验证过的，
#     注释保留「为什么」。没有移植的：① 他们用 ROCKNIX ABL 启动（p1 vfat BOOT + KERNEL），
#     我们是 boot.img 刷 boot_b；② 音频那套是他们 aw88166 功放专用，sheng 是 cs35l43 + 自己的
#     UCM，不通用。

# 11.1 VARIANT_ID=vr → steamdeck
#   原话：Frame steamclient reads VARIANT_ID=vr and Gamepad UI then throws.
#   三个副本都要改：/etc、/usr/lib（镜像内那份）、以及 /var/lib/overlays/etc/upper（ostree 风格覆盖层）。
_vfix=0
for _osr in /etc/os-release /usr/lib/os-release /var/lib/overlays/etc/upper/os-release; do
  [[ -f "$_osr" ]] || continue
  grep -q '^VARIANT_ID=' "$_osr" || continue
  sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr" && _vfix=$((_vfix + 1))
done
log "VARIANT_ID 已改成 steamdeck（$_vfix 个 os-release 副本）"

# 11.2 无线后端钉死在 wpa_supplicant（这是他们最关键的一条，也是我们「用着用着突然断网」的正解）
#   原话：Steam/steamos-manager rewrites 99-valve-wifi-backend.conf to iwd；而且
#   Do not nmcli connect/reconnect here: that flaps wlan0 and Steam stays on the library spinner.
#   wifi.powersave=2 是关省电 —— 省电会导致「用着用着掉线」。
install -d /etc/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d /usr/lib/steamos
cat > /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf <<'EOF'
[connection]
wifi.powersave=2
[device]
wifi.backend=wpa_supplicant
EOF
cp -f /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf \
      /usr/lib/NetworkManager/conf.d/40-sheng-wifi.conf
cat > /usr/lib/steamos/sheng-wifi-backend <<'EOF'
#!/bin/bash
# 把 NetworkManager 的无线后端钉回 wpa_supplicant。Steam / steamos-manager 会把这个
# fragment 改写成 iwd（其内核/我们这套上用不了/会抖），所以需要一直被改回来。
# ⚠️ 这里**不要** nmcli connect/reconnect：会让 wlan0 反复抖动，Steam 卡在载入圈。
set -u
BODY='[connection]
wifi.powersave=2
[device]
wifi.backend=wpa_supplicant
'
write_one() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s <(printf '%s' "$BODY") "$dest"; then
    chown root:root "$dest" 2>/dev/null || true
    chmod 0644 "$dest" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$BODY" >"$dest"
  chown root:root "$dest" 2>/dev/null || true
  chmod 0644 "$dest"
}
write_one /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf
[[ -d /var/lib/overlays/etc/upper ]] && \
  write_one /var/lib/overlays/etc/upper/NetworkManager/conf.d/99-valve-wifi-backend.conf
[[ -d /usr/lib/NetworkManager/conf.d ]] && \
  write_one /usr/lib/NetworkManager/conf.d/40-sheng-wifi.conf
ln -sfn /dev/null /etc/systemd/system/iwd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/iwd.service 2>/dev/null || true
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/NetworkManager.service.wants
if [[ -f /usr/lib/systemd/system/wpa_supplicant.service ]]; then
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    /etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    /etc/systemd/system/NetworkManager.service.wants/wpa_supplicant.service
fi
rfkill unblock wifi bluetooth 2>/dev/null || true
exit 0
EOF
chmod 0755 /usr/lib/steamos/sheng-wifi-backend
cat > /usr/lib/systemd/system/sheng-wifi-backend.service <<'EOF'
[Unit]
Description=sheng: 把 NetworkManager 无线后端钉回 wpa_supplicant
DefaultDependencies=no
After=local-fs.target
Before=NetworkManager.service iwd.service
Wants=local-fs.target
[Service]
Type=oneshot
# RemainAfterExit=yes 会让 PathChanged 之后不再重跑（Steam 又会写回 iwd）
RemainAfterExit=no
ExecStart=/usr/lib/steamos/sheng-wifi-backend
[Install]
WantedBy=NetworkManager.service
WantedBy=multi-user.target
EOF
cat > /usr/lib/systemd/system/sheng-wifi-backend.path <<'EOF'
[Unit]
Description=sheng: Steam 想把无线后端改成 iwd 时改回来
After=local-fs.target
[Path]
PathChanged=/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf
PathModified=/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf
PathChanged=/var/lib/overlays/etc/upper/NetworkManager/conf.d/99-valve-wifi-backend.conf
PathModified=/var/lib/overlays/etc/upper/NetworkManager/conf.d/99-valve-wifi-backend.conf
Unit=sheng-wifi-backend.service
[Install]
WantedBy=multi-user.target
EOF
install -d /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/99-sheng-wpa.conf <<'EOF'
[Unit]
After=wpa_supplicant.service
Wants=wpa_supplicant.service
[Service]
ExecStartPre=-/usr/lib/steamos/sheng-wifi-backend
ExecStartPost=-/usr/lib/steamos/sheng-wifi-backend
EOF
systemctl enable sheng-wifi-backend.service sheng-wifi-backend.path 2>/dev/null \
  && log "已启用 sheng-wifi-backend（service + path 哨兵）" || warn "启用 sheng-wifi-backend 失败"

# 11.3 无线接口名固定成 wlan0
#   原话：Frame/Steam look for wlan0. Kernel names the WCN7850 wlp1s0.
#   .link 由 udev 处理（不依赖 systemd-networkd），跟我们「只留 NM 一套管理器」不冲突。
install -d /usr/lib/systemd/network
cat > /usr/lib/systemd/network/99-sheng-wlan0.link <<'EOF'
[Match]
Type=wlan
[Link]
Name=wlan0
EOF
log "已固定无线接口名为 wlan0（.link）"

# 11.4 SteamVR / iwd / set-wifi-mac-address 一律屏蔽
#   Frame 残留：SteamVR 一起 gamescope 就死；set-wifi-mac-address 会在运行期改 MAC（掉线来源之一）。
install -d /etc/systemd/user /etc/systemd/system
for u in steamvr.service steamvr-logs.service steamvr-proxmicmute.service \
         steamvr-v4l2cam.service steamvr-nested-desktop.service; do
  ln -sfn /dev/null "/etc/systemd/user/$u"
done
for u in steamvr-program-ble.service steamvr-v4l2loopback.service \
         steamvr-set-kernel-thread-priorities.service \
         set-wifi-mac-address.service iwd.service; do
  ln -sfn /dev/null "/etc/systemd/system/$u"
done
log "已屏蔽 SteamVR 全家桶 / iwd / set-wifi-mac-address"

# 11.5 Plasma 的 Wayland 环境清理
#   原话：start-gamescope-session used to import QT_QPA_PLATFORM=xcb into that manager;
#   plasmashell/ksplash then try X11, fail, and leave kwin on a black DSI.
cat > /usr/lib/steamos/sheng-prepare-plasma <<'EOF'
#!/bin/bash
# 从 Game Mode 切桌面时，gamescope 那边残留的环境变量会把 Plasma 带沟里：清掉再显式设 wayland。
set -u
[[ -d /tmp/.X11-unix ]] || mkdir -p /tmp/.X11-unix
# gamescope 建这个目录时没有 sticky 位，kwin 会因此拒绝 Xwayland
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
unset QT_QPA_PLATFORM GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_SESSION_TARGET
export QT_QPA_PLATFORM=wayland
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export DESKTOP_SESSION=plasma
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user unset-environment \
    QT_QPA_PLATFORM GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_SESSION_TARGET \
    XDG_DESKTOP_PORTAL_DIR || true
  systemctl --user set-environment \
    QT_QPA_PLATFORM=wayland XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE DESKTOP_SESSION=plasma || true
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd \
    QT_QPA_PLATFORM XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP DESKTOP_SESSION >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 /usr/lib/steamos/sheng-prepare-plasma
cat > /usr/lib/steamos/sheng-startplasma <<'EOF'
#!/bin/bash
# 官方 startplasma-wayland，但先清掉 Game Mode 留下的 Qt/X11 环境
/usr/lib/steamos/sheng-prepare-plasma
exec /usr/bin/startplasma-wayland "$@"
EOF
chmod 0755 /usr/lib/steamos/sheng-startplasma
cat > /usr/lib/systemd/user/sheng-plasma-env.service <<'EOF'
[Unit]
Description=sheng: Plasma Wayland 环境清理
DefaultDependencies=no
Before=plasma-core.target plasma-workspace.target plasma-workspace-wayland.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos/sheng-prepare-plasma
EOF
cat > /usr/lib/steamos/sheng-plasma-wayland.conf <<'EOF'
[Service]
Environment=QT_QPA_PLATFORM=wayland
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=KDE
Environment=XDG_SESSION_DESKTOP=KDE
UnsetEnvironment=GAMESCOPE_WAYLAND_DISPLAY
EOF
plasma_n=0
for svc in plasma-plasmashell plasma-ksplash plasma-ksmserver plasma-kcminit plasma-kcminit-phase1 \
           plasma-kded6 plasma-kwin_wayland plasma-gmenudbusmenuproxy plasma-xembedsniproxy \
           plasma-kaccess plasma-powerdevil plasma-polkit-agent plasma-kglobalaccel plasma-kscreen \
           plasma-xdg-desktop-portal-kde plasma-krunner plasma-kactivitymanagerd plasma-dolphin \
           plasma-ksystemstats plasma-restoresession plasma-baloorunner; do
  install -d "/usr/lib/systemd/user/${svc}.service.d"
  cp -f /usr/lib/steamos/sheng-plasma-wayland.conf \
        "/usr/lib/systemd/user/${svc}.service.d/99-sheng-wayland.conf"
  plasma_n=$((plasma_n + 1))
done
log "已给 $plasma_n 个 plasma-* user 单元装上 Wayland 环境 drop-in"

# 11.6 gamescope 会话（游戏模式）：摘掉 SteamVR 耦合
#   原话：Drop SteamVR coupling from the Frame image; otherwise gamescope dies with steamvr.
#   以及 GAMESCOPE_FORCE_INTERNAL=1 强制走内屏（Frame 那套默认往 VR 头显走）。
install -d /usr/lib/systemd/user/gamescope-session.service.d \
           /usr/lib/systemd/user/gamescope-session.target.d
_icd=""
for _c in /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
          /usr/share/vulkan/icd.d/freedreno_icd.json; do
  [[ -f "$_c" ]] && { _icd="$_c"; break; }
done
{
  echo '[Unit]'
  echo 'Description=Gamescope sheng session'
  echo '# 摘掉 Frame 的 SteamVR 耦合：不摘 gamescope 会跟着 steamvr 一起死'
  echo 'PartOf='
  echo 'PartOf=graphical-session.target'
  echo ''
  echo '[Service]'
  echo 'TimeoutStartSec=45'
  echo 'Environment=GAMESCOPE_FORCE_INTERNAL=1'
  if [[ -n "$_icd" ]]; then
    echo "Environment=VK_ICD_FILENAMES=$_icd"
    echo "Environment=VK_DRIVER_FILES=$_icd"
  fi
} > /usr/lib/systemd/user/gamescope-session.service.d/99-sheng.conf
cat > /usr/lib/systemd/user/gamescope-session.target.d/99-sheng.conf <<'EOF'
[Unit]
Description=Gamescope sheng session
# 重置 Frame 的 SteamVR wants，只留 Steam 与它的辅助服务
Wants=
Wants=steam.service
Wants=steam-notif-daemon.service
Wants=ibus-gamescope.service
EOF
log "gamescope 会话已解耦 SteamVR（Vulkan ICD: ${_icd:-未探测到，跳过}）"

# 11.7 jupiter-dock-updater 桩
#   原话：Odin 2 has no dock. Missing /usr/bin/jupiter-dock-updater is exit 127 and Steam shows
#   "Error de actualización". --check must exit 7 (up to date). sheng 是平板，同样没有 dock。
if [[ ! -e /usr/bin/jupiter-dock-updater ]]; then
  cat > /usr/bin/jupiter-dock-updater <<'EOF'
#!/usr/bin/env bash
# sheng 没有 Valve Dock，但 Steam 在「软件更新」里会探测这个程序。
#   --check 退出 0  → 有更新（Steam 会卡在 apply）
#   --check 退出 7  → 已是最新（我们永远回这个）
#   程序缺失       → 127 → Steam 报「更新错误」
set -uo pipefail
FW_VER="0.13.15.124"
for arg in "$@"; do
  case "$arg" in
    --check) echo "FW Current: ${FW_VER}"; echo "FW Available: ${FW_VER}"; echo "FW up to date"; exit 7 ;;
  esac
done
exit 0
EOF
  chmod 0755 /usr/bin/jupiter-dock-updater
  install -d /usr/bin/steamos-polkit-helpers
  ln -sfn /usr/bin/jupiter-dock-updater /usr/bin/steamos-polkit-helpers/jupiter-dock-updater
  log "已放入 jupiter-dock-updater 桩（Steam 软件更新不再报错）"
fi

# 11.8 独立 home 分区：首启格式化 → 扩分区 → 扩文件系统 → 重建家目录
#   移植自他们的 steamos-sm8550-expand-home，改成 PARTLABEL=home，并多做一步：
#   分区存在但还没格式化时自动 mkfs（这样用户只要分好区、不用手动 mkfs）。
#   没有 home 分区就静默退出且**不打标记**，以后补上分区依然生效。
cat > /usr/lib/steamos/sheng-expand-home <<'EOF'
#!/bin/bash
# 让独立的 /home 分区可用并铺满：mkfs（若空白）→ growpart → resize2fs → 重建用户家目录。
set -u
STAMP=/var/lib/sheng/home-ready
LOG=/var/log/sheng-expand-home.log
mkdir -p "$(dirname "$STAMP")" /var/log
exec >>"$LOG" 2>&1
ts() { date -Iseconds; }
log() { printf '%s %s\n' "$(ts)" "$*"; }
log "=== expand-home start ==="
[[ -f "$STAMP" ]] && { log "已有标记 $STAMP，跳过"; exit 0; }

HOME_SRC=""
for c in /dev/disk/by-partlabel/home /dev/disk/by-label/home; do
  [[ -b "$c" ]] && { HOME_SRC="$(readlink -f "$c")"; break; }
done
[[ -n "$HOME_SRC" ]] || { log "没有 home 分区（PARTLABEL=home / LABEL=home 都没有），下次再看"; exit 0; }
log "home 分区: $HOME_SRC"

FSTYPE="$(blkid -o value -s TYPE "$HOME_SRC" 2>/dev/null || true)"
if [[ -z "$FSTYPE" ]]; then
  log "分区还是空白 → mkfs.ext4 -L home"
  mkfs.ext4 -F -L home -m 1 "$HOME_SRC" || { log "mkfs 失败，下次重试"; exit 0; }
  FSTYPE=ext4
fi
case "$FSTYPE" in
  ext2|ext3|ext4) ;;
  *) log "home 文件系统是 $FSTYPE，不是 ext*，不动它"; exit 0 ;;
esac

mountpoint -q /home || { mount "$HOME_SRC" /home 2>/dev/null || mount /home 2>/dev/null || true; }
mountpoint -q /home && log "/home 已挂载" || log "警告：/home 未挂载，继续尝试扩容"

PART_BASE="$(basename "$HOME_SRC")"
PART_NUM="$(cat "/sys/class/block/${PART_BASE}/partition" 2>/dev/null || true)"
DISK_NAME="$(lsblk -no PKNAME "$HOME_SRC" 2>/dev/null | head -1 || true)"
if [[ -n "$DISK_NAME" && -n "$PART_NUM" ]]; then
  if command -v growpart >/dev/null 2>&1; then
    growpart "/dev/${DISK_NAME}" "$PART_NUM" 2>&1 || log "growpart 非 0（多半已经是最大）"
  else
    echo ", +" | sfdisk --no-reread -N "$PART_NUM" "/dev/${DISK_NAME}" 2>&1 || true
  fi
  udevadm settle 2>/dev/null || true
  partx -u "/dev/${DISK_NAME}" 2>/dev/null || true
  sleep 0.2
fi
resize2fs "$HOME_SRC" 2>&1 || log "resize2fs 非 0（Nothing to do 属正常）"

# 空 home 分区会把 root 里的 /home/<user> 盖掉 → 按 /etc/passwd 重建，否则 SDDM 自动登录会找不到家目录
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1":"$3":"$4":"$6}' /etc/passwd 2>/dev/null); do
  un="${u%%:*}"; rest="${u#*:}"; uid_="${rest%%:*}"; rest="${rest#*:}"
  gid_="${rest%%:*}"; home_="${rest#*:}"
  [[ -n "$home_" && "$home_" != "/" ]] || continue
  if [[ ! -d "$home_" ]]; then
    mkdir -p "$home_" && chown "$uid_:$gid_" "$home_" && chmod 0755 "$home_" \
      && log "已建家目录 $home_（$un）"
  fi
done
touch "$STAMP"
log "=== expand-home done ==="
exit 0
EOF
chmod 0755 /usr/lib/steamos/sheng-expand-home
cat > /usr/lib/systemd/system/sheng-expand-home.service <<'EOF'
[Unit]
Description=sheng: 独立 home 分区首启准备与扩容
DefaultDependencies=no
Conflicts=shutdown.target
After=systemd-remount-fs.service
After=home.mount
Before=display-manager.service graphical.target
ConditionPathExists=!/var/lib/sheng/home-ready
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos/sheng-expand-home
TimeoutStartSec=180
[Install]
WantedBy=local-fs.target
WantedBy=multi-user.target
EOF
systemctl enable sheng-expand-home.service 2>/dev/null \
  && log "已启用 sheng-expand-home（有 home 分区就自动格式化 + 扩容）" \
  || warn "启用 sheng-expand-home 失败"

log "sheng 设备层注入完成（内核 $KVER）"