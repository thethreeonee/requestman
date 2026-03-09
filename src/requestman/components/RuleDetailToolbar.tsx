import React, { useEffect, useState } from 'react';
import { Button, Dropdown, Select, Space, Switch, Tooltip, Typography } from 'antd';
import { ArrowLeftOutlined, CheckOutlined, EllipsisOutlined } from '@ant-design/icons';
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
  onSave: () => boolean | void;
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
  const [showSaveSuccess, setShowSaveSuccess] = useState(false);

  useEffect(() => {
    if (!showSaveSuccess) return;
    const timer = window.setTimeout(() => setShowSaveSuccess(false), 2000);
    return () => window.clearTimeout(timer);
  }, [showSaveSuccess]);

  return <div className="detail-header">
    <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}>返回</Button>
    <Space>
      <Typography.Text type={enabled ? 'success' : 'secondary'}>{enabled ? '生效中' : '未生效'}</Typography.Text>
      <Switch checked={enabled} onChange={onEnabledChange} />
      <Dropdown menu={{ items: menuItems }}><Button icon={<EllipsisOutlined />} /></Dropdown>
      <Select
        value={groupId}
        style={{ width: 220 }}
        options={groups.map((g) => ({ value: g.id, label: `规则组：${g.name}` }))}
        labelRender={({ label }) => {
          const labelText = String(label ?? '');
          return <Tooltip title={labelText}>
            <span
              style={{
                display: 'inline-block',
                width: '100%',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {labelText}
            </span>
          </Tooltip>;
        }}
        onChange={onGroupChange}
        placeholder="规则组：请选择"
      />
      <Button onClick={onTest}>测试</Button>
      <Button
        type="primary"
        onClick={() => {
          const isSaved = onSave();
          if (isSaved) setShowSaveSuccess(true);
        }}
      >
        <Space size={4}>
          {showSaveSuccess ? <CheckOutlined /> : null}
          <span>{dirty ? '* 保存规则' : '保存规则'}</span>
        </Space>
      </Button>
    </Space>
  </div>;
}
