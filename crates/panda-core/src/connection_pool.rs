//! SSH 连接缓存：按 (host_id, credentials) 复用 `SshSession` 以减少重复握手。
//!
//! 与传统连接池不同，本缓存不设空闲超时——连接持久存活，直到：
//! - 被 `disconnect_host` 显式移除（用户关闭最后一个同主机标签页时）
//! - 在 `get_or_create` 的惰性存活检测中被发现已失效

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use tokio::sync::Mutex;

use crate::config::HostConfig;
use crate::hostkey::KnownHosts;
use crate::ssh::{Credentials, SshSession, UnknownHostKeyPolicy};
use crate::Result;

/// 连接缓存的键：同一主机 + 同一凭据才能复用。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct PoolKey {
    host_id: String,
    creds: Credentials,
}

/// 缓存条目。
pub(crate) struct PoolEntry {
    session: Arc<SshSession>,
}

/// 全局连接缓存。
pub struct ConnectionPool {
    entries: Arc<Mutex<HashMap<PoolKey, PoolEntry>>>,
}

impl ConnectionPool {
    /// 创建空连接缓存。
    pub fn new() -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 从缓存中获取已有会话，或新建并放入缓存中。
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
                    return Ok(Arc::clone(&entry.session));
                }
                // 已失效，移除。
                entries.remove(&key);
            }
        }

        // 新建连接。
        let session = Arc::new(SshSession::connect(cfg, creds, known_hosts, policy).await?);

        // 放入缓存中。
        let mut entries = self.entries.lock().await;
        entries.insert(
            key,
            PoolEntry {
                session: Arc::clone(&session),
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

    /// 移除某主机的全部会话条目。当用户关闭最后一个指向该主机的标签页时调用。
    /// 若此时有其他代码持有 `Arc<SshSession>`，会话在最后一个引用释放后断开。
    pub async fn disconnect_host(&self, host_id: &str) {
        let mut entries = self.entries.lock().await;
        entries.retain(|key, _| key.host_id != host_id);
    }

    /// 返回当前缓存中条目数量（主要用于测试与调试）。
    pub async fn len(&self) -> usize {
        self.entries.lock().await.len()
    }
}

/// 全局单例连接缓存。
static GLOBAL_POOL: OnceLock<ConnectionPool> = OnceLock::new();

pub fn global_pool() -> &'static ConnectionPool {
    GLOBAL_POOL.get_or_init(ConnectionPool::new)
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

    #[tokio::test]
    async fn disconnect_host_on_empty_pool_is_noop() {
        let pool = ConnectionPool::new();
        // 空池 disconnect 不 panic
        pool.disconnect_host("h1").await;
        assert_eq!(pool.len().await, 0);
    }
}
