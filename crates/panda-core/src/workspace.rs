//! 工作区标签页数据类型、纯算法与状态管理器。
//!
//! 本模块包含与平台无关的数据结构、标题消歧算法，以及工作区状态管理器
//! `WorkspaceService`（标签页列表、活动标签、关闭确认、终端会话）。

/// 标签页类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TabKind {
    Terminal,
    Sftp,
}

/// 标签页连接状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConnectionStatus {
    Inactive,
    Connecting,
    Connected,
    Failed,
}

impl ConnectionStatus {
    /// 优先级数值，用于聚合比较。connected > connecting > failed > inactive。
    pub fn priority(self) -> u8 {
        match self {
            Self::Inactive => 0,
            Self::Failed => 1,
            Self::Connecting => 2,
            Self::Connected => 3,
        }
    }
}

/// 工作区标签页。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceTab {
    pub id: String,
    pub host_id: String,
    pub kind: TabKind,
    pub title: String,
    pub connection_status: ConnectionStatus,
}

/// 关闭确认信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloseConfirmation {
    /// 需要确认关闭的标签页 id 列表。
    pub tab_ids: Vec<String>,
    /// 其中已连接终端标签页的数量。
    pub connected_terminal_count: u32,
    /// 是否为批量关闭（来自 request_close_all / request_close_others）。
    pub is_batch: bool,
}

/// 为页签保留既有标题，并为尚未命名的页签分配同主机消歧标题。
///
/// 规则：非空 `title` 表示页签已在创建时获得标题，必须原样保留。空标题按
/// `tabs` 数组顺序使用该主机未占用的最小序号：第一个为主机名，后续为
/// `(2)`、`(3)` 等。`host_name_provider` 查不到主机名时回退为 `host_id`。
///
/// 返回与 `tabs` 等长的标题 `Vec`。
pub fn compute_disambiguated_titles(
    tabs: &[WorkspaceTab],
    host_name_provider: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    let mut used_titles: std::collections::HashMap<String, std::collections::HashSet<String>> =
        std::collections::HashMap::new();
    let mut titles = Vec::with_capacity(tabs.len());

    for tab in tabs {
        let base = host_name_provider(&tab.host_id).unwrap_or_else(|| tab.host_id.clone());
        let used = used_titles.entry(tab.host_id.clone()).or_default();
        let title = if tab.title.is_empty() {
            let mut ordinal = 1;
            loop {
                let candidate = if ordinal == 1 {
                    base.clone()
                } else {
                    format!("{base} ({ordinal})")
                };
                if !used.contains(&candidate) {
                    break candidate;
                }
                ordinal += 1;
            }
        } else {
            tab.title.clone()
        };
        used.insert(title.clone());
        titles.push(title);
    }

    titles
}

/// 聚合同一主机下所有标签页的连接状态。
/// 优先级：connected > connecting > failed > inactive。
pub fn aggregate_connection_status(statuses: &[ConnectionStatus]) -> ConnectionStatus {
    let mut best = ConnectionStatus::Inactive;
    for &s in statuses {
        if s.priority() > best.priority() {
            best = s;
        }
    }
    best
}

/// 关闭活动标签后，计算新的活动标签 id。
/// 优先选择左侧相邻标签，越界则选右侧（即原索引位置）。
/// 若列表为空返回 `None`。
pub fn next_active_tab_after_close(tab_ids: &[String], closed_index: usize) -> Option<String> {
    if tab_ids.is_empty() {
        return None;
    }
    let target = if closed_index > 0 {
        closed_index - 1
    } else {
        0
    };
    Some(tab_ids[target].clone())
}

/// 在 Vec<String> 中将 item 移动到 before_item 之前。
/// 返回是否实际发生了移动（找不到元素或位置未变时返回 false）。
fn move_in_vec(vec: &mut Vec<String>, item: &str, before_item: &str) -> bool {
    let from = vec.iter().position(|id| id == item);
    let to = vec.iter().position(|id| id == before_item);
    match (from, to) {
        (Some(f), Some(t)) if f != t => {
            let removed = vec.remove(f);
            let adjusted = if t > f { t - 1 } else { t };
            vec.insert(adjusted, removed);
            true
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// 终端会话状态机
// ---------------------------------------------------------------------------

/// 终端会话阶段。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalPhase {
    /// 正在建立 SSH 连接。
    Connecting,
    /// Shell 已建立，可以进行交互。
    Shell,
    /// 连接失败或已断开。
    Failed,
}

/// 终端会话失败分类。
/// 与 `ssh::FailureCategory` 对应，但此处是终端会话层面的分类。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalFailureCategory {
    /// 连接超时。
    Timeout,
    /// 认证失败。
    AuthFailed,
    /// 缺少凭据（密码或口令）。
    MissingCredential,
    /// 主机密钥不匹配。
    HostKeyMismatch,
    /// 其他错误。
    Other,
}

/// 终端会话状态。
///
/// 记录单个终端标签页的会话状态机：连接中 → shell / 失败。
/// `attempt` 是连接代次计数器，重试时递增，用于检测过期的握手结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSessionState {
    /// 会话唯一标识（通常与标签页 id 相同）。
    pub id: String,
    /// 关联的主机 id。
    pub host_id: String,
    /// 当前阶段。
    pub phase: TerminalPhase,
    /// 失败分类（仅在 `phase == Failed` 时有意义）。
    pub failure_category: Option<TerminalFailureCategory>,
    /// 失败描述信息（仅在 `phase == Failed` 时有意义）。
    pub failure_message: Option<String>,
    /// 连接代次计数器：初始为 0，每次重试递增。
    /// 用于检测过期的握手结果——如果握手完成时代次已变化，说明结果已过期。
    pub attempt: u32,
}

impl TerminalSessionState {
    /// 创建新的终端会话，初始阶段为 `Connecting`，代次为 0。
    pub fn new(id: String, host_id: String) -> Self {
        Self {
            id,
            host_id,
            phase: TerminalPhase::Connecting,
            failure_category: None,
            failure_message: None,
            attempt: 0,
        }
    }
}

/// 状态转换：connecting → shell。
///
/// 握手成功，进入 shell 阶段。清除失败信息。
/// 若当前阶段不是 `Connecting`，返回 `None` 表示转换无效。
pub fn transition_to_shell(session: &TerminalSessionState) -> Option<TerminalSessionState> {
    if session.phase != TerminalPhase::Connecting {
        return None;
    }
    Some(TerminalSessionState {
        id: session.id.clone(),
        host_id: session.host_id.clone(),
        phase: TerminalPhase::Shell,
        failure_category: None,
        failure_message: None,
        attempt: session.attempt,
    })
}

/// 状态转换：任意阶段 → failed。
///
/// 连接失败或异常断开，进入失败阶段。记录失败分类和描述。
pub fn transition_to_failed(
    session: &TerminalSessionState,
    category: TerminalFailureCategory,
    message: String,
) -> TerminalSessionState {
    TerminalSessionState {
        id: session.id.clone(),
        host_id: session.host_id.clone(),
        phase: TerminalPhase::Failed,
        failure_category: Some(category),
        failure_message: Some(message),
        attempt: session.attempt,
    }
}

/// 状态转换：failed → connecting（重试）。
///
/// 用户触发重试：从失败阶段回到连接中阶段，代次计数器递增。
/// 若当前阶段不是 `Failed`，返回 `None` 表示转换无效。
pub fn transition_to_connecting(session: &TerminalSessionState) -> Option<TerminalSessionState> {
    if session.phase != TerminalPhase::Failed {
        return None;
    }
    Some(TerminalSessionState {
        id: session.id.clone(),
        host_id: session.host_id.clone(),
        phase: TerminalPhase::Connecting,
        failure_category: None,
        failure_message: None,
        attempt: session.attempt + 1,
    })
}

/// 检测握手结果是否已过期。
///
/// 当后台握手完成时，用发起时的代次 `request_generation` 与当前 `session.attempt` 比较。
/// 若不相等，说明在握手期间用户已重试或关闭，该结果应被丢弃。
pub fn is_stale(session: &TerminalSessionState, request_generation: u32) -> bool {
    session.attempt != request_generation
}

/// Shell 退出分类结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellExitClassification {
    /// 是否为正常退出（远端 shell 正常结束）。
    pub is_normal_exit: bool,
    /// 失败分类（异常断开时的类别）。
    pub failure_category: TerminalFailureCategory,
}

