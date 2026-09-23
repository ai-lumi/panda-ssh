//! 工作区标签页与终端会话状态机 FFI 导出。
//!
//! FFI 层作为薄包装，将所有业务逻辑委托给 `panda_core::WorkspaceService`。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use uuid::Uuid;

use crate::PandaError;
use crate::ffi_store::stores;

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
    pub is_batch: bool,
}

/// 关闭请求结果（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CloseResultEnum {
    /// 标签页已直接关闭。
    Closed,
    /// 需要用户确认关闭。
    PendingConfirmation,
}

impl From<panda_core::CloseResult> for CloseResultEnum {
    fn from(r: panda_core::CloseResult) -> Self {
        match r {
            panda_core::CloseResult::Closed => CloseResultEnum::Closed,
            panda_core::CloseResult::PendingConfirmation => {
                CloseResultEnum::PendingConfirmation
            }
        }
    }
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

/// 分组记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TabGroupRecord {
    pub id: String,
    pub name: String,
    pub tab_ids: Vec<String>,
}

impl From<panda_core::TabGroup> for TabGroupRecord {
    fn from(g: panda_core::TabGroup) -> Self {
        Self {
            id: g.id,
            name: g.name,
            tab_ids: g.tab_ids,
        }
    }
}

/// 分组快照记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct GroupSnapshotRecord {
    pub groups: Vec<TabGroupRecord>,
    pub ungrouped_tab_ids: Vec<String>,
}

