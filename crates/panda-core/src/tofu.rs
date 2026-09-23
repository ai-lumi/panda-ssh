//! TOFU（首次信任）并发协调器。
//!
//! 管理未知主机密钥的确认请求：同一主机+端口+密钥的多个并发连接
//! 共享一次用户确认。核心负责状态跟踪、等待者管理和结果分发；
//! UI 只展示呈现密钥并回传用户选择。

use std::collections::HashMap;
use std::sync::{mpsc, Mutex};

use crate::hostkey::KnownHosts;
use crate::Error;

/// TOFU 确认请求的呈现密钥信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PresentedKeyInfo {
    /// 主机地址。
    pub host: String,
    /// 端口。
    pub port: u16,
    /// OpenSSH 公钥串。
    pub key: String,
    /// SHA256 指纹。
    pub fingerprint: String,
}

/// TOFU 注册结果：首个呈现者需展示确认 UI，后续等待者阻塞直到结果。
#[derive(Debug)]
pub enum TofuRegistration {
    /// 首个请求者：应展示确认 UI。
    Presenter {
        request_id: String,
        presented: PresentedKeyInfo,
    },
    /// 后续请求者：等待已有确认的结果。
    Waiter { result: mpsc::Receiver<TofuOutcome> },
}

/// TOFU 确认结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TofuOutcome {
    /// 用户信任并已写入 known_hosts。
    Trusted,
    /// 用户拒绝。
    Rejected,
    /// 呈现者取消或等待者被中断。
    Cancelled,
}

struct PendingTofu {
    request_id: String,
    presented: PresentedKeyInfo,
    /// 等待结果的发送端；每个等待者（含呈现者）持有一个。
    waiters: Vec<mpsc::SyncSender<TofuOutcome>>,
}

/// TOFU 并发协调器：管理待确认请求和等待者。
pub struct TofuCoordinator {
    pending: Mutex<HashMap<String, PendingTofu>>,
    next_id: Mutex<u64>,
}

