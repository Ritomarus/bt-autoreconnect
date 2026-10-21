# bt-autoreconnect

macOS 上的蓝牙耳机自动重连守护程序：耳机走远掉线后回到范围内会自动连回 Mac，但**你在 Mac 上手动断开时不会再被连回去**。

A small macOS launchd agent that reconnects your Bluetooth headphone when it comes back in range, while respecting a manual disconnect made on the Mac.

## 它解决什么问题

常见的自动重连脚本只要发现耳机没连上，就每隔几秒去连一次。结果是你从菜单栏点了"断开连接"，几秒后耳机又被连了回来。

bt-autoreconnect 会区分两种断开：

| 断开方式 | 行为 |
|---|---|
| 走远 / 信号丢失 | 每隔约 6 秒尝试重连，回到范围内就连上 |
| 在 Mac 上手动断开（菜单栏、控制中心） | 暂停自动重连 |
| 暂停后耳机再次连上（手动连或耳机自己回连） | 自动恢复守护 |

## 原理

macOS 在本机主动断开一个音频设备时，`bluetoothd` 会在系统日志里记一行：

```
A2DPService is disconnecting device AA:BB:CC:DD:EE:FF
```

信号丢失、耳机没电这类断开不会产生这一行。守护程序用 `log stream` 监听这行日志，命中就创建一个暂停标记文件；主循环看到标记就不再重连，等耳机重新连上时删掉标记。

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

修改配置（`~/.config/bt-autoreconnect/config`）后，重新运行一次 `./install.sh` 即可重启生效。

## 卸载

```bash
./uninstall.sh
```

加上 `--purge` 会同时删除 `~/.config/bt-autoreconnect/`（配置和日志）。

## 已知限制

- **依赖未公开的系统日志。** 判断手动断开靠的是 `bluetoothd` 的内部日志文字，苹果没有承诺它不变。目前在 **macOS 26.5（Apple M4）+ Sony WH-1000XM6** 上测试通过，升级系统后如果手动断开又被连回去，多半是日志格式变了，欢迎提 issue。
- **被其他设备抢走时仍会抢回来。** 耳机通过多点连接切换到手机时，不算 Mac 本机主动断开，守护程序会尝试把它连回 Mac。
- **只支持一个设备。**
- **蓝牙权限。** 如果日志里出现 `Received abort signal ... access to Bluetooth API`，需要在"系统设置 → 隐私与安全性 → 蓝牙"里给运行 blueutil 的程序（终端或 `/bin/bash`）授权。

## License

[MIT](LICENSE)
