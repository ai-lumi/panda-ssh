# sftp-transfer Specification

## Purpose

基于 russh-sftp 的远程文件操作：目录列举、上传、下载、删除、建目录。SFTP 会话从既有 SSH 会话上开 channel 建立，不单独认证。

## Requirements

### Requirement: 目录列举

系统 SHALL 支持列举远程目录，返回条目包含：名称、完整路径、是否目录、字节大小、修改时间（可选）。

#### Scenario: 列举结果字段完整

- **WHEN** 列举一个含文件与子目录的远程目录
- **THEN** 每个条目都带有名称、路径、类型与大小

### Requirement: 文件传输

系统 SHALL 支持上传与下载；上传 MUST 支持进度回调（已传字节 / 总字节）。

#### Scenario: 上传带进度

- **WHEN** 上传一个本地文件并提供进度回调
- **THEN** 回调按字节递增被调用，完成后远程文件内容与本地一致

#### Scenario: 下载

- **WHEN** 下载一个远程文件到本地路径
- **THEN** 本地文件内容与远程一致

### Requirement: 远程文件管理

系统 SHALL 支持删除文件、删除目录、创建目录。

#### Scenario: 创建再删除

- **WHEN** 创建远程目录后将其删除
- **THEN** 两次操作均成功且目录不再存在
