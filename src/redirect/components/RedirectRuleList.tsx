import React from 'react';
import {
  AutoComplete,
  Button,
  Dropdown,
  Input,
  Modal,
  Space,
  Switch,
  Table,
  Tooltip,
  Typography,
} from 'antd';
import {
  CopyOutlined,
  DeleteOutlined,
  EditOutlined,
  FolderOpenOutlined,
  CaretRightOutlined,
  RetweetOutlined,
  EllipsisOutlined,
  ApiOutlined,
  CodeOutlined,
  InsertRowAboveOutlined,
  FileSearchOutlined,
  FileDoneOutlined,
  UserOutlined,
  StopOutlined,
  ClockCircleOutlined,
} from '@ant-design/icons';
import { genId } from '../rule-utils';
import type { RedirectGroup, RedirectRule } from '../types';

type GroupModalState = { open: boolean; mode: 'create' | 'rename' | 'move'; groupId?: string; ruleId?: string };

type Props = {
  groups: RedirectGroup[];
  rules: RedirectRule[];
  redirectEnabled: boolean;
  collapsedGroupIds: string[];
  groupModal: GroupModalState;
  groupInput: string;
  setRedirectEnabled: (value: boolean) => void;
  setCollapsedGroupIds: React.Dispatch<React.SetStateAction<string[]>>;
  setGroupModal: React.Dispatch<React.SetStateAction<GroupModalState>>;
  setGroupInput: React.Dispatch<React.SetStateAction<string>>;
  createRule: (ruleType: RedirectRule['type']) => void;
  openRuleDetail: (ruleId: string) => void;
  duplicateGroup: (groupId: string) => void;
  deleteGroup: (groupId: string) => void;
  confirmGroupModal: () => void;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  setGroups: React.Dispatch<React.SetStateAction<RedirectGroup[]>>;
  messageApi: { success: (content: string) => void };
  exportConfig: () => void;
  importConfig: () => void;
};

type GroupRow = { key: string; rowType: 'group'; group: RedirectGroup };
type RuleRow = { key: string; rowType: 'rule'; rule: RedirectRule };
type GroupEmptyRow = { key: string; rowType: 'group-empty'; group: RedirectGroup };
type TableRow = GroupRow | RuleRow | GroupEmptyRow;
type DragState = { ruleId: string; groupId: string };
type DropState = { targetRuleId: string; position: 'before' | 'after' };
type GroupDropState = { groupId: string };
type GroupOverlayRect = { top: number; left: number; width: number; height: number; roundBottom: boolean };

function getRuleEffectiveHint(redirectEnabled: boolean, groupEnabled: boolean, ruleEnabled: boolean) {
  if (!redirectEnabled) return '总开关关闭，当前规则不会生效';
  if (!groupEnabled) return '规则组已关闭，当前规则不会生效';
  if (!ruleEnabled) return '规则已关闭，不会生效';
  return '规则已开启，当前规则会生效';
}

function buildTableData(groups: RedirectGroup[], collapsedGroupIds: string[], displayRules: RedirectRule[]): TableRow[] {
  return groups.flatMap((group) => {
    const groupRow: GroupRow = { key: `group-${group.id}`, rowType: 'group', group };
    if (collapsedGroupIds.includes(group.id)) return [groupRow];

    const ruleRows: RuleRow[] = displayRules
      .filter((rule) => rule.groupId === group.id)
      .map((rule) => ({ key: `rule-${rule.id}`, rowType: 'rule', rule }));

    if (ruleRows.length === 0) {
      return [groupRow, { key: `group-empty-${group.id}`, rowType: 'group-empty', group }];
    }

    return [groupRow, ...ruleRows];
  });
}