/// 分类 shell 退出原因。
///
/// 区分正常 shell 退出（远端进程结束）与传输层异常（网络断开等）。
/// `error_message` 为 `None` 表示正常退出；`Some` 表示异常，需进一步分类。
pub fn classify_shell_exit(error_message: Option<&str>) -> ShellExitClassification {
    match error_message {
        None => ShellExitClassification {
            is_normal_exit: true,
            failure_category: TerminalFailureCategory::Other,
        },
        Some(msg) => {
            let category =
                if msg.contains("shell session closed") || msg.contains("ShellSessionClosed") {
                    // 正常退出：远端 shell 进程结束
                    // 注意：虽然 is_normal_exit 为 false（因为确实有错误消息），
                    // 但分类为 Other，由调用方根据上下文判断是否为正常退出
                    TerminalFailureCategory::Other
                } else if msg.contains("timeout") || msg.contains("timed out") {
                    TerminalFailureCategory::Timeout
                } else if msg.contains("auth") || msg.contains("authentication") {
                    TerminalFailureCategory::AuthFailed
                } else if msg.contains("host key") {
                    TerminalFailureCategory::HostKeyMismatch
                } else {
                    TerminalFailureCategory::Other
                };
            ShellExitClassification {
                is_normal_exit: false,
                failure_category: category,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 页签分组
// ---------------------------------------------------------------------------

/// 页签分组。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabGroup {
    pub id: String,
    pub name: String,
    pub tab_ids: Vec<String>,
}

impl TabGroup {
    pub fn is_empty(&self) -> bool {
        self.tab_ids.is_empty()
    }
}

/// 分组快照：有序分组列表 + 未分组标签页 id。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupSnapshot {
    pub groups: Vec<TabGroup>,
    pub ungrouped_tab_ids: Vec<String>,
}

// ---------------------------------------------------------------------------
// 工作区状态管理器
// ---------------------------------------------------------------------------

use std::collections::HashMap;

/// 关闭请求结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseResult {
    /// 标签页已直接关闭。
    Closed,
    /// 需要用户确认关闭。
    PendingConfirmation,
}

/// 内部标签页状态。
#[derive(Debug, Clone)]
struct InternalTab {
    id: String,
    host_id: String,
    kind: TabKind,
    title: String,
    connection_status: ConnectionStatus,
    terminal_connected: bool,
}

impl InternalTab {
    fn to_workspace_tab(&self) -> WorkspaceTab {
        WorkspaceTab {
            id: self.id.clone(),
            host_id: self.host_id.clone(),
            kind: self.kind,
            title: self.title.clone(),
            connection_status: self.connection_status,
        }
    }
}

/// 待关闭请求。
#[derive(Debug, Clone)]
enum PendingClose {
    Single(String),
    Batch {
        /// 请求时确定的目标标签页 id 集合，确认时只关闭这些。
        target_ids: Vec<String>,
        connected_terminal_count: u32,
    },
}

/// 工作区状态管理器。
///
/// 停机摘要：记录停机时关闭的标签页数量。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShutdownSummary {
    pub closed_tab_count: usize,
}

/// 管理标签页列表、活动标签、关闭确认、主机名映射和终端会话。
/// 从 FFI 层迁入，使业务逻辑可在核心层测试。
#[derive(Debug)]
pub struct WorkspaceService {
    tabs: Vec<InternalTab>,
    active_tab_id: Option<String>,
    pending_close: Option<PendingClose>,
    host_names: HashMap<String, String>,
    terminal_sessions: HashMap<String, TerminalSessionState>,
    groups: Vec<TabGroup>,
    ungrouped_tab_ids: Vec<String>,
    group_counter: u32,
    accepting_new_work: bool,
}

impl WorkspaceService {
    pub fn new() -> Self {
        Self {
            tabs: Vec::new(),
            active_tab_id: None,
            pending_close: None,
            host_names: HashMap::new(),
            terminal_sessions: HashMap::new(),
            groups: Vec::new(),
            ungrouped_tab_ids: Vec::new(),
            group_counter: 0,
            accepting_new_work: true,
        }
    }

    /// 增量更新主机名映射。
    pub fn update_host_names(&mut self, mappings: Vec<(String, String)>) {
        for (host_id, name) in mappings {
            self.host_names.insert(host_id, name);
        }
    }

    /// 返回当前标签页快照列表。
    pub fn tab_list(&self) -> Vec<WorkspaceTab> {
        self.tabs.iter().map(InternalTab::to_workspace_tab).collect()
    }

    /// 获取活动标签页 id。
    pub fn active_tab_id(&self) -> Option<&str> {
        self.active_tab_id.as_deref()
    }

    /// 打开新标签页。`tab_id` 由调用方生成。标题在创建时确定且不再变化。
    /// 新标签自动成为活动标签。停机后拒绝新建，返回 None。
    pub fn open_tab(
        &mut self,
        tab_id: String,
        host_id: String,
        kind: TabKind,
    ) -> Option<WorkspaceTab> {
        if !self.accepting_new_work {
            return None;
        }
        let mut tabs = self.tab_list();
        tabs.push(WorkspaceTab {
            id: tab_id.clone(),
            host_id: host_id.clone(),
            kind,
            title: String::new(),
            connection_status: ConnectionStatus::Connecting,
        });
        let title = compute_disambiguated_titles(&tabs, &|current_host_id| {
            self.host_names.get(current_host_id).cloned()
        })
        .pop()
        .expect("new tab must receive a title");
        let tab = InternalTab {
            id: tab_id.clone(),
            host_id,
            kind,
            title,
            connection_status: ConnectionStatus::Connecting,
            terminal_connected: false,
        };
        self.tabs.push(tab);
        self.active_tab_id = Some(tab_id.clone());
        self.ungrouped_tab_ids.push(tab_id.clone());
        self.tabs.last().unwrap().to_workspace_tab().into()
    }

    /// 选择标签页为活动标签。未知 id 时返回 false。
    pub fn select_tab(&mut self, tab_id: &str) -> bool {
        if self.tabs.iter().any(|t| t.id == tab_id) {
            self.active_tab_id = Some(tab_id.to_string());
            true
        } else {
            false
        }
    }

    /// 请求关闭标签页。已连接的终端标签页需要确认，其余直接关闭。
    pub fn request_close(&mut self, tab_id: &str) -> CloseResult {
        let tab = match self.tabs.iter().find(|t| t.id == tab_id) {
            Some(t) => t,
            None => return CloseResult::Closed,
        };
        if tab.kind == TabKind::Terminal && tab.terminal_connected {
            self.pending_close = Some(PendingClose::Single(tab_id.to_string()));
            CloseResult::PendingConfirmation
        } else {
            self.close_tab_internal(tab_id);
            CloseResult::Closed
        }
    }

    /// 确认待处理的关闭请求。
    pub fn confirm_close(&mut self) {
        match self.pending_close.take() {
            Some(PendingClose::Single(tab_id)) => {
                self.close_tab_internal(&tab_id);
            }
            Some(PendingClose::Batch { target_ids, .. }) => {
                for id in target_ids {
                    self.close_tab_internal(&id);
                }
            }
            None => {}
        }
    }

    /// 取消待处理的关闭请求。
    pub fn cancel_close(&mut self) {
        self.pending_close = None;
    }

    /// 获取待关闭确认信息。
    pub fn pending_close_info(&self) -> Option<CloseConfirmation> {
        match &self.pending_close {
            Some(PendingClose::Single(tab_id)) => {
                let tab = self.tabs.iter().find(|t| &t.id == tab_id)?;
                Some(CloseConfirmation {
                    tab_ids: vec![tab_id.clone()],
                    connected_terminal_count: if tab.terminal_connected { 1 } else { 0 },
                    is_batch: false,
                })
            }
            Some(PendingClose::Batch {
                target_ids,
                connected_terminal_count,
                ..
            }) => Some(CloseConfirmation {
                tab_ids: target_ids.clone(),
                connected_terminal_count: *connected_terminal_count,
                is_batch: true,
            }),
            None => None,
        }
    }

    /// 请求关闭其他标签页（保留指定标签页）。
    pub fn request_close_others(&mut self, keeping: &str) -> CloseResult {
        let connected_count = self
            .tabs
            .iter()
            .filter(|t| t.id != keeping && t.kind == TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            let target_ids: Vec<String> = self
                .tabs
                .iter()
                .filter(|t| t.id != keeping)
                .map(|t| t.id.clone())
                .collect();
            self.pending_close = Some(PendingClose::Batch {
                target_ids,
                connected_terminal_count: connected_count,
            });
            CloseResult::PendingConfirmation
        } else {
            self.close_others_internal(keeping);
            CloseResult::Closed
        }
    }

