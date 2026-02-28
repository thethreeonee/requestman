import React from 'react';
import { Button, Collapse, Dropdown, Input, Popconfirm, Select, Space, Switch, Typography } from 'antd';
import { CopyOutlined, DeleteOutlined, EditOutlined, HolderOutlined, PlusOutlined, SaveOutlined, SwapOutlined } from '@ant-design/icons';
import { SortableContext, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { isRuleEffectivelyEnabled } from '../rule-utils';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS } from '../match-options';
import type { RedirectGroup, RedirectRule, RuleDragData } from '../types';

type Props = {
  groups: RedirectGroup[];
  rulesByGroup: Map<string, RedirectRule[]>;
  groupEnabledMap: ReadonlyMap<string, boolean>;
  redirectEnabled: boolean;
  highlightedRuleId: string | null;
  collapsedGroupIds: string[];
  setCollapsedGroupIds: (ids: string[]) => void;
  addRule: (groupId: string) => void;
  openEditGroupModal: (groupId: string) => void;
  removeGroup: (groupId: string) => void;
  toggleGroupEnabled: (groupId: string, enabled: boolean) => void;
  moveRuleGroup: (ruleId: string, groupId: string) => void;
  updateRuleEnabled: (ruleId: string, enabled: boolean) => void;
  updateRuleMatchTarget: (ruleId: string, value: RedirectRule['matchTarget']) => void;
  updateRuleMatchMode: (ruleId: string, value: RedirectRule['matchMode']) => void;
  saveRuleDraft: (rule: RedirectRule) => void;
  duplicateRule: (ruleId: string) => void;
  removeRule: (ruleId: string) => void;
  getRuleFieldValue: (rule: RedirectRule, key: 'expression' | 'redirectUrl') => string;
  updateRuleDraft: (rule: RedirectRule, key: 'expression' | 'redirectUrl', value: string) => void;
  isRuleFieldDirty: (rule: RedirectRule, key: 'expression' | 'redirectUrl') => boolean;
};

function SortableRuleCard({
  rule,
  children,
}: {
  rule: RedirectRule;
  children: (dnd: { attributes: Record<string, unknown>; listeners: Record<string, unknown> }) => React.ReactNode;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: rule.id,
    data: { type: 'rule', groupId: rule.groupId } as RuleDragData,
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={isDragging ? 'simple-rule-card simple-rule-card-dragging' : 'simple-rule-card'}
      data-rule-id={rule.id}
    >
      {children({ attributes: attributes as Record<string, unknown>, listeners: listeners as Record<string, unknown> })}
    </div>
  );
}

