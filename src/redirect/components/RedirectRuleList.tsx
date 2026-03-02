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
import {
  CopyOutlined,
  DeleteOutlined,
  EditOutlined,
  FolderOpenOutlined,
  CaretRightOutlined,
  EllipsisOutlined,
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
  createRule: () => void;
  openRuleDetail: (ruleId: string) => void;
  duplicateGroup: (groupId: string) => void;
  deleteGroup: (groupId: string) => void;
  confirmGroupModal: () => void;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  setGroups: React.Dispatch<React.SetStateAction<RedirectGroup[]>>;
};

type GroupRow = { key: string; rowType: 'group'; group: RedirectGroup };
type RuleRow = { key: string; rowType: 'rule'; rule: RedirectRule };
type TableRow = GroupRow | RuleRow;

const RULE_TYPE_LABEL_MAP: Record<RedirectRule['type'], string> = {
  redirect_request: '重定向请求',
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
}: Props) {
  const currentGroupEnabled = new Map(groups.map((g) => [g.id, g.enabled]));
  const groupNameMap = new Map(groups.map((g) => [g.id, g.name]));
  const groupsOptions = groups.map((g) => ({ value: g.name }));

  const tableData: TableRow[] = groups.flatMap((group) => {
    const groupRow: GroupRow = { key: `group-${group.id}`, rowType: 'group', group };
    if (collapsedGroupIds.includes(group.id)) return [groupRow];
    const ruleRows: RuleRow[] = rules
      .filter((rule) => rule.groupId === group.id)
      .map((rule) => ({ key: `rule-${rule.id}`, rowType: 'rule', rule }));
    return [groupRow, ...ruleRows];
  });

  const toggleGroupCollapse = (groupId: string) => {
    setCollapsedGroupIds((prev) => {
      if (prev.includes(groupId)) return prev.filter((id) => id !== groupId);
      return [...prev, groupId];
    });
  };

  return <div>
    <div className="detail-header">
      <Space><Typography.Title level={4} style={{ margin: 0 }}>重定向请求</Typography.Title><Switch checked={redirectEnabled} onChange={setRedirectEnabled} /></Space>
      <Space><Button onClick={() => { setGroupModal({ open: true, mode: 'create' }); setGroupInput(''); }}>新建规则组</Button><Button type="primary" onClick={createRule}>新建规则</Button></Space>
    </div>
    <Table<TableRow>
      className="rules-list-table"
      pagination={false}
      dataSource={tableData}
      rowKey="key"
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
            return <Button type="link" style={{ paddingInline: 0, marginLeft: 40 }} onClick={() => openRuleDetail(row.rule.id)}>{row.rule.name}</Button>;
          },
        },
        {
          title: '类型',
          render: (_, row) => row.rowType === 'rule' ? RULE_TYPE_LABEL_MAP[row.rule.type] : null,
        },
        {
          title: '状态',
          width: 90,
          render: (_, row) => {
            if (row.rowType === 'group') {
              return <Switch size="small" checked={row.group.enabled} disabled={!redirectEnabled} onChange={(v) => setGroups((prev) => prev.map((g) => g.id === row.group.id ? { ...g, enabled: v } : g))} />;
            }
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
          render: (_, row) => {
            if (row.rowType === 'group') {
              return <Dropdown menu={{ items: [
                { key: 'rename', label: '重命名', icon: <EditOutlined />, onClick: () => { setGroupModal({ open: true, mode: 'rename', groupId: row.group.id }); setGroupInput(row.group.name); } },
                { key: 'copy', label: '复制', icon: <CopyOutlined />, onClick: () => duplicateGroup(row.group.id) },
                { key: 'delete', label: '删除', icon: <DeleteOutlined />, danger: true, onClick: () => deleteGroup(row.group.id) },
              ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown>;
            }
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
    <Modal open={groupModal.open} title={groupModal.mode === 'create' ? '新建规则组' : groupModal.mode === 'rename' ? '重命名规则组' : '修改规则组'} onCancel={() => setGroupModal({ open: false, mode: 'create' })} onOk={confirmGroupModal}>
      {groupModal.mode === 'move' ? <AutoComplete options={groupsOptions} value={groupInput} onChange={setGroupInput} placeholder="请选择或输入新规则组" /> : <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder="请输入名称" />}
    </Modal>
  </div>;
}
