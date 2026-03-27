import React, { useEffect, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/components/radix/dialog';
import { Brush } from '@/components/animate-ui/icons/brush';
import type { RedirectGroup, RedirectRule } from '../types';
import { t } from '../i18n';
import { renderRuleTypeIcon } from '../rule-type-meta';

type Props = {
  rule: RedirectRule;
  groups: RedirectGroup[];
  groupId: string;
  dirty: boolean;
  onGroupChange: (groupId: string) => void;
  onTest: () => void;
  onSave: () => boolean | void;
  onRename: (name: string) => void;
};

export default function RuleDetailToolbar({
  rule,
  groups,
  groupId,
  dirty,
  onGroupChange,
  onTest,
  onSave,
  onRename,
}: Props) {
  const [renameDialogOpen, setRenameDialogOpen] = useState(false);
  const [renameValue, setRenameValue] = useState(rule.name);

  useEffect(() => {
    setRenameValue(rule.name);
  }, [rule.name]);

  const confirmRename = () => {
    const nextName = renameValue.trim();
    if (!nextName) return;
    onRename(nextName);
    setRenameDialogOpen(false);
  };

  return <>
    <div className="detail-header">
      <div className="detail-header__title">
        <span className="detail-header__title-icon" aria-hidden="true">{renderRuleTypeIcon(rule.type)}</span>
        <span className="detail-header__title-text">{rule.name || t('未命名规则', 'Untitled rule')}</span>
        <Button
          variant="ghost"
          size="icon-sm"
          className="detail-header__rename-btn"
          aria-label={t('重命名规则', 'Rename rule')}
          onClick={() => setRenameDialogOpen(true)}
        >
          <Brush size={16} />
        </Button>
      </div>
      <div className="aui-space">
        <Select value={groupId || undefined} onValueChange={onGroupChange}>
          <SelectTrigger style={{ width: 220 }}>
            <SelectValue placeholder={t('规则组：请选择', 'Select group')} />
          </SelectTrigger>
          <SelectContent>
            {groups.map((g) => (
              <SelectItem key={g.id} value={g.id}>{t('规则组：', 'Group: ')}{g.name}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Button variant="outline" onClick={onTest}>{t('测试', 'Test')}</Button>
        <Button
          variant="default"
          disabled={!dirty}
          onClick={() => {
            onSave();
          }}
        >
          <span>{t('保存规则', 'Save rule')}</span>
        </Button>
      </div>
    </div>
    <Dialog open={renameDialogOpen} onOpenChange={setRenameDialogOpen}>
      <DialogContent showCloseButton>
        <DialogHeader>
          <DialogTitle>{t('重命名规则', 'Rename rule')}</DialogTitle>
        </DialogHeader>
        <Input
          autoFocus
          value={renameValue}
          onChange={(e) => setRenameValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') confirmRename();
          }}
          placeholder={t('请输入规则名称', 'Enter rule name')}
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => setRenameDialogOpen(false)}>{t('取消', 'Cancel')}</Button>
          <Button variant="default" onClick={confirmRename} disabled={!renameValue.trim()}>{t('确定', 'OK')}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </>;
}