impl From<panda_core::GroupSnapshot> for GroupSnapshotRecord {
    fn from(s: panda_core::GroupSnapshot) -> Self {
        Self {
            groups: s.groups.into_iter().map(|g: panda_core::TabGroup| g.into()).collect(),
            ungrouped_tab_ids: s.ungrouped_tab_ids,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal state — thin wrapper around panda_core::WorkspaceService
// ---------------------------------------------------------------------------

/// 工作区全局状态管理器（薄包装，委托至核心 WorkspaceService）。
struct WorkspaceState {
    service: panda_core::WorkspaceService,
}

impl WorkspaceState {
    fn new() -> Self {
        Self {
            service: panda_core::WorkspaceService::new(),
        }
    }

    /// 增量更新主机名映射。
    fn update_host_names(&mut self, mappings: Vec<HostNameMapping>) {
        self.service
            .update_host_names(mappings.into_iter().map(|m| (m.host_id, m.name)).collect());
    }

    /// 打开新标签页，返回标签页 id。UUID 在此层生成。停机时返回 None。
    fn open_tab(&mut self, host_id: String, kind: panda_core::TabKind) -> Option<String> {
        let id = Uuid::new_v4().to_string();
        self.service.open_tab(id.clone(), host_id, kind)?;
        Some(id)
    }

    /// 返回当前标签页快照列表。
    fn tab_list(&self) -> Vec<panda_core::WorkspaceTab> {
        self.service.tab_list()
    }

    /// 获取活动标签页 id。
    fn active_tab_id(&self) -> Option<String> {
        self.service.active_tab_id().map(|s| s.to_string())
    }

    /// 选择标签页为活动标签。
    fn select_tab(&mut self, tab_id: &str) -> bool {
        self.service.select_tab(tab_id)
    }

    /// 请求关闭标签页。
    fn request_close(&mut self, tab_id: &str) -> panda_core::CloseResult {
        self.service.request_close(tab_id)
    }

    /// 确认关闭（单标签与批量均由此方法处理）。
    fn confirm_close(&mut self) {
        self.service.confirm_close();
    }

    /// 取消关闭。
    fn cancel_close(&mut self) {
        self.service.cancel_close();
    }

    /// 获取待关闭确认信息。
    fn pending_close_info(&self) -> Option<CloseConfirmationRecord> {
        self.service.pending_close_info().map(|info| CloseConfirmationRecord {
            tab_ids: info.tab_ids,
            connected_terminal_count: info.connected_terminal_count,
            is_batch: info.is_batch,
        })
    }

    /// 请求关闭其他标签页。
    fn request_close_others(&mut self, keeping: &str) -> panda_core::CloseResult {
        self.service.request_close_others(keeping)
    }

    /// 请求关闭全部标签页。
    fn request_close_all(&mut self) -> panda_core::CloseResult {
        self.service.request_close_all()
    }

    /// 更新标签页连接状态。
    fn report_connection_status(&mut self, tab_id: &str, status: panda_core::ConnectionStatus) {
        self.service.report_connection_status(tab_id, status);
    }

    /// 聚合同一主机的连接状态。
    fn host_connection_status(&self, host_id: &str) -> panda_core::ConnectionStatus {
        self.service.host_connection_status(host_id)
    }

    /// 重置工作区状态。
    fn reset(&mut self) {
        self.service.reset();
    }

    /// 开始应用停机。
    fn begin_application_shutdown(&mut self) -> panda_core::ShutdownSummary {
        self.service.begin_application_shutdown()
    }

    /// 是否仍在接受新工作。
    fn is_accepting_new_work(&self) -> bool {
        self.service.is_accepting_new_work()
    }
}

static WORKSPACE_STATE: OnceLock<Mutex<WorkspaceState>> = OnceLock::new();

fn workspace_state() -> &'static Mutex<WorkspaceState> {
    WORKSPACE_STATE.get_or_init(|| Mutex::new(WorkspaceState::new()))
}

// ---------------------------------------------------------------------------
// Helper: convert WorkspaceTab to WorkspaceTabRecord
// ---------------------------------------------------------------------------

fn tab_to_record(t: panda_core::WorkspaceTab) -> WorkspaceTabRecord {
    WorkspaceTabRecord {
        id: t.id,
        host_id: t.host_id,
        kind: t.kind.into(),
        title: t.title,
        connection_status: t.connection_status.into(),
    }
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

/// 打开标签页。停机时返回 None。
#[uniffi::export]
pub fn workspace_open_tab(host_id: String, kind: TabKindEnum) -> Option<WorkspaceTabRecord> {
    let mut state = workspace_state().lock().unwrap();
    let tab_id = state.open_tab(host_id, kind.into())?;
    state
        .tab_list()
        .into_iter()
        .find(|t| t.id == tab_id)
        .map(tab_to_record)
}

/// 关闭标签页（请求式，可能需要确认）。
#[uniffi::export]
pub fn workspace_close_tab(tab_id: String) -> CloseResultEnum {
    let mut state = workspace_state().lock().unwrap();
    state.request_close(&tab_id).into()
}

/// 获取标签页列表（含消歧标题）。
#[uniffi::export]
pub fn workspace_tab_list() -> Vec<WorkspaceTabRecord> {
    let state = workspace_state().lock().unwrap();
    state.tab_list().into_iter().map(tab_to_record).collect()
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
pub fn workspace_close_other_tabs(keeping_tab_id: String) -> CloseResultEnum {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_others(&keeping_tab_id).into()
}

/// 关闭全部标签页。
#[uniffi::export]
pub fn workspace_close_all_tabs() -> CloseResultEnum {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_all().into()
}

/// 确认关闭（统一处理单标签与批量）。
#[uniffi::export]
pub fn workspace_confirm_close() {
    let mut state = workspace_state().lock().unwrap();
    state.confirm_close();
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
    state.select_tab(&tab_id);
}

/// 获取活动标签页 id。
#[uniffi::export]
pub fn workspace_active_tab_id() -> Option<String> {
    let state = workspace_state().lock().unwrap();
    state.active_tab_id()
}

/// 重置工作区状态（用于测试）。
#[uniffi::export]
pub fn workspace_reset() {
    let mut state = workspace_state().lock().unwrap();
    state.reset();
}

/// 停机摘要记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ShutdownSummaryRecord {
    pub closed_tab_count: i32,
}

/// 开始应用停机：拒绝新工作、强制关闭所有标签页。
#[uniffi::export]
pub fn workspace_begin_application_shutdown() -> ShutdownSummaryRecord {
    let mut state = workspace_state().lock().unwrap();
    let summary = state.begin_application_shutdown();
    ShutdownSummaryRecord {
        closed_tab_count: summary.closed_tab_count as i32,
    }
}

/// 是否仍在接受新工作。
#[uniffi::export]
pub fn workspace_is_accepting_new_work() -> bool {
    let state = workspace_state().lock().unwrap();
    state.is_accepting_new_work()
}

// ---------------------------------------------------------------------------
// Group API exports
// ---------------------------------------------------------------------------

/// 创建新分组并将指定标签页分配进去。返回分组 id。
#[uniffi::export]
pub fn workspace_create_group(tab_id: String, name: Option<String>) -> String {
    let mut state = workspace_state().lock().unwrap();
    state.service.create_group(&tab_id, name)
}

/// 删除指定分组。组内标签页移至未分组。
#[uniffi::export]
pub fn workspace_delete_group(group_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.delete_group(&group_id);
}

/// 重命名指定分组。
#[uniffi::export]
pub fn workspace_rename_group(group_id: String, new_name: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.rename_group(&group_id, &new_name);
}

/// 将标签页移动到指定分组。
#[uniffi::export]
pub fn workspace_move_tab_to_group(tab_id: String, group_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.move_tab_to_group(&tab_id, &group_id);
}

/// 将标签页从分组中移除，变为未分组状态。
#[uniffi::export]
pub fn workspace_remove_tab_from_group(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.remove_tab_from_group(&tab_id);
}

/// 获取分组快照（有序分组列表 + 未分组标签页 id）。
#[uniffi::export]
pub fn workspace_group_snapshot() -> GroupSnapshotRecord {
    let state = workspace_state().lock().unwrap();
    state.service.group_snapshot().into()
}

/// 获取显示顺序的标签页 id 列表。
#[uniffi::export]
pub fn workspace_display_order() -> Vec<String> {
    let state = workspace_state().lock().unwrap();
    state.service.display_order()
}

// ---------------------------------------------------------------------------
// TOFU 并发序列化（委托至核心 TofuCoordinator）
// ---------------------------------------------------------------------------

/// 呈现密钥记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct PresentedKeyRecord {
    pub host: String,
    pub port: u16,
    pub key: String,
    pub fingerprint: String,
}

impl From<panda_core::PresentedKeyInfo> for PresentedKeyRecord {
    fn from(info: panda_core::PresentedKeyInfo) -> Self {
        Self {
            host: info.host,
            port: info.port,
            key: info.key,
            fingerprint: info.fingerprint,
        }
    }
}

/// TOFU 注册结果。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TofuRegisterResult {
    /// 是否为呈现者（需要展示确认 UI）。
    pub is_presenter: bool,
    /// 呈现者的请求 ID 或等待者的令牌。
    pub token: String,
    /// 呈现密钥信息（仅呈现者有效）。
    pub presented: Option<PresentedKeyRecord>,
}

/// TOFU 确认结果（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TofuOutcomeEnum {
    Trusted,
    Rejected,
    Cancelled,
}

