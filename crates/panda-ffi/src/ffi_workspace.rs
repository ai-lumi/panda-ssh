//! 工作区标签页与终端会话状态机 FFI 导出。

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

use uuid::Uuid;

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// 标签页类型（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TabKindEnum {
    Terminal,
    Sftp,
}

impl From<TabKindEnum> for panda_core::TabKind {
    fn from(k: TabKindEnum) -> Self {
        match k {
            TabKindEnum::Terminal => panda_core::TabKind::Terminal,
            TabKindEnum::Sftp => panda_core::TabKind::Sftp,
        }
    }
}

impl From<panda_core::TabKind> for TabKindEnum {
    fn from(k: panda_core::TabKind) -> Self {
        match k {
            panda_core::TabKind::Terminal => TabKindEnum::Terminal,
            panda_core::TabKind::Sftp => TabKindEnum::Sftp,
        }
    }
}

/// 连接状态（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStatusEnum {
    Inactive,
    Connecting,
    Connected,
    Failed,
}

impl From<ConnectionStatusEnum> for panda_core::ConnectionStatus {
    fn from(s: ConnectionStatusEnum) -> Self {
        match s {
            ConnectionStatusEnum::Inactive => panda_core::ConnectionStatus::Inactive,
            ConnectionStatusEnum::Connecting => panda_core::ConnectionStatus::Connecting,
            ConnectionStatusEnum::Connected => panda_core::ConnectionStatus::Connected,
            ConnectionStatusEnum::Failed => panda_core::ConnectionStatus::Failed,
        }
    }
}

impl From<panda_core::ConnectionStatus> for ConnectionStatusEnum {
    fn from(s: panda_core::ConnectionStatus) -> Self {
        match s {
            panda_core::ConnectionStatus::Inactive => ConnectionStatusEnum::Inactive,
            panda_core::ConnectionStatus::Connecting => ConnectionStatusEnum::Connecting,
            panda_core::ConnectionStatus::Connected => ConnectionStatusEnum::Connected,
            panda_core::ConnectionStatus::Failed => ConnectionStatusEnum::Failed,
        }
    }
}

/// 标签页记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct WorkspaceTabRecord {
    pub id: String,
    pub host_id: String,
    pub kind: TabKindEnum,
    pub title: String,
    pub connection_status: ConnectionStatusEnum,
}

/// 关闭确认记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CloseConfirmationRecord {
    pub tab_ids: Vec<String>,
    pub connected_terminal_count: u32,
}

/// 终端会话阶段（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalPhaseEnum {
    Connecting,
    Shell,
    Failed,
}

impl From<TerminalPhaseEnum> for panda_core::TerminalPhase {
    fn from(p: TerminalPhaseEnum) -> Self {
        match p {
            TerminalPhaseEnum::Connecting => panda_core::TerminalPhase::Connecting,
            TerminalPhaseEnum::Shell => panda_core::TerminalPhase::Shell,
            TerminalPhaseEnum::Failed => panda_core::TerminalPhase::Failed,
        }
    }
}

impl From<panda_core::TerminalPhase> for TerminalPhaseEnum {
    fn from(p: panda_core::TerminalPhase) -> Self {
        match p {
            panda_core::TerminalPhase::Connecting => TerminalPhaseEnum::Connecting,
            panda_core::TerminalPhase::Shell => TerminalPhaseEnum::Shell,
            panda_core::TerminalPhase::Failed => TerminalPhaseEnum::Failed,
        }
    }
}

/// 终端会话失败分类（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalFailureCategoryEnum {
    Timeout,
    AuthFailed,
    MissingCredential,
    HostKeyMismatch,
    Other,
}

impl From<TerminalFailureCategoryEnum> for panda_core::TerminalFailureCategory {
    fn from(c: TerminalFailureCategoryEnum) -> Self {
        match c {
            TerminalFailureCategoryEnum::Timeout => panda_core::TerminalFailureCategory::Timeout,
            TerminalFailureCategoryEnum::AuthFailed => {
                panda_core::TerminalFailureCategory::AuthFailed
            }
            TerminalFailureCategoryEnum::MissingCredential => {
                panda_core::TerminalFailureCategory::MissingCredential
            }
            TerminalFailureCategoryEnum::HostKeyMismatch => {
                panda_core::TerminalFailureCategory::HostKeyMismatch
            }
            TerminalFailureCategoryEnum::Other => panda_core::TerminalFailureCategory::Other,
        }
    }
}

