# Swift 生产代码「用户可见提示文本」出口盘点（add-app-internationalization）

- 扫描范围：`apple/PandaSSH/` 下全部生产 Swift 源文件（排除 `apple/PandaSSHTests/`、`apple/PandaSSHMacOSTests/`、`apple/PandaSSHIOSTests/` 等测试目录）。
- 统计口径：同一字符串（含同文案不同出口）跨文件复用时**合并为一条**，并在「位置」列出全部出现点；同一文件内同文案也合并。`#Preview(...)` 标题与 Preview 专属演示数据仅 DEBUG 生效，不登记为出口（单独备注）。
- 类型取值：`静态`（字面量）、`条件`（同出口按状态二选一的字面量组）、`动态拼接`（含插值/拼接）、`格式化`（数值/时间格式化模板）。
- 建议资源键格式：`模块.场景.用途`；模块限 app/settings/host/group/snippet/workspace/terminal/sftp/transfer/monitor/log/auth/error，用途为小写蛇形。

## 全局复用文案（跨出口合并登记）

| 键 | 原文 | 类型 | 位置（文件:行） | 建议资源键 |
|---|---|---|---|---|
| U1 | `取消` | 静态 | Sheets.swift:61,146,194,222；SidebarView.swift:131,141；SnippetsView.swift:53；HostEditView.swift:115,130；SftpTabView.swift:181；WorkspaceView.swift:115,149,161 | app.action.cancel |
| U2 | `确定` | 静态 | SettingsView.swift:93,98,103；Sheets.swift:223 | app.action.confirm |
| U3 | `好` | 静态 | HostEditView.swift:125；ConnectionMonitorView.swift:199 | app.action.ok |
| U4 | `删除` | 静态 | SidebarView.swift:132,142；SnippetsView.swift:54；SftpTabView.swift:161 | app.action.delete |
| U5 | `保存` | 静态 | HostEditView.swift:118；SnippetsView.swift:214 | app.action.save |
| U6 | `重试` | 静态 | ConnectionGate.swift:269；TransferPanelView.swift:145,312；TerminalTabView.swift:161 | app.action.retry |
| U7 | `关闭标签` | 静态 | ConnectionGate.swift:271；TerminalTabView.swift:162,167 | workspace.action.close_tab |
| U8 | `添加主机` | 静态 | SidebarView.swift:118；UnifiedWorkspaceChrome.swift:78；WorkspaceView.swift:339,353 | host.action.add |
| U9 | `新建分组` | 静态 | SidebarView.swift:38(sheet 标题),125(工具栏)；UnifiedWorkspaceChrome.swift:83；TabContextMenuBuilder.swift:28 | group.action.create |
| U10 | `打开终端` | 静态 | HostDetailView.swift:47；SidebarView.swift:399 | host.action.open_terminal |
| U11 | `浏览文件 (SFTP)` | 静态 | HostDetailView.swift:53；SidebarView.swift:402 | host.action.open_sftp |
| U12 | `本地` | 静态 | SftpTabView.swift:206(Picker 项),264(栏头)；SftpSessionStore.swift:47,535(rootTitle)；TransferPanelView.swift:384,385(端点名) | sftp.pane.local |
| U13 | `远程` | 静态 | SftpTabView.swift:207；SftpSessionStore.swift:383,536(rootTitle) | sftp.pane.remote |
| U14 | `根级（无分组）` | 静态 | HostEditView.swift:63；SidebarView.swift:412 | group.label.root_none |
| U15 | `根级` | 静态 | Mock/Models.swift:129(GroupTree.path 兜底)；HostDetailView.swift:67 | group.label.root |
| U16 | `传输任务` | 静态 | PandaSSHApp.swift:79(窗口标题)；SidebarView.swift:476(侧栏入口)；TransferPanelView.swift:48(页头) | transfer.title |
| U17 | `连接监控` | 静态 | PandaSSHApp.swift:84(窗口标题)；SidebarView.swift:255,264(侧栏入口)；ConnectionMonitorView.swift:172(navigationTitle),193(alert 标题) | monitor.title |
| U18 | `日志` | 静态 | PandaSSHApp.swift:62(窗口标题)；SidebarView.swift:291,297(侧栏入口)；SidebarView.swift:320(window.title 匹配字面量，i18n 风险点)；LogView.swift:20(navigationTitle) | log.title |
| U19 | `关闭并断开` | 静态 | WorkspaceView.swift:114,127,149,160 | workspace.action.close_disconnect |
| U20 | `正在连接 {address}:{port} …` | 动态拼接 | ConnectionGate.swift:175(ConnectingRow)；TerminalTabView.swift:190 | workspace.connecting.status；参数：address、port |
| U21 | `设置` | 静态 | SettingsView.swift:75(navigationTitle)；SidebarView.swift:283(侧栏入口) | settings.title |
| U22 | `完成` | 静态 | SftpTabView.swift:471,494(多选模式按钮) | sftp.action.finish_select |
| U23 | `选择` | 静态 | SftpTabView.swift:471,494 | sftp.action.select |
| U24 | `移动到「{name}」` | 动态拼接 | TabContextMenuBuilder.swift:29,190；UnifiedWorkspaceTabStrip.swift:331 | workspace.menu.move_to_group；参数：name |
| U25 | `复制` | 静态 | SidebarView.swift:409(菜单)；SnippetsView.swift:150(按钮)；PandaTerminalView.swift:188(终端菜单) | app.action.copy |
| U26 | `重连` | 静态 | TabContextMenuBuilder.swift:24；PandaTerminalView.swift:193 | terminal.action.reconnect |
| U27 | `关闭标签页` | 静态 | TabContextMenuBuilder.swift:25；PandaTerminalView.swift:194 | workspace.menu.close_tab |
| U28 | `删除分组` | 静态 | SidebarView.swift:140(alert 标题),462(菜单)；TabContextMenuBuilder.swift:31 | group.action.delete |

## 各文件出口明细

### apple/PandaSSH/PandaSSHApp.swift
- 155 | AppModel.reload | `配置加载完成; 主机数=\(hosts.count)` | 动态拼接 | log.config.load_done | 参数：host_count（log 类出口，经 LogView 可见）

