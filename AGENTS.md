# 项目开发约定

- Git 提交的 message 必须使用中文。
- 功能改动完成验证后，推送代码并更新本机 `/Applications/PicGlide.app`，让本机安装跟随最新代码。
- 本机仅保留 `/Applications/PicGlide.app` 这一份可启动的 PicGlide，后续更新始终替换同一路径。
- 构建、测试、打包、下载验证及回滚产生的其他应用副本，使用完成后必须清理，包括 `build`、下载解压、临时目录中的 `.app` 和 `.app-backup`；验证用磁盘映像完成后必须卸载。需要保留备份或安装包时，仅保留 ZIP／DMG，不保留展开的应用目录。
- 更新前正常退出旧 App，保留未保存内容的提示；采用可回滚替换，不强制结束进程或丢弃用户数据。
- 每次更新完成后，核对版本与实际启动路径，检查 Spotlight、LaunchServices 和文件的“打开方式”，确认 PicGlide 只有 `/Applications/PicGlide.app` 一个有效应用入口。清理 PicGlide 的重复注册和失效路径，保留其他应用及用户的默认打开偏好。
- 只有用户明确要求发布时，才创建或推送版本标签并发布 GitHub Release。日常功能优化不发布新版本。