impl From<panda_core::TerminalFailureCategory> for TerminalFailureCategoryEnum {
    fn from(c: panda_core::TerminalFailureCategory) -> Self {
        match c {
            panda_core::TerminalFailureCategory::Timeout => TerminalFailureCategoryEnum::Timeout,
            panda_core::TerminalFailureCategory::AuthFailed => {
                TerminalFailureCategoryEnum::AuthFailed
            }
            panda_core::TerminalFailureCategory::MissingCredential => {
                TerminalFailureCategoryEnum::MissingCredential
            }
            panda_core::TerminalFailureCategory::HostKeyMismatch => {
                TerminalFailureCategoryEnum::HostKeyMismatch
            }
            panda_core::TerminalFailureCategory::Other => TerminalFailureCategoryEnum::Other,
        }
    }
}

/// 终端会话记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TerminalSessionRecord {
    pub id: String,
    pub host_id: String,
    pub phase: TerminalPhaseEnum,
    pub failure_category: Option<TerminalFailureCategoryEnum>,
    pub failure_message: Option<String>,
    pub attempt: u32,
}

impl From<panda_core::TerminalSessionState> for TerminalSessionRecord {
    fn from(s: panda_core::TerminalSessionState) -> Self {
        TerminalSessionRecord {
            id: s.id,
            host_id: s.host_id,
            phase: s.phase.into(),
            failure_category: s.failure_category.map(|c| c.into()),
            failure_message: s.failure_message,
            attempt: s.attempt,
        }
    }
}

/// 主机名映射记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostNameMapping {
    pub host_id: String,
    pub name: String,
}

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

/// 工作区内部标签页状态。
#[derive(Debug, Clone)]
struct InternalTab {
    id: String,
    host_id: String,
    kind: panda_core::TabKind,
    /// 页签创建时确定的显示标题，在其生命周期内保持不变。
    title: String,
    connection_status: panda_core::ConnectionStatus,
    /// 终端标签页是否已连接（用于关闭确认判断）。
    terminal_connected: bool,
}

impl InternalTab {
    fn to_workspace_tab(&self) -> panda_core::WorkspaceTab {
        panda_core::WorkspaceTab {
            id: self.id.clone(),
            host_id: self.host_id.clone(),
            kind: self.kind,
            title: self.title.clone(),
            connection_status: self.connection_status,
        }
    }
}

/// 批量关闭待确认。
#[derive(Debug, Clone)]
enum PendingClose {
    /// 单标签关闭确认。
    Single(String),
    /// 批量关闭确认。
    Batch {
        scope: panda_core::workspace::BatchCloseScope,
        connected_terminal_count: u32,
    },
}

/// 工作区全局状态管理器。
struct WorkspaceState {
    tabs: Vec<InternalTab>,
    active_tab_id: Option<String>,
    pending_close: Option<PendingClose>,
    /// 主机名映射表：host_id -> name
    host_names: HashMap<String, String>,
    /// 终端会话状态机：tab_id -> TerminalSessionState
    terminal_sessions: HashMap<String, panda_core::TerminalSessionState>,
    /// TOFU 并发序列化：host_id → 等待该主机确认结果的 oneshot sender 列表。
    tofu_waiters: HashMap<String, Vec<tokio::sync::oneshot::Sender<bool>>>,
    /// TOFU 并发序列化：host_id → 是否已有探测在进行中。
    tofu_probing: HashSet<String>,
}

impl WorkspaceState {
    fn new() -> Self {
        Self {
            tabs: Vec::new(),
            active_tab_id: None,
            pending_close: None,
            host_names: HashMap::new(),
            terminal_sessions: HashMap::new(),
            tofu_waiters: HashMap::new(),
            tofu_probing: HashSet::new(),
        }
    }

    /// 增量更新主机名映射。
    fn update_host_names(&mut self, mappings: Vec<HostNameMapping>) {
        for mapping in mappings {
            self.host_names.insert(mapping.host_id, mapping.name);
        }
    }

    /// 返回当前标签页列表（标题在创建时已确定）。
    fn tab_list(&self) -> Vec<panda_core::WorkspaceTab> {
        self.tabs
            .iter()
            .map(InternalTab::to_workspace_tab)
            .collect()
    }

    /// 打开新标签页，返回标签页 id。
    fn open_tab(&mut self, host_id: String, kind: panda_core::TabKind) -> String {
        let id = Uuid::new_v4().to_string();
        let mut tabs = self.tab_list();
        tabs.push(panda_core::WorkspaceTab {
            id: id.clone(),
            host_id: host_id.clone(),
            kind,
            title: String::new(),
            connection_status: panda_core::ConnectionStatus::Connecting,
        });
        let title = panda_core::compute_disambiguated_titles(&tabs, &|current_host_id| {
            self.host_names.get(current_host_id).cloned()
        })
        .pop()
        .expect("new tab must receive a title");
        self.tabs.push(InternalTab {
            id: id.clone(),
            host_id,
            kind,
            title,
            connection_status: panda_core::ConnectionStatus::Connecting,
            terminal_connected: false,
        });
        self.active_tab_id = Some(id.clone());
        id
    }