impl From<panda_core::TofuOutcome> for TofuOutcomeEnum {
    fn from(o: panda_core::TofuOutcome) -> Self {
        match o {
            panda_core::TofuOutcome::Trusted => TofuOutcomeEnum::Trusted,
            panda_core::TofuOutcome::Rejected => TofuOutcomeEnum::Rejected,
            panda_core::TofuOutcome::Cancelled => TofuOutcomeEnum::Cancelled,
        }
    }
}

/// 等待者通道存储：token → mpsc::Receiver<TofuOutcome>。
static TOFU_WAITER_CHANNELS: OnceLock<Mutex<HashMap<String, std::sync::mpsc::Receiver<panda_core::TofuOutcome>>>> = OnceLock::new();

fn waiter_channels() -> &'static Mutex<HashMap<String, std::sync::mpsc::Receiver<panda_core::TofuOutcome>>> {
    TOFU_WAITER_CHANNELS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// TOFU 注册：委托至核心 TofuCoordinator。
#[uniffi::export]
pub fn tofu_register(
    host: String,
    port: u16,
    key: String,
    fingerprint: String,
) -> Result<TofuRegisterResult, PandaError> {
    let stores = stores()?;
    let registration = stores.core.tofu_register(host, port, key, fingerprint);
    match registration {
        panda_core::TofuRegistration::Presenter { request_id, presented } => {
            Ok(TofuRegisterResult {
                is_presenter: true,
                token: request_id,
                presented: Some(presented.into()),
            })
        }
        panda_core::TofuRegistration::Waiter { result } => {
            let token = format!("waiter-{}", Uuid::new_v4());
            waiter_channels().lock().unwrap().insert(token.clone(), result);
            Ok(TofuRegisterResult {
                is_presenter: false,
                token,
                presented: None,
            })
        }
    }
}