### apple/PandaSSH/SettingsView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 16-20 | SettingsTab.title | `通用` / `外观` / `连接` / `终端` / `高级`（5 条） | 静态 | settings.tab.{general,appearance,connection,terminal,advanced}.title | — |
| 92 | settingsTabsWithAlerts | `导入失败` | 静态 | settings.import.error_title | — |
| 97 | settingsTabsWithAlerts | `导入成功` | 静态 | settings.import.success_title | — |
| 102 | settingsTabsWithAlerts | `密码保护操作失败` | 静态 | settings.protection.error_title | — |
| 120 | tabContent | `\(tab.title)设置即将上线` | 动态拼接 | settings.placeholder.coming_soon | 参数：tab_title |
| 137 | appearanceTab | `外观设置即将上线` | 静态 | settings.placeholder.appearance_coming_soon（可与上条共用模板） | — |
| 166 | configSection | `配置`（Section） | 静态 | settings.section.config | — |
| 167 | configSection | `导出配置…` | 静态 | settings.export.action | — |
| 170 | configSection | `导入配置…` | 静态 | settings.import.action | — |
| 187 | configSection | `密码保护`（Section） | 静态 | settings.section.protection | — |
| 189 | configSection | `当前保护密钥`（SecureField） | 静态 | settings.protection.current_key_label | — |
| 190 | configSection | `新的保护密钥（留空则只解锁）` | 静态 | settings.protection.new_key_label | — |
| 191 | configSection | `重启后需在此输入当前保护密钥，才能使用已保存的密码与私钥口令。` | 静态 | settings.protection.restart_hint | — |
| 194 | configSection | `解锁或更新保护` | 静态 | settings.protection.unlock_action | — |
| 196 | configSection | `移除密码保护` | 静态 | settings.protection.remove_action | — |
| 199 | configSection | `密码保护密钥（可选）` | 静态 | settings.protection.optional_key_label | — |
| 200 | configSection | `未设置保护密钥时，已保存的密码与私钥口令会以明文保存在本机配置目录。` | 静态 | settings.protection.plaintext_warning | — |
| 203 | configSection | `应用密码保护` | 静态 | settings.protection.apply_action | — |
| 217 | enableCredentialProtection | `无法更新密码保护：\(error.localizedDescription)` | 动态拼接 | settings.protection.update_failed | 参数：error |
| 229 | unlockOrUpdateCredentialProtection | `无法解锁或更新密码保护：\(error.localizedDescription)` | 动态拼接 | settings.protection.unlock_failed | 参数：error |
| 242 | removeCredentialProtection | `无法移除密码保护：\(error.localizedDescription)` | 动态拼接 | settings.protection.remove_failed | 参数：error |
| 248 | aboutSection | `关于`（Section） | 静态 | settings.section.about | — |
| 249 | aboutSection | `版本`（LabeledContent 标签） | 静态 | settings.about.version_label | — |
| 249 | aboutSection | `Panda SSH 0.1.0 · Rust core v0.1`（值） | 静态 | —（产品版本信息，建议不翻译） | — |
| 250 | aboutSection | `开源协议`（标签） | 静态 | settings.about.license_label | — |
| 250 | aboutSection | `Apache-2.0`（值） | 静态 | —（不翻译） | — |
| 251 | aboutSection | `技术栈`（标签） | 静态 | settings.about.stack_label | — |
| 251 | aboutSection | `Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定`（值） | 静态 | settings.about.stack_value（含中文「绑定」，需拆分处理） | — |
| 266,281 | exportConfig（macOS/iOS 两分支，同文案） | `导出失败: \(error.localizedDescription)` | 动态拼接 | settings.export.failed | 参数：error |
| 301-302 | handleImportResult | `配置导入成功。密码/口令未包含在归档中，需重新输入。` + `\n已备份文件: \(list)` | 动态拼接 | settings.import.success / settings.import.backup_files | 参数：backup_list |
| 305 | handleImportResult | `导入失败: \(error.localizedDescription)` | 动态拼接 | settings.import.failed | 参数：error |
| 308 | handleImportResult | `选择文件失败: \(error.localizedDescription)` | 动态拼接 | settings.import.pick_failed | 参数：error |

（`#Preview("设置")` 为 DEBUG 画布标题，不计。）

### apple/PandaSSH/Sheets.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 53 | TofuConfirmSheet | `未知主机密钥` | 静态 | host.tofu.title | — |
| 55 | TofuConfirmSheet | `首次连接 **\(host.name)**（\(host.address):\(host.port)）。\n请核对服务器出示的主机密钥指纹，确认无误后再信任。信任后指纹将被记录，之后连接不再询问。` | 动态拼接 | host.tofu.detail | 参数：host_name、address、port |
| 59 | TofuConfirmSheet(FingerprintBox) | `\(host.fingerprintAlgorithm) 指纹` | 动态拼接 | host.tofu.fingerprint_label | 参数：algorithm |
| 62 | TofuConfirmSheet | `信任并连接` | 静态 | host.tofu.confirm_action | — |
| 85 | HostKeyMismatchSheet | `服务器密钥已变更！` | 静态 | host.mismatch.title | — |
| 88 | HostKeyMismatchSheet | `「\(host.name)」出示的主机密钥与本地记录**不一致**。\n服务器可能被重装，也可能正在遭遇**中间人攻击**。为安全起见已中断连接。` | 动态拼接 | host.mismatch.detail | 参数：host_name |
| 93 | HostKeyMismatchSheet(FingerprintBox) | `已记录指纹（known_hosts）` | 静态 | host.mismatch.recorded_label | — |
| 94 | HostKeyMismatchSheet(FingerprintBox) | `对方出示指纹` | 静态 | host.mismatch.presented_label | — |
| 96 | HostKeyMismatchSheet | `断开连接` | 静态 | host.mismatch.disconnect_action | — |
| 122 | PasswordPromptSheet | `输入登录密码` / `输入私钥口令` | 条件 | auth.prompt.title | — |
| 124 | PasswordPromptSheet | `连接至 \(host.username)@\(host.address):\(host.port)` | 动态拼接 | auth.prompt.target | 参数：username、address、port |
| 133 | PasswordPromptSheet | `密码` / `私钥口令` | 条件 | auth.prompt.field_label | — |
| 135 | PasswordPromptSheet | `请输入密码` / `请输入私钥口令`（SecureField 占位） | 条件 | auth.prompt.placeholder | — |
| 140 | PasswordPromptSheet | `仅用于当前标签页，关闭标签后即销毁。` | 静态 | auth.prompt.ephemeral_hint | — |
| 147 | PasswordPromptSheet | `登录` | 静态 | auth.prompt.login_action | — |
| 177 | KeyPickerSheet | `需要私钥` | 静态 | auth.keypicker.title | — |
| 179 | KeyPickerSheet | `主机 **\(host.name)** 使用密钥认证，但本机尚未选择私钥文件。请选择本机可用的私钥。` | 动态拼接 | auth.keypicker.detail | 参数：host_name |
| 191 + Auth/KeyPicker.swift:34 | KeyPickerSheet Label；SystemKeyPicker NSOpenPanel title（同文案跨文件合并） | `选择私钥文件` | 静态 | auth.keypicker.pick_action | — |
| 217 | GroupNameSheet | `分组名称`（TextField 占位） | 静态 | group.name.placeholder | — |

