# bt-autoreconnect

macOS 上的蓝牙耳机自动重连守护程序：耳机走远掉线后回到范围内会自动连回 Mac，但**你在 Mac 上手动断开时不会再被连回去**，耳机自己切去别的设备时也不会被反复抢回来。

A small macOS launchd agent that reconnects your Bluetooth headphone when it comes back in range, while respecting a manual disconnect made on the Mac and not fighting the headphone when it switches to another device.

## 它解决什么问题

常见的自动重连脚本只要发现耳机没连上，就每隔几秒去连一次。结果是你从菜单栏点了"断开连接"，几秒后耳机又被连了回来；想把耳机切到手机上用，也会马上被 Mac 抢回去。

bt-autoreconnect 会区分断开的原因：

| 断开方式 | 行为 |
|---|---|
| 走远 / 信号丢失 | 持续尝试重连，回到范围内就连上 |
| 在 Mac 上手动断开（菜单栏、控制中心、系统设置） | 暂停自动重连 |
| 耳机自己断开（关机、切到别的设备） | 先试着连回 45 秒；没连回来就不再主动连，等耳机开机时自己连回 Mac。如果刚被连回来、几分钟内又自己离开，就放手（暂停） |
| 暂停后耳机再次连上（手动连或耳机自己回连） | 自动恢复守护 |

## 原理

守护程序用 `log stream` 监听 `bluetoothd` 的两种系统日志。

macOS 在本机主动断开一个音频设备时，会记一行：

```
A2DPService is disconnecting device AA:BB:CC:DD:EE:FF
```

信号丢失、耳机关机这类断开不会产生这一行。命中就创建一个暂停标记文件；主循环看到标记就不再重连，等耳机重新连上时删掉标记。这行日志比链路真正断开早，通常早 2–3 秒，实测最长早过 25 秒，所以标记创建后的头 30 秒（`SETTLE`）里"耳机还连着"不算"重新连上"，否则标记会被提前清掉、耳机断开后又被连回来。如果链路断得比这还晚，断开时的原因码 `10722`（见下表）会再次暂停。

链路断开时还会记一行带原因码的日志：

```
ACL disconnected: AA:BB:CC:DD:EE:FF, result 0, reason 10719
```

| 原因码 | 含义 |
|---|---|
| `328` / `10708` | 链路超时（走出范围） |
| `10719` | 耳机一方结束连接（关机，或切到别的设备） |
| `10722` | Mac 一方结束连接（手动断开） |

耳机关机和切到别的设备用的是同一个原因码，区分办法是看重连结果：耳机主动断开后 45 秒内（`STEAL_WINDOW`）就被连回来，说明它一直开着，是有意离开的。如果它在随后 3 分钟内（`YIELD_WINDOW`）再次主动断开，守护程序就不再去抢，直到它重新连上这台 Mac。

45 秒内没连回来，就当耳机已经关机，守护程序停止寻呼，等它开机时自己连回来（耳机开机会自动连最后用过的设备）。不能在它开机时去连：那一刻耳机自己也在连 Mac，两边会同时建立免提（HFP）通道，macOS 可能卡在一半，表现为"显示已连接，但没有声音"，系统根本不往耳机送音频，只有彻底断开再连才能恢复。

链路丢失（走远）后，每次失败的重连尝试会让蓝牙射频持续寻呼约 15 秒，可能影响其他蓝牙设备和 2.4 GHz Wi-Fi。所以重试间隔会随离开时间拉长：前 10 分钟每 6 秒一次，一小时内每 15 秒一次，之后每 30 秒一次。

## 安装

需要 [blueutil](https://github.com/toy/blueutil)：

```bash
brew install blueutil
```

克隆仓库后运行安装脚本，按提示从已配对设备里选出耳机的 MAC 地址：

```bash
./install.sh
```

也可以直接带上 MAC 地址和名字：

```bash
./install.sh aa-bb-cc-dd-ee-ff "WH-1000XM6"
```

安装脚本会：

- 把 `autoreconnect.sh` 和配置文件放到 `~/.config/bt-autoreconnect/`；
- 生成 `~/Library/LaunchAgents/local.bt-autoreconnect.plist`，开机自动运行，进程意外退出后自动重启。

想先看看会装什么，可以用 `DRY_RUN=1 ./install.sh` 预览，不会做任何改动。

## 使用

正常情况下不需要做任何事。另外支持手动控制：

```bash
touch ~/.config/bt-autoreconnect/paused   # 暂停自动重连
```

```bash
rm ~/.config/bt-autoreconnect/paused      # 立即恢复
```

查看运行日志：

```bash
tail -f ~/.config/bt-autoreconnect/autoreconnect.log
```

日志会写明每次断开的原因和守护程序的处理：

```
2026-01-01 10:29:04 WH-1000XM6 link lost (out of range)
2026-01-01 10:41:12 reconnected to WH-1000XM6
2026-01-01 12:27:51 manual disconnect of WH-1000XM6 detected, auto-reconnect paused
2026-01-01 12:28:31 WH-1000XM6 connected again, auto-reconnect resumed
2026-01-01 15:02:10 WH-1000XM6 ended the connection (powered off or switched to another device)
2026-01-01 15:02:58 WH-1000XM6 not back within 45s, waiting for it to reconnect by itself
2026-01-01 16:10:37 WH-1000XM6 connected (by the headphone or by hand)
```

修改配置（`~/.config/bt-autoreconnect/config`）后，重新运行一次 `./install.sh` 即可重启生效。可调的参数见 [config.example](config.example)。

## 测试

`tests/run.sh` 用假的 `blueutil` 和假的 `log stream` 把守护程序跑一遍各种场景（手动断开、走远、关机再开机、切到别的设备），不需要耳机，也不需要蓝牙权限，约两分钟：

```bash
tests/run.sh
```

## 卸载

```bash
./uninstall.sh
```

加上 `--purge` 会同时删除 `~/.config/bt-autoreconnect/`（配置和日志）。

## 已知限制

- **依赖未公开的系统日志。** 判断断开原因靠的是 `bluetoothd` 的内部日志文字和原因码，苹果没有承诺它们不变。目前在 **macOS 26.5（Apple M4）+ Sony WH-1000XM6** 上测试通过，升级系统后如果手动断开又被连回去，多半是日志格式变了，欢迎提 issue。
- **耳机切到别的设备时会被抢回一次。** 关机和切换设备的原因码相同，只有连回来之后才能分辨，所以第一次切走仍会被 Mac 连回去；再切一次才会放手。放手之后要等耳机重新连上这台 Mac（手动连，或耳机开机时自己回连）才恢复守护。
- **关机后靠耳机自己回连。** 耳机关机超过 45 秒，守护程序就不再主动连它；耳机开机时会自己连回最后用过的设备。如果它开机后先连上了别的设备，这台 Mac 不会去抢。
- **开机和寻呼撞上时仍可能卡住。** 关机后 45 秒内又开机，或者走远后在外面关机、回来再开机，耳机开机那一刻守护程序可能正好在连它，仍有可能出现"已连接但没声音"。这时把耳机关机，等一分钟（守护程序这时已停止寻呼）再开机，耳机会自己干净地连回来。
- **只支持一个设备。**
- **蓝牙权限。** 如果日志里出现 `Received abort signal ... access to Bluetooth API`，需要在"系统设置 → 隐私与安全性 → 蓝牙"里给运行 blueutil 的程序（终端或 `/bin/bash`）授权。

## License

[MIT](LICENSE)
