//! 活动 SSH 连接索引。
//!
//! 该注册表只保存弱引用，供按运行时连接标识执行健康检查；它不按主机或凭据
//! 查找连接，也不参与业务复用，因此不会形成连接池。
//!
//! ## 作用域
//!
//! [`ActiveConnectionRegistry`] 与 [`global_registry`] 是**进程级**单例，独立
//! 于 `PandaCore` 的上下文（存储/工作区）作用域。注册表只持有 `Weak<SshSession>`
//! 引用，读取操作（[`prune`](ActiveConnectionRegistry::prune)、
//! [`check_health`](ActiveConnectionRegistry::check_health)）不会新建连接；
//! `prune` 只清除已释放的弱引用，`check_health` 只对已登记连接做 SSH 探测。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::ssh::SshSession;
use crate::telemetry::HealthState;
use crate::{Error, Result};

#[derive(Default)]
pub struct ActiveConnectionRegistry {
    connections: Mutex<HashMap<u64, Weak<SshSession>>>,
}

impl ActiveConnectionRegistry {
    pub fn register(&self, session: &Arc<SshSession>) {
        self.prune();
        self.lock()
            .insert(session.telemetry_id(), Arc::downgrade(session));
    }

    pub async fn check_health(&self, connection_id: u64) -> Result<HealthState> {
        self.prune();
        let weak = self.lock().get(&connection_id).cloned();
        let Some(session) = weak.and_then(|entry| entry.upgrade()) else {
            self.lock().remove(&connection_id);
            return Err(Error::UnknownConnection(connection_id));
        };
        Ok(session.check_health().await)
    }

    pub fn prune(&self) -> usize {
        let mut connections = self.lock();
        let before = connections.len();
        connections.retain(|_, session| session.strong_count() > 0);
        before - connections.len()
    }

    #[cfg(test)]
    fn contains(&self, connection_id: u64) -> bool {
        self.lock().contains_key(&connection_id)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Weak<SshSession>>> {
        self.connections
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

static GLOBAL: OnceLock<ActiveConnectionRegistry> = OnceLock::new();

pub fn global_registry() -> &'static ActiveConnectionRegistry {
    GLOBAL.get_or_init(ActiveConnectionRegistry::default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unknown_connection_is_not_recreated() {
        let registry = ActiveConnectionRegistry::default();
        assert!(matches!(
            registry.check_health(99).await,
            Err(Error::UnknownConnection(99))
        ));
        assert!(!registry.contains(99));
        assert_eq!(registry.prune(), 0);
    }

    #[tokio::test]
    async fn lookup_prunes_all_expired_entries_without_owning_connections() {
        let registry = ActiveConnectionRegistry::default();
        registry.lock().insert(1, Weak::new());
        registry.lock().insert(2, Weak::new());
        assert!(registry.check_health(1).await.is_err());
        assert!(!registry.contains(2), "查找应惰性清理全部失效弱引用");
    }
}
