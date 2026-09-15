下载进度回归测试（不会安装更新或连接风扇 helper）。

在仓库根目录启动本地限速下载服务，记下输出的端口：

```sh
python3 script/update_download_verify/server.py
```

另开终端，编译并传入该端口：

```sh
xcrun swiftc -parse-as-library Fankit/Services/UpdateDownloadDelegate.swift script/update_download_verify/main.swift -o /tmp/FankitDownloadVerify
/tmp/FankitDownloadVerify PORT
```

验证有、无 Content-Length 时的中途进度和最终文件大小；测试完成后用 Ctrl-C 停止服务。