function moveRuleWithinGroup(
  rules: RedirectRule[],
  draggedRuleId: string,
  targetRuleId: string,
  position: 'before' | 'after',
) {
  if (draggedRuleId === targetRuleId) return rules;
  const draggedRule = rules.find((rule) => rule.id === draggedRuleId);
  const targetRule = rules.find((rule) => rule.id === targetRuleId);
  if (!draggedRule || !targetRule || draggedRule.groupId !== targetRule.groupId) return rules;

  const groupRules = rules.filter((rule) => rule.groupId === draggedRule.groupId);
  const fromIndex = groupRules.findIndex((rule) => rule.id === draggedRuleId);
  const targetIndex = groupRules.findIndex((rule) => rule.id === targetRuleId);
  if (fromIndex === -1 || targetIndex === -1) return rules;

  const reorderedGroupRules = [...groupRules];
  const [movedRule] = reorderedGroupRules.splice(fromIndex, 1);
  const insertIndex = targetIndex + (position === 'after' ? 1 : 0) - (fromIndex < targetIndex ? 1 : 0);
  reorderedGroupRules.splice(insertIndex, 0, movedRule);

  let groupRuleIndex = 0;
  return rules.map((rule) => (
    rule.groupId === draggedRule.groupId
      ? reorderedGroupRules[groupRuleIndex++]
      : rule
  ));
}

function normalizeDropState(
  rules: RedirectRule[],
  draggedRuleId: string,
  targetRuleId: string,
  position: 'before' | 'after',
): DropState {
  if (position === 'before') return { targetRuleId, position };
  const targetRule = rules.find((rule) => rule.id === targetRuleId);
  if (!targetRule) return { targetRuleId, position };
  const groupRules = rules.filter((rule) => rule.groupId === targetRule.groupId);
  const targetIndex = groupRules.findIndex((rule) => rule.id === targetRuleId);
  const nextRule = groupRules[targetIndex + 1];
  if (!nextRule || nextRule.id === draggedRuleId) return { targetRuleId, position: 'after' };
  return { targetRuleId: nextRule.id, position: 'before' };
}

function moveRuleToGroup(
  rules: RedirectRule[],
  groups: RedirectGroup[],
  draggedRuleId: string,
  targetGroupId: string,
) {
  const draggedRule = rules.find((rule) => rule.id === draggedRuleId);
  if (!draggedRule || draggedRule.groupId === targetGroupId) return rules;

  const remainingRules = rules.filter((rule) => rule.id !== draggedRuleId);
  const movedRule: RedirectRule = { ...draggedRule, groupId: targetGroupId };
  const lastTargetIndex = remainingRules.reduce((lastIndex, rule, index) => (
    rule.groupId === targetGroupId ? index : lastIndex
  ), -1);

  if (lastTargetIndex !== -1) {
    const nextRules = [...remainingRules];
    nextRules.splice(lastTargetIndex + 1, 0, movedRule);
    return nextRules;
  }

  const targetGroupIndex = groups.findIndex((group) => group.id === targetGroupId);
  if (targetGroupIndex === -1) return rules;

  const laterGroupIds = new Set(groups.slice(targetGroupIndex + 1).map((group) => group.id));
  const insertIndex = remainingRules.findIndex((rule) => laterGroupIds.has(rule.groupId));
  const nextRules = [...remainingRules];
  nextRules.splice(insertIndex === -1 ? nextRules.length : insertIndex, 0, movedRule);
  return nextRules;
}

const RULE_TYPE_LABEL_MAP: Record<RedirectRule['type'], string> = {
  redirect_request: '重定向请求',
  rewrite_string: '重写字符串',
  query_params: 'Query参数',
  modify_request_body: '修改请求体',
  modify_response_body: '修改请求响应',
  modify_headers: '修改Headers',
  user_agent: 'User-Agent',
  cancel_request: '取消请求',
  request_delay: '网络请求延迟',
};

const RULE_TYPE_ICON_MAP: Record<RedirectRule['type'], React.ReactNode> = {
  redirect_request: <RetweetOutlined />,
  rewrite_string: <CodeOutlined />,
  query_params: <InsertRowAboveOutlined />,
  modify_request_body: <FileSearchOutlined />,
  modify_response_body: <FileDoneOutlined />,
  modify_headers: <ApiOutlined />,
  user_agent: <UserOutlined />,
  cancel_request: <StopOutlined />,
  request_delay: <ClockCircleOutlined />,
};

