## ADDED Requirements

### Requirement: 显式连接所有权

系统 SHALL 为终端标签、SFTP 标签和后台传输分别建立由该所有者独占的 SSH Transport。不同所有者即使连接同一主机并使用相同凭据，也 MUST NOT 隐式共享 Socket。系统 MAY 维护仅用于查找、监控和精确关闭的活动连接注册表，但该注册表 MUST NOT 缓存或复用连接。

#### Scenario: 同一主机的两个终端独立建连

- **WHEN** 用户为同一主机打开两个终端标签
- **THEN** 系统建立两条独立 SSH Transport，每个标签仅拥有其中一条

#### Scenario: 终端与 SFTP 不共享 Socket

- **WHEN** 用户已打开某主机的终端标签，随后打开同一主机的 SFTP 标签
- **THEN** SFTP 标签建立自己的 SSH Transport，MUST NOT 复用终端标签的 Socket

### Requirement: 按连接标识精确关闭

系统 SHALL 按稳定的运行时连接标识释放指定所有者的连接，MUST NOT 因关闭一个终端、SFTP 标签或传输任务而按主机批量关闭其他连接。关闭操作 SHALL 具备幂等性。

#### Scenario: 关闭一个终端不影响同主机其他终端

- **GIVEN** 同一主机有两个已连接终端标签
- **WHEN** 其中一个终端执行 `exit` 或被用户关闭
- **THEN** 系统只关闭该终端拥有的 Channel 与 Socket，另一个终端保持可交互

#### Scenario: 重复关闭同一连接

- **WHEN** 同一连接标识被连续关闭两次
- **THEN** 第二次关闭安全返回，且 MUST NOT 关闭其他连接

### Requirement: 空闲连接与保活

已认证连接 SHALL NOT 因没有业务流量而被客户端 inactivity timeout 关闭。系统 SHALL 使用 SSH keepalive 及有限失败次数判定不可用；未发生 EOF、读写错误或 keepalive 失败的无流量连接 MUST 报告为空闲而非异常。

#### Scenario: 空闲超过三十秒

- **GIVEN** 已认证连接没有终端输入、输出或文件传输
- **WHEN** 连接空闲超过三十秒且 keepalive 正常
- **THEN** 连接保持存活并报告为空闲，MUST NOT 因 inactivity timeout 被关闭

## MODIFIED Requirements

### Requirement: 连接失效检测与重连

系统 SHALL 根据 EOF、Socket 读写错误、SSH keepalive 连续失败或通道打开失败检测指定连接失效，并将失效状态同步给其唯一所有者。系统 MUST NOT 自动为其他所有者替换连接；用户触发终端重试时 SHALL 为该标签只提交一次建连并建立一条新 Transport。

#### Scenario: 失效连接被标记

- **WHEN** 某终端拥有的连接因网络中断失效
- **THEN** 系统将该终端标记为不可交互并保留可重试入口，且同主机其他独立连接状态不变

#### Scenario: 单次重试只建立一条连接

- **GIVEN** 一个已关闭或失败的终端标签
- **WHEN** 用户点击一次重试
- **THEN** 系统只提交一次建连并为该标签建立一条新 Transport，MUST NOT 出现瞬时重复 Socket

### Requirement: 线程安全

活动连接注册、查找、精确关闭和遥测操作 SHALL 是线程安全的，支持在多线程或多 tokio task 环境下并发访问而不引发数据竞争、重复关闭或所有权串扰。

#### Scenario: 并发建立同一主机的独立连接

- **WHEN** 两个所有者并发请求连接同一主机
- **THEN** 两者分别获得一条有效 Transport，连接标识不同且生命周期互不影响

### Requirement: 连接生命周期遥测

系统 SHALL 为每条新建的传输/SSH 连接分配稳定的运行时连接标识，并在显式关闭、检测失效及最终释放时维护可查询的生命周期状态。遥测 MUST 以实际 Socket I/O、SSH keepalive 与通道事件更新状态，MUST NOT 通过另建连接伪造健康状态。已释放或判定失效的连接 MUST 不再被报告为健康的活动连接。

#### Scenario: 失效连接状态同步

- **GIVEN** 一条 SSH 连接因通道打开失败或 keepalive 连续失败而失效
- **WHEN** 活动连接注册表同步其状态
- **THEN** 后续遥测快照将该连接标记为不可用或不再列为活动连接，且 MUST NOT 将其继续报告为健康

## REMOVED Requirements

### Requirement: 连接复用

**Reason**: 跨所有者全局复用把无关标签和传输耦合到同一 Socket，造成单点关闭和竞态扩散。

**Migration**: 每个终端标签、SFTP 标签和后台传输改为显式持有自己的连接。

### Requirement: 显式断开

**Reason**: 主机级 `disconnect_host` 会批量影响同主机的无关所有者，无法表达精确生命周期。

**Migration**: 调用方保存稳定连接/会话句柄，并按句柄执行幂等关闭。

### Requirement: 多路频道复用

**Reason**: 本产品不再在不同 UI 会话或后台任务之间共享 SSH Transport。

**Migration**: 一个所有者可在自己的 Transport 内使用所需 Channel，但不同所有者必须使用独立 Transport。
