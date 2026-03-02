import React from 'react';
import { Button, Dropdown, Input, Popconfirm, Select, Space, Switch } from 'antd';
import {
  CopyOutlined,
  DeleteOutlined,
  EditOutlined,
  PlusOutlined,
  SwapOutlined,
} from '@ant-design/icons';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS } from './constants';
import GroupTitleDropArea from './components/GroupTitleDropArea';
import type { MatchMode, MatchTarget, RedirectGroup, RedirectRule } from './types';

type RuleColumnsDeps = {
  groups: RedirectGroup[];
  redirectEnabled: boolean;
  groupEnabledMap: ReadonlyMap<string, boolean>;
  getRuleFieldValue: (row: RedirectRule, key: 'expression' | 'redirectUrl') => string;
  isRuleFieldDirty: (row: RedirectRule, key: 'expression' | 'redirectUrl') => boolean;
  updateRuleDraft: (row: RedirectRule, key: 'expression' | 'redirectUrl', value: string) => void;
  saveRuleField: (row: RedirectRule, key: 'expression' | 'redirectUrl') => void;
  onToggleRuleEnabled: (id: string, enabled: boolean) => void;
  onUpdateRuleMatchTarget: (id: string, value: MatchTarget) => void;
  onUpdateRuleMatchMode: (id: string, value: MatchMode) => void;
  onMoveRuleGroup: (id: string, groupId: string) => void;
  onDuplicateRule: (id: string) => void;
  onRemoveRule: (id: string) => void;
};

