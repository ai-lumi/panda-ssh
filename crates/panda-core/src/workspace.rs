//! 工作区标签页数据类型与纯算法。
//!
//! 本模块只包含与平台无关的数据结构和标题消歧算法；
//! 全局状态管理（标签页列表、活动标签、关闭确认）由 panda-ffi 层持有。

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
}

/// 批量关闭范围。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BatchCloseScope {
    /// 关闭除 keeping 外的所有标签页。
    Others { keeping: String },
    /// 关闭全部标签页。
    All,
}

/// 待处理的批量关闭请求。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingBatchClose {
    pub scope: BatchCloseScope,
    pub connected_terminal_count: u32,
}

/// 为同主机多标签页计算消歧标题。
///
/// 规则：按 `tabs` 数组顺序遍历，同一 `host_id` 第一个标签不带序号，
/// 后续追加 `(2)`、`(3)` 等。`host_name_provider` 查不到主机名时回退为 `host_id`。
///
/// 返回与 `tabs` 等长的标题 `Vec`。
pub fn compute_disambiguated_titles(
    tabs: &[WorkspaceTab],
    host_name_provider: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    let mut counts: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut titles = Vec::with_capacity(tabs.len());

    for tab in tabs {
        let base = host_name_provider(&tab.host_id).unwrap_or_else(|| tab.host_id.clone());
        let ordinal = counts.entry(tab.host_id.clone()).or_insert(0);
        *ordinal += 1;
        let title = if *ordinal == 1 {
            base
        } else {
            format!("{base} ({ordinal})")
        };
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
            let category = if msg.contains("shell session closed") || msg.contains("ShellSessionClosed") {
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
    fn closing_middle_tab_renumbers_remaining() {
        // 初始：server, server (2), server (3)
        // 关闭 server (2) 后：server, server (2)
        let tabs = vec![
            make_tab("1", "server", TabKind::Terminal),
            make_tab("3", "server", TabKind::Terminal),
        ];
        let names = |_id: &str| -> Option<String> { Some("server".to_string()) };
        let titles = compute_disambiguated_titles(&tabs, &names);
        assert_eq!(titles, vec!["server", "server (2)"]);
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
        assert_eq!(aggregate_connection_status(&statuses), ConnectionStatus::Connected);
    }

    #[test]
    fn aggregate_connecting_wins_over_failed_and_inactive() {
        let statuses = vec![
            ConnectionStatus::Inactive,
            ConnectionStatus::Failed,
            ConnectionStatus::Connecting,
        ];
        assert_eq!(aggregate_connection_status(&statuses), ConnectionStatus::Connecting);
    }

    #[test]
    fn aggregate_failed_wins_over_inactive() {
        let statuses = vec![ConnectionStatus::Inactive, ConnectionStatus::Failed];
        assert_eq!(aggregate_connection_status(&statuses), ConnectionStatus::Failed);
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
        let result = transition_to_failed(&session, TerminalFailureCategory::Timeout, "连接超时".into());
        assert_eq!(result.phase, TerminalPhase::Failed);
        assert_eq!(result.failure_category, Some(TerminalFailureCategory::Timeout));
        assert_eq!(result.failure_message, Some("连接超时".into()));
        assert_eq!(result.attempt, 0);
    }

    #[test]
    fn transition_to_failed_from_shell() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Shell,
            ..make_session("tab-1", "host-1")
        };
        let result = transition_to_failed(&session, TerminalFailureCategory::Other, "连接异常断开".into());
        assert_eq!(result.phase, TerminalPhase::Failed);
        assert_eq!(result.failure_category, Some(TerminalFailureCategory::Other));
    }

    #[test]
    fn transition_to_failed_from_failed_overwrites() {
        let session = TerminalSessionState {
            phase: TerminalPhase::Failed,
            failure_category: Some(TerminalFailureCategory::Timeout),
            failure_message: Some("旧错误".into()),
            ..make_session("tab-1", "host-1")
        };
        let result = transition_to_failed(&session, TerminalFailureCategory::AuthFailed, "新错误".into());
        assert_eq!(result.failure_category, Some(TerminalFailureCategory::AuthFailed));
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
        let failed1 = transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
        assert_eq!(failed1.attempt, 0);
        // 第一次重试
        let retry1 = transition_to_connecting(&failed1).unwrap();
        assert_eq!(retry1.attempt, 1);
        // 第二次失败
        let failed2 = transition_to_failed(&retry1, TerminalFailureCategory::AuthFailed, "认证失败".into());
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
        let failed = transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
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
        assert_eq!(result.failure_category, TerminalFailureCategory::HostKeyMismatch);
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
        let failed = transition_to_failed(&session, TerminalFailureCategory::Timeout, "超时".into());
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
        let failed = transition_to_failed(&session, TerminalFailureCategory::AuthFailed, "认证失败".into());

        // 重试，代次变为 1
        let retry = transition_to_connecting(&failed).unwrap();
        assert_eq!(retry.attempt, 1);

        // 代次 0 的握手结果到达，应被判定为过期
        assert!(is_stale(&retry, gen0));

        // 代次 1 的握手结果到达，应为有效
        assert!(!is_stale(&retry, retry.attempt));
    }
}
