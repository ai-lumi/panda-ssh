//! SSH 连接池：按 (host_id, credentials) 复用 `SshSession` 以减少重复握手。

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::Mutex;

use crate::config::HostConfig;
use crate::hostkey::KnownHosts;
use crate::ssh::{Credentials, SshSession, UnknownHostKeyPolicy};
use crate::Result;

/// 空闲超时：会话最后一次被使用后 30 秒未再使用则回收。
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// 后台扫描间隔。
const CHECK_INTERVAL: Duration = Duration::from_secs(5);

/// 连接池的键：同一主机 + 同一凭据才能复用。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct PoolKey {
    host_id: String,
    creds: Credentials,
}

/// 池内条目。
pub(crate) struct PoolEntry {
    session: Arc<SshSession>,
    last_used: Instant,
}

/// 全局连接池。
pub struct ConnectionPool {
    entries: Arc<Mutex<HashMap<PoolKey, PoolEntry>>>,
}

impl ConnectionPool {
    /// 创建空连接池（不会自动启动回收任务；需调用 `start_cleanup_task`）。
    pub fn new() -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 从池中获取已有会话，或新建并放入池中。
    ///
    /// 复用前通过 `open_channel()` 检测会话活性；若已断开则自动移除并重建。
    pub async fn get_or_create(
        &self,
        host_id: String,
        cfg: &HostConfig,
        creds: Credentials,
        known_hosts: &mut KnownHosts,
        policy: UnknownHostKeyPolicy,
    ) -> Result<Arc<SshSession>> {
        let key = PoolKey {
            host_id,
            creds: creds.clone(),
        };

        // 尝试复用。
        {
            let mut entries = self.entries.lock().await;
            if let Some(entry) = entries.get_mut(&key) {
                // 惰性检测：尝试开一条新频道验证会话是否仍存活。
                if entry.session.open_channel().await.is_ok() {
                    entry.last_used = Instant::now();
                    return Ok(Arc::clone(&entry.session));
                }
                // 已失效，移除。
                entries.remove(&key);
            }
        }

        // 新建连接。
        let session = Arc::new(SshSession::connect(cfg, creds, known_hosts, policy).await?);

        // 放入池中。
        let mut entries = self.entries.lock().await;
        entries.insert(
            key,
            PoolEntry {
                session: Arc::clone(&session),
                last_used: Instant::now(),
            },
        );

        Ok(session)
    }

    /// 显式移除某 key 对应的会话（例如用户主动断开标签时）。
    pub async fn remove(&self, host_id: &str, creds: &Credentials) {
        let key = PoolKey {
            host_id: host_id.to_string(),
            creds: creds.clone(),
        };
        let mut entries = self.entries.lock().await;
        entries.remove(&key);
    }

    /// 启动后台超时回收任务。
    pub fn start_cleanup_task(&self) {
        let entries = Arc::clone(&self.entries);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(CHECK_INTERVAL).await;
                Self::cleanup_stale_entries(&entries).await;
            }
        });
    }

    /// 扫描并移除超时会话（供后台任务与测试直接调用）。
    pub(crate) async fn cleanup_stale_entries(entries: &Arc<Mutex<HashMap<PoolKey, PoolEntry>>>) {
        let mut guard = entries.lock().await;
        let now = Instant::now();
        let stale: Vec<PoolKey> = guard
            .iter()
            .filter(|(_, entry)| now.duration_since(entry.last_used) > IDLE_TIMEOUT)
            .map(|(key, _)| key.clone())
            .collect();
        for key in stale {
            guard.remove(&key);
        }
    }

    /// 返回当前池中条目数量（主要用于测试与调试）。
    pub async fn len(&self) -> usize {
        self.entries.lock().await.len()
    }
}

/// 全局单例连接池；首次访问时自动启动回收任务。
static GLOBAL_POOL: OnceLock<ConnectionPool> = OnceLock::new();

pub fn global_pool() -> &'static ConnectionPool {
    GLOBAL_POOL.get_or_init(|| {
        let pool = ConnectionPool::new();
        pool.start_cleanup_task();
        pool
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ssh::Credentials;

    #[test]
    fn pool_key_equality() {
        let k1 = PoolKey {
            host_id: "h1".to_string(),
            creds: Credentials::Password("pass".to_string()),
        };
        let k2 = PoolKey {
            host_id: "h1".to_string(),
            creds: Credentials::Password("pass".to_string()),
        };
        let k3 = PoolKey {
            host_id: "h1".to_string(),
            creds: Credentials::Password("wrong".to_string()),
        };
        assert_eq!(k1, k2);
        assert_ne!(k1, k3);
    }

    #[test]
    fn pool_key_hash_consistent() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let k1 = PoolKey {
            host_id: "h1".to_string(),
            creds: Credentials::Password("pass".to_string()),
        };
        let k2 = PoolKey {
            host_id: "h1".to_string(),
            creds: Credentials::Password("pass".to_string()),
        };
        let mut s1 = DefaultHasher::new();
        k1.hash(&mut s1);
        let mut s2 = DefaultHasher::new();
        k2.hash(&mut s2);
        assert_eq!(s1.finish(), s2.finish());
    }

}
