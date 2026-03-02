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
  Typography,
} from 'antd';
import { DndContext, PointerSensor, useDroppable, useSensor, useSensors, type DragEndEvent } from '@dnd-kit/core';
import { SortableContext, arrayMove, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
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

type RowProps = React.HTMLAttributes<HTMLTableRowElement> & {
  'data-row-key'?: string;
  'data-row-type'?: TableRow['rowType'];
  'data-group-id'?: string;
  'data-rule-id'?: string;
};

function SortableTableRow(props: RowProps) {
  const rowType = props['data-row-type'];
  const rowKey = props['data-row-key'];
  const groupId = props['data-group-id'];
  const ruleId = props['data-rule-id'];

  const sortable = useSortable({
    id: rowType === 'rule' && ruleId ? ruleId : `noop-${String(rowKey ?? '')}`,
    disabled: rowType !== 'rule' || !ruleId,
  });
  const droppable = useDroppable({
    id: rowType === 'group' && groupId ? `group-drop:${groupId}` : `noop-group-${String(rowKey ?? '')}`,
    data: rowType === 'group' && groupId ? { type: 'group', groupId } : undefined,
    disabled: rowType !== 'group' || !groupId,
  });

  const style = rowType === 'rule'
    ? {
      ...props.style,
      transform: sortable.isDragging ? CSS.Transform.toString(sortable.transform) : undefined,
      transition: sortable.isDragging ? sortable.transition : undefined,
      cursor: 'grab',
    }
    : props.style;

  const className = [
    props.className,
    rowType === 'rule' && sortable.isDragging ? 'rule-row-dragging' : '',
    rowType === 'group' && droppable.isOver ? 'rule-group-row-drop-over' : '',
  ].filter(Boolean).join(' ');

  return (
    <tr
      {...props}
      ref={rowType === 'rule' ? sortable.setNodeRef : rowType === 'group' ? droppable.setNodeRef : undefined}
      style={style}
      className={className}
      {...(rowType === 'rule' ? sortable.attributes : undefined)}
      {...(rowType === 'rule' ? sortable.listeners : undefined)}
    />
  );
}

function moveRuleWithDropTarget(list: RedirectRule[], groupOrder: string[], activeRuleId: string, overId: string) {
  const active = list.find((rule) => rule.id === activeRuleId);
  if (!active) return list;

  if (overId.startsWith('group-drop:')) {
    const targetGroupId = overId.replace('group-drop:', '');
    if (!targetGroupId || active.groupId === targetGroupId) return list;
    const withoutActive = list.filter((rule) => rule.id !== activeRuleId);
    const next = [...withoutActive];
    const lastInTargetGroup = withoutActive.reduce((idx, rule, index) => (rule.groupId === targetGroupId ? index : idx), -1);

    if (lastInTargetGroup >= 0) {
      next.splice(lastInTargetGroup + 1, 0, { ...active, groupId: targetGroupId });
      return next;
    }

    const targetGroupIndex = groupOrder.findIndex((id) => id === targetGroupId);
    const nextGroupIds = new Set(groupOrder.slice(targetGroupIndex + 1));
    const insertIndex = withoutActive.findIndex((rule) => nextGroupIds.has(rule.groupId));
    next.splice(insertIndex >= 0 ? insertIndex : next.length, 0, { ...active, groupId: targetGroupId });
    return next;
  }

  const overRule = list.find((rule) => rule.id === overId);
  if (!overRule) return list;
  if (activeRuleId === overId) return list;

  if (active.groupId === overRule.groupId) {
    const activeIndex = list.findIndex((rule) => rule.id === activeRuleId);
    const overIndex = list.findIndex((rule) => rule.id === overId);
    if (activeIndex < 0 || overIndex < 0 || activeIndex === overIndex) return list;
    return arrayMove(list, activeIndex, overIndex);
  }

  const withoutActive = list.filter((rule) => rule.id !== activeRuleId);
  const overIndex = withoutActive.findIndex((rule) => rule.id === overId);
  if (overIndex < 0) return list;
  const next = [...withoutActive];
  next.splice(overIndex, 0, { ...active, groupId: overRule.groupId });
  return next;
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
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 4 } }));
  const currentGroupEnabled = new Map(groups.map((g) => [g.id, g.enabled]));
  const groupNameMap = new Map(groups.map((g) => [g.id, g.name]));
  const groupsOptions = groups.map((g) => ({ value: g.name }));

  const tableData: TableRow[] = groups.flatMap((group) => {
    const groupRow: GroupRow = { key: `group-${group.id}`, rowType: 'group', group };
    if (collapsedGroupIds.includes(group.id)) return [groupRow];
    const ruleRows: RuleRow[] = rules
      .filter((rule) => rule.groupId === group.id)
      .map((rule) => ({ key: `rule-${rule.id}`, rowType: 'rule', rule }));
    if (ruleRows.length === 0) {
      return [groupRow, { key: `group-empty-${group.id}`, rowType: 'group-empty', group }];
    }
    return [groupRow, ...ruleRows];
  });

  const toggleGroupCollapse = (groupId: string) => {
    setCollapsedGroupIds((prev) => {
      if (prev.includes(groupId)) return prev.filter((id) => id !== groupId);
      return [...prev, groupId];
    });
  };

  const handleDragEnd = (event: DragEndEvent) => {
    const activeId = String(event.active.id);
    const overId = event.over ? String(event.over.id) : '';
    if (!overId) return;
    let reordered = false;
    setRules((prev) => {
      const next = moveRuleWithDropTarget(prev, groups.map((group) => group.id), activeId, overId);
      reordered = next !== prev;
      return next;
    });
    if (reordered) {
      messageApi.success('排序已更新');
    }
  };

  return <div>
    <div className="detail-header">
      <Space><Typography.Title level={4} style={{ margin: 0 }}>重定向请求</Typography.Title><Switch checked={redirectEnabled} onChange={setRedirectEnabled} /></Space>
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
    <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
      <SortableContext items={rules.map((rule) => rule.id)} strategy={verticalListSortingStrategy}>
        <Table<TableRow>
          className="rules-list-table"
          pagination={false}
          dataSource={tableData}
          rowKey="key"
          onRow={(row) => ({
            'data-row-type': row.rowType,
            'data-group-id': row.rowType === 'rule' ? row.rule.groupId : row.group.id,
            'data-rule-id': row.rowType === 'rule' ? row.rule.id : undefined,
          })}
          components={{ body: { row: SortableTableRow } }}
          rowClassName={(row) => row.rowType === 'group' ? 'rule-group-row' : 'rule-item-row'}
          columns={[
        {
          title: '名称',
          dataIndex: 'name',
          render: (_, row) => {
            if (row.rowType === 'group') {
              const isCollapsed = collapsedGroupIds.includes(row.group.id);
              return (
                <Space>
                  <Button
                    type="text"
                    className="group-collapse-btn"
                    icon={<CaretRightOutlined className={isCollapsed ? '' : 'expanded'} />}
                    onClick={() => toggleGroupCollapse(row.group.id)}
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
          width: 150,
          render: (_, row) => {
            if (row.rowType !== 'rule') return null;
            return <Space size={6}>{RULE_TYPE_ICON_MAP[row.rule.type]}<span>{RULE_TYPE_LABEL_MAP[row.rule.type]}</span></Space>;
          },
        },
        {
          title: '状态',
          width: 90,
          render: (_, row) => {
            if (row.rowType === 'group') {
              return <Switch size="small" checked={row.group.enabled} disabled={!redirectEnabled} onChange={(v) => setGroups((prev) => prev.map((g) => g.id === row.group.id ? { ...g, enabled: v } : g))} />;
            }
            if (row.rowType === 'group-empty') return null;
            return (
              <Switch
                size="small"
                checked={row.rule.enabled}
                disabled={!redirectEnabled || !currentGroupEnabled.get(row.rule.groupId)}
                onChange={(v) => setRules((prev) => prev.map((r) => r.id === row.rule.id ? { ...r, enabled: v } : r))}
              />
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
      </SortableContext>
    </DndContext>
    <Modal open={groupModal.open} title={groupModal.mode === 'create' ? '新建规则组' : groupModal.mode === 'rename' ? '重命名规则组' : '修改规则组'} onCancel={() => setGroupModal({ open: false, mode: 'create' })} onOk={confirmGroupModal}>
      {groupModal.mode === 'move' ? <AutoComplete options={groupsOptions} value={groupInput} onChange={setGroupInput} placeholder="请选择或输入新规则组" /> : <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder="请输入名称" />}
    </Modal>
  </div>;
}