（GroupNameSheet 的 title/message 参数由 SidebarView 传入，见 SidebarView 节。）

### apple/PandaSSH/SidebarView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 38,455 | sheetContent(GroupNameSheet title)；GroupRowView 菜单 | `新建子分组` | 静态 | group.action.create_subgroup | — |
| 39 | sheetContent(GroupNameSheet message) | `在「\($0.name)」下创建子分组：` / `在根级创建新分组：` | 动态拼接 | group.create.message | 参数：group_name |
| 42 | sheetContent toast | `分组已创建` | 静态 | group.toast.created | — |
| 45 | sheetContent(GroupNameSheet title) | `重命名分组` | 静态 | group.rename.title | — |
| 47 | sheetContent toast | `分组已重命名` | 静态 | group.toast.renamed | — |
| 111,174 | searchable prompt（iOS）；searchField TextField（macOS），同文案 | `搜索主机` | 静态 | host.search.placeholder | — |
| 130,421 | alert 标题；主机菜单项，同文案 | `删除主机` | 静态 | host.delete.title | — |
| 135 | alert 后 toast | `主机已删除` | 静态 | host.toast.deleted | — |
| 138 | 删除主机 alert message | `确定删除「\(host.name)」吗？此操作不可撤销。` | 动态拼接 | host.delete.confirm | 参数：host_name |
| 147 | 删除分组 alert message | `确定删除分组「\(group.name)」吗？组内主机将移回根级，子分组将一并删除。` | 动态拼接 | group.delete.confirm | 参数：group_name |
| 144 | 删除分组后 toast | `分组已删除，主机已移回根级` | 静态 | group.toast.deleted | — |
| 218 | treeView 搜索空态 | `无匹配主机` | 静态 | host.search.empty | — |
| 361-364 | HostRowView.dotTip（状态圆点 tooltip/a11y，4 条） | `当前存在可用 SSH 会话` / `正在建立 SSH 会话` / `当前 SSH 会话不可达` / `当前未建立 SSH 会话` | 静态 | host.status.dot_{connected,connecting,failed,inactive} | — |
| 391 | HostRowView a11y | `\(host.name)，\(host.subtitle)` | 动态拼接 | host.row.accessibility_label（用户数据为主，建议拼装键） | 参数：name、subtitle |
| 406 | HostRowView 菜单 | `编辑…` | 静态 | host.action.edit | — |
| 411 | HostRowView 菜单 | `移至分组`（Menu 标题） | 静态 | host.action.move_to_group | — |
| 451 | GroupRowView 菜单 | `在此分组添加主机…` | 静态 | group.action.add_host_here | — |
| 458 | GroupRowView 菜单 | `重命名` | 静态 | group.action.rename | — |
| 507 | SideEntryButton 角标 a11y | `\(badgeCount) 个活动任务` | 动态拼接 | app.entry.active_tasks_a11y | 参数：count |

### apple/PandaSSH/HostDetailView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 67 | chips | `分组：\((try? groupPath(...)) ?? "根级")` | 动态拼接 | host.detail.group_chip | 参数：group_path（兜底值见 U15） |
| 70 | chips | `⚠ 主机密钥不匹配` | 静态 | host.detail.mismatch_chip | — |
| 73 | chips | `✓ 主机密钥已记录` | 静态 | host.detail.recorded_chip | — |
| 75 | chips | `主机密钥未验证` | 静态 | host.detail.unverified_chip | — |
| 83 | authLabel | `密钥 \(host.keyPath)` | 动态拼接 | host.detail.auth_key | 参数：key_path |
| 85 | authLabel | `密码（已保存）` / `密码（未保存）` | 条件 | host.detail.auth_password_{saved,unsaved} | — |

### apple/PandaSSH/HostEditView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 53 | Form | `主机`（Section） | 静态 | host.edit.section_host | — |
| 54 | TextField | `名称` | 静态 | host.edit.name_label | — |
| 54 | TextField prompt | `如 web-prod` | 静态 | host.edit.name_placeholder | — |
| 55 | TextField | `地址` | 静态 | host.edit.address_label | — |
| 55 | TextField prompt | `IP 或域名` | 静态 | host.edit.address_placeholder | — |
| 56 | TextField | `端口` | 静态 | host.edit.port_label | — |
| 60 | TextField | `用户名` | 静态 | host.edit.username_label | — |
| 61 | TextField | `备注` | 静态 | host.edit.note_label | — |
| 61 | TextField prompt | `可选` | 静态 | host.edit.optional_placeholder | — |
| 62 | Picker | `所属分组` | 静态 | host.edit.group_label | — |
| 70 | Form | `认证`（Section） | 静态 | host.edit.section_auth | — |
| 71 | Picker | `方式` | 静态 | host.edit.auth_method_label | — |
| 73 | Picker 项 | `密钥` | 静态 | host.edit.auth_key_option | — |
| 78 | TextField | `私钥路径` | 静态 | host.edit.keypath_label | — |
| 78 | TextField prompt | `~/.ssh/id_ed25519` | 静态 | host.edit.keypath_placeholder | — |
| 79 | Button | `选择文件…` | 静态 | host.edit.pick_key_action | — |
| 81 | SecureField | `密钥口令（可选）` | 静态 | host.edit.passphrase_label | — |
| 82 | Toggle | `保存口令` | 静态 | host.edit.save_passphrase_label | — |
| 84 | Button | `清除已保存的口令` | 静态 | host.edit.clear_passphrase_action | — |
| 94 | SecureField prompt | `已保存` / `输入密码` | 条件 | host.edit.password_{saved,enter}_placeholder | — |
| 96 | Toggle | `保存密码` | 静态 | host.edit.save_password_label | — |
| 98 | Text | `连接时将要求手动输入` | 静态 | host.edit.manual_input_hint | — |
| 103 | Button | `清除已保存的密码` | 静态 | host.edit.clear_password_action | — |
| 112 | navigationTitle | `添加主机` / `编辑主机` | 条件 | host.edit.title_{new,edit} | — |
| 124 | alert | `无法保存主机` | 静态 | host.edit.save_failed_title | — |
| 127 | alert message | `凭据写入本地文件失败，主机未保存。请重试。` | 静态 | host.edit.save_failed_detail | — |
| 129 | alert | `清除已保存凭据？` | 静态 | host.edit.clear_credentials_title | — |
| 131 | Button | `清除` | 静态 | host.edit.clear_action | — |
| 133 | alert message | `清除后下次连接需要重新输入，且不会自动填充。` | 静态 | host.edit.clear_credentials_detail | — |

