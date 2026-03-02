import React from 'react';
import { AutoComplete, Button, Dropdown, Input, Modal, Space, Switch, Table, Typography } from 'antd';
import { EllipsisOutlined } from '@ant-design/icons';
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
  const tableData = groups.map((group) => ({ key: `group-${group.id}`, group }));
  const currentGroupEnabled = new Map(groups.map((g) => [g.id, g.enabled]));
  const groupNameMap = new Map(groups.map((g) => [g.id, g.name]));
  const groupsOptions = groups.map((g) => ({ value: g.name }));

  return <div>
    <div className="detail-header">
      <Space><Typography.Title level={4} style={{ margin: 0 }}>重定向请求</Typography.Title><Switch checked={redirectEnabled} onChange={setRedirectEnabled} /></Space>
      <Space><Button onClick={() => { setGroupModal({ open: true, mode: 'create' }); setGroupInput(''); }}>新建规则组</Button><Button type="primary" onClick={createRule}>新建规则</Button></Space>
    </div>
    <Table
      pagination={false}
      dataSource={tableData}
      rowKey="key"
      expandable={{
        expandedRowKeys: groups.filter((group) => !collapsedGroupIds.includes(group.id)).map((group) => `group-${group.id}`),
        onExpand: (expanded, row) => {
          const record = row as { group: RedirectGroup };
          setCollapsedGroupIds((prev) => {
            if (expanded) return prev.filter((id) => id !== record.group.id);
            if (prev.includes(record.group.id)) return prev;
            return [...prev, record.group.id];
          });
        },
        expandedRowRender: (row) => {
          const record = row as { group: RedirectGroup };
          const groupRules = rules.filter((r) => r.groupId === record.group.id);
          if (groupRules.length === 0) {
            return <Typography.Text type="secondary">当前规则组暂无规则</Typography.Text>;
          }

          return (
            <Table
              size="small"
              pagination={false}
              dataSource={groupRules}
              rowKey="id"
              columns={[
                {
                  title: '名称',
                  dataIndex: 'name',
                  render: (_, rule) => <Button type="link" style={{ paddingInline: 0 }} onClick={() => openRuleDetail(rule.id)}>{rule.name}</Button>,
                },
                {
                  title: '类型',
                  render: () => '重定向请求',
                },
                {
                  title: '状态',
                  render: (_, rule) => (
                    <Switch
                      checked={rule.enabled}
                      disabled={!redirectEnabled || !currentGroupEnabled.get(rule.groupId)}
                      onChange={(v) => setRules((prev) => prev.map((r) => r.id === rule.id ? { ...r, enabled: v } : r))}
                    />
                  ),
                },
                {
                  title: '操作',
                  render: (_, rule) => (
                    <Dropdown menu={{ items: [
                      { key: 'move', label: '修改规则组', onClick: () => { setGroupModal({ open: true, mode: 'move', ruleId: rule.id }); setGroupInput(groupNameMap.get(rule.groupId) ?? ''); } },
                      { key: 'copy', label: '复制', onClick: () => setRules((prev) => { const idx = prev.findIndex((r) => r.id === rule.id); const next = [...prev]; next.splice(idx + 1, 0, { ...rule, id: genId(), name: `${rule.name} 副本` }); return next; }) },
                      { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => setRules((prev) => prev.filter((r) => r.id !== rule.id)) }) },
                    ] }}>
                      <Button type="text" icon={<EllipsisOutlined />} />
                    </Dropdown>
                  ),
                },
              ]}
            />
          );
        },
      }}
      columns={[
        { title: '规则组', dataIndex: 'group', render: (group: RedirectGroup) => <Typography.Text strong>{group.name}</Typography.Text> },
        { title: '状态', render: (_, row) => {
          const record = row as { group: RedirectGroup };
          return <Switch checked={record.group.enabled} disabled={!redirectEnabled} onChange={(v) => setGroups((prev) => prev.map((g) => g.id === record.group.id ? { ...g, enabled: v } : g))} />;
        } },
        { title: '操作', render: (_, row) => {
          const record = row as { group: RedirectGroup };
          return <Dropdown menu={{ items: [
            { key: 'rename', label: '重命名', onClick: () => { setGroupModal({ open: true, mode: 'rename', groupId: record.group.id }); setGroupInput(record.group.name); } },
            { key: 'copy', label: '复制', onClick: () => duplicateGroup(record.group.id) },
            { key: 'delete', label: '删除', danger: true, onClick: () => deleteGroup(record.group.id) },
          ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown>;
        } },
      ]}
    />
    <Modal open={groupModal.open} title={groupModal.mode === 'create' ? '新建规则组' : groupModal.mode === 'rename' ? '重命名规则组' : '修改规则组'} onCancel={() => setGroupModal({ open: false, mode: 'create' })} onOk={confirmGroupModal}>
      {groupModal.mode === 'move' ? <AutoComplete options={groupsOptions} value={groupInput} onChange={setGroupInput} placeholder="请选择或输入新规则组" /> : <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder="请输入名称" />}
    </Modal>
  </div>;
}