    /// 请求关闭全部标签页。
    pub fn request_close_all(&mut self) -> CloseResult {
        let connected_count = self
            .tabs
            .iter()
            .filter(|t| t.kind == TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            let target_ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
            self.pending_close = Some(PendingClose::Batch {
                target_ids,
                connected_terminal_count: connected_count,
            });
            CloseResult::PendingConfirmation
        } else {
            self.close_all_internal();
            CloseResult::Closed
        }
    }

    /// 更新标签页连接状态。
    pub fn report_connection_status(&mut self, tab_id: &str, status: ConnectionStatus) {
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == tab_id) {
            tab.connection_status = status;
            if tab.kind == TabKind::Terminal {
                match status {
                    ConnectionStatus::Connected => {
                        tab.terminal_connected = true;
                    }
                    ConnectionStatus::Failed | ConnectionStatus::Inactive => {
                        tab.terminal_connected = false;
                    }
                    _ => {}
                }
            }
        }
    }

    /// 聚合同一主机的连接状态。
    pub fn host_connection_status(&self, host_id: &str) -> ConnectionStatus {
        let statuses: Vec<_> = self
            .tabs
            .iter()
            .filter(|t| t.host_id == host_id)
            .map(|t| t.connection_status)
            .collect();
        aggregate_connection_status(&statuses)
    }

    /// 是否仍在接受新工作。停机后返回 false。
    pub fn is_accepting_new_work(&self) -> bool {
        self.accepting_new_work
    }

    /// 开始应用停机：拒绝新工作、清除待处理关闭、强制关闭所有标签页。
    /// 返回关闭的标签页数量。幂等——第二次调用时已无标签页可关。
    pub fn begin_application_shutdown(&mut self) -> ShutdownSummary {
        self.accepting_new_work = false;
        self.pending_close = None;
        let count = self.tabs.len();
        self.tabs.clear();
        self.terminal_sessions.clear();
        self.active_tab_id = None;
        self.ungrouped_tab_ids.clear();
        self.groups.clear();
        ShutdownSummary {
            closed_tab_count: count,
        }
    }

    /// 重置所有状态。
    pub fn reset(&mut self) {
        self.tabs.clear();
        self.active_tab_id = None;
        self.pending_close = None;
        self.terminal_sessions.clear();
        self.groups.clear();
        self.ungrouped_tab_ids.clear();
        self.group_counter = 0;
        self.accepting_new_work = true;
    }

    // -- 终端会话管理 --

    /// 注册终端会话。
    pub fn terminal_session_register(
        &mut self,
        host_id: String,
        tab_id: String,
    ) -> TerminalSessionState {
        let session = TerminalSessionState::new(tab_id.clone(), host_id);
        self.terminal_sessions.insert(tab_id, session.clone());
        session
    }

    /// 获取终端会话。
    pub fn terminal_session_get(&self, tab_id: &str) -> Option<&TerminalSessionState> {
        self.terminal_sessions.get(tab_id)
    }

    /// 终端会话转换到 shell 阶段。
    pub fn terminal_session_transition_to_shell(&mut self, tab_id: &str) {
        if let Some(session) = self.terminal_sessions.get(tab_id).cloned() {
            if let Some(new_session) = transition_to_shell(&session) {
                self.terminal_sessions.insert(tab_id.to_string(), new_session);
            }
        }
    }

    /// 终端会话转换到 failed 阶段。
    pub fn terminal_session_transition_to_failed(
        &mut self,
        tab_id: &str,
        category: TerminalFailureCategory,
        message: String,
    ) {
        if let Some(session) = self.terminal_sessions.get(tab_id).cloned() {
            let new_session = transition_to_failed(&session, category, message);
            self.terminal_sessions.insert(tab_id.to_string(), new_session);
        }
    }

    /// 终端会话重试。
    pub fn terminal_session_retry(
        &mut self,
        tab_id: &str,
    ) -> Option<TerminalSessionState> {
        if let Some(session) = self.terminal_sessions.get(tab_id).cloned() {
            if let Some(new_session) = transition_to_connecting(&session) {
                self.terminal_sessions
                    .insert(tab_id.to_string(), new_session.clone());
                return Some(new_session);
            }
        }
        None
    }

    /// 关闭终端会话。
    pub fn terminal_session_close(&mut self, tab_id: &str) {
        self.terminal_sessions.remove(tab_id);
    }

    /// 检测终端会话握手结果是否过期。
    pub fn terminal_session_is_stale(&self, tab_id: &str, request_generation: u32) -> bool {
        match self.terminal_sessions.get(tab_id) {
            Some(session) => is_stale(session, request_generation),
            None => true,
        }
    }

    // -- 分组管理 --

    /// 创建新分组并将指定标签页分配进去。
    /// `name` 为 None 时自动生成 "分组 N"。返回新分组 id。
    /// 标签页不存在时仍创建分组（空组），调用方负责验证。
    pub fn create_group(&mut self, tab_id: &str, name: Option<String>) -> String {
        self.group_counter += 1;
        let group_name = name.unwrap_or_else(|| format!("分组 {}", self.group_counter));
        let group_id = uuid::Uuid::new_v4().to_string();
        let mut tab_ids = Vec::new();
        if self.tabs.iter().any(|t| t.id == tab_id) {
            tab_ids.push(tab_id.to_string());
            self.ungrouped_tab_ids.retain(|id| id != tab_id);
        }
        self.groups.push(TabGroup {
            id: group_id.clone(),
            name: group_name,
            tab_ids,
        });
        group_id
    }

    /// 删除分组。非空分组的标签页移至未分组。
    pub fn delete_group(&mut self, group_id: &str) {
        if let Some(index) = self.groups.iter().position(|g| g.id == group_id) {
            let group = self.groups.remove(index);
            for tab_id in &group.tab_ids {
                if !self.ungrouped_tab_ids.contains(tab_id) {
                    self.ungrouped_tab_ids.push(tab_id.clone());
                }
            }
        }
    }

    /// 重命名分组。未知分组为 no-op。
    pub fn rename_group(&mut self, group_id: &str, new_name: &str) {
        if let Some(group) = self.groups.iter_mut().find(|g| g.id == group_id) {
            group.name = new_name.to_string();
        }
    }

    /// 将标签页移动到目标分组。标签页已在其他分组时先从原分组移除。
    /// 目标分组不存在时为 no-op。
    pub fn move_tab_to_group(&mut self, tab_id: &str, group_id: &str) {
        let target_index = match self.groups.iter().position(|g| g.id == group_id) {
            Some(i) => i,
            None => return,
        };
        self.remove_tab_from_any_group(tab_id);
        self.ungrouped_tab_ids.retain(|id| id != tab_id);
        if self.tabs.iter().any(|t| t.id == tab_id) {
            self.groups[target_index].tab_ids.push(tab_id.to_string());
        }
    }

    /// 将标签页从分组中移除，变为未分组。
    pub fn remove_tab_from_group(&mut self, tab_id: &str) {
        self.remove_tab_from_any_group(tab_id);
        if self.tabs.iter().any(|t| t.id == tab_id)
            && !self.ungrouped_tab_ids.contains(&tab_id.to_string())
        {
            self.ungrouped_tab_ids.push(tab_id.to_string());
        }
    }

    /// 返回分组快照：有序分组列表 + 未分组标签页 id。
    pub fn group_snapshot(&self) -> GroupSnapshot {
        GroupSnapshot {
            groups: self.groups.clone(),
            ungrouped_tab_ids: self.ungrouped_tab_ids.clone(),
        }
    }

    /// 应用分组快照：用新的分组归属和排序替换当前状态。
    /// 对快照中不存在的 tab（已关闭的）忽略；对快照中未包含的活跃 tab，
    /// 追加到 ungrouped_tab_ids 末尾。不修改 tab 列表本身。
    pub fn apply_group_snapshot(&mut self, snapshot: &GroupSnapshot) {
        let valid_ids: std::collections::HashSet<&str> = self
            .tabs
            .iter()
            .map(|t| t.id.as_str())
            .collect();

        // 收集快照中出现的所有 tab_id
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();

        let mut new_groups: Vec<TabGroup> = Vec::new();
        for g in &snapshot.groups {
            let filtered_ids: Vec<String> = g
                .tab_ids
                .iter()
                .filter(|id| valid_ids.contains(id.as_str()) && seen.insert(id.as_str()))
                .cloned()
                .collect();
            // 只有分组内还有 tab 时才保留分组
            if !filtered_ids.is_empty() || self.groups.iter().any(|existing| existing.id == g.id) {
                // 如果分组本身存在（即使变空了），也保留它（用户只是把 tab 移走了）
                // 但如果是全新的空分组，就不创建了
                let _ = self.groups.iter().any(|existing| existing.id == g.id);
            }
            new_groups.push(TabGroup {
                id: g.id.clone(),
                name: g.name.clone(),
                tab_ids: filtered_ids,
            });
        }

        // 未分组 tab：过滤掉不存在的和已经在分组里的
        let mut new_ungrouped: Vec<String> = snapshot
            .ungrouped_tab_ids
            .iter()
            .filter(|id| valid_ids.contains(id.as_str()) && seen.insert(id.as_str()))
            .cloned()
            .collect();

        // 确保所有活跃 tab 都被放置（追加未出现的到 ungrouped）
        for tab in &self.tabs {
            if !seen.contains(tab.id.as_str()) {
                new_ungrouped.push(tab.id.clone());
            }
        }

        self.groups = new_groups;
        self.ungrouped_tab_ids = new_ungrouped;
    }

    /// 返回显示顺序的标签页 id：按分组顺序输出各组标签页，再输出未分组标签页。
    pub fn display_order(&self) -> Vec<String> {
        let mut order = Vec::new();
        for group in &self.groups {
            for tab_id in &group.tab_ids {
                if self.tabs.iter().any(|t| t.id == *tab_id) {
                    order.push(tab_id.clone());
                }
            }
        }
        for tab_id in &self.ungrouped_tab_ids {
            if self.tabs.iter().any(|t| t.id == *tab_id) {
                order.push(tab_id.clone());
            }
        }
        order
    }

    /// 查询标签页所在分组 id；未分组返回 None。
    pub fn group_id_for_tab(&self, tab_id: &str) -> Option<&str> {
        self.groups
            .iter()
            .find(|g| g.tab_ids.iter().any(|id| id == tab_id))
            .map(|g| g.id.as_str())
    }

    /// 将 tab_id 移动到 before_tab_id 之前（同一容器内：同分组或均未分组）。
    /// 跨容器为 no-op。两个 tab 相同或不存在时也为 no-op。
    /// 返回是否实际发生了移动。
    pub fn reorder_tab_before(&mut self, tab_id: &str, before_tab_id: &str) -> bool {
        if tab_id == before_tab_id {
            return false;
        }
        // 先取 group_id 的拥有所有权副本，避免后续借用冲突
        let gid_a = self.group_id_for_tab(tab_id).map(|s| s.to_string());
        let gid_b = self.group_id_for_tab(before_tab_id).map(|s| s.to_string());

        match (gid_a.as_ref(), gid_b.as_ref()) {
            // 两个 tab 都在同一分组
            (Some(ga), Some(gb)) if ga == gb => {
                if let Some(group) = self.groups.iter_mut().find(|g| &g.id == ga) {
                    move_in_vec(&mut group.tab_ids, tab_id, before_tab_id)
                } else {
                    false
                }
            }
            // 两个 tab 都未分组
            (None, None) => move_in_vec(&mut self.ungrouped_tab_ids, tab_id, before_tab_id),
            // 跨分组或一个在组内一个未分组 → no-op
            _ => false,
        }
    }

    fn remove_tab_from_any_group(&mut self, tab_id: &str) {
        for group in &mut self.groups {
            group.tab_ids.retain(|id| id != tab_id);
        }
    }

    // -- 内部方法 --

    fn close_tab_internal(&mut self, tab_id: &str) {
        if let Some(index) = self.tabs.iter().position(|t| t.id == tab_id) {
            self.tabs.remove(index);
            self.terminal_sessions.remove(tab_id);
            if self.active_tab_id.as_deref() == Some(tab_id) {
                let remaining_ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
                self.active_tab_id = next_active_tab_after_close(&remaining_ids, index);
            }
            self.ungrouped_tab_ids.retain(|id| id != tab_id);
            for group in &mut self.groups {
                group.tab_ids.retain(|id| id != tab_id);
            }
            self.groups.retain(|g| !g.is_empty());
        }
    }

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

    fn close_all_internal(&mut self) {
        let ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
        for id in ids {
            self.close_tab_internal(&id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_tab(id: &str, host_id: &str, kind: TabKind) -> WorkspaceTab {
        WorkspaceTab {
            id: id.to_string(),
            host_id: host_id.to_string(),
            kind,
            title: String::new(),
            connection_status: ConnectionStatus::Inactive,
        }
    }

    // -----------------------------------------------------------------------
    // 标题消歧
    // -----------------------------------------------------------------------

    #[test]
    fn single_tab_has_no_suffix() {
        let tabs = vec![make_tab("1", "server", TabKind::Terminal)];
        let names = |_id: &str| -> Option<String> { Some("server".to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["server"]);
    }

    #[test]
    fn same_host_multiple_tabs_get_numbered() {
        let tabs = vec![
            make_tab("1", "server", TabKind::Terminal),
            make_tab("2", "server", TabKind::Terminal),
            make_tab("3", "server", TabKind::Sftp),
        ];
        let names = |_id: &str| -> Option<String> { Some("server".to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["server", "server (2)", "server (3)"]);
    }

    #[test]
    fn different_hosts_have_independent_numbering() {
        let tabs = vec![
            make_tab("1", "serverA", TabKind::Terminal),
            make_tab("2", "serverB", TabKind::Terminal),
            make_tab("3", "serverA", TabKind::Terminal),
        ];
        let names = |id: &str| -> Option<String> { Some(id.to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["serverA", "serverB", "serverA (2)"]);
    }

    #[test]
    fn closing_middle_tab_preserves_remaining_titles() {
        // 初始：server, server (2), server (3)。关闭中间页签后，第三个页签
        // 仍是创建时获得的 server (3)，而不是按剩余列表重编号为 server (2)。
        let tabs = vec![
            make_tab("1", "server", TabKind::Terminal),
            WorkspaceTab {
                title: "server (3)".to_string(),
                ..make_tab("3", "server", TabKind::Terminal)
            },
        ];
        let names = |_id: &str| -> Option<String> { Some("server".to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["server", "server (3)"]);
    }

    #[test]
    fn empty_title_uses_smallest_unused_suffix_for_its_host() {
        let tabs = vec![
            WorkspaceTab {
                title: "server".to_string(),
                ..make_tab("1", "server", TabKind::Terminal)
            },
            WorkspaceTab {
                title: "server (3)".to_string(),
                ..make_tab("2", "server", TabKind::Terminal)
            },
            make_tab("3", "server", TabKind::Sftp),
            make_tab("4", "other", TabKind::Terminal),
        ];
        let names = |id: &str| -> Option<String> { Some(id.to_string()) };

        let titles = compute_disambiguated_titles(&tabs, &names);

        assert_eq!(titles, vec!["server", "server (3)", "server (2)", "other"]);
    }

    #[test]
    fn unknown_host_falls_back_to_host_id() {
        let tabs = vec![make_tab("1", "host-uuid-123", TabKind::Terminal)];
        let names = |_id: &str| -> Option<String> { None };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["host-uuid-123"]);
    }

    #[test]
    fn empty_tabs_returns_empty_titles() {
        let tabs: Vec<WorkspaceTab> = vec![];
        let names = |_id: &str| -> Option<String> { Some("x".to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert!(titles.is_empty());
    }

    // -----------------------------------------------------------------------
    // 连接状态聚合
    // -----------------------------------------------------------------------

    #[test]
    fn aggregate_connected_wins_over_all() {
        let statuses = vec![
            ConnectionStatus::Failed,
            ConnectionStatus::Connected,
            ConnectionStatus::Connecting,
        ];
        assert_eq!(
            aggregate_connection_status(&statuses),
            ConnectionStatus::Connected
        );
    }

    #[test]
    fn aggregate_connecting_wins_over_failed_and_inactive() {
        let statuses = vec![
            ConnectionStatus::Inactive,
            ConnectionStatus::Failed,
            ConnectionStatus::Connecting,
        ];
        assert_eq!(
            aggregate_connection_status(&statuses),
            ConnectionStatus::Connecting
        );
    }

    #[test]
    fn aggregate_failed_wins_over_inactive() {
        let statuses = vec![ConnectionStatus::Inactive, ConnectionStatus::Failed];
        assert_eq!(
            aggregate_connection_status(&statuses),
            ConnectionStatus::Failed
        );
    }

    #[test]
    fn aggregate_empty_is_inactive() {
        assert_eq!(aggregate_connection_status(&[]), ConnectionStatus::Inactive);
    }

    #[test]
    fn aggregate_single_inactive() {
        assert_eq!(
            aggregate_connection_status(&[ConnectionStatus::Inactive]),
            ConnectionStatus::Inactive
        );
    }

    // -----------------------------------------------------------------------
    // 活动标签选择
    // -----------------------------------------------------------------------

    #[test]
    fn next_active_prefers_left_neighbor() {
        // 关闭索引 1 ("b")，剩余 ["a", "c"]，应选索引 0 ("a")
        assert_eq!(
            next_active_tab_after_close(&["a".to_string(), "c".to_string()], 1),
            Some("a".to_string())
        );
    }

    #[test]
    fn next_active_first_tab_selects_right_neighbor() {
        let ids = vec!["b".to_string(), "c".to_string()];
        // 关闭索引 0 ("a" 已移除)，剩余 ["b", "c"]，应选索引 0 ("b")
        assert_eq!(next_active_tab_after_close(&ids, 0), Some("b".to_string()));
    }

    #[test]
    fn next_active_empty_returns_none() {
        let empty: Vec<String> = vec![];
        assert_eq!(next_active_tab_after_close(&empty, 0), None);
    }

    #[test]
    fn next_active_last_tab_selects_left() {
        let ids = vec!["a".to_string(), "b".to_string()];
        // 关闭最后一个（索引 2，原数组 [a,b,c]），剩余 [a,b]，选索引 1 ("b")
        assert_eq!(next_active_tab_after_close(&ids, 2), Some("b".to_string()));
    }

    // -----------------------------------------------------------------------
    // ConnectionStatus priority
    // -----------------------------------------------------------------------

    #[test]
    fn priority_ordering() {
        assert!(ConnectionStatus::Connected.priority() > ConnectionStatus::Connecting.priority());
        assert!(ConnectionStatus::Connecting.priority() > ConnectionStatus::Failed.priority());
        assert!(ConnectionStatus::Failed.priority() > ConnectionStatus::Inactive.priority());
    }

    // -----------------------------------------------------------------------
    // 终端会话状态机
    // -----------------------------------------------------------------------

    fn make_session(id: &str, host_id: &str) -> TerminalSessionState {
        TerminalSessionState::new(id.to_string(), host_id.to_string())
    }

    // -- 初始状态 --

    #[test]
    fn terminal_session_initial_state_is_connecting() {
        let session = make_session("tab-1", "host-1");
        assert_eq!(session.phase, TerminalPhase::Connecting);
        assert_eq!(session.attempt, 0);
        assert_eq!(session.failure_category, None);
        assert_eq!(session.failure_message, None);
    }

    // -- 状态转换：connecting → shell --

    #[test]
    fn transition_to_shell_from_connecting() {
        let session = make_session("tab-1", "host-1");
        let result = transition_to_shell(&session).unwrap();
        assert_eq!(result.phase, TerminalPhase::Shell);
        assert_eq!(result.attempt, 0);
        assert_eq!(result.failure_category, None);
    }

    #[test]
    fn transition_to_shell_from_shell_is_invalid() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Shell,
            ..make_session("tab-1", "host-1")
        };
        assert!(transition_to_shell(&session).is_none());
    }

    #[test]
    fn transition_to_shell_from_failed_is_invalid() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Failed,
            failure_category: Some(TerminalFailureCategory::Timeout),
            failure_message: Some("timeout".into()),
            ..make_session("tab-1", "host-1")
        };
        assert!(transition_to_shell(&session).is_none());
    }

    // -- 状态转换：任意 → failed --

    #[test]
    fn transition_to_failed_from_connecting() {
        let session = make_session("tab-1", "host-1");
        let result = transition_to_failed(
            &session,
            TerminalFailureCategory::Timeout,
            "连接超时".into(),
        );
        assert_eq!(result.phase, TerminalPhase::Failed);
        assert_eq!(
            result.failure_category,
            Some(TerminalFailureCategory::Timeout)
        );
        assert_eq!(result.failure_message, Some("连接超时".into()));
        assert_eq!(result.attempt, 0);
    }

    #[test]
    fn transition_to_failed_from_shell() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Shell,
            ..make_session("tab-1", "host-1")
        };
        let result = transition_to_failed(
            &session,
            TerminalFailureCategory::Other,
            "连接异常断开".into(),
        );
        assert_eq!(result.phase, TerminalPhase::Failed);
        assert_eq!(
            result.failure_category,
            Some(TerminalFailureCategory::Other)
        );
    }

    #[test]
    fn transition_to_failed_from_failed_overwrites() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Failed,
            failure_category: Some(TerminalFailureCategory::Timeout),
            failure_message: Some("旧错误".into()),
            ..make_session("tab-1", "host-1")
        };
        let result = transition_to_failed(
            &session,
            TerminalFailureCategory::AuthFailed,
            "新错误".into(),
        );
        assert_eq!(
            result.failure_category,
            Some(TerminalFailureCategory::AuthFailed)
        );
        assert_eq!(result.failure_message, Some("新错误".into()));
    }

    // -- 状态转换：failed → connecting（重试）--

    #[test]
    fn transition_to_connecting_from_failed_increments_attempt() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Failed,
            failure_category: Some(TerminalFailureCategory::Timeout),
            failure_message: Some("超时".into()),
            attempt: 0,
            ..make_session("tab-1", "host-1")
        };
        let result = transition_to_connecting(&session).unwrap();
        assert_eq!(result.phase, TerminalPhase::Connecting);
        assert_eq!(result.attempt, 1);
        assert_eq!(result.failure_category, None);
        assert_eq!(result.failure_message, None);
    }

    #[test]
    fn transition_to_connecting_from_connecting_is_invalid() {
        let session = make_session("tab-1", "host-1");
        assert!(transition_to_connecting(&session).is_none());
    }

    #[test]
    fn transition_to_connecting_from_shell_is_invalid() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Shell,
            ..make_session("tab-1", "host-1")
        };
        assert!(transition_to_connecting(&session).is_none());
    }

    #[test]
    fn multiple_retries_increment_attempt() {
        let session = make_session("tab-1", "host-1");
        // 第一次失败
        let failed1 =
            transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
        assert_eq!(failed1.attempt, 0);
        // 第一次重试
        let retry1 = transition_to_connecting(&failed1).unwrap();
        assert_eq!(retry1.attempt, 1);
        // 第二次失败
        let failed2 = transition_to_failed(
            &retry1,
            TerminalFailureCategory::AuthFailed,
            "认证失败".into(),
        );
        assert_eq!(failed2.attempt, 1);
        // 第二次重试
        let retry2 = transition_to_connecting(&failed2).unwrap();
        assert_eq!(retry2.attempt, 2);
    }

    // -- 代际追踪（过期检测）--

    #[test]
    fn is_stale_returns_false_when_generation_matches() {
        let session = make_session("tab-1", "host-1");
        assert!(!is_stale(&session, 0));
    }

    #[test]
    fn is_stale_returns_true_when_generation_differs() {
        let session = TerminalSessionState {
            attempt: 2,
            ..make_session("tab-1", "host-1")
        };
        assert!(is_stale(&session, 0));
        assert!(is_stale(&session, 1));
        assert!(!is_stale(&session, 2));
    }

    #[test]
    fn stale_detection_after_retry() {
        let session = make_session("tab-1", "host-1");
        // 代次 0 发起握手
        let request_generation = session.attempt;
        // 握手期间用户重试
        let failed =
            transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
        let retried = transition_to_connecting(&failed).unwrap();
        // 旧握手结果到达，应被判定为过期
        assert!(is_stale(&retried, request_generation));
    }

    // -- Shell 退出分类 --

    #[test]
    fn classify_shell_exit_normal_exit() {
        let result = classify_shell_exit(None);
        assert!(result.is_normal_exit);
        assert_eq!(result.failure_category, TerminalFailureCategory::Other);
    }

    #[test]
    fn classify_shell_exit_session_closed() {
        let result = classify_shell_exit(Some("shell session closed"));
        assert!(!result.is_normal_exit);
        assert_eq!(result.failure_category, TerminalFailureCategory::Other);
    }

    #[test]
    fn classify_shell_exit_timeout() {
        let result = classify_shell_exit(Some("connection timed out"));
        assert!(!result.is_normal_exit);
        assert_eq!(result.failure_category, TerminalFailureCategory::Timeout);
    }

    #[test]
    fn classify_shell_exit_auth_failed() {
        let result = classify_shell_exit(Some("authentication failed"));
        assert!(!result.is_normal_exit);
        assert_eq!(result.failure_category, TerminalFailureCategory::AuthFailed);
    }

    #[test]
    fn classify_shell_exit_host_key_mismatch() {
        let result = classify_shell_exit(Some("host key verification failed"));
        assert!(!result.is_normal_exit);
        assert_eq!(
            result.failure_category,
            TerminalFailureCategory::HostKeyMismatch
        );
    }

    #[test]
    fn classify_shell_exit_unknown_error() {
        let result = classify_shell_exit(Some("something unexpected happened"));
        assert!(!result.is_normal_exit);
        assert_eq!(result.failure_category, TerminalFailureCategory::Other);
    }

    // -- 完整生命周期 --

    #[test]
    fn full_lifecycle_connecting_failed_retry_connecting_shell() {
        // 初始：connecting
        let session = make_session("tab-1", "host-1");
        assert_eq!(session.phase, TerminalPhase::Connecting);
        assert_eq!(session.attempt, 0);

        // 连接失败
        let failed =
            transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
        assert_eq!(failed.phase, TerminalPhase::Failed);
        assert_eq!(failed.attempt, 0);

        // 重试
        let retry = transition_to_connecting(&failed).unwrap();
        assert_eq!(retry.phase, TerminalPhase::Connecting);
        assert_eq!(retry.attempt, 1);

        // 连接成功
        let shell = transition_to_shell(&retry).unwrap();
        assert_eq!(shell.phase, TerminalPhase::Shell);
        assert_eq!(shell.attempt, 1);
    }

    #[test]
    fn full_lifecycle_with_stale_handshake() {
        // 初始：connecting，代次 0
        let session = make_session("tab-1", "host-1");
        let gen0 = session.attempt;

        // 连接失败
        let failed = transition_to_failed(
            &session,
            TerminalFailureCategory::AuthFailed,
            "认证失败".into(),
        );

        // 重试，代次变为 1
        let retry = transition_to_connecting(&failed).unwrap();
        assert_eq!(retry.attempt, 1);

        // 代次 0 的握手结果到达，应被判定为过期
        assert!(is_stale(&retry, gen0));

        // 代次 1 的握手结果到达，应为有效
        assert!(!is_stale(&retry, retry.attempt));
    }

    // -----------------------------------------------------------------------
    // WorkspaceService 测试
    // -----------------------------------------------------------------------

    fn ws() -> WorkspaceService {
        WorkspaceService::new()
    }

    fn ws_with_host(host_id: &str, name: &str) -> WorkspaceService {
        let mut svc = ws();
        svc.update_host_names(vec![(host_id.to_string(), name.to_string())]);
        svc
    }

    // -- 正常流程：开/选/关 --

    #[test]
    fn ws_open_tab_adds_tab_and_sets_active() {
        let mut svc = ws_with_host("h1", "server1");
        let tab = svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal).unwrap();
        assert_eq!(tab.id, "t1");
        assert_eq!(tab.title, "server1");
        assert_eq!(svc.active_tab_id(), Some("t1"));
        assert_eq!(svc.tab_list().len(), 1);
    }

    #[test]
    fn ws_open_multiple_tabs_gets_disambiguated_titles() {
        let mut svc = ws_with_host("h1", "server1");
        let t1 = svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal).unwrap();
        let t2 = svc.open_tab("t2".into(), "h1".into(), TabKind::Sftp).unwrap();
        let t3 = svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal).unwrap();
        assert_eq!(t1.title, "server1");
        assert_eq!(t2.title, "server1 (2)");
        assert_eq!(t3.title, "server1 (3)");
        assert_eq!(svc.active_tab_id(), Some("t3"));
    }

    #[test]
    fn ws_title_is_fixed_at_creation_and_does_not_change() {
        let mut svc = ws_with_host("h1", "server1");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        let t3 = svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal).unwrap();
        assert_eq!(t3.title, "server1 (3)");
        // 关闭中间标签后，t3 的标题保持不变
        svc.close_tab_internal("t2");
        let tabs = svc.tab_list();
        assert_eq!(tabs[0].title, "server1");
        assert_eq!(tabs[1].title, "server1 (3)");
    }

    #[test]
    fn ws_select_tab_changes_active() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        assert_eq!(svc.active_tab_id(), Some("t2"));
        assert!(svc.select_tab("t1"));
        assert_eq!(svc.active_tab_id(), Some("t1"));
    }

    #[test]
    fn ws_close_non_connected_terminal_closes_immediately() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let result = svc.request_close("t1");
        assert_eq!(result, CloseResult::Closed);
        assert!(svc.tab_list().is_empty());
        assert_eq!(svc.active_tab_id(), None);
    }

    #[test]
    fn ws_close_sftp_always_closes_immediately() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Sftp);
        // 即使报告为 connected，SFTP 也不需要确认
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        let result = svc.request_close("t1");
        assert_eq!(result, CloseResult::Closed);
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn ws_close_connected_terminal_requires_confirmation() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        let result = svc.request_close("t1");
        assert_eq!(result, CloseResult::PendingConfirmation);
        // 标签页仍在
        assert_eq!(svc.tab_list().len(), 1);
        // 确认后才关闭
        svc.confirm_close();
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn ws_cancel_close_keeps_tab() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        svc.request_close("t1");
        svc.cancel_close();
        assert_eq!(svc.tab_list().len(), 1);
        assert!(svc.pending_close_info().is_none());
    }

    // -- 正常流程：逻辑顺序与连接聚合 --

    #[test]
    fn ws_tab_order_preserved() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        let ids: Vec<String> = svc.tab_list().iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids, vec!["t1", "t2", "t3"]);
    }

    #[test]
    fn ws_host_connection_status_aggregated() {
        let mut svc = ws();
        svc.update_host_names(vec![
            ("h1".into(), "s1".into()),
            ("h2".into(), "s2".into()),
        ]);
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Sftp);
        svc.open_tab("t3".into(), "h2".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        svc.report_connection_status("t2", ConnectionStatus::Connecting);
        assert_eq!(svc.host_connection_status("h1"), ConnectionStatus::Connected);
        assert_eq!(svc.host_connection_status("h2"), ConnectionStatus::Connecting);
    }

    #[test]
    fn ws_connection_status_updates_terminal_connected_flag() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        // 初始 terminal_connected = false
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        // 现在关闭需要确认
        assert_eq!(
            svc.request_close("t1"),
            CloseResult::PendingConfirmation
        );
        svc.cancel_close();
        // 断开后关闭不需要确认
        svc.report_connection_status("t1", ConnectionStatus::Failed);
        assert_eq!(svc.request_close("t1"), CloseResult::Closed);
    }

    // -- 正常流程：批量关闭 --

    #[test]
    fn ws_close_others_no_connected_closes_immediately() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        let result = svc.request_close_others("t2");
        assert_eq!(result, CloseResult::Closed);
        assert_eq!(svc.tab_list().len(), 1);
        assert_eq!(svc.tab_list()[0].id, "t2");
        assert_eq!(svc.active_tab_id(), Some("t2"));
    }

    #[test]
    fn ws_close_others_with_connected_requires_confirmation() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        let result = svc.request_close_others("t2");
        assert_eq!(result, CloseResult::PendingConfirmation);
        let info = svc.pending_close_info().unwrap();
        assert_eq!(info.tab_ids, vec!["t1"]);
        assert_eq!(info.connected_terminal_count, 1);
        svc.confirm_close();
        assert_eq!(svc.tab_list().len(), 1);
        assert_eq!(svc.tab_list()[0].id, "t2");
    }

    #[test]
    fn ws_close_all_no_connected_closes_immediately() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Sftp);
        let result = svc.request_close_all();
        assert_eq!(result, CloseResult::Closed);
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn ws_close_all_with_connected_requires_confirmation() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        svc.report_connection_status("t2", ConnectionStatus::Connected);
        let result = svc.request_close_all();
        assert_eq!(result, CloseResult::PendingConfirmation);
        let info = svc.pending_close_info().unwrap();
        assert_eq!(info.connected_terminal_count, 2);
        assert_eq!(info.tab_ids.len(), 2);
    }

    // -- 意外流程 --

    #[test]
    fn ws_close_unknown_tab_returns_closed() {
        let mut svc = ws();
        let result = svc.request_close("nonexistent");
        assert_eq!(result, CloseResult::Closed);
    }

    #[test]
    fn ws_select_unknown_tab_returns_false() {
        let mut svc = ws();
        assert!(!svc.select_tab("nonexistent"));
        assert_eq!(svc.active_tab_id(), None);
    }

    #[test]
    fn ws_report_status_unknown_tab_is_noop() {
        let mut svc = ws();
        svc.report_connection_status("nonexistent", ConnectionStatus::Connected);
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn ws_confirm_close_without_pending_is_noop() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.confirm_close();
        assert_eq!(svc.tab_list().len(), 1);
    }

    #[test]
    fn ws_pending_close_info_none_when_no_pending() {
        let svc = ws();
        assert!(svc.pending_close_info().is_none());
    }

    #[test]
    fn ws_terminal_session_stale_for_unknown_tab() {
        let svc = ws();
        assert!(svc.terminal_session_is_stale("nonexistent", 0));
    }

    // -- 边界条件 --

    #[test]
    fn ws_empty_workspace_has_no_active_tab() {
        let svc = ws();
        assert_eq!(svc.active_tab_id(), None);
        assert!(svc.tab_list().is_empty());
        assert_eq!(
            svc.host_connection_status("any"),
            ConnectionStatus::Inactive
        );
    }

    #[test]
    fn ws_close_active_tab_selects_left_neighbor() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.select_tab("t2");
        svc.close_tab_internal("t2");
        assert_eq!(svc.active_tab_id(), Some("t1"));
    }

    #[test]
    fn ws_close_first_tab_selects_right_neighbor() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.close_tab_internal("t1");
        assert_eq!(svc.active_tab_id(), Some("t2"));
    }

    #[test]
    fn ws_close_last_tab_selects_left() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.close_tab_internal("t3");
        assert_eq!(svc.active_tab_id(), Some("t2"));
    }

    #[test]
    fn ws_close_only_tab_clears_active() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.close_tab_internal("t1");
        assert_eq!(svc.active_tab_id(), None);
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn ws_close_non_active_tab_does_not_change_active() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.select_tab("t2");
        svc.close_tab_internal("t1");
        assert_eq!(svc.active_tab_id(), Some("t2"));
    }

    #[test]
    fn ws_unknown_host_falls_back_to_host_id_in_service() {
        let mut svc = ws();
        let tab = svc.open_tab("t1".into(), "uuid-123".into(), TabKind::Terminal).unwrap();
        assert_eq!(tab.title, "uuid-123");
    }

    #[test]
    fn ws_reset_clears_all_state() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.reset();
        assert!(svc.tab_list().is_empty());
        assert_eq!(svc.active_tab_id(), None);
        assert!(svc.pending_close_info().is_none());
        assert!(svc.terminal_session_get("t1").is_none());
    }

    #[test]
    fn ws_close_tab_also_removes_terminal_session() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        assert!(svc.terminal_session_get("t1").is_some());
        svc.close_tab_internal("t1");
        assert!(svc.terminal_session_get("t1").is_none());
    }

    // -- WorkspaceService 终端会话管理 --

    #[test]
    fn ws_terminal_session_lifecycle_through_service() {
        let mut svc = ws_with_host("h1", "s");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let session = svc.terminal_session_register("h1".into(), "t1".into());
        assert_eq!(session.phase, TerminalPhase::Connecting);
        assert_eq!(session.attempt, 0);

        svc.terminal_session_transition_to_shell("t1");
        assert_eq!(
            svc.terminal_session_get("t1").unwrap().phase,
            TerminalPhase::Shell
        );

        svc.terminal_session_transition_to_failed(
            "t1",
            TerminalFailureCategory::Timeout,
            "超时".into(),
        );
        assert_eq!(
            svc.terminal_session_get("t1").unwrap().phase,
            TerminalPhase::Failed
        );

        let retry = svc.terminal_session_retry("t1").unwrap();
        assert_eq!(retry.phase, TerminalPhase::Connecting);
        assert_eq!(retry.attempt, 1);

        assert!(!svc.terminal_session_is_stale("t1", 1));
        assert!(svc.terminal_session_is_stale("t1", 0));

        svc.terminal_session_close("t1");
        assert!(svc.terminal_session_get("t1").is_none());
    }

    #[test]
    fn ws_terminal_session_retry_unknown_returns_none() {
        let mut svc = ws();
        assert!(svc.terminal_session_retry("nonexistent").is_none());
    }

    #[test]
    fn ws_host_name_update_is_incremental() {
        let mut svc = ws();
        svc.update_host_names(vec![("h1".into(), "server1".into())]);
        let tab1 = svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal).unwrap();
        assert_eq!(tab1.title, "server1");

        svc.update_host_names(vec![("h2".into(), "server2".into())]);
        let tab2 = svc.open_tab("t2".into(), "h2".into(), TabKind::Terminal).unwrap();
        assert_eq!(tab2.title, "server2");
        // h1 的映射仍然存在，t1 初始状态为 Connecting
        assert_eq!(svc.host_connection_status("h1"), ConnectionStatus::Connecting);
    }

    // -- 10.3 关闭确认与会话资源集成 --

    #[test]
    fn ws_close_connected_terminal_confirms_and_cleans_session() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        assert_eq!(svc.request_close("t1"), CloseResult::PendingConfirmation);
        assert!(svc.terminal_session_get("t1").is_some());

        svc.confirm_close();
        assert!(svc.tab_list().is_empty());
        assert!(svc.terminal_session_get("t1").is_none());
    }

    #[test]
    fn ws_cancel_close_preserves_session() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        svc.request_close("t1");
        svc.cancel_close();

        assert_eq!(svc.tab_list().len(), 1);
        assert!(svc.terminal_session_get("t1").is_some());
    }

    #[test]
    fn ws_batch_close_confirms_and_cleans_all_sessions() {
        let mut svc = ws();
        svc.update_host_names(vec![("h1".into(), "s1".into()), ("h2".into(), "s2".into())]);
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h2".into(), TabKind::Sftp);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.terminal_session_register("h1".into(), "t2".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        assert_eq!(svc.request_close_all(), CloseResult::PendingConfirmation);
        let info = svc.pending_close_info().unwrap();
        assert_eq!(info.connected_terminal_count, 1);
        assert_eq!(info.tab_ids.len(), 3);

        svc.confirm_close();
        assert!(svc.tab_list().is_empty());
        assert!(svc.terminal_session_get("t1").is_none());
        assert!(svc.terminal_session_get("t2").is_none());
    }

    #[test]
    fn ws_close_others_confirms_and_cleans_target_sessions() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.terminal_session_register("h1".into(), "t2".into());
        svc.terminal_session_register("h1".into(), "t3".into());
        svc.report_connection_status("t2", ConnectionStatus::Connected);

        assert_eq!(svc.request_close_others("t1"), CloseResult::PendingConfirmation);
        svc.confirm_close();

        assert_eq!(svc.tab_list().len(), 1);
        assert_eq!(svc.tab_list()[0].id, "t1");
        assert!(svc.terminal_session_get("t1").is_some());
        assert!(svc.terminal_session_get("t2").is_none());
        assert!(svc.terminal_session_get("t3").is_none());
    }

    #[test]
    fn ws_reconnect_during_close_confirmation_preserves_intent() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        svc.request_close("t1");
        assert!(svc.pending_close_info().is_some());

        // 用户在确认期间重试连接（状态变 Failed 再回 Connected）
        svc.report_connection_status("t1", ConnectionStatus::Failed);
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        // 确认关闭仍然有效
        svc.confirm_close();
        assert!(svc.tab_list().is_empty());
        assert!(svc.terminal_session_get("t1").is_none());
    }

    #[test]
    fn ws_new_tab_during_close_confirmation_not_affected() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        svc.request_close("t1");

        // 确认前用户打开新标签
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t2".into());

        svc.confirm_close();
        // t1 被关闭，t2 保留
        assert_eq!(svc.tab_list().len(), 1);
        assert_eq!(svc.tab_list()[0].id, "t2");
        assert!(svc.terminal_session_get("t1").is_none());
        assert!(svc.terminal_session_get("t2").is_some());
    }

    #[test]
    fn ws_sftp_close_does_not_affect_terminal_sessions() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Sftp);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        svc.report_connection_status("t2", ConnectionStatus::Connected);

        // 关闭 SFTP 标签不需要确认，不影响终端会话
        assert_eq!(svc.request_close("t2"), CloseResult::Closed);
        assert_eq!(svc.tab_list().len(), 1);
        assert!(svc.terminal_session_get("t1").is_some());
    }

    #[test]
    fn ws_close_disconnected_terminal_cleans_session_immediately() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.report_connection_status("t1", ConnectionStatus::Failed);

        assert_eq!(svc.request_close("t1"), CloseResult::Closed);
        assert!(svc.tab_list().is_empty());
        assert!(svc.terminal_session_get("t1").is_none());
    }

    #[test]
    fn ws_confirm_without_pending_is_noop() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());

        svc.confirm_close();
        assert_eq!(svc.tab_list().len(), 1);
        assert!(svc.terminal_session_get("t1").is_some());
    }

    #[test]
    fn ws_close_captures_target_set_at_request_time() {
        let mut svc = ws_with_host("h1", "server");
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t1".into());
        svc.terminal_session_register("h1".into(), "t2".into());
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        svc.request_close_all();
        let info = svc.pending_close_info().unwrap();
        assert_eq!(info.tab_ids.len(), 2);

        // 确认前新标签加入，不应被关闭
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.terminal_session_register("h1".into(), "t3".into());

        svc.confirm_close();
        assert_eq!(svc.tab_list().len(), 1);
        assert_eq!(svc.tab_list()[0].id, "t3");
        assert!(svc.terminal_session_get("t3").is_some());
    }

    // -----------------------------------------------------------------------
    // 分组管理
    // -----------------------------------------------------------------------

    #[test]
    fn group_create_default_name_assigns_tab() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let gid = svc.create_group("t1", None);
        let snap = svc.group_snapshot();
        assert_eq!(snap.groups.len(), 1);
        assert_eq!(snap.groups[0].name, "分组 1");
        assert_eq!(snap.groups[0].tab_ids, vec!["t1"]);
        assert!(snap.ungrouped_tab_ids.is_empty());
        assert_eq!(svc.group_id_for_tab("t1"), Some(gid.as_str()));
    }

    #[test]
    fn group_create_custom_name() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.create_group("t1", Some("生产".into()));
        assert_eq!(svc.group_snapshot().groups[0].name, "生产");
    }

    #[test]
    fn group_delete_empty_removes_group() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let gid = svc.create_group("t1", None);
        svc.remove_tab_from_group("t1");
        // 手动移除最后一个成员后分组不为空（Swift 语义：移出时保留空组）
        // 但 delete_group 应正常工作
        svc.delete_group(&gid);
        assert!(svc.group_snapshot().groups.is_empty());
    }

    #[test]
    fn group_delete_non_empty_moves_tabs_to_ungrouped() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        let gid = svc.create_group("t1", None);
        svc.move_tab_to_group("t2", &gid);
        svc.delete_group(&gid);
        let snap = svc.group_snapshot();
        assert!(snap.groups.is_empty());
        assert_eq!(snap.ungrouped_tab_ids, vec!["t1", "t2"]);
    }

    #[test]
    fn group_rename() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let gid = svc.create_group("t1", None);
        svc.rename_group(&gid, "测试");
        assert_eq!(svc.group_snapshot().groups[0].name, "测试");
    }

    #[test]
    fn group_move_tab_between_groups() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        let g1 = svc.create_group("t1", Some("A".into()));
        let g2 = svc.create_group("t2", Some("B".into()));
        svc.move_tab_to_group("t1", &g2);
        let snap = svc.group_snapshot();
        assert!(snap.groups[0].tab_ids.is_empty());
        assert_eq!(snap.groups[1].tab_ids, vec!["t2", "t1"]);
        assert_eq!(svc.group_id_for_tab("t1"), Some(g2.as_str()));
        let _ = g1;
    }

    #[test]
    fn group_remove_tab_becomes_ungrouped() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.create_group("t1", None);
        svc.remove_tab_from_group("t1");
        let snap = svc.group_snapshot();
        assert!(snap.groups[0].tab_ids.is_empty());
        assert_eq!(snap.ungrouped_tab_ids, vec!["t1"]);
    }

    #[test]
    fn group_delete_nonexistent_is_noop() {
        let mut svc = WorkspaceService::new();
        svc.delete_group("nonexistent");
        assert!(svc.group_snapshot().groups.is_empty());
    }

    #[test]
    fn group_rename_nonexistent_is_noop() {
        let mut svc = WorkspaceService::new();
        svc.rename_group("nonexistent", "x");
        assert!(svc.group_snapshot().groups.is_empty());
    }

    #[test]
    fn group_move_tab_to_nonexistent_group_is_noop() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.move_tab_to_group("t1", "nonexistent");
        assert_eq!(svc.group_snapshot().ungrouped_tab_ids, vec!["t1"]);
    }

    #[test]
    fn group_auto_increment_names() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        svc.create_group("t1", None);
        svc.create_group("t2", None);
        svc.create_group("t3", None);
        let snap = svc.group_snapshot();
        assert_eq!(snap.groups[0].name, "分组 1");
        assert_eq!(snap.groups[1].name, "分组 2");
        assert_eq!(snap.groups[2].name, "分组 3");
    }

    #[test]
    fn group_empty_auto_cleanup_on_tab_close() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.create_group("t1", None);
        assert_eq!(svc.group_snapshot().groups.len(), 1);
        svc.request_close("t1");
        assert!(svc.group_snapshot().groups.is_empty());
    }

    #[test]
    fn group_display_order_groups_then_ungrouped() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t2".into(), "h1".into(), TabKind::Terminal);
        svc.open_tab("t3".into(), "h1".into(), TabKind::Terminal);
        let gid = svc.create_group("t2", None);
        svc.move_tab_to_group("t3", &gid);
        let order = svc.display_order();
        assert_eq!(order, vec!["t2", "t3", "t1"]);
    }

    #[test]
    fn group_new_tab_starts_ungrouped() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        let snap = svc.group_snapshot();
        assert!(snap.groups.is_empty());
        assert_eq!(snap.ungrouped_tab_ids, vec!["t1"]);
    }

    #[test]
    fn group_reset_clears_all() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.create_group("t1", None);
        svc.reset();
        let snap = svc.group_snapshot();
        assert!(snap.groups.is_empty());
        assert!(snap.ungrouped_tab_ids.is_empty());
    }

    // -----------------------------------------------------------------------
    // 应用停机
    // -----------------------------------------------------------------------

    #[test]
    fn shutdown_force_closes_connected_terminals() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        svc.open_tab("t2".into(), "h2".into(), TabKind::Sftp);

        let summary = svc.begin_application_shutdown();

        assert!(svc.tab_list().is_empty());
        assert_eq!(summary.closed_tab_count, 2);
        assert!(!svc.is_accepting_new_work());
    }

    #[test]
    fn shutdown_rejects_new_tabs() {
        let mut svc = WorkspaceService::new();
        svc.begin_application_shutdown();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn shutdown_clears_pending_close() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        let result = svc.request_close_all();
        assert_eq!(result, CloseResult::PendingConfirmation);
        assert!(svc.pending_close_info().is_some());

        svc.begin_application_shutdown();

        assert!(svc.pending_close_info().is_none());
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn shutdown_is_idempotent() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);

        let first = svc.begin_application_shutdown();
        let second = svc.begin_application_shutdown();

        assert_eq!(first.closed_tab_count, 1);
        assert_eq!(second.closed_tab_count, 0);
    }

    #[test]
    fn shutdown_with_no_tabs() {
        let mut svc = WorkspaceService::new();
        let summary = svc.begin_application_shutdown();
        assert_eq!(summary.closed_tab_count, 0);
        assert!(!svc.is_accepting_new_work());
    }

    #[test]
    fn shutdown_with_pending_single_close() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);
        let result = svc.request_close("t1");
        assert_eq!(result, CloseResult::PendingConfirmation);
        assert!(svc.pending_close_info().is_some());

        let summary = svc.begin_application_shutdown();

        assert_eq!(summary.closed_tab_count, 1);
        assert!(svc.pending_close_info().is_none());
        assert!(svc.tab_list().is_empty());
    }

    #[test]
    fn shutdown_confirm_close_is_noop() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.begin_application_shutdown();
        assert!(svc.tab_list().is_empty());

        svc.confirm_close();

        assert!(svc.tab_list().is_empty());
        assert!(svc.pending_close_info().is_none());
    }

    #[test]
    fn shutdown_request_close_returns_closed() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.begin_application_shutdown();

        let result = svc.request_close("t1");
        assert_eq!(result, CloseResult::Closed);
    }

    #[test]
    fn reset_restores_accepting_new_work() {
        let mut svc = WorkspaceService::new();
        svc.begin_application_shutdown();
        assert!(!svc.is_accepting_new_work());

        svc.reset();

        assert!(svc.is_accepting_new_work());
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        assert_eq!(svc.tab_list().len(), 1);
    }

    #[test]
    fn shutdown_marks_terminals_inactive() {
        let mut svc = WorkspaceService::new();
        svc.open_tab("t1".into(), "h1".into(), TabKind::Terminal);
        svc.report_connection_status("t1", ConnectionStatus::Connected);

        svc.begin_application_shutdown();

        assert!(svc.tab_list().is_empty());
        assert!(!svc.is_accepting_new_work());
    }
}