export default function RuleGroupsCollapse({
  groups,
  rulesByGroup,
  groupEnabledMap,
  redirectEnabled,
  highlightedRuleId,
  collapsedGroupIds,
  setCollapsedGroupIds,
  addRule,
  openEditGroupModal,
  removeGroup,
  toggleGroupEnabled,
  moveRuleGroup,
  updateRuleEnabled,
  updateRuleMatchTarget,
  updateRuleMatchMode,
  saveRuleDraft,
  duplicateRule,
  removeRule,
  getRuleFieldValue,
  updateRuleDraft,
  isRuleFieldDirty,
}: Props) {
  return (
    <Collapse
      activeKey={groups.filter((group) => !collapsedGroupIds.includes(group.id)).map((group) => group.id)}
      onChange={(keys) => {
        const openKeys = (Array.isArray(keys) ? keys : [keys]).map((key) => String(key));
        setCollapsedGroupIds(groups.filter((group) => !openKeys.includes(group.id)).map((group) => group.id));
      }}
      items={groups.map((group) => {
        const groupRules = rulesByGroup.get(group.id) ?? [];
        const activeCount = groupRules.filter((rule) => isRuleEffectivelyEnabled(rule, groupEnabledMap)).length;

        return {
          key: group.id,
          label: (
            <div className="simple-group-head">
              <Space size={8}>
                <Switch
                  checked={group.enabled}
                  disabled={!redirectEnabled}
                  onClick={(_, e) => e.stopPropagation()}
                  onChange={(checked) => toggleGroupEnabled(group.id, checked)}
                />
                <Typography.Text strong>{group.name}</Typography.Text>
                <Typography.Text type="secondary">{activeCount}/{groupRules.length}</Typography.Text>
              </Space>
            </div>
          ),
          extra: (
            <Space size={6} onClick={(e) => e.stopPropagation()}>
              <Button type="text" size="small" className="simple-group-action-btn" icon={<PlusOutlined />} onClick={() => addRule(group.id)} />
              <Button type="text" size="small" className="simple-group-action-btn" icon={<EditOutlined />} onClick={() => openEditGroupModal(group.id)} />
              <Popconfirm title="删除分组？" description="该分组下规则会一并删除" okButtonProps={{ danger: true, type: 'default' }} onConfirm={() => removeGroup(group.id)}>
                <Button type="text" size="small" className="simple-group-action-btn" danger icon={<DeleteOutlined />} />
              </Popconfirm>
            </Space>
          ),
          children: groupRules.length === 0 ? (
            <Typography.Text type="secondary">暂无规则，点击右上角 + 添加规则。</Typography.Text>
          ) : (
            <SortableContext items={groupRules.map((rule) => rule.id)} strategy={verticalListSortingStrategy}>
              <Space direction="vertical" size={10} style={{ width: '100%' }}>
                {groupRules.map((rule) => {
                  const dirty = isRuleFieldDirty(rule, 'expression') || isRuleFieldDirty(rule, 'redirectUrl');
                  return (
                    <SortableRuleCard key={rule.id} rule={rule}>
                      {({ attributes, listeners }) => (
                        <div className={`simple-rule-card-content ${highlightedRuleId === rule.id ? 'simple-rule-card-highlighted' : ''}`}>
                          <div className="simple-rule-top-row">
                            <Space wrap size={8}>
                              <Button type="text" size="small" icon={<HolderOutlined />} className="simple-rule-drag-handle" {...attributes} {...listeners} />
                              <Switch
                                checked={rule.enabled}
                                disabled={!redirectEnabled || !group.enabled}
                                onChange={(checked) => updateRuleEnabled(rule.id, checked)}
                              />
                              <Select style={{ width: 120 }} value={rule.matchTarget} options={MATCH_TARGET_OPTIONS} onChange={(value) => updateRuleMatchTarget(rule.id, value)} />
                              <Select style={{ width: 120 }} value={rule.matchMode} options={MATCH_MODE_OPTIONS} onChange={(value) => updateRuleMatchMode(rule.id, value)} />
                            </Space>
                            <Space size={6}>
                              <Dropdown
                                trigger={['click']}
                                disabled={groups.length <= 1}
                                menu={{
                                  items: groups.filter((targetGroup) => targetGroup.id !== rule.groupId).map((targetGroup) => ({ key: targetGroup.id, label: targetGroup.name })),
                                  onClick: ({ key }) => moveRuleGroup(rule.id, String(key)),
                                }}
                              >
                                <Button type="text" icon={<SwapOutlined />} title="移动到其他分组" aria-label="移动到其他分组" />
                              </Dropdown>
                              <Button type="text" icon={<SaveOutlined />} title="保存规则" aria-label="保存规则" disabled={!dirty} onClick={() => saveRuleDraft(rule)} />
                              <Button type="text" icon={<CopyOutlined />} title="复制规则" aria-label="复制规则" onClick={() => duplicateRule(rule.id)} />
                              <Popconfirm title="删除规则？" okButtonProps={{ danger: true, type: 'default' }} onConfirm={() => removeRule(rule.id)}>
                                <Button type="text" danger icon={<DeleteOutlined />} title="删除规则" aria-label="删除规则" />
                              </Popconfirm>
                            </Space>
                          </div>
                          <div className="simple-rule-field">
                            <Typography.Text type="secondary">匹配表达式</Typography.Text>
                            <Input value={getRuleFieldValue(rule, 'expression')} placeholder="请输入用于匹配的表达式" onChange={(e) => updateRuleDraft(rule, 'expression', e.target.value)} />
                          </div>
                          <div className="simple-rule-field">
                            <Typography.Text type="secondary">重定向 URL</Typography.Text>
                            <Input value={getRuleFieldValue(rule, 'redirectUrl')} placeholder="请输入重定向目标 URL" onChange={(e) => updateRuleDraft(rule, 'redirectUrl', e.target.value)} />
                          </div>
                          {dirty ? (
                            <div className="simple-rule-save-row">
                              <Typography.Text type="warning">有未保存修改</Typography.Text>
                            </div>
                          ) : null}
                        </div>
                      )}
                    </SortableRuleCard>
                  );
                })}
              </Space>
            </SortableContext>
          ),
        };
      })}
    />
  );
}