### apple/PandaSSH/SnippetsView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 43,48 | sheet 保存后 toast（两处同文案） | `片段已保存` | 静态 | snippet.toast.saved | — |
| 52 | alert | `删除片段` | 静态 | snippet.delete.title | — |
| 57 | toast | `片段已删除` | 静态 | snippet.toast.deleted | — |
| 60 | alert message | `确定删除片段「\(snippet.title)」吗？` | 动态拼接 | snippet.delete.confirm | 参数：title |
| 72 | header | `代码片段` | 静态 | snippet.page_title | — |
| 75 | Button | `＋ 新建片段` | 静态 | snippet.action.new | — |
| 87 | ContentUnavailableView | `暂无片段` | 静态 | snippet.empty.title | — |
| 152 | toast | `已复制` | 静态 | snippet.toast.copied | — |
| 154 | Button | `编辑` | 静态 | snippet.action.edit | — |
| 163 | ContentUnavailableView | `选择或新建一个片段` | 静态 | snippet.empty.pick_or_new | — |
| 199 | TextField | `标题` | 静态 | snippet.edit.title_label | — |
| 200 | TextField | `标签` | 静态 | snippet.edit.tags_label | — |
| 200 | TextField prompt | `逗号分隔，如：运维, 日志` | 静态 | snippet.edit.tags_placeholder | — |
| 201 | TextField | `说明` | 静态 | snippet.edit.summary_label | — |
| 202 | Section | `代码` | 静态 | snippet.edit.section_code | — |
| 208 | navigationTitle | `新建片段` / `编辑片段` | 条件 | snippet.edit.title_{new,edit} | — |

### apple/PandaSSH/QuitProtectionToast.swift
- 14 | QuitProtectionToast | `再按一次退出` | 静态 | app.quit.press_again

### apple/PandaSSH/PandaCoreBackend.swift（log 类）
- 16 | init | `FFI 初始化成功` | 静态 | log.ffi.init_ok
- 19 | init | `FFI 初始化失败; 原因=\(error.localizedDescription)` | 动态拼接 | log.ffi.init_failed | 参数：error

### apple/PandaSSH/Workspace/ConnectionGate.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 233 | ConnectionFailure.title | `连接超时` | 静态 | error.connection.timeout_title | — |
| 234 | ConnectionFailure.title | `认证失败` | 静态 | error.connection.auth_failed_title | — |
| 235 | ConnectionFailure.title | `缺少凭据` | 静态 | error.connection.missing_credential_title | — |
| 236 | ConnectionFailure.title | `需要确认主机密钥` | 静态 | error.connection.unknown_host_key_title | — |
| 237 | ConnectionFailure.title | `连接失败` | 静态 | error.connection.other_title | — |
| 243 | ConnectionFailure.detail | `无法在规定时间内连接到远程主机，请检查网络或主机是否在线。` | 静态 | error.connection.timeout_detail | — |
| 244 | ConnectionFailure.detail | `服务器拒绝了提供的认证信息，请检查用户名、密码或私钥。` | 静态 | error.connection.auth_failed_detail | — |
| 245 | ConnectionFailure.detail | `连接需要密码或私钥口令。` | 静态 | error.connection.missing_credential_detail | — |
| 246 | ConnectionFailure.detail | `服务器主机密钥尚未确认。` | 静态 | error.connection.unknown_host_key_detail | — |
| 265 | ConnectFailureView | `\(host.address):\(host.port)\n\(failure.detail)` | 动态拼接 | error.connection.target_detail | 参数：address、port、detail |
| 303 | TOFU 信任后 toast | `已记录主机密钥指纹` | 静态 | host.toast.fingerprint_recorded | — |
| 61 | log | `私钥未选择 host=\(host.address):\(host.port)` | 动态拼接 | log.hostkey.key_not_selected | 参数：address、port |
| 67 | log | `凭据缺失 host=\(host.address):\(host.port)` | 动态拼接 | log.hostkey.credential_missing | 参数：address、port |
| 113 | log | `已信任主机密钥 host=\(host.address):\(host.port)` | 动态拼接 | log.hostkey.trusted | 参数：address、port |
| 119 | log | `TOFU 待确认 host=\(host.address):\(host.port)` | 动态拼接 | log.hostkey.tofu_pending | 参数：address、port |
| 126 | log | `主机密钥变更 host=…; 已知指纹=…; 呈现指纹=…` | 动态拼接 | log.hostkey.mismatch | 参数：address、port、stored、presented |
| 131 | log | `主机密钥探测失败 host=…; 原因=…` | 动态拼接 | log.hostkey.probe_failed | 参数：address、port、error |

