## MODIFIED Requirements

### Requirement: 标签页标题消歧

同一主机存在多个标签页时，系统 SHALL 在标签页标题中添加区分标识，MUST NOT 出现两个无法区分的同名标签。系统 MUST 在页签创建时确定标题；该标题在该页签保持打开期间 SHALL 保持不变，且 MUST NOT 因关闭其他页签、拖拽排序、调整分组或读取页签列表而改变。

#### Scenario: 同主机多标签编号

- **GIVEN** 工作区中已存在某主机的一个或多个标签页
- **WHEN** 用户再次为该主机打开标签页
- **THEN** 各标签页标题带序号等区分标识（如「web-prod (2)」）

#### Scenario: 关闭较早的同主机页签

- **GIVEN** 同一主机的三个打开页签标题依次为「web-prod」、「web-prod (2)」和「web-prod (3)」
- **WHEN** 用户关闭「web-prod」或「web-prod (2)」
- **THEN** 所有仍打开页签保留其关闭前的标题

#### Scenario: 重排或分组同主机页签

- **GIVEN** 同一主机存在多个带消歧标题的打开页签
- **WHEN** 用户拖拽重排页签或将页签移入、移出分组
- **THEN** 各页签标题保持不变
