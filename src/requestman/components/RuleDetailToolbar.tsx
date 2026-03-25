import React, { useEffect, useState } from 'react';
import { Button, Select, Space, Switch, Typography } from '../primitives';
import { ArrowLeftOutlined, CheckOutlined, EllipsisVerticalOutlined } from '../icons';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import type { RequestmanDropdownMenuBaseItem } from '../dropdown-menu-types';
import type { RedirectGroup } from '../types';
import { t } from '../i18n';

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
  menuItems: RequestmanDropdownMenuBaseItem[];
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
    <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}>{t('返回', 'Back')}</Button>
    <Space>
      <Typography.Text type={enabled ? 'success' : 'secondary'}>{enabled ? t('生效中', 'Enabled') : t('未生效', 'Disabled')}</Typography.Text>
      <Switch checked={enabled} onChange={onEnabledChange} />
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <span>
            <Button size="icon-sm" icon={<EllipsisVerticalOutlined />} />
          </span>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" sideOffset={6}>
          {menuItems.map((item, index) => (
            <DropdownMenuItem
              key={item.key ?? `detail-toolbar-item-${index}`}
              disabled={item.disabled}
              variant={item.danger ? 'destructive' : 'default'}
              onMouseEnter={item.onMouseEnter}
              onMouseLeave={item.onMouseLeave}
              onSelect={() => item.onClick?.()}
            >
              {item.icon}
              {item.label}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
      <Select
        value={groupId}
        style={{ width: 220 }}
        options={groups.map((g) => ({ value: g.id, label: `${t('规则组：', 'Group: ')}${g.name}` }))}
        onChange={onGroupChange}
        placeholder={t('规则组：请选择', 'Select group')}
      />
      <Button onClick={onTest}>{t('测试', 'Test')}</Button>
      <Button
        type="primary"
        onClick={() => {
          const isSaved = onSave();
          if (isSaved) setShowSaveSuccess(true);
        }}
      >
        <Space size={4}>
          {showSaveSuccess ? <CheckOutlined /> : null}
          <span>{dirty ? `* ${t('保存规则', 'Save rule')}` : t('保存规则', 'Save rule')}</span>
        </Space>
      </Button>
    </Space>
  </div>;
}