export default function RedirectRuleList({
  groups,
  rules,
  redirectEnabled,
  collapsedGroupIds,
  groupModal,
  groupInput,
  setRedirectEnabled,
  setCollapsedGroupIds,
  setGroupModal,
  setGroupInput,
  createRule,
  openRuleDetail,
  duplicateGroup,
  deleteGroup,
  confirmGroupModal,
  setRules,
  setGroups,
  messageApi,
  exportConfig,
  importConfig,
}: Props) {
  const tableWrapperRef = React.useRef<HTMLDivElement | null>(null);
  const [dragState, setDragState] = React.useState<DragState | null>(null);
  const [dropState, setDropState] = React.useState<DropState | null>(null);
  const [groupDropState, setGroupDropState] = React.useState<GroupDropState | null>(null);
  const [groupOverlayRect, setGroupOverlayRect] = React.useState<GroupOverlayRect | null>(null);
  const currentGroupEnabled = new Map(groups.map((g) => [g.id, g.enabled]));
  const groupNameMap = new Map(groups.map((g) => [g.id, g.name]));
  const groupsOptions = groups.map((g) => ({ value: g.name }));

  const tableData = React.useMemo(
    () => buildTableData(groups, collapsedGroupIds, rules),
    [collapsedGroupIds, groups, rules],
  );
  const lastVisibleGroupId = React.useMemo(() => {
    const groupRows = tableData.filter((row): row is GroupRow => row.rowType === 'group');
    return groupRows[groupRows.length - 1]?.group.id ?? null;
  }, [tableData]);

  React.useLayoutEffect(() => {
    if (!groupDropState || !tableWrapperRef.current) {
      setGroupOverlayRect(null);
      return undefined;
    }

    const updateOverlayRect = () => {
      const wrapperEl = tableWrapperRef.current;
      if (!wrapperEl) return;
      const groupRows = wrapperEl.querySelectorAll<HTMLTableRowElement>(`tr[data-group-id="${groupDropState.groupId}"]`);
      const tableContainer = wrapperEl.querySelector<HTMLElement>('.ant-table-container');
      if (!groupRows.length || !tableContainer) {
        setGroupOverlayRect(null);
        return;
      }

      const firstRect = groupRows[0].getBoundingClientRect();
      const lastRect = groupRows[groupRows.length - 1].getBoundingClientRect();
      const wrapperRect = wrapperEl.getBoundingClientRect();
      const containerRect = tableContainer.getBoundingClientRect();

      setGroupOverlayRect({
        top: firstRect.top - wrapperRect.top,
        left: containerRect.left - wrapperRect.left,
        width: containerRect.width,
        height: lastRect.bottom - firstRect.top,
        roundBottom: groupDropState.groupId === lastVisibleGroupId,
      });
    };

    updateOverlayRect();
    window.addEventListener('resize', updateOverlayRect);
    window.addEventListener('scroll', updateOverlayRect, true);
    return () => {
      window.removeEventListener('resize', updateOverlayRect);
      window.removeEventListener('scroll', updateOverlayRect, true);
    };
  }, [groupDropState, lastVisibleGroupId, tableData]);

  const toggleGroupCollapse = (groupId: string) => {
    setCollapsedGroupIds((prev) => {
      if (prev.includes(groupId)) return prev.filter((id) => id !== groupId);
      return [...prev, groupId];
    });
  };

  const handleRedirectEnabledChange = (value: boolean) => {
    setRedirectEnabled(value);
    messageApi.success(value ? '总开关已开启' : '总开关已关闭');
  };

  const handleGroupEnabledChange = (group: RedirectGroup, value: boolean) => {
    setGroups((prev) => prev.map((g) => g.id === group.id ? { ...g, enabled: value } : g));
    messageApi.success(`规则组「${group.name}」已${value ? '开启' : '关闭'}`);
  };

  const handleRuleEnabledChange = (rule: RedirectRule, value: boolean) => {
    setRules((prev) => prev.map((r) => r.id === rule.id ? { ...r, enabled: value } : r));
    messageApi.success(`规则「${rule.name}」已${value ? '开启' : '关闭'}`);
  };

  const clearDragState = () => {
    setDragState(null);
    setDropState(null);
    setGroupDropState(null);
    setGroupOverlayRect(null);
  };

  const handleRuleDragStart = (event: React.DragEvent<HTMLElement>, rule: RedirectRule) => {
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', rule.id);
    setDragState({ ruleId: rule.id, groupId: rule.groupId });
    setDropState(null);
    setGroupDropState(null);
  };

  const handleRuleDragOver = (event: React.DragEvent<HTMLTableRowElement>, row: RuleRow) => {
    if (!dragState || dragState.groupId !== row.rule.groupId || dragState.ruleId === row.rule.id) return;
    event.preventDefault();
    setGroupDropState(null);
    const { top, height } = event.currentTarget.getBoundingClientRect();
    const position = event.clientY - top < height / 2 ? 'before' : 'after';
    const nextDropState = normalizeDropState(rules, dragState.ruleId, row.rule.id, position);
    setDropState((prev) => (
      prev?.targetRuleId === nextDropState.targetRuleId && prev.position === nextDropState.position
        ? prev
        : nextDropState
    ));
  };

  const handleRuleDrop = (event: React.DragEvent<HTMLTableRowElement>, row: RuleRow) => {
    if (!dragState || dragState.groupId !== row.rule.groupId || dragState.ruleId === row.rule.id) {
      clearDragState();
      return;
    }
    event.preventDefault();
    const { top, height } = event.currentTarget.getBoundingClientRect();
    const position = event.clientY - top < height / 2 ? 'before' : 'after';
    setRules((prev) => moveRuleWithinGroup(prev, dragState.ruleId, row.rule.id, position));
    messageApi.success('规则排序已更新');
    clearDragState();
  };

  const handleGroupDragOver = (event: React.DragEvent<HTMLTableRowElement>, groupId: string) => {
    if (!dragState || dragState.groupId === groupId) return;
    event.preventDefault();
    setDropState(null);
    setGroupDropState((prev) => prev?.groupId === groupId ? prev : { groupId });
  };

  const handleGroupDrop = (event: React.DragEvent<HTMLTableRowElement>, groupId: string) => {
    if (!dragState || dragState.groupId === groupId) {
      clearDragState();
      return;
    }
    event.preventDefault();
    setRules((prev) => moveRuleToGroup(prev, groups, dragState.ruleId, groupId));
    messageApi.success(`规则已移动到规则组「${groupNameMap.get(groupId) ?? ''}」`);
    clearDragState();
  };

  const getRowGroupId = (row: TableRow) => (row.rowType === 'rule' ? row.rule.groupId : row.group.id);

  return <div>
    <div className="detail-header">
      <Space><Typography.Title level={4} style={{ margin: 0 }}>重定向请求</Typography.Title><Switch checked={redirectEnabled} onChange={handleRedirectEnabledChange} /></Space>
      <Space>
        <Dropdown menu={{ items: [
          { key: 'export', label: '导出配置', onClick: exportConfig },
          { key: 'import', label: '导入配置', onClick: importConfig },
        ] }} trigger={['click']}>
          <Button icon={<EllipsisOutlined />} />
        </Dropdown>
        <Button onClick={() => { setGroupModal({ open: true, mode: 'create' }); setGroupInput(''); }}>新建规则组</Button>
        <Dropdown
          menu={{
            items: [
              {
                key: 'url_rewrites_group',
                type: 'group',
                label: 'URL rewrites',
                children: [
                  { key: 'redirect_request', icon: RULE_TYPE_ICON_MAP.redirect_request, label: RULE_TYPE_LABEL_MAP.redirect_request, onClick: () => createRule('redirect_request') },
                  { key: 'rewrite_string', icon: RULE_TYPE_ICON_MAP.rewrite_string, label: RULE_TYPE_LABEL_MAP.rewrite_string, onClick: () => createRule('rewrite_string') },
                  { key: 'query_params', icon: RULE_TYPE_ICON_MAP.query_params, label: RULE_TYPE_LABEL_MAP.query_params, onClick: () => createRule('query_params') },
                ],
              },
              {
                key: 'api_mocking_group',
                type: 'group',
                label: 'API mocking',
                children: [
                  { key: 'modify_request_body', icon: RULE_TYPE_ICON_MAP.modify_request_body, label: RULE_TYPE_LABEL_MAP.modify_request_body, onClick: () => createRule('modify_request_body') },
                  { key: 'modify_response_body', icon: RULE_TYPE_ICON_MAP.modify_response_body, label: RULE_TYPE_LABEL_MAP.modify_response_body, onClick: () => createRule('modify_response_body') },
                ],
              },
              {
                key: 'headers_group',
                type: 'group',
                label: 'Headers',
                children: [
                  { key: 'modify_headers', icon: RULE_TYPE_ICON_MAP.modify_headers, label: RULE_TYPE_LABEL_MAP.modify_headers, onClick: () => createRule('modify_headers') },
                  { key: 'user_agent', icon: RULE_TYPE_ICON_MAP.user_agent, label: RULE_TYPE_LABEL_MAP.user_agent, onClick: () => createRule('user_agent') },
                ],
              },
              {
                key: 'others_group',
                type: 'group',
                label: 'Others',
                children: [
                  { key: 'cancel_request', icon: RULE_TYPE_ICON_MAP.cancel_request, label: RULE_TYPE_LABEL_MAP.cancel_request, onClick: () => createRule('cancel_request') },
                  { key: 'request_delay', icon: RULE_TYPE_ICON_MAP.request_delay, label: RULE_TYPE_LABEL_MAP.request_delay, onClick: () => createRule('request_delay') },
                ],
              },
            ],
          }}
          trigger={['click']}
        >
          <Button type="primary">新建规则</Button>
        </Dropdown>
      </Space>
    </div>
    <div className="rules-list-table-wrapper" ref={tableWrapperRef}>
      {groupOverlayRect ? (
        <div
          className={`rule-group-drop-overlay${groupOverlayRect.roundBottom ? ' is-last-group' : ''}`}
          style={{
            top: groupOverlayRect.top,
            left: groupOverlayRect.left,
            width: groupOverlayRect.width,
            height: groupOverlayRect.height,
          }}
        />
      ) : null}
      <Table<TableRow>
        className="rules-list-table"
        pagination={false}
        dataSource={tableData}
        rowKey="key"
        rowClassName={(row) => {
          if (row.rowType === 'group') return 'rule-group-row';
          if (row.rowType !== 'rule') return 'rule-item-row';
          const classNames = ['rule-item-row'];
          if (dragState?.ruleId === row.rule.id) classNames.push('dragging-rule-row');
          if (dropState?.targetRuleId === row.rule.id) {
            classNames.push(dropState.position === 'before' ? 'drop-before-row' : 'drop-after-row');
          }
          return classNames.join(' ');
        }}
        onRow={(row) => {
          const groupId = getRowGroupId(row);
          const rowProps = {
            'data-group-id': groupId,
            'data-row-type': row.rowType,
            onDragOver: (event) => handleGroupDragOver(event, groupId),
            onDrop: (event) => handleGroupDrop(event, groupId),
          };

          if (row.rowType !== 'rule') return rowProps;

          return {
            ...rowProps,
            draggable: true,
            onDragStart: (event: React.DragEvent<HTMLTableRowElement>) => handleRuleDragStart(event, row.rule),
            onDragEnd: clearDragState,
            onDragOver: (event: React.DragEvent<HTMLTableRowElement>) => {
              if (dragState?.groupId === row.rule.groupId) {
                handleRuleDragOver(event, row);
                return;
              }
              handleGroupDragOver(event, row.rule.groupId);
            },
            onDrop: (event: React.DragEvent<HTMLTableRowElement>) => {
              if (dragState?.groupId === row.rule.groupId) {
                handleRuleDrop(event, row);
                return;
              }
              handleGroupDrop(event, row.rule.groupId);
            },
            onDragLeave: () => {
              setDropState((prev) => prev?.targetRuleId === row.rule.id ? null : prev);
            },
          };
        }}
        columns={[
        {
          title: '名称',
          dataIndex: 'name',
          onCell: (row) => row.rowType === 'group'
            ? {
              className: 'rule-group-name-cell',
              onClick: () => toggleGroupCollapse(row.group.id),
            }
            : {},
          render: (_, row) => {
            if (row.rowType === 'group') {
              const isCollapsed = collapsedGroupIds.includes(row.group.id);
              return (
                <Space>
                  <Button
                    type="text"
                    className="group-collapse-btn"
                    icon={<CaretRightOutlined className={isCollapsed ? '' : 'expanded'} />}
                    onClick={(event) => {
                      event.stopPropagation();
                      toggleGroupCollapse(row.group.id);
                    }}
                  />
                  <Typography.Text strong>{row.group.name}</Typography.Text>
                </Space>
              );
            }
            if (row.rowType === 'group-empty') {
              return <Typography.Text type="secondary" style={{ marginLeft: 40 }}>该规则组暂无规则</Typography.Text>;
            }
            return <Button type="link" style={{ paddingInline: 0, marginLeft: 40 }} onClick={() => openRuleDetail(row.rule.id)}>{row.rule.name}</Button>;
          },
        },
        {
          title: '类型',
          width: 180,
          render: (_, row) => {
            if (row.rowType !== 'rule') return null;
            return <Space size={6}>{RULE_TYPE_ICON_MAP[row.rule.type]}<span>{RULE_TYPE_LABEL_MAP[row.rule.type]}</span></Space>;
          },
        },
        {
          title: '状态',
          width: 100,
          render: (_, row) => {
            if (row.rowType === 'group') {
              return (
                <Space size={6}>
                  <Tooltip title={redirectEnabled ? (row.group.enabled ? '规则组已开启，组内规则可生效' : '规则组已关闭，组内规则不会生效') : '总开关关闭，组内规则不会生效'}>
                    <Switch size="small" checked={row.group.enabled} disabled={!redirectEnabled} onChange={(v) => handleGroupEnabledChange(row.group, v)} />
                  </Tooltip>
                </Space>
              );
            }
            if (row.rowType === 'group-empty') return null;
            const groupEnabled = currentGroupEnabled.get(row.rule.groupId) !== false;
            return (
              <Space size={6}>
                <Tooltip title={getRuleEffectiveHint(redirectEnabled, groupEnabled, row.rule.enabled)}>
                  <Switch
                    size="small"
                    checked={row.rule.enabled}
                    disabled={!redirectEnabled || !groupEnabled}
                    onChange={(v) => handleRuleEnabledChange(row.rule, v)}
                  />
                </Tooltip>
              </Space>
            );
          },
        },
        {
          title: '操作',
          width: 80,
          render: (_, row) => {
            if (row.rowType === 'group') {
              return <Dropdown menu={{ items: [
                { key: 'rename', label: '重命名', icon: <EditOutlined />, onClick: () => { setGroupModal({ open: true, mode: 'rename', groupId: row.group.id }); setGroupInput(row.group.name); } },
                { key: 'copy', label: '复制', icon: <CopyOutlined />, onClick: () => duplicateGroup(row.group.id) },
                { key: 'delete', label: '删除', icon: <DeleteOutlined />, danger: true, onClick: () => deleteGroup(row.group.id) },
              ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown>;
            }
            if (row.rowType === 'group-empty') return null;
            return (
              <Dropdown menu={{ items: [
                { key: 'move', label: '修改规则组', icon: <FolderOpenOutlined />, onClick: () => { setGroupModal({ open: true, mode: 'move', ruleId: row.rule.id }); setGroupInput(groupNameMap.get(row.rule.groupId) ?? ''); } },
                { key: 'copy', label: '复制', icon: <CopyOutlined />, onClick: () => setRules((prev) => { const idx = prev.findIndex((r) => r.id === row.rule.id); const next = [...prev]; next.splice(idx + 1, 0, { ...row.rule, id: genId(), name: `${row.rule.name} 副本` }); return next; }) },
                { key: 'delete', label: '删除', icon: <DeleteOutlined />, danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => setRules((prev) => prev.filter((r) => r.id !== row.rule.id)) }) },
              ] }}>
                <Button type="text" icon={<EllipsisOutlined />} />
              </Dropdown>
            );
          },
        },
        ]}
      />
    </div>
    <Modal open={groupModal.open} title={groupModal.mode === 'create' ? '新建规则组' : groupModal.mode === 'rename' ? '重命名规则组' : '修改规则组'} onCancel={() => setGroupModal({ open: false, mode: 'create' })} onOk={confirmGroupModal}>
      {groupModal.mode === 'move' ? <AutoComplete options={groupsOptions} value={groupInput} onChange={setGroupInput} placeholder="请选择或输入新规则组" /> : <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder="请输入名称" />}
    </Modal>
  </div>;
}