export function buildRuleColumns({
  groups,
  redirectEnabled,
  groupEnabledMap,
  getRuleFieldValue,
  isRuleFieldDirty,
  updateRuleDraft,
  saveRuleField,
  onToggleRuleEnabled,
  onUpdateRuleMatchTarget,
  onUpdateRuleMatchMode,
  onMoveRuleGroup,
  onDuplicateRule,
  onRemoveRule,
}: RuleColumnsDeps) {
  return [
    {
      title: '',
      key: 'drag',
      width: 40,
      className: 'drag-cell',
      render: () => (
        <div
          style={{
            height: 32,
            width: '100%',
          }}
        />
      ),
    },
    {
      title: '启用',
      dataIndex: 'enabled',
      width: 44,
      render: (_: unknown, row: RedirectRule) => (
        <div
          style={{ height: 32, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
          onPointerDownCapture={(event) => event.stopPropagation()}
        >
          <Switch
            size="small"
            checked={row.enabled}
            disabled={!redirectEnabled || groupEnabledMap.get(row.groupId) === false}
            onChange={(v) => onToggleRuleEnabled(row.id, v)}
          />
        </div>
      ),
    },
    {
      title: '规则内容',
      key: 'ruleBody',
      render: (_: unknown, row: RedirectRule) => {
        const expressionValue = getRuleFieldValue(row, 'expression');
        const redirectUrlValue = getRuleFieldValue(row, 'redirectUrl');
        const expressionEmpty = expressionValue.trim().length === 0;
        const redirectUrlEmpty = redirectUrlValue.trim().length === 0;

        return (
          <Space
            direction="vertical"
            size={10}
            style={{ width: '100%' }}
            onPointerDownCapture={(event) => event.stopPropagation()}
          >
            <div style={{ display: 'flex', gap: 10, width: '100%' }}>
              <Select
                style={{ width: 84 }}
                value={row.matchTarget}
                options={MATCH_TARGET_OPTIONS as { label: string; value: MatchTarget }[]}
                onChange={(v: MatchTarget) => {
                  onUpdateRuleMatchTarget(row.id, v);
                }}
              />
              <Select
                style={{ width: 84 }}
                value={row.matchMode}
                options={MATCH_MODE_OPTIONS as { label: string; value: MatchMode }[]}
                onChange={(v: MatchMode) => {
                  onUpdateRuleMatchMode(row.id, v);
                }}
              />
              <Space.Compact style={{ flex: 1, minWidth: 0 }}>
                <Button disabled type="default" style={{ cursor: 'default' }} tabIndex={-1}>
                  表达式
                </Button>
                <Input
                  style={{ flex: 1, minWidth: 0 }}
                  value={expressionValue}
                  status={expressionEmpty ? 'error' : ''}
                  onChange={(e) => {
                    updateRuleDraft(row, 'expression', e.target.value);
                  }}
                  onPressEnter={() => {
                    if (!expressionEmpty) saveRuleField(row, 'expression');
                  }}
                />
                {isRuleFieldDirty(row, 'expression') ? (
                  <Button
                    type="primary"
                    disabled={expressionEmpty}
                    onClick={() => saveRuleField(row, 'expression')}
                  >
                    保存
                  </Button>
                ) : null}
              </Space.Compact>
            </div>
            <Space.Compact style={{ width: '100%' }}>
              <Button disabled type="default" style={{ cursor: 'default' }} tabIndex={-1}>
                目标 URL
              </Button>
              <Input
                style={{ flex: 1, minWidth: 0 }}
                value={redirectUrlValue}
                status={redirectUrlEmpty ? 'error' : ''}
                onChange={(e) => {
                  updateRuleDraft(row, 'redirectUrl', e.target.value);
                }}
                onPressEnter={() => {
                  if (!redirectUrlEmpty) saveRuleField(row, 'redirectUrl');
                }}
              />
              {isRuleFieldDirty(row, 'redirectUrl') ? (
                <Button
                  type="primary"
                  disabled={redirectUrlEmpty}
                  onClick={() => saveRuleField(row, 'redirectUrl')}
                >
                  保存
                </Button>
              ) : null}
            </Space.Compact>
          </Space>
        );
      },
    },
    {
      title: '操作',
      key: 'action',
      width: 130,
      render: (_: unknown, row: RedirectRule) => (
        <div
          style={{ height: 32, display: 'flex', alignItems: 'center' }}
          onPointerDownCapture={(event) => event.stopPropagation()}
        >
          <Space size={6}>
            <Dropdown
              trigger={['click']}
              disabled={groups.length <= 1}
              menu={{
                items: groups
                  .filter((g) => g.id !== row.groupId)
                  .map((g) => ({ key: g.id, label: g.name })),
                onClick: ({ key }) => {
                  onMoveRuleGroup(row.id, String(key));
                },
              }}
            >
              <Button size="small" type="text" icon={<SwapOutlined />} title="移动到分组" />
            </Dropdown>
            <Button
              size="small"
              type="text"
              icon={<CopyOutlined />}
              title="复制规则"
              onClick={() => onDuplicateRule(row.id)}
            />
            <Popconfirm
              title="确认删除这条规则？"
              okText="删除"
              cancelText="取消"
              okButtonProps={{ danger: true, type: 'primary' }}
              onConfirm={() => onRemoveRule(row.id)}
            >
              <Button
                size="small"
                type="text"
                danger
                icon={<DeleteOutlined />}
                title="删除规则"
              />
            </Popconfirm>
          </Space>
        </div>
      ),
    },
  ];
}

type GroupColumnsDeps = {
  redirectEnabled: boolean;
  groupRuleCountMap: ReadonlyMap<string, number>;
  groupActiveRuleCountMap: ReadonlyMap<string, number>;
  onToggleGroupEnabled: (id: string, enabled: boolean) => void;
  onAddRule: (groupId: string) => void;
  onOpenEditGroupModal: (groupId: string) => void;
  onRemoveGroup: (groupId: string) => void;
};

export function buildGroupColumns({
  redirectEnabled,
  groupRuleCountMap,
  groupActiveRuleCountMap,
  onToggleGroupEnabled,
  onAddRule,
  onOpenEditGroupModal,
  onRemoveGroup,
}: GroupColumnsDeps) {
  return [
    {
      title: '规则组',
      key: 'group',
      render: (_: unknown, g: RedirectGroup) => {
        const active = groupActiveRuleCountMap.get(g.id) ?? 0;
        const count = groupRuleCountMap.get(g.id) ?? 0;
        return (
          <GroupTitleDropArea
            group={g}
            activeCount={active}
            totalCount={count}
            disabled={!redirectEnabled}
            onToggle={onToggleGroupEnabled}
          />
        );
      },
    },
    {
      title: '操作',
      key: 'action',
      width: 130,
      render: (_: unknown, g: RedirectGroup) => {
        const count = groupRuleCountMap.get(g.id) ?? 0;
        return (
          <div
            style={{ height: 32, display: 'flex', alignItems: 'center' }}
            onPointerDownCapture={(event) => event.stopPropagation()}
          >
            <Space size={6}>
              <Button
                size="small"
                type="text"
                icon={<PlusOutlined />}
                onClick={() => onAddRule(g.id)}
                title="新增规则"
              />
              <Button
                size="small"
                type="text"
                icon={<EditOutlined />}
                onClick={() => onOpenEditGroupModal(g.id)}
                title="编辑分组"
              />
              <Popconfirm
                title={`确认删除分组「${g.name}」？`}
                description={`确认后会删除该分组下的 ${count} 条规则，此操作不可恢复。`}
                okText="确认删除"
                cancelText="取消"
                okButtonProps={{ danger: true, type: 'primary' }}
                onConfirm={() => onRemoveGroup(g.id)}
              >
                <Button
                  size="small"
                  type="text"
                  danger
                  icon={<DeleteOutlined />}
                  title="删除分组"
                />
              </Popconfirm>
            </Space>
          </div>
        );
      },
    },
  ];
}