impl TofuCoordinator {
    pub fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            next_id: Mutex::new(1),
        }
    }

    /// 注册一个 TOFU 确认请求。
    ///
    /// 同一 `(host, port, key)` 只产生一个待确认项；后续注册者成为等待者，
    /// 通过返回的 `mpsc::Receiver` 阻塞获取结果。
    pub fn register(
        &self,
        host: String,
        port: u16,
        key: String,
        fingerprint: String,
    ) -> TofuRegistration {
        let mut pending = self.pending.lock().unwrap();

        for existing in pending.values() {
            if existing.presented.host == host
                && existing.presented.port == port
                && existing.presented.key == key
            {
                let (tx, rx) = mpsc::sync_channel(1);
                let existing_mut = pending.values_mut().find(|p| {
                    p.presented.host == host
                        && p.presented.port == port
                        && p.presented.key == key
                }).unwrap();
                existing_mut.waiters.push(tx);
                return TofuRegistration::Waiter { result: rx };
            }
        }

        let mut next_id = self.next_id.lock().unwrap();
        let request_id = format!("tofu-{}", *next_id);
        *next_id += 1;
        drop(next_id);

        let (tx, _presenter_rx) = mpsc::sync_channel(1);
        let presented = PresentedKeyInfo {
            host,
            port,
            key,
            fingerprint,
        };
        let presenter_presented = presented.clone();
        let presenter_request_id = request_id.clone();
        pending.insert(
            presenter_request_id.clone(),
            PendingTofu {
                request_id,
                presented,
                waiters: vec![tx],
            },
        );

        TofuRegistration::Presenter {
            request_id: presenter_request_id,
            presented: presenter_presented,
        }
    }

    /// 确认信任：将密钥写入 known_hosts 并通知所有等待者。
    ///
    /// 写入失败时通知所有等待者为 `Cancelled` 并返回错误。
    /// 未知 request_id 返回错误且不产生副作用。
    pub fn confirm(
        &self,
        request_id: &str,
        known_hosts: &KnownHosts,
    ) -> std::result::Result<(), Error> {
        let entry = {
            let mut pending = self.pending.lock().unwrap();
            pending.remove(request_id)
        };

        let Some(entry) = entry else {
            return Err(Error::Other(format!("未知 TOFU 请求: {request_id}")));
        };

        match known_hosts.accept(&entry.presented.host, entry.presented.port, &entry.presented.key) {
            Ok(()) => {
                for tx in &entry.waiters {
                    let _ = tx.send(TofuOutcome::Trusted);
                }
                Ok(())
            }
            Err(e) => {
                for tx in &entry.waiters {
                    let _ = tx.send(TofuOutcome::Cancelled);
                }
                Err(e)
            }
        }
    }

    /// 拒绝信任：通知所有等待者为 `Rejected`。
    ///
    /// 未知 request_id 为静默无操作（幂等）。
    pub fn reject(&self, request_id: &str) {
        let entry = {
            let mut pending = self.pending.lock().unwrap();
            pending.remove(request_id)
        };

        if let Some(entry) = entry {
            for tx in &entry.waiters {
                let _ = tx.send(TofuOutcome::Rejected);
            }
        }
    }

    /// 取消请求（呈现者关闭等场景）。
    ///
    /// 通知所有等待者为 `Cancelled`。若无人等待则为静默无操作。
    pub fn cancel(&self, request_id: &str) {
        let entry = {
            let mut pending = self.pending.lock().unwrap();
            pending.remove(request_id)
        };

        if let Some(entry) = entry {
            for tx in &entry.waiters {
                let _ = tx.send(TofuOutcome::Cancelled);
            }
        }
    }

    /// 查询当前待确认请求的快照。
    pub fn pending_requests(&self) -> Vec<(String, PresentedKeyInfo)> {
        let pending = self.pending.lock().unwrap();
        pending
            .values()
            .map(|e| (e.request_id.clone(), e.presented.clone()))
            .collect()
    }

    /// 检查指定请求是否仍在等待。
    pub fn is_pending(&self, request_id: &str) -> bool {
        let pending = self.pending.lock().unwrap();
        pending.contains_key(request_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tempfile::tempdir;

    const KEY_A: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample";
    const KEY_B: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChanged";

    fn make_known_hosts() -> (tempfile::TempDir, KnownHosts) {
        let dir = tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        (dir, kh)
    }

    // MARK: - 正常流程

    #[test]
    fn single_registration_returns_presenter() {
        let coord = TofuCoordinator::new();
        let result = coord.register(
            "example.com".into(),
            22,
            KEY_A.into(),
            "SHA256:test".into(),
        );
        match result {
            TofuRegistration::Presenter { request_id, presented } => {
                assert!(request_id.starts_with("tofu-"));
                assert_eq!(presented.host, "example.com");
                assert_eq!(presented.port, 22);
                assert_eq!(presented.key, KEY_A);
            }
            _ => panic!("首次注册应返回 Presenter"),
        }
    }

    #[test]
    fn concurrent_connections_share_one_confirmation() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let second_rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("同主机同密钥的后续注册应为 Waiter"),
        };

        let third = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let third_rx = match third {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("第三个注册也应为 Waiter"),
        };

        // 只有一项待确认。
        assert_eq!(coord.pending_requests().len(), 1);

        // 确认后所有等待者收到 Trusted。
        coord.confirm(&request_id, &kh).unwrap();
        assert_eq!(second_rx.recv().unwrap(), TofuOutcome::Trusted);
        assert_eq!(third_rx.recv().unwrap(), TofuOutcome::Trusted);

        // known_hosts 已写入。
        assert!(matches!(
            kh.check("host", 22, KEY_A).unwrap(),
            crate::hostkey::HostKeyStatus::Match
        ));
    }

    #[test]
    fn presenter_also_receives_trusted_via_waiter_channel() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        // 呈现者也通过 waiter 通道接收结果。
        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("应为 Waiter"),
        };

        coord.confirm(&request_id, &kh).unwrap();
        assert_eq!(rx.recv().unwrap(), TofuOutcome::Trusted);
    }

    // MARK: - 意外操作

    #[test]
    fn reject_notifies_all_waiters() {
        let coord = TofuCoordinator::new();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("应为 Waiter"),
        };

        coord.reject(&request_id);
        assert_eq!(rx.recv().unwrap(), TofuOutcome::Rejected);
        assert!(!coord.is_pending(&request_id));
    }

    #[test]
    fn confirm_unknown_request_returns_error() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let result = coord.confirm("nonexistent", &kh);
        assert!(result.is_err());
    }

    #[test]
    fn reject_unknown_request_is_silent_noop() {
        let coord = TofuCoordinator::new();
        coord.reject("nonexistent");
        assert!(coord.pending_requests().is_empty());
    }

    #[test]
    fn key_change_invalidates_old_confirmation() {
        let coord = TofuCoordinator::new();
        let (_dir, _kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp-a".into());
        let id_a = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let second = coord.register("host".into(), 22, KEY_A.into(), "fp-a".into());
        let waiter_rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("应为 Waiter"),
        };

        // 密钥变化：取消旧确认，新密钥产生新请求。
        coord.cancel(&id_a);
        assert_eq!(waiter_rx.recv().unwrap(), TofuOutcome::Cancelled);

        let new_reg = coord.register("host".into(), 22, KEY_B.into(), "fp-b".into());
        match new_reg {
            TofuRegistration::Presenter { request_id, presented } => {
                assert_ne!(request_id, id_a);
                assert_eq!(presented.key, KEY_B);
            }
            _ => panic!("新密钥应产生新的 Presenter"),
        }

        // 旧请求不再存在。
        assert!(!coord.is_pending(&id_a));
        assert_eq!(coord.pending_requests().len(), 1);
    }

    #[test]
    fn store_failure_notifies_cancelled_and_returns_error() {
        let coord = TofuCoordinator::new();
        // 使用一个不可写的路径来模拟存储失败。
        let kh = KnownHosts::new("/dev/null/impossible/known_hosts".into());

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("应为 Waiter"),
        };

        let result = coord.confirm(&request_id, &kh);
        assert!(result.is_err());
        assert_eq!(rx.recv().unwrap(), TofuOutcome::Cancelled);
    }

    // MARK: - 边界条件

    #[test]
    fn presenter_close_allows_new_presenter() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let id1 = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        // 呈现者关闭（取消）。
        coord.cancel(&id1);

        // 新的呈现者可以注册。
        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let id2 = match second {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("取消后新注册应为 Presenter"),
        };
        assert_ne!(id1, id2);

        // 新呈现者可以确认。
        coord.confirm(&id2, &kh).unwrap();
    }

    #[test]
    fn cancel_with_no_waiters_is_silent() {
        let coord = TofuCoordinator::new();
        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        // 取消不 panic。
        coord.cancel(&request_id);
        assert!(!coord.is_pending(&request_id));
    }

    #[test]
    fn duplicate_confirm_after_first_is_noop() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        coord.confirm(&request_id, &kh).unwrap();
        // 第二次确认为未知请求。
        assert!(coord.confirm(&request_id, &kh).is_err());
    }

    #[test]
    fn late_confirm_after_cancel_returns_error() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        coord.cancel(&request_id);
        assert!(coord.confirm(&request_id, &kh).is_err());
    }

    #[test]
    fn different_ports_are_separate_entries() {
        let coord = TofuCoordinator::new();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let second = coord.register("host".into(), 2222, KEY_A.into(), "fp".into());

        match (first, second) {
            (
                TofuRegistration::Presenter { .. },
                TofuRegistration::Presenter { .. },
            ) => {}
            other => panic!("不同端口应产生独立请求，得到 {:?}", 
                matches!(other.0, TofuRegistration::Presenter { .. }),
            ),
        }

        assert_eq!(coord.pending_requests().len(), 2);
    }

    #[test]
    fn different_hosts_are_separate_entries() {
        let coord = TofuCoordinator::new();

        let first = coord.register("host-a".into(), 22, KEY_A.into(), "fp".into());
        let second = coord.register("host-b".into(), 22, KEY_A.into(), "fp".into());

        match (first, second) {
            (
                TofuRegistration::Presenter { .. },
                TofuRegistration::Presenter { .. },
            ) => {}
            _ => panic!("不同主机应产生独立请求"),
        }

        assert_eq!(coord.pending_requests().len(), 2);
    }

    #[test]
    fn waiter_does_not_hang_when_presenter_drops_without_resolve() {
        let coord = TofuCoordinator::new();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let second = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let rx = match second {
            TofuRegistration::Waiter { result } => result,
            _ => panic!("应为 Waiter"),
        };

        // 模拟呈现者消失（不调用 confirm/reject，直接 cancel）。
        coord.cancel(&request_id);

        // 等待者不应悬挂：收到 Cancelled。
        let outcome = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(outcome, TofuOutcome::Cancelled);
    }

    #[test]
    fn multiple_waiters_all_receive_same_outcome() {
        let coord = TofuCoordinator::new();
        let (_dir, kh) = make_known_hosts();

        let first = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
        let request_id = match first {
            TofuRegistration::Presenter { request_id, .. } => request_id,
            _ => panic!("首次应为 Presenter"),
        };

        let mut receivers = Vec::new();
        for _ in 0..5 {
            let reg = coord.register("host".into(), 22, KEY_A.into(), "fp".into());
            match reg {
                TofuRegistration::Waiter { result } => receivers.push(result),
                _ => panic!("后续注册应为 Waiter"),
            }
        }

        coord.confirm(&request_id, &kh).unwrap();

        for rx in &receivers {
            assert_eq!(rx.recv_timeout(Duration::from_secs(1)).unwrap(), TofuOutcome::Trusted);
        }
    }
}
