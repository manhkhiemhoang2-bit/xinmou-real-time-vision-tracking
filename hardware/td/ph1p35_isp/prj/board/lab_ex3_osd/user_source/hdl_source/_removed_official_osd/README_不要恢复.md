# 已移除的官方 OSD 资源（2026-09-14）

这两个文件是安路官方 lab_ex3_osd 例程自带的 OSD 资源，原由 hdmi_mixer.v 实例化，
在 HDMI 输出最后一级把安路 Logo 和字符叠加到画面上。

本工程已把 hdmi_mixer.v 改写为纯直通（见同目录 hdmi_mixer.v 的文件头说明），
因此这两个模块不再被任何文件引用，已从 td_project\camera_to_dsi_display.al
的文件列表中移除，并从 hdl_source 移到这里存档。

不要恢复。恢复它们 = 恢复官方 Logo 叠加 = 原创性风险 + 重新引入 0.103ns 关键路径。