    /// 更新标签页连接状态。
    fn report_connection_status(&mut self, tab_id: &str, status: panda_core::ConnectionStatus) {
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == tab_id) {
            tab.connection_status = status;
            if tab.kind == panda_core::TabKind::Terminal {
                match status {
                    panda_core::ConnectionStatus::Connected => {
                        tab.terminal_connected = true;
                    }
                    panda_core::ConnectionStatus::Failed
                    | panda_core::ConnectionStatus::Inactive => {
                        tab.terminal_connected = false;
                    }
                    _ => {}
                }
            }
        }
    }

    /// 聚合同一主机的连接状态。
    fn host_connection_status(&self, host_id: &str) -> panda_core::ConnectionStatus {
        let statuses: Vec<_> = self
            .tabs
            .iter()
            .filter(|t| t.host_id == host_id)
            .map(|t| t.connection_status)
            .collect();
        panda_core::aggregate_connection_status(&statuses)
    }

    /// 内部关闭标签页（无确认检查）。
    fn close_tab_internal(&mut self, tab_id: &str) {
        if let Some(index) = self.tabs.iter().position(|t| t.id == tab_id) {
            self.tabs.remove(index);
            self.terminal_sessions.remove(tab_id);
            if self.active_tab_id.as_deref() == Some(tab_id) {
                let remaining_ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
                self.active_tab_id = panda_core::next_active_tab_after_close(&remaining_ids, index);
            }
        }
    }

    /// 请求关闭标签页。若为已连接终端标签页，设置待确认；否则直接关闭。
    /// 返回是否需要确认。
    fn request_close(&mut self, tab_id: &str) -> bool {
        let tab = match self.tabs.iter().find(|t| t.id == tab_id) {
            Some(t) => t,
            None => return false,
        };
        if tab.kind == panda_core::TabKind::Terminal && tab.terminal_connected {
            self.pending_close = Some(PendingClose::Single(tab_id.to_string()));
            true
        } else {
            self.close_tab_internal(tab_id);
            false
        }
    }

    /// 确认单标签关闭。
    fn confirm_close(&mut self) {
        if let Some(PendingClose::Single(tab_id)) = self.pending_close.take() {
            self.close_tab_internal(&tab_id);
        }
    }

    /// 取消关闭。
    fn cancel_close(&mut self) {
        self.pending_close = None;
    }

    /// 获取待确认信息。
    fn pending_close_info(&self) -> Option<CloseConfirmationRecord> {
        match &self.pending_close {
            Some(PendingClose::Single(tab_id)) => {
                let tab = self.tabs.iter().find(|t| &t.id == tab_id)?;
                Some(CloseConfirmationRecord {
                    tab_ids: vec![tab_id.clone()],
                    connected_terminal_count: if tab.terminal_connected { 1 } else { 0 },
                })
            }
            Some(PendingClose::Batch {
                scope,
                connected_terminal_count,
            }) => {
                let tab_ids = match scope {
                    panda_core::workspace::BatchCloseScope::Others { keeping } => self
                        .tabs
                        .iter()
                        .filter(|t| &t.id != keeping)
                        .map(|t| t.id.clone())
                        .collect(),
                    panda_core::workspace::BatchCloseScope::All => {
                        self.tabs.iter().map(|t| t.id.clone()).collect()
                    }
                };
                Some(CloseConfirmationRecord {
                    tab_ids,
                    connected_terminal_count: *connected_terminal_count,
                })
            }
            None => None,
        }
    }

    /// 请求关闭其他标签页。
    fn request_close_others(&mut self, keeping: &str) {
        let others: Vec<_> = self.tabs.iter().filter(|t| t.id != keeping).collect();
        let connected_count = others
            .iter()
            .filter(|t| t.kind == panda_core::TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            self.pending_close = Some(PendingClose::Batch {
                scope: panda_core::workspace::BatchCloseScope::Others {
                    keeping: keeping.to_string(),
                },
                connected_terminal_count: connected_count,
            });
        } else {
            self.close_others_internal(keeping);
        }
    }

    /// 请求关闭全部标签页。
    fn request_close_all(&mut self) {
        let connected_count = self
            .tabs
            .iter()
            .filter(|t| t.kind == panda_core::TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            self.pending_close = Some(PendingClose::Batch {
                scope: panda_core::workspace::BatchCloseScope::All,
                connected_terminal_count: connected_count,
            });
        } else {
            self.close_all_internal();
        }
    }

    /// 确认批量关闭。
    fn confirm_batch_close(&mut self) {
        if let Some(PendingClose::Batch { scope, .. }) = self.pending_close.take() {
            match scope {
                panda_core::workspace::BatchCloseScope::Others { keeping } => {
                    self.close_others_internal(&keeping);
                }
                panda_core::workspace::BatchCloseScope::All => {
                    self.close_all_internal();
                }
            }
        }
    }

    /// 内部关闭其他标签页。
    fn close_others_internal(&mut self, keeping: &str) {
        let to_remove: Vec<String> = self
            .tabs
            .iter()
            .filter(|t| t.id != keeping)
            .map(|t| t.id.clone())
            .collect();
        for id in to_remove {
            self.close_tab_internal(&id);
        }
        if self.tabs.iter().any(|t| t.id == keeping) {
            self.active_tab_id = Some(keeping.to_string());
        }
    }

    /// 内部关闭全部标签页。
    fn close_all_internal(&mut self) {
        let ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
        for id in ids {
            self.close_tab_internal(&id);
        }
    }
}

