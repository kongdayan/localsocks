# macOS 客户端

运行 `./macos/build.sh` 构建 `dist/Localsocks.app`，具体准备步骤见根目录 README。

- Core.swift：节点与设置存储、配置渲染、健康探测、launchd 和系统代理操作。
- LocalsocksApp.swift：AppKit 菜单栏及管理窗口。
- LogoGenerator.swift：构建时生成图标。

默认使用用户域 launchd 服务。系统域为显式选项，需要管理员认证。
退出 App 后后台服务可以继续运行；完整停用请同时卸载 launchd 服务并关闭系统 SOCKS 代理。
仓库内置节点仅为示例，首次使用时需要配置自己的服务端。