### apple/PandaSSH/Workspace/ConnectionMonitorView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 69 | errorSummary | `连接 #\(id) 不存在或已结束` | 动态拼接 | monitor.error.connection_missing | 参数：id |
| 98-102 | ConnectionMonitorFormatter.transport | `Socket 连接中` / `Socket 活跃` / `Socket 空闲（正常）` / `Socket 已关闭` / `Socket 异常` | 静态 | monitor.transport.{connecting,active,idle,closed,failed} | — |
| 108-111 | Formatter.ssh | `SSH 协商中` / `SSH 已认证` / `SSH 已关闭` / `SSH 异常` | 静态 | monitor.ssh.{connecting,authenticated,closed,failed} | — |
| 116-119 | Formatter.health | `未检查` / `健康` / `不可用` | 静态 | monitor.health.{unknown,healthy,unavailable} | — |
| 125-127 | Formatter.channelKind | `终端` / `命令`（`SFTP` 为拉丁字母不译） | 静态 | monitor.channel.{shell,exec} | — |
| 132-135 | Formatter.channelState | `可用` / `已关闭` / `不可交互` | 静态 | monitor.channel_state.{open,closed,failed} | — |
| 156-158 | ContentUnavailableView | `暂无连接` + `建立终端或 SFTP 会话后，可在这里查看 Socket、SSH、通道和流量状态。` | 静态 | monitor.empty.title / monitor.empty.detail | — |
| 178 | 工具栏 Label | `刷新` | 静态 | monitor.action.refresh | — |
| 184 | ProgressView | `读取连接状态…` | 静态 | monitor.loading | — |
| 201 | alert message 兜底 | `未知错误` | 静态 | error.unknown | — |
| 207 | explanation | `流量为应用层实际读写的加密 SSH 字节与通道逻辑数据，不含 TCP/IP 头和重传。空闲表示近期无数据，不是异常。` | 静态 | monitor.traffic_explanation | — |
| 225 | connectionCard | `Session #\(connection.id) · \(connection.ownerKind) \(connection.ownerId) · 主机 \(connection.hostId)` | 动态拼接 | monitor.session_meta | 参数：id、owner_kind、owner_id、host_id |
| 236 | Button Label | `检查` | 静态 | monitor.action.check | — |
| 246-247 | trafficMetric | `接收` / `发送` | 静态 | monitor.traffic.{received,sent} | — |
| 252-254 | connectionCard 时间行 | `建立：{ts}  ·  最近活动：{ts}  ·  最近检查：{ts|尚未检查}` | 动态拼接 | monitor.timeline / monitor.not_checked_yet | 参数：created_at、last_activity、last_check |
| 298 | statusBadge | `探测：\(health)` | 动态拼接 | monitor.probe_badge | 参数：health |

（单位数组 `["B","KiB",…]`、`B/s` 等为计量单位，通常不翻译，仅备注。）

### apple/PandaSSH/Workspace/SftpTabView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 157 | browser alert | `确认删除` | 静态 | sftp.delete.confirm_title | — |
| 172 | 删除后 toast | `已删除 \(result.deleted) 项` / `已删除 \(candidate.names[0])` | 动态拼接 | sftp.toast.deleted_count / sftp.toast.deleted_one | 参数：count / name |
| 174 | toast | `已删除 \(result.deleted) 项，\(result.failed.count) 项失败` | 动态拼接 | sftp.toast.partial_failed | 参数：deleted、failed |
| 176-177 | toast | `\(name): \(error)`（以`；`连接）；`删除失败：\(details)` | 动态拼接 | sftp.toast.delete_failed | 参数：items |
| 185 | alert message | `确定要删除 \(candidate.names.count) 项吗？此操作不可撤销。` | 动态拼接 | sftp.delete.confirm_batch | 参数：count |
| 187 | alert message | `确定要删除「\(candidate.names[0])」吗？此操作不可撤销。` | 动态拼接 | sftp.delete.confirm_one | 参数：name |
| 202,211 | Picker（labelsHidden）+ a11y | `文件位置` | 静态 | sftp.pane.position_label | — |
| 264 | paneHead 标题按钮 | `远程 — \(host.name)`（与 U12 `本地`同出口） | 动态拼接 | sftp.pane.remote_title | 参数：host_name |
| 281 | a11y | `返回顶级目录` | 静态 | sftp.nav.root_a11y | — |
| 304 | a11y | `返回上级` | 静态 | sftp.nav.go_up_a11y | — |
| 328 | a11y | `刷新当前目录` | 静态 | sftp.nav.reload_a11y | — |
| 342 | TextField | `输入绝对路径，例如 /var/log` | 静态 | sftp.path.placeholder | — |
| 349 | a11y | `本地目录路径` / `远程目录路径` | 条件 | sftp.path.a11y_{local,remote} | — |
| 382 | a11y | `前往目录` | 静态 | sftp.path.go_a11y | — |
| 433 | a11y | `编辑本地路径` / `编辑远程路径` | 条件 | sftp.path.edit_a11y_{local,remote} | — |
| 488,511 | a11y（本地/远程多选按钮） | `完成选择`；`进入本地多选模式` / `进入多选模式` | 静态 | sftp.select.done_a11y / sftp.select.enter_a11y_{local,remote} | — |
| 581 | 空目录 | `空目录` | 静态 | sftp.list.empty | — |
| 751 | fileContextMenu actionLabel | `\(verb) \(count) 项` | 动态拼接 | sftp.menu.collective_suffix | 参数：verb、count |
| 758 | 菜单 Label | `进入` | 静态 | sftp.menu.enter | — |
| 765 | 菜单 Label | `上传` | 静态 | sftp.menu.upload | — |
| 771 | 菜单 Label | `下载` | 静态 | sftp.menu.download | — |
| 787 | 菜单 Label | `删除`（动词，与 U4 按钮同字面量，语义均为删除） | 静态 | sftp.menu.delete | — |
| 799 | paneFoot | `已选 \(count) 项` | 动态拼接 | sftp.select.count | 参数：count |
| 802,820 | 批量/单选 Button | `上传 →` / `← 下载` | 条件 | sftp.action.upload_arrow / sftp.action.download_arrow | — |
| 806 | toast | `已加入批量\(local ? "上传" : "下载")队列：\(name) 等 \(count) 项` | 动态拼接 | sftp.toast.batch_queued | 参数：direction、name、count |
| 815 | paneFoot | `已选：` | 静态 | sftp.select.selected_prefix | — |
| 824 | toast | `已加入上传队列：` / `已加入下载队列：` + name | 动态拼接 | sftp.toast.queued | 参数：direction、name |
| 831 | paneFoot 提示 | `单击选中 · 双击文件夹进入` | 静态 | sftp.select.hint | — |
| 446 | submitPath 失败 toast | `无法访问路径：\(target)。\(error.localizedDescription)` | 动态拼接 | sftp.path.navigate_failed | 参数：target、error |
| 881 | startRealConnection | `无法读取远程目录。` | 静态 | sftp.error.read_remote_failed | — |
| 986 | OverwriteConfirmationSheet | `“\(conflict.name)” 已存在` | 动态拼接 | sftp.conflict.exists_title | 参数：name |
| 990,992 | fileColumn | `源文件` / `目标文件` | 静态 | sftp.conflict.{source,target}_label | — |
| 996 | Button | `跳过` | 静态 | sftp.conflict.skip_action | — |
| 1001 | Button | `覆盖` | 静态 | sftp.conflict.overwrite_action | — |