static WORKSPACE_STATE: OnceLock<Mutex<WorkspaceState>> = OnceLock::new();

fn workspace_state() -> &'static Mutex<WorkspaceState> {
    WORKSPACE_STATE.get_or_init(|| Mutex::new(WorkspaceState::new()))
}

// ---------------------------------------------------------------------------
// Workspace API exports
// ---------------------------------------------------------------------------

/// 设置主机名映射表。
#[uniffi::export]
pub fn workspace_set_host_names(host_names: Vec<HostNameMapping>) {
    let mut state = workspace_state().lock().unwrap();
    state.update_host_names(host_names);
}

/// 打开标签页。
#[uniffi::export]
pub fn workspace_open_tab(host_id: String, kind: TabKindEnum) -> WorkspaceTabRecord {
    let mut state = workspace_state().lock().unwrap();
    let tab_id = state.open_tab(host_id, kind.into());
    let tabs = state.tab_list();
    tabs.into_iter()
        .find(|t| t.id == tab_id)
        .map(|t| WorkspaceTabRecord {
            id: t.id,
            host_id: t.host_id,
            kind: t.kind.into(),
            title: t.title,
            connection_status: t.connection_status.into(),
        })
        .expect("just created tab should exist")
}

/// 关闭标签页（请求式，可能需要确认）。
#[uniffi::export]
pub fn workspace_close_tab(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.request_close(&tab_id);
}

/// 获取标签页列表（含消歧标题）。
#[uniffi::export]
pub fn workspace_tab_list() -> Vec<WorkspaceTabRecord> {
    let state = workspace_state().lock().unwrap();
    state
        .tab_list()
        .into_iter()
        .map(|t| WorkspaceTabRecord {
            id: t.id,
            host_id: t.host_id,
            kind: t.kind.into(),
            title: t.title,
            connection_status: t.connection_status.into(),
        })
        .collect()
}

/// 获取主机连接状态（聚合）。
#[uniffi::export]
pub fn workspace_host_connection_status(host_id: String) -> ConnectionStatusEnum {
    let state = workspace_state().lock().unwrap();
    state.host_connection_status(&host_id).into()
}

/// 更新标签页连接状态。
#[uniffi::export]
pub fn workspace_report_connection_status(tab_id: String, status: ConnectionStatusEnum) {
    let mut state = workspace_state().lock().unwrap();
    state.report_connection_status(&tab_id, status.into());
}

/// 关闭其他标签页（保留指定标签页）。
#[uniffi::export]
pub fn workspace_close_other_tabs(keeping_tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_others(&keeping_tab_id);
}

/// 关闭全部标签页。
#[uniffi::export]
pub fn workspace_close_all_tabs() {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_all();
}

/// 确认关闭。
#[uniffi::export]
pub fn workspace_confirm_close() {
    let mut state = workspace_state().lock().unwrap();
    let is_batch = matches!(&state.pending_close, Some(PendingClose::Batch { .. }));
    if is_batch {
        state.confirm_batch_close();
    } else {
        state.confirm_close();
    }
}

/// 取消关闭。
#[uniffi::export]
pub fn workspace_cancel_close() {
    let mut state = workspace_state().lock().unwrap();
    state.cancel_close();
}

/// 获取待关闭确认信息。
#[uniffi::export]
pub fn workspace_pending_close() -> Option<CloseConfirmationRecord> {
    let state = workspace_state().lock().unwrap();
    state.pending_close_info()
}