/// TOFU 确认信任：委托至核心。
#[uniffi::export]
pub fn tofu_confirm(request_id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    Ok(stores.core.tofu_confirm(&request_id)?)
}

/// TOFU 拒绝：委托至核心。
#[uniffi::export]
pub fn tofu_reject(request_id: String) {
    if let Ok(stores) = stores() {
        stores.core.tofu_reject(&request_id);
    }
}

/// TOFU 取消：委托至核心。
#[uniffi::export]
pub fn tofu_cancel(request_id: String) {
    if let Ok(stores) = stores() {
        stores.core.tofu_cancel(&request_id);
    }
}

/// 等待者阻塞获取结果。
#[uniffi::export]
pub fn tofu_await_outcome(token: String) -> TofuOutcomeEnum {
    let rx = waiter_channels().lock().unwrap().remove(&token);
    match rx {
        Some(rx) => rx.recv().unwrap_or(panda_core::TofuOutcome::Cancelled).into(),
        None => TofuOutcomeEnum::Cancelled,
    }
}

/// TOFU 重置：清理等待者通道（仅用于测试）。
#[uniffi::export]
pub fn tofu_reset() {
    waiter_channels().lock().unwrap().clear();
    if let Ok(stores) = stores() {
        for (request_id, _) in stores.core.tofu_coordinator().pending_requests() {
            stores.core.tofu_cancel(&request_id);
        }
    }
}

// ---------------------------------------------------------------------------
// Terminal session API exports
// ---------------------------------------------------------------------------

/// 注册/创建终端会话。
#[uniffi::export]
pub fn terminal_session_register(host_id: String, tab_id: String) -> TerminalSessionRecord {
    let mut state = workspace_state().lock().unwrap();
    state.service.terminal_session_register(host_id, tab_id).into()
}

/// 获取终端会话当前阶段。
#[uniffi::export]
pub fn terminal_session_phase(tab_id: String) -> Option<TerminalPhaseEnum> {
    let state = workspace_state().lock().unwrap();
    state
        .service
        .terminal_session_get(&tab_id)
        .map(|s| s.phase.into())
}

/// 状态转换：connecting → shell。
#[uniffi::export]
pub fn terminal_session_transition_to_shell(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.terminal_session_transition_to_shell(&tab_id);
}

/// 状态转换：任意阶段 → failed。
#[uniffi::export]
pub fn terminal_session_transition_to_failed(
    tab_id: String,
    category: TerminalFailureCategoryEnum,
    message: String,
) {
    let mut state = workspace_state().lock().unwrap();
    state
        .service
        .terminal_session_transition_to_failed(&tab_id, category.into(), message);
}

/// 重试：failed → connecting，代次递增。
#[uniffi::export]
pub fn terminal_session_retry(tab_id: String) -> Option<TerminalSessionRecord> {
    let mut state = workspace_state().lock().unwrap();
    state.service.terminal_session_retry(&tab_id).map(|s| s.into())
}

/// 关闭终端会话，从状态管理器中移除。
#[uniffi::export]
pub fn terminal_session_close(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.service.terminal_session_close(&tab_id);
}

/// 检测握手结果是否已过期。
#[uniffi::export]
pub fn terminal_session_is_stale(tab_id: String, request_generation: u32) -> bool {
    let state = workspace_state().lock().unwrap();
    state.service.terminal_session_is_stale(&tab_id, request_generation)
}

/// 获取终端会话当前状态记录。
#[uniffi::export]
pub fn terminal_session_get(tab_id: String) -> Option<TerminalSessionRecord> {
    let state = workspace_state().lock().unwrap();
    state
        .service
        .terminal_session_get(&tab_id)
        .cloned()
        .map(|s| s.into())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "tests/ffi_workspace_tests.rs"]
mod tests;