### apple/PandaSSH/Workspace/TransferPanelView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 14-16 | ContentUnavailableView | `暂无传输任务` + `选中文件后点击「上传 →」或「← 下载」` | 静态 | transfer.empty.title / transfer.empty.detail | — |
| 50 | header | `\(store.activeCount) 个活动任务 · 共 \(store.tasks.count) 项` | 动态拼接 | transfer.summary | 参数：active、total |
| 55 | Button | `清除已完成` | 静态 | transfer.action.clear_finished | — |
| 128,291 | Button（组/任务，同文案合并） | `暂停` | 静态 | transfer.action.pause | — |
| 137,301 | Button | `继续` | 静态 | transfer.action.resume | — |
| 176,182 | endpoint 标题 | `源` | 静态 | transfer.endpoint.source | — |
| 178,183 | endpoint 标题 | `目标` | 静态 | transfer.endpoint.destination | — |
| 186 | Button | `收起完整路径` / `查看完整路径` | 条件 | transfer.action.{hide,show}_path | — |
| 218 | conflictNotice | `“\(conflict.name)” 已存在，等待覆盖确认` | 动态拼接 | transfer.conflict.waiting | 参数：name |
| 239 | speedInfo | `速度 \(formatSpeed(...))` | 动态拼接 | transfer.speed.live | 参数：speed |
| 240 | speedInfo | `均速 \(formatSpeed(...))` | 动态拼接 | transfer.speed.average | 参数：speed |
| 243 | speedInfo | `剩余 \(formatDuration(...))` | 动态拼接 | transfer.eta | 参数：eta |
| 259 | endpoint | `\(title)：\(name)` | 动态拼接 | transfer.endpoint.line | 参数：title、name |
| 268 | endpoint a11y | `\(title)路径：\(path)` | 动态拼接 | transfer.endpoint.a11y | 参数：title、path |
| 383 | TransferTaskPresentation 兜底 | `未知主机` | 静态 | transfer.unknown_host | — |

### apple/PandaSSH/Workspace/TransferStore.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 24-29 | TransferStatus.label（状态徽标） | `排队` / `传输中` / `已暂停` / `已完成` / `失败` / `已取消`（6 条） | 静态 | transfer.status.{queued,running,paused,done,failed,cancelled} | — |
| 610,1071,1105 | 批量任务名兜底（三处同文案） | `批量上传` / `批量下载` | 条件 | transfer.batch.name | 参数：direction |
| 613,1075,1109 | 批量任务名（三处同模板） | `\(first) 等 \(count) 项` | 动态拼接 | transfer.batch.name_many | 参数：first、count |
| 931 | 终态 log | `传输完成 name=\(name); 方向=\(dir); 大小=\(size)` | 动态拼接 | log.transfer.done | 参数：name、direction、size |
| 933 | 终态 log | `传输失败 name=\(name); 方向=\(dir); 原因=\(error|未知)` | 动态拼接 | log.transfer.failed | 参数：name、direction、error |
| 935 | 终态 log | `传输取消 name=\(name); 方向=\(dir)` | 动态拼接 | log.transfer.cancelled | 参数：name、direction |

### apple/PandaSSH/Workspace/TransferSpeedCalculator.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 17 | formatDuration | `1 秒内` | 静态 | transfer.duration.under_second | — |
| 18 | formatDuration | `\(seconds) 秒` | 动态拼接 | transfer.duration.seconds | 参数：seconds |
| 21 | formatDuration | `\(minutes) 分 \(secs) 秒` | 动态拼接 | transfer.duration.minutes | 参数：minutes、seconds |
| 24 | formatDuration | `\(hours) 时 \(mins) 分` | 动态拼接 | transfer.duration.hours | 参数：hours、minutes |

（`formatSpeed`/`formatBytes` 的 `B/s`、`KB` 等单位与 `%.1f` 数字格式为计量表达，建议保留不译或走 ICU 数字格式。）

### apple/PandaSSH/Workspace/WorkspaceView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 108,154 | 批量关闭 alert（macOS/iOS 同文案） | `关闭已连接终端？` | 静态 | workspace.close.batch_title | — |
| 117,164 | 批量关闭 message | `将关闭并断开 \(n) 个已连接终端会话。` | 动态拼接 | workspace.close.batch_detail | 参数：count |
| 121,143 | 单标签关闭 alert（macOS/iOS 同文案） | `关闭终端？` | 静态 | workspace.close.title | — |
| 130,152 | 单标签关闭 message | `关闭后将断开与「\(title)」的 SSH 连接。` | 动态拼接 | workspace.close.detail | 参数：tab_title |
| 189 | pendingCloseTabTitle 兜底 | `此主机` | 静态 | workspace.close.fallback_title | — |
| 274-277 | ContentUnavailableView | `标签页不可用` + `对应的主机可能已被删除,请关闭该标签页` | 静态 | workspace.tab.unavailable_title / workspace.tab.unavailable_detail | — |
| 330 | 空态标题 | `还没有主机` / `选择一个主机` | 条件 | workspace.empty.title_{no_hosts,choose} | — |
| 332 | 空态描述 | `添加主机后即可打开终端或浏览文件` / `从侧栏查看主机详情，再选择终端或 SFTP` | 条件 | workspace.empty.detail_{no_hosts,choose} | — |
| 347 | Button | `选择主机` | 静态 | workspace.empty.choose_host_action | — |

### apple/PandaSSH/Workspace/WorkspaceStore.swift
- 382 | createGroup 自动命名 | `分组 \(groupCounter)` | 动态拼接 | workspace.group.auto_name | 参数：index

### apple/PandaSSH/Workspace/UnifiedWorkspaceChrome.swift
- 88 | sidebarTools Label（iconOnly，a11y） | `隐藏侧栏` | 静态 | workspace.chrome.hide_sidebar
- 106 | sidebarRecovery a11y | `显示侧栏` | 静态 | workspace.chrome.show_sidebar