/// 选择标签页（设为活动标签）。
#[uniffi::export]
pub fn workspace_select_tab(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    if state.tabs.iter().any(|t| t.id == tab_id) {
        state.active_tab_id = Some(tab_id);
    }
}

/// 获取活动标签页 id。
#[uniffi::export]
pub fn workspace_active_tab_id() -> Option<String> {
    let state = workspace_state().lock().unwrap();
    state.active_tab_id.clone()
}

/// 重置工作区状态（用于测试）。
#[uniffi::export]
pub fn workspace_reset() {
    let mut state = workspace_state().lock().unwrap();
    state.tabs.clear();
    state.active_tab_id = None;
    state.pending_close = None;
    state.terminal_sessions.clear();
}

// ---------------------------------------------------------------------------
// TOFU 并发序列化（状态存储在工作区中）
// ---------------------------------------------------------------------------

/// TOFU 并发序列化：注册等待者。
#[uniffi::export]
pub fn preconnect_tofu_register_waiter(host_id: String) -> bool {
    let mut state = workspace_state().lock().unwrap();
    if state.tofu_probing.contains(&host_id) {
        false
    } else {
        state.tofu_probing.insert(host_id);
        true
    }
}

/// TOFU 并发序列化：广播确认结果给所有等待者，并清理状态。
#[uniffi::export]
pub fn preconnect_tofu_resolve(host_id: String, trusted: bool) {
    let mut state = workspace_state().lock().unwrap();
    if let Some(waiters) = state.tofu_waiters.remove(&host_id) {
        for sender in waiters {
            let _ = sender.send(trusted);
        }
    }
    state.tofu_probing.remove(&host_id);
}

/// TOFU 并发序列化：重置所有状态（仅用于测试）。
#[uniffi::export]
pub fn preconnect_tofu_reset() {
    let mut state = workspace_state().lock().unwrap();
    state.tofu_waiters.clear();
    state.tofu_probing.clear();
}

// ---------------------------------------------------------------------------
// Terminal session API exports
// ---------------------------------------------------------------------------

/// 注册/创建终端会话。
#[uniffi::export]
pub fn terminal_session_register(host_id: String, tab_id: String) -> TerminalSessionRecord {
    let mut state = workspace_state().lock().unwrap();
    let session = panda_core::TerminalSessionState::new(tab_id.clone(), host_id);
    state.terminal_sessions.insert(tab_id, session.clone());
    session.into()
}

/// 获取终端会话当前阶段。
#[uniffi::export]
pub fn terminal_session_phase(tab_id: String) -> Option<TerminalPhaseEnum> {
    let state = workspace_state().lock().unwrap();
    state.terminal_sessions.get(&tab_id).map(|s| s.phase.into())
}

/// 状态转换：connecting → shell。
#[uniffi::export]
pub fn terminal_session_transition_to_shell(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        if let Some(new_session) = panda_core::transition_to_shell(&session) {
            state.terminal_sessions.insert(tab_id, new_session);
        }
    }
}

/// 状态转换：任意阶段 → failed。
#[uniffi::export]
pub fn terminal_session_transition_to_failed(
    tab_id: String,
    category: TerminalFailureCategoryEnum,
    message: String,
) {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        let new_session = panda_core::transition_to_failed(&session, category.into(), message);
        state.terminal_sessions.insert(tab_id, new_session);
    }
}

/// 重试：failed → connecting，代次递增。
#[uniffi::export]
pub fn terminal_session_retry(tab_id: String) -> Option<TerminalSessionRecord> {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        if let Some(new_session) = panda_core::transition_to_connecting(&session) {
            state.terminal_sessions.insert(tab_id, new_session.clone());
            return Some(new_session.into());
        }
    }
    None
}

/// 关闭终端会话，从状态管理器中移除。
#[uniffi::export]
pub fn terminal_session_close(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.terminal_sessions.remove(&tab_id);
}

/// 检测握手结果是否已过期。
#[uniffi::export]
pub fn terminal_session_is_stale(tab_id: String, request_generation: u32) -> bool {
    let state = workspace_state().lock().unwrap();
    match state.terminal_sessions.get(&tab_id) {
        Some(session) => panda_core::is_stale(session, request_generation),
        None => true,
    }
}

/// 获取终端会话当前状态记录。
#[uniffi::export]
pub fn terminal_session_get(tab_id: String) -> Option<TerminalSessionRecord> {
    let state = workspace_state().lock().unwrap();
    state
        .terminal_sessions
        .get(&tab_id)
        .map(|s| s.clone().into())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "tests/ffi_workspace_tests.rs"]
mod tests;
