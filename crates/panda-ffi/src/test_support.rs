//! 仅供 crate 单元测试使用的进程级全局状态串行锁。

use std::sync::{Mutex, MutexGuard};

static GLOBAL_TEST_LOCK: Mutex<()> = Mutex::new(());

pub(crate) type GlobalTestGuard = MutexGuard<'static, ()>;

pub(crate) fn global_test_lock() -> GlobalTestGuard {
    GLOBAL_TEST_LOCK.lock().unwrap()
}