### apple/PandaSSH/Workspace/UnifiedWorkspaceTabStrip.swift
- 29,35 | 空态 Text + a11y | `暂无已打开页签` | 静态 | workspace.tabstrip.empty
- 146 | browseButton a11y | `浏览前一页签` / `浏览后一页签` | 条件 | workspace.tabstrip.browse_{prev,next}_a11y
- 235 | closeButton a11y | `关闭 \(tab.title)` | 动态拼接 | workspace.tabstrip.close_a11y | 参数：tab_title

### apple/PandaSSH/Workspace/TabContextMenuBuilder.swift
- 26 | TabMenuItem.title | `关闭其他标签页` | 静态 | workspace.menu.close_others
- 27 | TabMenuItem.title | `关闭全部标签页` | 静态 | workspace.menu.close_all
- 30 | TabMenuItem.title | `未分组` | 静态 | workspace.menu.ungroup
- 198 | NSImage accessibilityDescription | `移动到分组` | 静态 | workspace.menu.move_to_group_a11y

### apple/PandaSSH/Workspace/PandaTerminalView.swift（终端右键 NSMenu 标题）
| 行 | 原文 | 类型 | 建议资源键 |
|---|---|---|---|
| 183 | `复制链接地址` | 静态 | terminal.menu.copy_link |
| 184 | `打开链接` | 静态 | terminal.menu.open_link |
| 186 | `粘贴` | 静态 | terminal.menu.paste |
| 187 | `粘贴并回车` | 静态 | terminal.menu.paste_and_enter |
| 188 | `全选` | 静态 | terminal.menu.select_all |
| 189 | `清屏` | 静态 | terminal.menu.clear_screen |
| 190 | `重置终端` | 静态 | terminal.menu.reset_terminal |
| 191 | `复制并粘贴` | 静态 | terminal.menu.copy_and_paste |

### apple/PandaSSH/Workspace/TerminalTabView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 126 | ended 态标题 | `SSH 会话已结束` | 静态 | terminal.ended.title | — |
| 128 | ended 态描述 | `远端 shell 已正常退出。` | 静态 | terminal.ended.detail | — |
| 166 | Button | `重新连接` | 静态 | terminal.action.reconnect_new | — |
| 435 | log | `SSH 输入暂时拥塞；本次输入未发送` | 动态拼接 | log.ssh.input_backpressure | — |
| 455 | log | `终端初始尺寸上报 cols=\(cols) rows=\(rows)` | 动态拼接 | log.ssh.size_initial | 参数：cols、rows |
| 463 | log | `终端尺寸去抖上报 cols=\(cols) rows=\(rows)` | 动态拼接 | log.ssh.size_debounced | 参数：cols、rows |

### apple/PandaSSH/Workspace/TerminalSessionStore.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 59-61 | Mock 欢迎文本 | `✓ 已建立连接`（+ 英文 `Last login: …` / `Welcome to \(host.name)`，Mock 演示文本） | 动态拼接 | terminal.welcome.connected（英文部分建议标记不译/另行决策） | 参数：host_name |
| 128 | markFailed | `SSH 会话已断开。` | 静态 | terminal.error.disconnected | — |
| 142 | 读循环错误 | `SSH 连接异常，无法继续通信。` | 静态 | terminal.error.read_failed | — |
| 86 | log | `SSH 过期握手释放失败 handle=\(handle)` | 动态拼接 | log.ssh.stale_release_failed | 参数：handle |
| 93 | log | `已连接 host=\(record.host):\(record.port); owner=终端标签#\(handle); attempt=\(n)` | 动态拼接 | log.ssh.connected | 参数：host、port、handle、attempt |
| 99 | log | `连接失败 host=\(record.host):\(record.port); attempt=\(n)` | 动态拼接 | log.ssh.connect_failed | 参数：host、port、attempt |
| 106 | log | `SSH 重试 host=…; attempt=\(n)` | 动态拼接 | log.ssh.retry | 参数：host、port、attempt |
| 141 | log | `SSH 通信异常 host=…; attempt=\(n)` | 动态拼接 | log.ssh.io_error | 参数：host、port、attempt |
| 150 | log | `SSH shell 已结束 host=…` | 动态拼接 | log.ssh.shell_ended | 参数：host、port |
| 158 | log | `SSH 显式关闭 host=…` | 动态拼接 | log.ssh.explicit_close | 参数：host、port |
| 169 | log | `SSH 句柄释放失败 host=…` | 动态拼接 | log.ssh.handle_release_failed | 参数：host、port |

### apple/PandaSSH/Workspace/SftpSessionStore.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 | 参数 |
|---|---|---|---|---|---|
| 1053 | deleteRemoteCore 兜底 | `条目不存在` | 静态 | sftp.error.entry_missing | — |
| 493 | log | `SFTP 连接失败 host=\(host.address):\(host.port)` | 动态拼接 | log.sftp.connect_failed | 参数：address、port |
| 510 | log | `SFTP 已连接 host=\(host.address):\(host.port)` | 动态拼接 | log.sftp.connected | 参数：address、port |
| 1044 | log | `删除本地文件失败: path=\(path), error=\(error)` | 动态拼接 | log.sftp.delete_local_failed | 参数：path、error |
| 1073 | log | `删除远程文件失败: path=\(path), error=\(error)` | 动态拼接 | log.sftp.delete_remote_failed | 参数：path、error |
| 1184 | log | `SFTP 已断开 host=…; handle=\(handle)` | 动态拼接 | log.sftp.disconnected | 参数：address、port、handle |
| 1186 | log | `SFTP 断开失败 host=…; handle=\(handle)` | 动态拼接 | log.sftp.disconnect_failed | 参数：address、port、handle |

（rootTitle `本地`/`远程`/`远程 — host.name` 已并入 U12/U13 与 SftpTabView 表。）

### apple/PandaSSH/Workspace/LocalFilePicker.swift
- 32 | NSOpenPanel.title | `选择要上传的文件或目录` | 静态 | sftp.pick.upload_panel_title

### apple/PandaSSH/Logging/LogView.swift
| 行 | 上下文 | 原文 | 类型 | 建议资源键 |
|---|---|---|---|---|
| 12-14 | ContentUnavailableView | `暂无日志` + `运行时日志将在此显示` | 静态 | log.empty.title / log.empty.detail |
| 26 | 工具栏 Label | `清除` | 静态 | log.action.clear |

