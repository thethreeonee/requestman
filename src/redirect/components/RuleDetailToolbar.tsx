import React from 'react';
import { Button, Dropdown, Select, Space, Switch, Typography } from 'antd';
import { ArrowLeftOutlined, EllipsisOutlined } from '@ant-design/icons';
import type { MenuProps } from 'antd';
import type { RedirectGroup } from '../types';

type Props = {
  groups: RedirectGroup[];
  groupId: string;
  enabled: boolean;
  dirty: boolean;
  onBack: () => void;
  onEnabledChange: (value: boolean) => void;
  onGroupChange: (groupId: string) => void;
  onTest: () => void;
  onSave: () => void;
  menuItems: MenuProps['items'];
};

export default function RuleDetailToolbar({
  groups,
  groupId,
  enabled,
  dirty,
  onBack,
  onEnabledChange,
  onGroupChange,
  onTest,
  onSave,
  menuItems,
}: Props) {
  return <div className="detail-header">
    <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}>返回</Button>
    <Space>
      <Typography.Text>启用规则</Typography.Text>
      <Switch checked={enabled} onChange={onEnabledChange} />
      <Dropdown menu={{ items: menuItems }}><Button icon={<EllipsisOutlined />} /></Dropdown>
      <Select
        value={groupId}
        style={{ width: 220 }}
        options={groups.map((g) => ({ value: g.id, label: `规则组：${g.name}` }))}
        onChange={onGroupChange}
        placeholder="规则组：请选择"
      />
      <Button onClick={onTest}>测试</Button>
      <Button type="primary" onClick={onSave}>{dirty ? '* 保存规则' : '保存规则'}</Button>
    </Space>
  </div>;
}