（`#Preview` 中的 `previewLogger()` 演示日志为 DEBUG 专用，不计。`Logger.swift` 的模块名常量 SSH/SFTP/Transfer/HostKey/Config/FFI 会随 `formatted` 呈现在日志窗口，是否本地化需决策；`LogEntry.formatted` 模板 `[ts] [LEVEL] [module] msg` 本身不含中文。）

## 备注与特殊情况

1. **Mock 演示数据（标记：不翻译）**——`Mock/MockBackend.swift` 中 `DemoData` 的分组名（`生产环境`/`华东`/`测试环境`）、主机名/地址/备注（如 `线上主 Web 服务器，Nginx + Node`）、片段标题/标签/摘要（`查看磁盘占用 Top 10` 等）均为业务演示数据，随用户数据呈现，**不登记为提示出口、不做本地化**。`PreviewSupport.swift` 仅组装演示实例，无文案。
2. **国际化风险点（代码逻辑与文案耦合）**：
   - `SidebarView.swift:320`：`window.title == "日志"` 用中文字面量做窗口匹配，标题本地化后匹配会失效，应改为按 `openWindow(id:)`/常量比较（连接监控那处 `ConnectionMonitorWindow.title` 同理，虽经常量但仍是显示文案参与匹配）。
   - `PandaCoreBackend.swift:282-308`（Snippet 互转）使用 Markdown 标记 `## 说明` / `## 代码` 作为持久化解析标记，**不是 UI 文案**，本地化时严禁改动（与 Rust `panda-core::Snippet::to_markdown` 契约绑定）。
   - `SettingsTab.title`（settings 标签）既做 tabItem 文本又拼进 `"\(tab.title)设置即将上线"`，提取时需用参数化模板而非字符串拼接。
   - `Toast.swift` / `QuitProtection.swift` / `Sheets.swift` 的 `GroupNameSheet.title/message` 等为**文案容器**，字符串由调用方注入（SidebarView 等），资源键需落在调用点。
3. **仅 DEBUG 可见**：全部 `#Preview("…")` 标题（SettingsView、HostEditView、SnippetsView、Sheets、WorkspaceView、LogView、ConnectionGate 等）与 `LogView.previewLogger()` 演示日志不进入 Release 包，未计入出口。
4. **未登记的纯代码文件（无任何用户可见文案）**：`MainWindowChrome.swift`、`PandaCoreBridge.swift`、`ApplicationQuitCoordinator.swift`、`QuitProtection.swift`（纯状态机）、`CloseTabKeyInterceptor.swift`、`SidebarTree.swift`、`Toast.swift`、`HostListView.swift`、`Mock/AppBackend.swift`、`Auth/CredentialResolver.swift`、`Workspace/` 下策略与几何纯值文件（`UnifiedWorkspaceChromeLayout`、`WorkspaceLayoutPolicy`、`WorkspacePresentationSelection`、`WorkspaceTerminalTabPolicy`、`WorkspaceChromeAdapterContract`、`WorkspaceEmptyStateRouter`、`IPadWorkspaceChromeHostPolicy`、`TitlebarTabStripGeometry`、`TabStripViewportState`、`TabSwitchHelper`、`TabRightClickCatcher`、`TabGroup`、`SFTPPresentationState`、`ShellConnection`、`PandaIOSTerminalView`（菜单标题由 macOS 侧 `PandaTerminalView.title(for:)` 统一提供）、`Workspace/TabContextMenuBuilder.swift` 的 `TabMenuActionHandler` 部分等）。
5. **特殊待决策文案**：About 值（`Panda SSH 0.1.0 · Rust core v0.1`、`Apache-2.0`）、`技术栈` 值、Mock 终端欢迎语的英文部分（`Last login:` / `Welcome to`）、日志模块名常量、`formatBytes/formatSpeed/ConnectionMonitorFormatter.bytes` 的计量单位与数字格式——建议统一决策（多为保留不译，走 ICU 数字/单位格式）。
6. **log 类出口**：所有 `Logger.shared.*` 调用共 29 条，会经 `LogView` 直接呈现给用户（窗口「日志」/iPad 侧栏日志页），属于用户可见文本，需随本变更一并双语化；本报告按其业务场景分别落在 log/terminal/sftp/transfer/monitor/host 等模块键下。

## 统计

- **扫描文件数**：57（`apple/PandaSSH/` 生产 Swift 文件全量；测试目录已排除）
- **含出口的文件数**：26；无文案文件 31（见备注 4）
- **出口总数（合并复用后唯一文案条目）**：**331**
  - 全局复用合并条目：28
  - log 类出口（Logger 调用）：29（已含在总数内，分布见各文件明细）
- **按模块分布（建议资源键前缀）**：

| 模块 | 出口数 | 主要来源 |
|---|---|---|
| app | 9 | 通用动作（取消/确定/好/删除/保存/重试/复制）、退出保护 toast、配置加载 log |
| settings | 37 | SettingsView 全部（标签页/导入导出/密码保护/关于） |
| host | 73 | HostEditView、HostDetailView、SidebarView 主机区、Sheets(TOFU/密钥变更/私钥选择)、连接失败 toast |
| group | 5 | 分组新建/重命名/删除、根级标签、页签分组自动命名 |
| snippet | 16 | SnippetsView + SnippetEditSheet |
| workspace | 26 | WorkspaceView 空态/关闭确认、页签栏、页签右键菜单、侧栏显隐 |
| terminal | 26 | 终端右键菜单、会话结束/失败态、Mock 欢迎语、终端 log |
| sftp | 50 | SftpTabView、SftpSessionStore、本地/远程面板、覆盖确认、上传选择器 |
| transfer | 32 | TransferPanelView、TransferStatus 徽标、批量任务名、时长格式化 |
| monitor | 28 | ConnectionMonitorView（状态徽标/卡片/空态） |
| log | 12 | LogView、FFI 初始化 log、复用标题「日志」 |
| auth | 6 | 密码/口令手动输入框（Sheets PasswordPromptSheet） |
| error | 11 | ConnectionFailure 五类标题+四类详情+展示模板 |

- **动态拼接/格式化出口占比**：约 45%（含插值模板、条件对、数值/时长格式化），是本地化时需优先参数化（`String(localized:defaultValue:)` + 格式参数）的部分。
- **重点大文件**：SftpTabView.swift（38 条）、HostEditView.swift（29 条）、ConnectionMonitorView.swift（27 条）、SettingsView.swift（36 条，含 3 条待决策产品信息值）、Sheets.swift（19 条）。
